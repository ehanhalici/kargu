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
     (mapconcat
      (lambda (name)
        (format "- `%s`: %s" name (kargu-tool-description name)))
      (sort (seq-filter #'kargu-tool-visible-p (kargu-registered-tools))
            #'string<)
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
    kargu--environment-block
    kargu-prompt--tools-guidance-block
    kargu-prompt--instruction-block
    kargu-prompt--skills-block
    kargu-prompt--mode-block)
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
        (and kargu--compaction-system t)))

(defun kargu--get-system-prompt ()
  "Return the system prompt for the active mode.
During compaction, `kargu--compaction-system' replaces this."
  (or kargu--compaction-system
      (string-join
       (delq nil (mapcar (lambda (fn)
                           (let ((s (funcall fn)))
                             (and (stringp s) (not (string-empty-p (string-trim s))) s)))
                         kargu-prompt--parts))
       "\n\n")))

(defun kargu-prompt-debug-message ()
  "Construct the debug mode message for the AI with LSP schema and guidance."
  (let* ((skeleton (when (fboundp 'kargu-lsp-build-skeleton)
                     (condition-case nil
                         (let ((s (kargu-lsp-build-skeleton)))
                           (if (and (stringp s) (not (string-prefix-p "ERROR:" s)))
                               s
                             nil))
                       (error nil))))
         (ctx (if (fboundp 'kargu-dape-context-snapshot)
                  (kargu-dape-context-snapshot)
                nil))
         (ctx-str (if (and (stringp ctx) (not (string-prefix-p "ERROR:" ctx)))
                      (format "Current debugger state:\n%s\n\n" ctx)
                    ""))
         (lang-guidance (if (fboundp 'kargu-language-prompt-guidance)
                            (kargu-language-prompt-guidance (and (fboundp 'kargu-language-active)
                                                                 (kargu-language-active)))
                          "")))
    (concat
     "<system-reminder>\n"
     "Şu anda DEBUG modundasın. / You are currently in DEBUG mode.\n\n"
     (if (and (stringp lang-guidance) (not (string-empty-p lang-guidance)))
         (concat lang-guidance "\n\n")
       "")
     (if skeleton
         (format "Kodun LSP şeması (semboller tablosu) / Code LSP schema:\n```\n%s\n```\n\n" skeleton)
       "Kodun LSP şeması / Code LSP schema: (LSP/eglot sembol tablosu henüz hazır değil; `lsp_project_skeleton' ile bakabilirsin)\n\n")
     "Debug başladı ve şu an çalışmıyor (girişte duraklatıldı). İstediğin yerlere breakpoint koyup run edebilirsin.\n"
     "Debugger started and is currently paused at entry. You can place breakpoints where you want and run/continue.\n\n"
     "ÖNEMLİ (Çoklu Komut): Aynı anda birden fazla komut (tool call) gönderebilirsin! Gönderdiğin komutlar sırayla arka arkaya çalıştırılıp çıktıları sana topluca dönecektir.\n"
     "IMPORTANT (Multi-Tool Calling): You can call MULTIPLE tools in a single turn! They will be executed sequentially and all their outputs returned together.\n"
     "Örnekler / Examples:\n"
     "- Debug: `debug_set_breakpoint' ile (file_path ve line vererek, örn: {\"file_path\": \"src/main.rs\", \"line\": 42}) breakpoint koyup hemen ardından aynı turda `debug_continue' (run) diyebilirsin; program breakpoint'e gelene kadar koşup durduğunda hem breakpoint onayı hem de duraklanan konumun kaynak kodu, stack ve değişkenleri tek seferde sana döner.\n"
     "- İnceleme: `list_files', `workspace_grep', `read_file', `git_status' gibi komutları tek bir turda topluca gönderebilirsin.\n\n"
     ctx-str
     "Kullanabileceğin 20 debug komutu: `debug_set_breakpoint', `debug_clear_breakpoint', `debug_toggle_breakpoint', `debug_list_breakpoints', `debug_continue' (run), `debug_step_over' (next), `debug_step_in' (step), `debug_step_out' (out/finish), `debug_pause', `debug_up', `debug_down', `debug_threads', `debug_stack', `debug_modules', `debug_sources', `debug_scope', `debug_watch', `debug_eval', `debug_restart', `debug_kill', `debug_disconnect', `debug_quit'.\n"
     "Tavsiye / Tip: Değişkenleri ve koleksiyon uzunluklarını görmek için eval çalıştırmadan önce duraklama anında listelenen in-scope variables'a (`debug_scope' / `debug_get_context') bakınız.\n"
     "</system-reminder>")))

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
