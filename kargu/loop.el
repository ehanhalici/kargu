;;; kargu/loop.el --- Agent run: send, stop, status -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; One run plist at a time.  Submodules implement compact, tools,
;; healing, and the event table (`kargu/loop/machine').
;; Requires: `kargu/api', `kargu/prompt', `kargu/history',
;; `kargu/tools/diff', `kargu/tools/lsp'.
;; Public: `kargu-loop-send', `kargu-loop-stop',
;; `kargu-loop-running-p', `kargu-loop-status'.

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
(require 'kargu/contract)
(require 'kargu/config)
(require 'kargu/prompt)
(require 'kargu/history)
(require 'kargu/history-compact)
(require 'kargu/api)
(require 'kargu/tools/diff)
(require 'kargu/tools/lsp)

(defgroup kargu-loop nil
  "The autonomous agent loop."
  :group 'kargu
  :prefix "kargu-loop-")

(defcustom kargu-loop-mutating-tools
  '("edit_file" "write_file" "edit" "write" "apply_patch" "patch" "bash" "debug_toggle_breakpoint"
    "git_commit" "git_stage" "git_unstage" "git_branch" "git_stash")
  "Tools that modify files, git history, or program state.
They are advertised and executable only in agent mode."
  :type '(repeat (string :tag "Tool name"))
  :group 'kargu-loop)

(defcustom kargu-loop-empty-retries 2
  "How many times to re-prompt after a tool-less empty model reply."
  :type 'natnum
  :group 'kargu-loop)

(defcustom kargu-loop-upstream-retries 3
  "How many times to resend after a retryable provider 502/overload.
History is left unchanged; no System Notice is injected.  This is
on top of HTTP-layer retries (`kargu-api-retry-max')."
  :type 'natnum
  :group 'kargu-loop)

(defvar kargu--loop-run nil
  "Plist of the run in progress; nil when idle.
Keys include :state, :prompt, :on-delta, :on-finish, :iterations,
:healing, :verifications, :empty-retries, :compactions,
:length-continues, :doom-sigs.")

(defvar kargu--loop-call-seq 0
  "Counter for synthesizing tool-call ids when a provider omits them.")

(defun kargu-loop--live-p (run)
  "Non-nil when RUN is still the active loop."
  (eq run kargu--loop-run))

(defun kargu-loop--set-state (run state)
  "Set RUN `:state' to STATE."
  (plist-put run :state state)
  state)

(defun kargu-loop--tool-visible-p (name)
  "Return non-nil when tool NAME may be advertised to the model."
  (and (not (plist-get kargu--loop-run :no-tools))
       (or (not (member name kargu-loop-mutating-tools))
           (eq kargu-active-mode 'agent))))

(defun kargu-loop--gate-tool (name)
  "Return an error string when NAME may not run in the active mode."
  (when (and (member name kargu-loop-mutating-tools)
             (not (eq kargu-active-mode 'agent)))
    (format
     "ERROR: tool `%s' is disabled in %s mode (read-only); switch to agent mode (M-x kargu-set-mode) before modifying files or debugger state"
     name kargu-active-mode)))

(setq kargu--tools-visible-p #'kargu-loop--tool-visible-p)

(defun kargu-loop-running-p ()
  "Return non-nil while an agent run is in progress."
  (not (null kargu--loop-run)))

(defun kargu-loop-stop (&optional reason)
  "Stop the agent run in progress, if any."
  (interactive)
  (if (null kargu--loop-run)
      (message "kargu: no run in progress")
    (kargu-api-cancel)
    (kargu--loop-finish kargu--loop-run
                        :stopped
                        (or reason "stopped by the user"))))

(defun kargu-loop-status ()
  "Return a short loop state string; message it when interactive."
  (interactive)
  (let ((report
         (if (null kargu--loop-run)
             "idle"
           (format
            "running: state %s, iteration %d/%d, healing rounds %d/%d, verifications %d, model request %s"
            (or (plist-get kargu--loop-run :state) 'request)
            (or (plist-get kargu--loop-run :iterations) 0)
            kargu-max-iterations
            (or (plist-get kargu--loop-run :healing) 0)
            kargu-max-healing-steps
            (or (plist-get kargu--loop-run :verifications) 0)
            (if (kargu-busy-p) "in flight" "local work")))))
    (when (called-interactively-p 'any)
      (message "kargu loop: %s" report))
    report))

(defun kargu-loop--message-report (report)
  "Default ON-FINISH handler: echo the run outcome."
  (message "kargu: %s — %s"
           (plist-get report :status)
           (truncate-string-to-width
            (let ((text (plist-get report :text))
                  (err (plist-get report :error)))
              (if (and (stringp text) (not (string-empty-p text)))
                  text
                (or err "")))
            120)))

(defun kargu-loop-send (prompt &optional on-delta on-finish)
  "Start an agent run with PROMPT (a non-empty string)."
  (interactive "skargu prompt: ")
  (when (kargu-loop-running-p)
    (user-error "kargu: a run is already in progress (M-x kargu-loop-stop)"))
  (kargu-contract-assert #'kargu-contract-non-empty-string-p prompt
                         "kargu: prompt must be a non-empty string: %S" prompt)
  (kargu-contract-assert #'kargu-contract-callback-p on-delta
                         "kargu: on-delta must be callable or nil: %S" on-delta)
  (kargu-contract-assert #'kargu-contract-callback-p on-finish
                         "kargu: on-finish must be callable or nil: %S" on-finish)
  (let ((run (list :prompt prompt
                   :state 'request
                   :on-delta on-delta
                   :on-finish (or on-finish
                                  #'kargu-loop--message-report)
                   :iterations 0
                   :healing 0
                   :verifications 0
                   :empty-retries 0
                   :upstream-retries 0
                   :compactions 0
                   :length-continues 0
                   :doom-sigs nil)))
    (when (fboundp 'kargu-diff-reset-run-files)
      (kargu-diff-reset-run-files))
    (setq kargu--loop-run run)
    (plist-put kargu--session :active t)
    (kargu-log 'info "run start (mode=%s, model=%s)"
               kargu-active-mode (kargu--model))
    (kargu--loop-request run (kargu-prompt-wrap-user prompt))
    run))

(defun kargu--loop-finish (run status &optional text)
  "End RUN with STATUS and TEXT; deliver the report to on-finish."
  (when (kargu-loop--live-p run)
    (let ((report (list :status status
                        :text (if (eq status :error) "" (or text ""))
                        :iterations (or (plist-get run :iterations) 0)
                        :healing (or (plist-get run :healing) 0)
                        :verifications
                        (or (plist-get run :verifications) 0))))
      (when (eq status :error)
        (plist-put report :error (or text "unknown error")))
      (when (fboundp 'kargu-diff-run-modified-files)
        (when-let* ((modified (kargu-diff-run-modified-files)))
          (plist-put report :modified-files (copy-sequence modified))))
      (let ((pending (kargu-diff-changed-files)))
        (when pending
          (plist-put report :pending-files pending)
          (kargu-log 'warn
                     "run end with %d unconsumed changed file(s)"
                     (length pending))))
      (setq kargu--loop-run nil)
      (setq kargu--compaction-system nil)
      (plist-put kargu--session :active nil)
      (kargu--validate-history)
      (kargu-log 'info "run end: %s (iterations=%d, healing=%d)"
                 status
                 (plist-get report :iterations)
                 (plist-get report :healing))
      (condition-case-unless-debug err
          (let ((on-finish (plist-get run :on-finish)))
            (when on-finish
              (funcall on-finish report)))
        (error
         (kargu-log 'error "on-finish callback failed: %s"
                    (error-message-string err))))
      report)))

(defun kargu-loop--reset-guard (&rest _args)
  "Stop a running agent loop before the session resets."
  (when (kargu-loop-running-p)
    (kargu-loop-stop "session reset")))

(advice-add 'kargu-session-reset :before #'kargu-loop--reset-guard)

(require 'kargu/loop/compact)
(require 'kargu/loop/tools)
(require 'kargu/loop/heal)
(require 'kargu/loop/machine)

(kargu-log 'info "loop module loaded")

(provide 'kargu/loop)

;;; kargu/loop.el ends here
