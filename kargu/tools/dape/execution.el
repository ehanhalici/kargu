;;; execution.el --- Debug execution and stop waits -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Run execution commands and finish asynchronous stop or timeout waits.

;;; Code:

(require 'kargu/tools/dape/context)
(require 'kargu/tools/dape/events)

;;;; Stepping & execution control ------------------------------------------

(defun kargu-dape--stopped-report-text (selection action-name ctx)
  "Format captured SELECTION's paused ACTION-NAME location and collected CTX."
  (let* ((live-conn (kargu-dape-selection-connection selection))
         (top-frame (kargu-dape-selection-frame selection))
         (file (and live-conn top-frame (kargu-dape--frame-path live-conn top-frame)))
         (line (and top-frame (plist-get top-frame :line)))
         (fn-name (and top-frame (plist-get top-frame :name)))
         (src-snippet (when (and file (not (equal file "?")) (numberp line))
                       (kargu-dape--source-snippet file line 4))))
    (concat
     (format "[DEBUGGER PAUSED: Action '%s' completed]\n" action-name)
     (format "Location: %s:%s%s\n"
             (or file "?") (or line "?")
             (if fn-name (format " in `%s`" fn-name) ""))
     (if src-snippet
         (format "\n### Source Context (%s:%s):\n```\n%s\n```\n\n"
                 file line src-snippet)
       "\n")
     ctx
     "\n\nAvailable Next Actions:\n"
     "  - Inspect Variables: Review in-scope variables above. For struct/vector fields, use `debug_scope` (or `debug_inspect_variable`).\n"
     "  - Custom Evaluation: Use `debug_eval` (the language profile in the system prompt says what expressions the adapter can evaluate).\n"
     "  - Stack Navigation: `debug_up` (caller), `debug_down` (callee), `debug_stack` (all frames), `debug_threads`.\n"
     "  - Step & Continue: `debug_step_over` (next), `debug_step_in` (step), `debug_step_out` (out), or `debug_continue`.\n"
     "  - Breakpoints: `debug_set_breakpoint`, `debug_clear_breakpoint`, `debug_list_breakpoints`.\n"
     "  - Lifecycle: `debug_watch`, `debug_restart`, `debug_kill`, `debug_disconnect`, `debug_quit`.")))

(defun kargu-dape--format-stopped-report (action-name callback &optional connection)
  "Build a paused report for ACTION-NAME and pass it to CALLBACK.
The context and location use captured CONNECTION when supplied."
  (let* ((conn (or connection (kargu-dape--raw-connection)))
         (selection (and conn (kargu-dape-capture-selection conn))))
    (kargu-dape-get-context
     (lambda (ctx)
       (funcall callback
                (if (string-prefix-p "ERROR:" ctx) ctx
                  (kargu-dape--stopped-report-text
                   selection action-name ctx))))
     conn selection)))

(defun kargu-dape--running-message (action-name timeout)
  "Report text for ACTION-NAME still running after TIMEOUT seconds."
  (format "[DEBUGGER STILL RUNNING]\nAction '%s' initiated, but program did not pause within %ds timeout (still running or waiting for input).\nUse `debug_pause` to pause execution."
          action-name (round timeout)))

(defun kargu-dape--show-report (report)
  "Show the debugger REPORT in the echo area (interactive commands)."
  (message "kargu debug: %s" report))

(cl-defun kargu-dape--action-and-wait (action-fn action-name &key callback (timeout 10.0))
  "Run ACTION-FN and report ACTION-NAME through CALLBACK.
Wait asynchronously for a stop or TIMEOUT seconds.  When CALLBACK is nil,
display the report in the echo area."
  (let ((conn (or (kargu-dape--raw-connection) (kargu-dape--connection))))
    (cond
     ((stringp conn)
      (if callback (funcall callback conn) conn))
     (t
      (kargu-dape--start-action conn action-fn (or callback #'kargu-dape--show-report)
                                :name action-name :timeout timeout)
      (unless callback
        (format "Action '%s' started; the result appears in the echo area." action-name))))))

(defconst kargu-dape--action-poll-interval 0.25
  "Seconds between adapter-liveness checks during an execution wait.")

(cl-defstruct (kargu-dape--action-wait (:constructor kargu-dape--make-action-wait))
  "One execution command's captured ownership and report stage."
  origin root session connection name timeout task (stage :running))

(defun kargu-dape--action-valid-p (wait)
  "Return non-nil while WAIT's originating workspace and session still exist."
  (let ((origin (kargu-dape--action-wait-origin wait)))
    (and (buffer-live-p origin)
         (with-current-buffer origin
           (and (equal (kargu-dape--action-wait-root wait) (kargu-permission-project-root))
                (equal (kargu-dape--action-wait-session wait) (kargu-session-id)))))))

(defun kargu-dape--action-connected-p (wait)
  "Return non-nil when WAIT's captured adapter is still live in its workspace."
  (memq (kargu-dape--action-wait-connection wait)
        (kargu-dape-project-connections (kargu-dape--action-wait-root wait))))

(defun kargu-dape--action-event (wait connection event)
  "Handle EVENT from CONNECTION only when it belongs to WAIT."
  (when (eq connection (kargu-dape--action-wait-connection wait))
    (let ((task (kargu-dape--action-wait-task wait))
          (name (kargu-dape--action-wait-name wait)))
      (pcase event
        ((or 'exited 'terminated)
         (kargu-async-finish task (format "[DEBUGGER PROGRAM EXITED]\nAction '%s' completed." name)))
        ('stopped
         (when (and (eq (kargu-dape--action-wait-stage wait) :running)
                    (kargu-dape--action-connected-p wait)
                    (dape--stopped-threads connection))
           (setf (kargu-dape--action-wait-stage wait) :reporting)
           (kargu-dape--format-stopped-report
            name (kargu-async-wrap task (lambda (text) (kargu-async-finish task text))) connection)))))))

(defun kargu-dape--tick-action-wait (wait)
  "Check WAIT's exact adapter without adopting a replacement or foreign stop."
  (let ((task (kargu-dape--action-wait-task wait)))
    (if (not (kargu-async-pending-p task)) (kargu-async-finish task nil)
      (funcall
       (kargu-async-wrap
        task (lambda ()
               (unless (kargu-dape--action-connected-p wait)
                 (kargu-async-finish task nil "Captured debug adapter disconnected"))))))))

(defun kargu-dape--action-deadline (wait)
  "Report WAIT's running timeout only while it still owns its live adapter."
  (kargu-dape--tick-action-wait wait)
  (let ((task (kargu-dape--action-wait-task wait)))
    (when (and (kargu-async-pending-p task)
               (eq (kargu-dape--action-wait-stage wait) :running))
      (funcall
       (kargu-async-wrap
        task (lambda ()
               (kargu-async-finish
                task (kargu-dape--running-message
                      (kargu-dape--action-wait-name wait) (kargu-dape--action-wait-timeout wait)))))))))

(cl-defun kargu-dape--action-timer (wait function seconds &key repeat)
  "Acquire a SECONDS timer calling FUNCTION for WAIT, optionally with REPEAT."
  (let ((task (kargu-dape--action-wait-task wait)))
    (when (kargu-async-pending-p task)
      (let ((timer (run-at-time seconds repeat function wait)))
        (kargu-async-add-cleanup task (lambda () (cancel-timer timer)))))))

(defun kargu-dape--install-action-wait (wait)
  "Acquire connection-bearing notifications and owned timers for WAIT."
  (let* ((task (kargu-dape--action-wait-task wait))
         (listener (kargu-async-wrap
                    task (lambda (conn event) (kargu-dape--action-event wait conn event)))))
    (add-hook 'kargu-dape-event-hook listener)
    (kargu-async-add-cleanup task (lambda () (remove-hook 'kargu-dape-event-hook listener)))
    (kargu-dape--action-timer wait #'kargu-dape--tick-action-wait
                              kargu-dape--action-poll-interval :repeat kargu-dape--action-poll-interval)
    (kargu-dape--action-timer wait #'kargu-dape--action-deadline (kargu-dape--action-wait-timeout wait))))

(cl-defun kargu-dape--start-action (conn action-fn callback &key name timeout)
  "Run ACTION-FN on CONN and deliver one NAME report to CALLBACK after TIMEOUT."
  (let* ((wait (kargu-dape--make-action-wait
                :origin (current-buffer) :root (kargu-permission-project-root)
                :session (copy-sequence (kargu-session-id)) :connection conn :name name :timeout timeout))
         (task (kargu-async-start
                (lambda (value error) (funcall callback (if error (concat "ERROR: DAP: " error) value)))
                :valid-p (lambda () (kargu-dape--action-valid-p wait))
                :timeout (+ timeout kargu-dape-request-timeout))))
    (setf (kargu-dape--action-wait-task wait) task)
    (funcall (kargu-async-wrap
              task (lambda ()
                     (unless (kargu-dape--action-connected-p wait)
                       (error "Captured debug adapter is not live in this workspace"))
                     (kargu-dape--install-action-wait wait)
                     (funcall action-fn conn))))
    task))

(defun kargu-dape-step-over (&optional callback)
  "Step over the current line and report the stop to CALLBACK."
  (interactive)
  (kargu-dape--action-and-wait #'dape-next "step_over" :callback callback))

(defun kargu-dape-step-in (&optional callback)
  "Step into the current function and report the stop to CALLBACK."
  (interactive)
  (kargu-dape--action-and-wait #'dape-step-in "step_in" :callback callback))

(defun kargu-dape-step-out (&optional callback)
  "Step out of the current function and report the stop to CALLBACK."
  (interactive)
  (kargu-dape--action-and-wait #'dape-step-out "step_out" :callback callback))

(defun kargu-dape-continue (&optional callback)
  "Resume execution and report the next stop to CALLBACK."
  (interactive)
  (kargu-dape--action-and-wait #'dape-continue "continue" :callback callback :timeout 30.0))

(defun kargu-dape-pause (&optional callback)
  "Pause execution and report the stopped state to CALLBACK."
  (interactive)
  (kargu-dape--action-and-wait #'dape-pause "pause" :callback callback))

(defun kargu-dape-restart ()
  "Restart the active debugging session."
  (interactive)
  (let ((conn (kargu-dape--raw-connection)))
    (if (null conn)
        "ERROR: no live dape session to restart"
      (condition-case err
          (progn
            (dape-restart conn)
            "Restart signal sent to debug session.")
        (error (format "ERROR: restart failed: %s" (error-message-string err)))))))

(provide 'kargu/tools/dape/execution)

;;; execution.el ends here
