;;; loop.el --- Agent run: send, stop, status -*- lexical-binding: t; -*-

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
(require 'kargu/core)
(require 'kargu/contract)
(require 'kargu/state)
(require 'kargu/config)
(require 'kargu/prompt)
(require 'kargu/history)
(require 'kargu/history/compact)
(require 'kargu/api)
(require 'kargu/edit)
(require 'kargu/tools/deps nil t)
(require 'kargu/confirm)

(declare-function kargu-model-supports-tools-p "kargu/api/catalog" (&optional model-id provider))
(declare-function kargu-session-project-root "kargu/chat/session" (&optional buffer-or-dir))
(declare-function kargu-deps-missing "kargu/tools/deps" (&optional root))

(defgroup kargu-loop nil
  "The autonomous agent loop."
  :group 'kargu
  :prefix "kargu-loop-")

(defcustom kargu-loop-mutating-tools
  '("edit_file" "write_file" "edit" "write" "apply_patch" "patch" "bash"
    "edit_symbol" "edit_with_lsp" "edit_by_symbol"
    "git_commit" "git_stage" "git_unstage" "git_branch" "git_stash")
  "Tools that modify files or git history.
They are advertised and executable only in agent mode."
  :type '(repeat (string :tag "Tool name"))
  :group 'kargu-loop)

(defcustom kargu-loop-debug-tools
  '("debug_get_context" "debug_eval" "debug_list_breakpoints"
    "debug_set_breakpoint" "debug_clear_breakpoint" "debug_toggle_breakpoint"
    "debug_step_over" "debug_step_in" "debug_step_out" "debug_continue"
    "debug_pause" "debug_restart"
    "step_over" "next" "step_in" "step" "step_out" "finish" "continue"
    "pause" "restart" "set_breakpoint" "clear_breakpoint")
  "Tools that inspect and control the live debug session in dape.
They are advertised and executable in debug and agent modes."
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


(defun kargu-loop--live-p (run)
  "Non-nil when RUN is still the active loop."
  (eq run kargu--loop-run))

(defun kargu-loop--set-state (run state)
  "Set RUN `:state' to STATE and synchronize with central state store."
  (plist-put run :state state)
  (when (fboundp 'kargu-state-transition-status)
    (let ((st (pcase state
                ((or 'request :requesting) :requesting)
                ((or 'wait :waiting-model) :waiting-model)
                ((or 'tools :executing-tools) :executing-tools)
                ((or 'verify :verifying) :verifying)
                ((or 'compact :compacting) :compacting)
                ((or 'pause :pause) :pause)
                ((or 'done :done) :done)
                ((or 'limit :limit) :limit)
                ((or 'stopped :stopped) :stopped)
                ((or 'error :error) :error)
                (_ nil))))
      (when st
        (kargu-state-transition-status st))))
  state)

(defun kargu-loop-tool-visible-p (name)
  "Return non-nil when tool NAME may be advertised to the model."
  (let ((mode (kargu-state-mode)))
    (and (kargu-tools-enabled-p)
         (not (kargu-tool-policy-error name))
         (cond
          ((member name kargu-loop-debug-tools)
           (memq mode '(debug agent)))
          ((member name kargu-loop-mutating-tools)
           (eq mode 'agent))
          (t t)))))

(defun kargu-loop--gate-tool (name)
  "Return an error string when NAME may not run in the active mode."
  (let ((mode (kargu-state-mode)))
    (cond
     ((kargu-tool-policy-error name))
     ((and (member name kargu-loop-debug-tools)
           (not (memq mode '(debug agent))))
      (format
       (concat "Permission denied: Debug tool `%s' is blocked in %s mode.\n"
               "  - Active mode: %s\n"
               "  - Allowed modes for debugging: debug, agent\n"
               "  - Guidance: Switch to debug mode to interact with the live debugger.")
       name mode mode))
     ((and (member name kargu-loop-mutating-tools)
           (not (eq mode 'agent)))
      (format
       (concat "Permission denied: Tool `%s' is blocked in %s mode.\n"
               "  - Active mode: %s (read-only)\n"
               "  - Blocked tool: `%s' (modifying files or execution state is prohibited in this mode)\n"
               "  - Allowed tools in this mode: `read_file', `workspace_grep', `find_files', `list_files', and LSP inspection tools.\n"
               "  - Guidance: You do not have permission to execute mutating tools while in %s mode. To modify code or run commands, switch to agent mode (M-x kargu-set-mode) or provide a read-only plan/response to the user.")
       name mode mode name mode))
     (t nil))))

(defun kargu-loop-running-p ()
  "Return non-nil while an agent run is in progress."
  (not (null kargu--loop-run)))

(defun kargu-loop-stop (&optional reason)
  "Stop the current agent run, optionally recording REASON."
  (interactive)
  (if (null kargu--loop-run)
      (message "kargu: no run in progress")
    (kargu-async-cancel-owner kargu--loop-run)
    (when (fboundp 'kargu-bash-kill-active-async)
      (kargu-bash-kill-active-async))
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
            (kargu-loop--turn-cap kargu--loop-run)
            (or (plist-get kargu--loop-run :healing) 0)
            kargu-max-healing-steps
            (or (plist-get kargu--loop-run :verifications) 0)
            (if (kargu-busy-p) "in flight" "local work")))))
    (when (called-interactively-p 'any)
      (message "kargu loop: %s" report))
    report))

(defun kargu-loop--message-report (report)
  "Display the agent outcome from REPORT in the echo area."
  (message "kargu: %s — %s"
           (plist-get report :status)
           (truncate-string-to-width
            (let ((text (plist-get report :text))
                  (err (plist-get report :error)))
              (if (and (stringp text) (not (string-empty-p text)))
                  text
                (or err "")))
            120)))

(defun kargu-tools-enabled-p (&optional run)
  "Return non-nil when tools may be used for RUN (default: the live run).
The single answer to \"can this request use tools\": the model must not be
ruled out by the catalog or by a provider refusal, and RUN must not have
switched tools off (for example while compacting)."
  (and (kargu-model-supports-tools-p)
       (not (plist-get (or run kargu--loop-run) :no-tools))))

(defun kargu-loop-require-tools-for-agent ()
  "Signal `user-error' when agent mode is on and the model cannot call tools."
  (when (and (eq (kargu-state-mode) 'agent)
             (not (kargu-model-supports-tools-p)))
    (user-error "Model '%s' does not support tool calling; switch to a tool-capable model or ask mode"
                (or (kargu--model) "unknown"))))

(defun kargu-loop-preflight ()
  "Signal `user-error' when a run cannot start now.
Return non-nil when the run must be tool-free (the model cannot call tools
and the mode is not agent).  Touches no state, so a refused start leaves
the diff run files and the UI as they were."
  (when (kargu-loop-running-p)
    (user-error "Kargu: a run is already in progress (M-x kargu-loop-stop)"))
  (let ((missing (and (fboundp 'kargu-deps-missing)
                      (kargu-deps-missing
                       (if (fboundp 'kargu-session-project-root)
                           (kargu-session-project-root)
                         (kargu-permission-project-root))))))
    (when missing
      (user-error "Kargu: Run cannot start because mandatory tools are missing: %s"
                  (string-join (mapcar (lambda (m) (format "%s" (plist-get m :name))) missing) ", "))))
  (kargu-loop-require-tools-for-agent)
  (not (kargu-model-supports-tools-p)))

(cl-defun kargu-loop--new-run (prompt &key no-tools on-delta on-finish)
  "Build a run record for PROMPT with NO-TOOLS, ON-DELTA and ON-FINISH."
  (list :prompt prompt :state 'request :chat-buffer (current-buffer)
        :max-iterations kargu-max-iterations :on-delta on-delta
        :on-finish (or on-finish #'kargu-loop--message-report)
        :iterations 0 :healing 0 :verifications 0 :empty-retries 0
        :upstream-retries 0 :compactions 0 :length-continues 0
        :doom-sigs nil :no-tools no-tools))

(defun kargu-loop--start-run (run prompt)
  "Publish RUN and start its first request for PROMPT, handling startup errors."
  (let ((generation kargu--generation))
    (setq kargu--loop-run run)
    (condition-case err
        (progn
          (kargu-state-transition-status :requesting)
          (plist-put kargu--session :active t)
          (kargu-log 'info "run start (mode=%s, model=%s)"
                     (kargu-state-mode) (kargu--model))
          (kargu--loop-request run prompt))
      (error
       (when (kargu-loop--live-p run)
         (when (> kargu--generation generation) (kargu-api-cancel))
         (kargu--loop-finish run :error (error-message-string err)))))))

(defun kargu-loop-send (prompt &optional on-delta on-finish)
  "Start an agent run with PROMPT.
Deliver streaming events to ON-DELTA and the final report to ON-FINISH."
  (interactive "skargu prompt: ")
  (kargu-contract-assert #'kargu-contract-non-empty-string-p prompt
                         "kargu: prompt must be a non-empty string: %S" prompt)
  (kargu-contract-assert #'kargu-contract-callback-p on-delta
                         "kargu: on-delta must be callable or nil: %S" on-delta)
  (kargu-contract-assert #'kargu-contract-callback-p on-finish
                         "kargu: on-finish must be callable or nil: %S" on-finish)
  (let* ((no-tools (kargu-loop-preflight))
         (wrapped (kargu-prompt-wrap-user prompt))
         (run (kargu-loop--new-run prompt :no-tools no-tools
                                   :on-delta on-delta :on-finish on-finish)))
    (setq kargu--compaction-system nil)
    (kargu-edit-changes :reset)
    (kargu-loop--start-run run wrapped)
    run))

(defun kargu-loop--finish-report (run status text)
  "Build the completion report for RUN with STATUS and TEXT."
  (let ((report (list :status status
                      :text (if (eq status :error) "" (or text ""))
                      :iterations (or (plist-get run :iterations) 0)
                      :healing (or (plist-get run :healing) 0)
                      :verifications (or (plist-get run :verifications) 0))))
    (when (eq status :error)
      (plist-put report :error (or text "unknown error")))
    (when-let* ((modified (kargu-edit-changes :modified)))
      (plist-put report :modified-files (copy-sequence modified)))
    (when-let* ((pending (kargu-edit-changes :pending)))
      (plist-put report :pending-files pending)
      (kargu-log 'warn "run end with %d unconsumed changed file(s)" (length pending)))
    report))

(defun kargu--loop-finish (run status &optional text)
  "End RUN with STATUS and TEXT; deliver the report to on-finish."
  (when (kargu-loop--live-p run)
    (let ((report (kargu-loop--finish-report run status text)))
      (kargu-async-cancel-owner run)
      (setq kargu--loop-run nil)
      (kargu-dismiss-confirmations)
      (when (memq status '(:stopped :error))
        (kargu-edit-changes :abort))
      (setq kargu--compaction-system nil)
      (plist-put kargu--session :active nil)
      (when (fboundp 'kargu-state-transition-status)
        (let ((final-st (if (memq status '(:done :limit :stopped :error))
                            status :idle)))
          (kargu-state-transition-status final-st (or text (symbol-name status)))))
      (kargu--validate-history 'keep-assistant-tail)
      (kargu-log 'info "run end: %s (iterations=%d, healing=%d)"
                 status (plist-get report :iterations) (plist-get report :healing))
      (condition-case-unless-debug err
          (when-let* ((on-finish (plist-get run :on-finish)))
            (funcall on-finish report))
        (error (kargu-log 'error "on-finish callback failed: %s"
                          (error-message-string err))))
      report)))

(require 'kargu/loop/compact)
(require 'kargu/loop/tools)
(require 'kargu/loop/heal)
(require 'kargu/loop/machine)

(kargu-log 'info "loop module loaded")

(provide 'kargu/loop)

;;; loop.el ends here
