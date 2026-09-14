;;; kargu/prompt.el --- System prompt assembly -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Builds the system prompt in OpenCode order: provider-specific
;; base, environment, project instructions, skills catalog, then a
;; short mode paragraph.  A per-mode `<system-reminder>' is appended
;; to real user turns.  Requires: `kargu/core', `kargu/config'.
;; Public: `kargu--get-system-prompt', `kargu-prompt-wrap-user',
;; `kargu-prompt-clear-cache'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory (Magit-style kargu/core features).
(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'kargu/core)
(require 'kargu/config)
(require 'kargu/state/selectors)
(require 'kargu/tools/toolchain)

(defvar kargu--compaction-system nil
  "When non-nil, `kargu--get-system-prompt' returns this string.")

(defgroup kargu-prompt nil
  "System prompt and instruction-file injection."
  :group 'kargu
  :prefix "kargu-prompt-")

(defcustom kargu-instruction-files '("AGENTS.md" "CLAUDE.md" "CONTEXT.md")
  "Project-root filenames tried in order for extra system instructions."
  :type '(repeat string)
  :group 'kargu-prompt)

(defcustom kargu-instruction-max-chars 20000
  "Character cap for the injected project instruction file."
  :type 'natnum
  :group 'kargu-prompt)

(defconst kargu-prompt--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of `kargu/prompt.el', parent of `prompt/*.txt'.")

(defconst kargu-prompt-mode-reminders
  '((ask . "<system-reminder>\nThis is a read-only ASK turn. Analyze and explain. Do not call edit_file, write_file, edit, write, or bash. If a change is needed, describe it as a proposal with paths and line numbers.\n</system-reminder>")
    (plan . "<system-reminder>\nThis is a READ-ONLY PLAN turn. Explore with read_file/read, workspace_grep/grep, find_files_by_glob/glob, and LSP tools. Do not call edit_file, write_file, or bash. Produce a markdown checklist: steps, full file paths, symbols to change (verify they exist), risks, and a test strategy.\n</system-reminder>")
    (debug . "<system-reminder>\nThis is DEBUG mode. Ground the analysis in DAP/runtime evidence (debug_get_context, debug_eval) and lsp_diagnostics. Do not apply file edits unless the user explicitly asked.\n</system-reminder>")
    (agent . "<system-reminder>\nAGENT mode: inspect with tools, surgical edit_file/write_file, verify with Flycheck/LSP diagnostics, and run the project compiler/test suite via bash. Be concise. Do not narrate tool plans in assistant text.\n</system-reminder>"))
  "Alist of mode symbol to per-turn `<system-reminder>' text.")

(defvar kargu-prompt--file-cache (make-hash-table :test #'equal)
  "Map basename to loaded prompt file text.")

(defvar kargu-prompt--env-cache nil
  "Plist cache: :time :root :git-repo :branch :instructions.")

(defconst kargu-prompt--env-ttl 5.0
  "Seconds to reuse `kargu-prompt--env-cache'.")

(defun kargu-prompt-clear-cache ()
  "Drop the environment / instruction / prompt-file cache."
  (setq kargu-prompt--env-cache nil)
  (clrhash kargu-prompt--file-cache))

(defun kargu-prompt--read-file (basename)
  "Return text of prompt/BASENAME, or nil."
  (or (gethash basename kargu-prompt--file-cache)
      (let ((path (expand-file-name (concat "prompt/" basename)
                                    kargu-prompt--directory)))
        (when (file-readable-p path)
          (puthash basename
                   (with-temp-buffer
                     (insert-file-contents path)
                     (buffer-string))
                   kargu-prompt--file-cache)))))

(defun kargu-prompt--provider-base ()
  "Provider-specific base prompt for `kargu--model'."
  (let ((id (downcase (or (kargu--model) ""))))
    (or (cond
         ((or (string-match-p "gpt-4" id)
              (string-match-p "\\bo1\\b" id)
              (string-match-p "\\bo3\\b" id))
          (kargu-prompt--read-file "beast.txt"))
         ((and (string-match-p "gpt" id) (string-match-p "codex" id))
          (kargu-prompt--read-file "gpt.txt"))
         ((string-match-p "gpt" id)
          (kargu-prompt--read-file "gpt.txt"))
         ((string-match-p "gemini-" id)
          (kargu-prompt--read-file "gemini.txt"))
         ((string-match-p "claude" id)
          (kargu-prompt--read-file "anthropic.txt"))
         ((or (string-match-p "kimi" id)
              (string-match-p "moonshot" id))
          (kargu-prompt--read-file "kimi.txt"))
         (t nil))
        (kargu-prompt--read-file "default.txt")
        "You are kargu, an expert software engineer running inside GNU Emacs.")))

(defun kargu-prompt--workspace ()
  "Absolute workspace / project root directory."
  (file-name-as-directory
   (expand-file-name
    (or (and (fboundp 'kargu--project-root)
             (ignore-errors (kargu--project-root)))
        default-directory))))

(defun kargu-prompt--git-info (root)
  "Return (REPO-P . BRANCH) for ROOT with a single git invocation."
  (let ((default-directory root))
    (if (not (executable-find "git"))
        (cons nil "(none)")
      (with-temp-buffer
        (if (eq 0 (call-process "git" nil t nil
                                "rev-parse" "--abbrev-ref" "HEAD"))
            (let ((branch (string-trim (buffer-string))))
              (cons t (if (string-empty-p branch) "(none)" branch)))
          (cons nil "(none)"))))))

(defun kargu-prompt--read-instructions (root)
  "Load the first readable instruction file under ROOT, or nil."
  (let (found)
    (dolist (name kargu-instruction-files)
      (unless found
        (let ((path (expand-file-name name root)))
          (when (and (file-regular-p path) (file-readable-p path))
            (setq found path)))))
    (when found
      (let* ((limit kargu-instruction-max-chars)
             (size (file-attribute-size (file-attributes found)))
             (raw (with-temp-buffer
                    (insert-file-contents found nil nil
                                          (and size (min size limit)))
                    (buffer-string)))
             (capped (if (and size (> size limit))
                         (concat raw "\n... [truncated]\n")
                       raw)))
        (format "Instructions from: %s\n%s" found capped)))))

(defun kargu-prompt--cached-env (root)
  "Return cached env plist for ROOT, refreshing when stale."
  (if (and kargu-prompt--env-cache
           (equal (plist-get kargu-prompt--env-cache :root) root)
           (< (- (float-time)
                 (or (plist-get kargu-prompt--env-cache :time) 0))
              kargu-prompt--env-ttl))
      kargu-prompt--env-cache
    (let* ((git (kargu-prompt--git-info root))
           (cache (list :time (float-time)
                        :root root
                        :git-repo (car git)
                        :branch (cdr git)
                        :instructions (kargu-prompt--read-instructions root))))
      (setq kargu-prompt--env-cache cache)
      cache)))

(defun kargu-prompt--detect-toolchain (root)
  "Detect the primary language and toolchain for ROOT.
Uses the Strategy Pattern registry in `kargu/tools/toolchain'."
  (kargu-toolchain-detect root))

(defun kargu-prompt--toolchain-block (root)
  "Format the detected toolchain XML block for ROOT."
  (let ((tc (kargu-prompt--detect-toolchain root)))
    (if tc
        (concat
         "<project_toolchain>\n"
         (format "  Language: %s\n" (plist-get tc :language))
         (format "  Build / Compiler: %s\n" (plist-get tc :build-cmd))
         (format "  Test command: %s\n" (plist-get tc :test-cmd))
         (format "  Notes: %s\n" (plist-get tc :notes))
         "  Flycheck / LSP: Active. Edits are checked automatically for syntax and compiler errors.\n"
         "  Execution: In agent mode, use `bash' to run build and test commands.\n"
         "  Verification Rule: Always verify that tests pass and no compile errors remain before concluding your work.\n"
         "</project_toolchain>\n")
      (concat
       "<project_toolchain>\n"
       "  Language: Not automatically detected\n"
       "  Flycheck / LSP: Active. Edits are checked automatically for syntax and compiler errors.\n"
       "  Execution: In agent mode, use `bash' to run the project's build and test commands.\n"
       "  Verification Rule: Inspect the repo for build/test tools and run them with `bash' before concluding your work.\n"
       "</project_toolchain>\n"))))

(defun kargu--environment-block ()
  "XML environment snapshot injected into the system prompt."
  (let* ((root (kargu-prompt--workspace))
         (env (kargu-prompt--cached-env root)))
    (concat
     (format "You are powered by the model named %s.\n" (kargu--model))
     "Here is some useful information about the environment you are running in:\n"
     "<env>\n"
     (format "  Working directory: %s\n" root)
     (format "  Workspace root folder: %s\n" root)
     (format "  Is directory a git repo: %s\n"
             (if (plist-get env :git-repo) "yes" "no"))
     (format "  Platform: %s\n" (kargu--os-description))
     (format "  Today's date: %s\n" (format-time-string "%Y-%m-%d"))
     (format "  Emacs: %s\n" emacs-version)
     (format "  Shell: %s\n" (kargu--shell-description))
     (format "  Git Branch: %s\n" (or (plist-get env :branch) "(none)"))
     (format "  Context file: %s\n"
             (or (kargu--context-file-name) "(none)"))
     (format "  Mode: %s\n" (kargu-state-mode))
     "</env>\n\n"
     (kargu-prompt--toolchain-block root))))

(defun kargu-prompt--tools-guidance-block ()
  "Tools capability and recommendation block."
  (let* ((fd (or (executable-find "fd") (executable-find "fdfind")))
         (rg (executable-find "rg")))
    (concat
     "<available_tools_guidance>\n"
     "  Inspection tools (available in all modes):\n"
     (if fd
         "  - `fd` is available and recommended for finding files (preferred over `find`).\n"
       "  - `find` is available for file discovery.\n")
     (if rg
         "  - `rg` (ripgrep) is available and recommended for searching code (preferred over `grep`).\n"
       "  - `grep` is available for searching code.\n")
     "  - `list_files` (or `ls`) is available for listing directory contents.\n"
     "  - Git inspection tools (`git_status`, `git_diff`, `git_log`, `git_blame`) are available in all modes.\n"
     "  Execution tools (agent mode only):\n"
     "  - `bash` tool is active to run project commands. You are free to pick appropriate toolchains (e.g. `uv` or `python` for Python, `go` for Golang, `cargo` for Rust, `npm` for Node).\n"
     "  - Git mutating tools (`git_commit`, `git_stage`, `git_unstage`, `git_branch`, `git_stash`) and file modification tools (`edit_file`, `write_file`) are available.\n"
     "</available_tools_guidance>")))

(defun kargu-prompt--instruction-block ()
  "Cached project instruction file text, or nil."
  (plist-get (kargu-prompt--cached-env (kargu-prompt--workspace))
             :instructions))

(defun kargu-prompt--skills-block ()
  "Skills catalog for the system prompt, or nil."
  (when (fboundp 'kargu-skill-format-catalog)
    (kargu-skill-format-catalog)))

(defun kargu-prompt--mode-block ()
  "Mode-specific system paragraph."
  (let ((mode (kargu-state-mode)))
    (or (cdr (assq mode kargu-mode-system-prompts))
        (cdr (assq 'ask kargu-mode-system-prompts)))))

(defconst kargu-prompt--parts
  '(kargu-prompt--provider-base
    kargu--environment-block
    kargu-prompt--tools-guidance-block
    kargu-prompt--instruction-block
    kargu-prompt--skills-block
    kargu-prompt--mode-block)
  "Ordered functions whose non-empty strings form the system prompt.")

(defun kargu--get-system-prompt ()
  "Return the system prompt for `kargu-active-mode'.
During compaction, `kargu--compaction-system' replaces this."
  (or kargu--compaction-system
      (string-join
       (delq nil (mapcar (lambda (fn)
                           (let ((s (funcall fn)))
                             (and (stringp s) (not (string-empty-p (string-trim s))) s)))
                         kargu-prompt--parts))
       "\n\n")))

(defun kargu-prompt-mode-reminder ()
  "Per-turn `<system-reminder>' for `kargu-active-mode', or nil."
  (let ((mode (kargu-state-mode)))
    (cdr (assq mode kargu-prompt-mode-reminders))))

(defconst kargu-prompt--synthetic-prefixes
  '("System Notice:" "<system-reminder>" "COMPACTION_REQUEST:" "COMPACTION_ACK:")
  "User-turn prefixes that are loop-injected, not human text.")

(defun kargu-prompt-synthetic-user-p (prompt)
  "Non-nil when PROMPT is a loop-injected notice, not a human turn."
  (or (null prompt)
      (string-empty-p prompt)
      (equal prompt "Continue.")
      (cl-some (lambda (p) (string-prefix-p p (string-trim prompt)))
               kargu-prompt--synthetic-prefixes)))

(defun kargu-prompt-wrap-user (prompt)
  "Append the mode `<system-reminder>' to a real user PROMPT."
  (let ((rem (kargu-prompt-mode-reminder)))
    (if (or (null rem) (kargu-prompt-synthetic-user-p prompt))
        prompt
      (concat prompt "\n\n" rem))))

(defconst kargu-prompt-compaction-user
  (concat
   "COMPACTION_REQUEST: Summarize the conversation so far for another "
   "coding agent. Output a structured summary with these headings: "
   "Goal, Done, Files and symbols touched, Open issues, Next step. "
   "Use exact paths. Do not continue the task. Do not call tools. "
   "Reply with the summary only.")
  "User message for a tools-off compaction turn.")

(defconst kargu-prompt-compaction-system
  (concat
   "You are a context summarization assistant. "
   "Produce a structured summary of the given conversation so another "
   "coding agent can continue. Follow the headings requested by the user. "
   "Do not answer the user's original task. Do not call tools.")
  "System prompt used only during a tools-off compaction turn.")

(defconst kargu-prompt-max-steps-nudge
  "<system-reminder>\nThis is the last model turn of the run. Tools are no longer available. Summarize what you did and what remains. Do not call tools.\n</system-reminder>"
  "User nudge on the final iteration when tools are hidden.")

(provide 'kargu/prompt)

;;; kargu/prompt.el ends here
