;;; execution.el --- Debug execution and stop waits -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Run execution commands and finish asynchronous stop or timeout waits.

;;; Code:

(require 'kargu/tools/dape/context)

;;;; Stepping & execution control ------------------------------------------

(defun kargu-dape--format-stopped-report (action-name callback)
  "Build the paused-session report for ACTION-NAME and pass it to CALLBACK.
The call stack and variables are fetched before the report is built."
  (kargu-dape-get-context
   (lambda (ctx)
     (let* ((live-conn (kargu-dape--raw-connection))
            (thread (and live-conn (or (dape--current-thread live-conn)
                                       (car (dape--stopped-threads live-conn)))))
            (top-frame (and live-conn (or (dape--current-stack-frame live-conn)
                                          (car (plist-get thread :stackFrames)))))
            (file (and live-conn top-frame (kargu-dape--frame-path live-conn top-frame)))
            (line (and top-frame (plist-get top-frame :line)))
            (fn-name (and top-frame (plist-get top-frame :name)))
            (src-snippet (when (and file (not (equal file "?")) (numberp line))
                           (kargu-dape--source-snippet file line 4))))
       (funcall callback
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
                 "  - Lifecycle: `debug_watch`, `debug_restart`, `debug_kill`, `debug_disconnect`, `debug_quit`."))))))

(defun kargu-dape--cleanup-wait (timer hook-stop hook-exit)
  "Clean up TIMER and HOOK-STOP / HOOK-EXIT listeners."
  (when timer (cancel-timer timer))
  (when (boundp 'dape-stopped-hook)
    (remove-hook 'dape-stopped-hook hook-stop))
  (when (boundp 'dape-active-mode-off-hook)
    (remove-hook 'dape-active-mode-off-hook hook-exit)))

(defun kargu-dape--running-message (action-name timeout)
  "Report text for ACTION-NAME still running after TIMEOUT seconds."
  (format "[DEBUGGER STILL RUNNING]\nAction '%s' initiated, but program did not pause within %ds timeout (still running or waiting for input).\nUse `debug_pause` to pause execution."
          action-name (round timeout)))

(defun kargu-dape--show-report (report)
  "Show the debugger REPORT in the echo area (interactive commands)."
  (message "kargu debug: %s" report))

(defun kargu-dape--action-and-wait (action-fn action-name &optional callback timeout)
  "Run ACTION-FN and report ACTION-NAME through CALLBACK.
Wait asynchronously for a stop or TIMEOUT seconds.  When CALLBACK is nil,
display the report in the echo area."
  (let ((conn (or (kargu-dape--raw-connection) (kargu-dape--connection))))
    (cond
     ((stringp conn)
      (if callback (funcall callback conn) conn))
     (t
      (kargu-dape--start-action conn action-fn action-name
                                (or callback #'kargu-dape--show-report)
                                (or timeout 10.0))
      (unless callback
        (format "Action '%s' started; the result appears in the echo area." action-name))))))

(cl-defun kargu-dape--install-action-wait (task conn &key name timeout)
  "Install stop/exit listeners for TASK on CONN, reporting NAME after TIMEOUT."
  (let (wait-timer hook-stop hook-exit)
    (setf (kargu-async-task-cancel task)
          (lambda () (kargu-dape--cleanup-wait wait-timer hook-stop hook-exit)))
    (setq hook-stop
          (kargu-async-wrap
           task (lambda (&rest _)
                  (when (eq conn (kargu-dape--raw-connection))
                    (kargu-dape--cleanup-wait wait-timer hook-stop hook-exit)
                    (kargu-dape--format-stopped-report
                     name (kargu-async-wrap task (lambda (text) (kargu-async-finish task text))))))))
    (setq hook-exit
          (kargu-async-wrap
           task (lambda (&rest _)
                  (kargu-async-finish
                   task (format "[DEBUGGER PROGRAM EXITED]\nAction '%s' completed." name)))))
    (add-hook 'dape-stopped-hook hook-stop)
    (add-hook 'dape-active-mode-off-hook hook-exit)
    (setq wait-timer
          (run-at-time timeout nil
                       (lambda ()
                         (kargu-async-finish task
                                             (kargu-dape--running-message name timeout)))))))

(defun kargu-dape--start-action (conn action-fn action-name callback timeout)
  "Run ACTION-FN on CONN and deliver one ACTION-NAME report to CALLBACK."
  (let ((task (kargu-async-start
               (lambda (value error)
                 (funcall callback (if error (concat "ERROR: DAP: " error) value)))
               :timeout (+ timeout kargu-dape-request-timeout))))
    (kargu-dape--install-action-wait task conn :name action-name :timeout timeout)
    (funcall (kargu-async-wrap task (lambda () (funcall action-fn conn))))))

(defun kargu-dape-step-over (&optional callback)
  "Step over the current line and report the stop to CALLBACK."
  (interactive)
  (kargu-dape--action-and-wait #'dape-next "step_over" callback 10.0))

(defun kargu-dape-step-in (&optional callback)
  "Step into the current function and report the stop to CALLBACK."
  (interactive)
  (kargu-dape--action-and-wait #'dape-step-in "step_in" callback 10.0))

(defun kargu-dape-step-out (&optional callback)
  "Step out of the current function and report the stop to CALLBACK."
  (interactive)
  (kargu-dape--action-and-wait #'dape-step-out "step_out" callback 10.0))

(defun kargu-dape-continue (&optional callback)
  "Resume execution and report the next stop to CALLBACK."
  (interactive)
  (kargu-dape--action-and-wait #'dape-continue "continue" callback 30.0))

(defun kargu-dape-pause (&optional callback)
  "Pause execution and report the stopped state to CALLBACK."
  (interactive)
  (kargu-dape--action-and-wait #'dape-pause "pause" callback 10.0))

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
