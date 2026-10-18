;;; prompt.el --- System prompt assembly -*- lexical-binding: t; -*-

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
(require 'kargu/core)
(require 'kargu/config)
(require 'kargu/state/selectors)
(require 'kargu/tools/toolchain)
(require 'kargu/languages)
(require 'kargu/api/cache)

(declare-function kargu-tools-enabled-p "kargu/loop" (&optional run))
(declare-function kargu-provider-prompt-file "kargu/providers/registry" (model-id))
(declare-function kargu-lsp-build-skeleton "kargu/tools/lsp/skeleton" (&optional refresh))
(declare-function kargu-dape-live-p "kargu/tools/dape/session")
(declare-function kargu-dape-context-snapshot "kargu/tools/dape/context")

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

(defvar kargu-prompt--file-cache (make-hash-table :test #'equal)
  "Map basename to loaded prompt file text.")

(defvar kargu-prompt--env-cache nil
  "Plist cache: :time :root :git-repo :branch :instructions.")

(defconst kargu-prompt--env-ttl 5.0
  "Seconds to reuse `kargu-prompt--env-cache'.")

(declare-function kargu-permission-project-root "kargu/permission/guards" (&optional buffer))

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

(defun kargu-prompt--plain-base ()
  "Base prompt for a model that cannot call tools.
No tool name appears here.  The request will not include a tools schema."
  "You are kargu, an expert software engineer running inside GNU Emacs.
Answer in plain text. Do not invent function-call markup.
Be concise. State what you found. No greetings, no preamble.
Do not add comments to code unless the user asked. Match existing style.
Never commit unless the user explicitly asks.")

(defun kargu-prompt--catalog-base (model-id)
  "Base prompt file named by the provider catalog for MODEL-ID."
  (let ((file (and (fboundp 'kargu-provider-prompt-file)
                   (kargu-provider-prompt-file model-id))))
    (or (and file (kargu-prompt--read-file file))
        (kargu-prompt--read-file "default.txt")
        "You are kargu, an expert software engineer running inside GNU Emacs.")))

(defun kargu-prompt--provider-base ()
  "Base prompt for the active model.
A model that cannot call tools gets a plain base with no tool names.
The file for a tool-capable model comes from the provider catalog record."
  (if (kargu-prompt--tools-off-p)
      (kargu-prompt--plain-base)
    (kargu-prompt--catalog-base (or (kargu--model) ""))))

(defvar kargu-context-buffer)

(defun kargu-prompt--context-file-name ()
  "File name of `kargu-context-buffer', or nil."
  (cond
   ((and (boundp 'kargu-context-buffer)
         (bufferp kargu-context-buffer)
         (buffer-live-p kargu-context-buffer))
    (or (buffer-file-name kargu-context-buffer)
        (buffer-name kargu-context-buffer)))
   ((and (boundp 'kargu-context-buffer)
         (stringp kargu-context-buffer)
         (not (string-empty-p kargu-context-buffer)))
    kargu-context-buffer)
   (t nil)))

(defun kargu--os-description ()
  "Short OS / CPU string for the environment block."
  (format "%s (%s)"
          (pcase system-type
            ('gnu/linux "linux")
            ('darwin "darwin")
            ('windows-nt "windows")
            (sym (symbol-name sym)))
          (car (split-string system-configuration "-"))))

(defun kargu--shell-description ()
  "Login shell path for the environment block."
  (or (getenv "SHELL")
      (and (boundp 'shell-file-name) shell-file-name)
      "unknown"))

(defun kargu-prompt--workspace ()
  "Absolute workspace / project root directory."
  (kargu-permission-project-root))

(defun kargu-prompt--git-dir (root)
  "The git directory of the repository containing ROOT, or nil.
A worktree or submodule has a `.git' file that names the real directory."
  (when-let* ((top (locate-dominating-file root ".git")))
    (let ((dot-git (expand-file-name ".git" top)))
      (if (file-directory-p dot-git)
          dot-git
        (with-temp-buffer
          (insert-file-contents dot-git nil 0 1000)
          (when (re-search-forward "^gitdir: *\\(.+\\)$" nil t)
            (expand-file-name (match-string 1) top)))))))

(defun kargu-prompt--git-info (root)
  "Return repository status and branch for ROOT by reading Git HEAD."
  (let* ((git-dir (ignore-errors (kargu-prompt--git-dir root)))
         (head (and git-dir (expand-file-name "HEAD" git-dir))))
    (if (not (and head (file-readable-p head)))
        (cons nil "(none)")
      (with-temp-buffer
        (insert-file-contents head nil 0 500)
        (cons t (if (re-search-forward "^ref: refs/heads/\\(.+\\)$" nil t)
                    (match-string 1)
                  "HEAD"))))))

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
                         (format "%s\n... [instructions truncated: first %d of %d bytes shown]\n"
                                 raw limit size)
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
         (kargu-prompt--lsp-status)
         "  Execution: In agent mode, use `bash' to run build and test commands.\n"
         "  Verification Rule: Always verify that tests pass and no compile errors remain before concluding your work.\n"
         "</project_toolchain>\n")
      (concat
       "<project_toolchain>\n"
       "  Language: Not automatically detected\n"
       (kargu-prompt--lsp-status)
       "  Execution: In agent mode, use `bash' to run the project's build and test commands.\n"
       "  Verification Rule: Inspect the repo for build/test tools and run them with `bash' before concluding your work.\n"
       "</project_toolchain>\n"))))

(defun kargu-prompt--lsp-status ()
  "Describe actual project LSP availability without promising diagnostics."
  (if (kargu-eglot-connected-p)
      "  Flymake / LSP: Connected; request diagnostics explicitly.\n"
    "  Flymake / LSP: Unavailable; use available file/search tools and project tests.\n"))

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
             (or (kargu-prompt--context-file-name) "(none)"))
     (format "  Mode: %s\n" (kargu-state-mode))
     "</env>\n\n"
     (kargu-prompt--toolchain-block root))))

(defun kargu-prompt--tools-off-p ()
  "Return non-nil when the active request cannot use tools."
  (not (kargu-tools-enabled-p)))

(defconst kargu-prompt--no-tools-reminder
  "<system-reminder>\nThis model cannot call tools. Answer in plain text. Do not invent function-call markup.\n</system-reminder>"
  "Reminder used when the active model has no tool calling.")

(declare-function kargu-registered-tools "kargu/api/tools" ())
(declare-function kargu-advertised-tools "kargu/api/tools" ())
(declare-function kargu-tool-description "kargu/api/tools" (name))
(declare-function kargu-tool-visible-p "kargu/api/tools" (name))
(declare-function kargu-eglot-connected-p "kargu/tools/lsp/context" ())

(defun kargu-prompt--tools-guidance-block ()
  "Describe only tools available to the active request."
  (unless (kargu-prompt--tools-off-p)
    (concat
     "<available_tools_guidance>\n"
     "You can call MULTIPLE tools in one turn; execution is sequential.\n"
     "Search first; read only relevant line ranges. Use structural tools "
     "when available. Verify edits with available diagnostics and tests.\n"
     (if kargu-low-usage-mode
         "Low usage mode: use targeted searches, small line ranges and concise results. Do not repeat unchanged file reads or request whole-project dumps.\n"
       "")
     (mapconcat
      (lambda (name)
        (format "- `%s`: %s" name (kargu-tool-description name)))
      (kargu-advertised-tools)
      "\n")
     "\n</available_tools_guidance>")))

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
    kargu-prompt--instruction-block
    kargu-prompt--skills-block
    kargu-prompt--mode-block
    kargu-prompt--tools-guidance-block)
  "Ordered functions whose non-empty strings form the system prompt.")

(defvar kargu--system-key nil
  "Value of `kargu-prompt-system-key' the stored system message was built for.")

(defun kargu-prompt-system-key ()
  "Everything the system prompt text depends on that can change mid-session.
When this differs from `kargu--system-key' the stored system message is stale."
  (list (kargu-state-mode)
        (and (kargu-prompt--tools-off-p) t)
        (kargu--model)
        (and (kargu-eglot-connected-p) t)
        (and kargu--compaction-system t)
        (kargu-prompt--workspace)
        (kargu-prompt--context-file-name)
        (format-time-string "%Y-%m-%d")
        (kargu-prompt--cached-env (kargu-prompt--workspace))
        (kargu-advertised-tools)
        kargu-low-usage-mode))

(defun kargu--get-system-prompt ()
  "Return the system prompt for the active mode.
During compaction, `kargu--compaction-system' replaces this."
  (or kargu--compaction-system
      (string-join
       (append
        (delq nil (mapcar (lambda (fn)
                            (let ((s (funcall fn)))
                              (and (stringp s) (not (string-empty-p (string-trim s))) s)))
                          kargu-prompt--parts))
        (list (concat kargu-cache-runtime-boundary (kargu--environment-block)
                      "</runtime_environment>")))
       "\n\n")))

(declare-function kargu-dape-tool-guide "kargu/tools/dape/policy" ())

(defun kargu-prompt-debug-message ()
  "Explain the debugger workflow using observed state and available tools."
  (let ((context (and (fboundp 'kargu-dape-context-snapshot)
                      (kargu-dape-context-snapshot)))
        (language (and (fboundp 'kargu-language-prompt-guidance)
                       (kargu-language-prompt-guidance (kargu-language-active)))))
    (concat
     "<system-reminder>\nYou are in DEBUG mode, not a shell-based debugger.\n"
     "The tools connect to Emacs Dape and its language-specific DAP adapter. "
     "Do not start a second debugger, invent commands, or assume the target is paused. "
     "Only advertised tools are available; availability changes with session state "
     "and adapter capabilities. Files remain read-only in this mode.\n"
     "Workflow: inspect the observed state, set a file/line breakpoint, continue, "
     "then inspect the stopped stack and scopes. Use returned frame, thread and "
     "variable identifiers, never guessed ones. Evaluate only when needed; "
     "expressions can execute code and change the target. "
     "A running/timeout report is not evidence that a breakpoint was reached. "
     "Pause before inspecting a running target. Tool calls execute sequentially.\n"
     (or language "") "\nObserved debugger state:\n" (or context "Unknown") "\n"
     "Currently available debugger tools:\n"
     (if (fboundp 'kargu-dape-tool-guide) (kargu-dape-tool-guide) "")
     "\n</system-reminder>")))

(defun kargu-prompt-mode-reminder ()
  "Per-turn `<system-reminder>' for the active mode, or nil.
A model that cannot call tools gets a plain-text reminder instead of
a list of tool names."
  (if (kargu-prompt--tools-off-p)
      kargu-prompt--no-tools-reminder
    (let ((mode (kargu-state-mode)))
      (if (eq mode 'debug)
          (kargu-prompt-debug-message)
        (format "<system-reminder>\n%s Use only advertised tools and respect their permissions.\n</system-reminder>"
                (kargu-prompt--mode-block))))))

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

(provide 'kargu/prompt)

;;; prompt.el ends here
