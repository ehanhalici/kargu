;;; settle.el --- Owned asynchronous diagnostic waits -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Tie verification to its document, project, caller and run lifetime.

;;; Code:

(require 'kargu/async)
(require 'kargu/tools/lsp/freshness)

(declare-function kargu-lsp-format-diagnostics "kargu/tools/lsp/diagnostics" (file-path data))
(declare-function kargu-lsp-diagnostics-snapshot "kargu/tools/lsp/diagnostics" (file-path))

(defconst kargu-lsp--diagnostic-poll-interval 0.25
  "Seconds between nonblocking diagnostic readiness probes.")

(cl-defstruct (kargu-lsp--diagnostic-wait
               (:constructor kargu-lsp--make-diagnostic-wait))
  "Resources belonging to one caller's verification task."
  path root origin barrier task timer)

(defun kargu-lsp--diagnostic-wait-valid-p (wait)
  "Return non-nil while WAIT's origin, project and document remain valid."
  (let ((origin (kargu-lsp--diagnostic-wait-origin wait)))
    (and (buffer-live-p origin)
         (with-current-buffer origin
           (equal (kargu-lsp--diagnostic-wait-root wait)
                  (kargu-permission-project-root)))
         (kargu-lsp-diagnostic-barrier-valid-p
          (kargu-lsp--diagnostic-wait-barrier wait)))))

(defun kargu-lsp--poll-diagnostic-wait (wait)
  "Complete WAIT only after its captured checkers report fresh diagnostics."
  (when (kargu-lsp-diagnostic-barrier-ready-p
         (kargu-lsp--diagnostic-wait-barrier wait))
    (unless (and (kargu-lsp-sync-diagnostic-barrier
                  (kargu-lsp--diagnostic-wait-barrier wait))
                 (kargu-lsp--diagnostic-wait-valid-p wait))
      (error "Diagnostic document changed during publication"))
    (let ((path (kargu-lsp--diagnostic-wait-path wait))
          (kargu-permission--override-root (kargu-lsp--diagnostic-wait-root wait)))
      (kargu-async-finish
       (kargu-lsp--diagnostic-wait-task wait)
       (kargu-lsp-format-diagnostics path (kargu-lsp-diagnostics-snapshot path))))))

(defun kargu-lsp--tick-diagnostic-wait (wait)
  "Probe WAIT or release its resources if the run owner was replaced."
  (let ((task (kargu-lsp--diagnostic-wait-task wait)))
    (if (not (kargu-async-pending-p task))
        (kargu-async-finish task nil)
      (funcall (kargu-async-wrap
                task (lambda () (kargu-lsp--poll-diagnostic-wait wait)))))))

(defun kargu-lsp--start-diagnostic-wait (wait)
  "Acquire a document barrier and cancellable timer for WAIT."
  (let* ((task (kargu-lsp--diagnostic-wait-task wait))
         (barrier (kargu-lsp-begin-diagnostic-barrier
                   (find-buffer-visiting (kargu-lsp--diagnostic-wait-path wait)))))
    (if (null barrier) (kargu-async-finish task nil)
      (setf (kargu-lsp--diagnostic-wait-barrier wait) barrier
            (kargu-async-task-valid-p task)
            (lambda () (kargu-lsp--diagnostic-wait-valid-p wait)))
      (setf (kargu-lsp--diagnostic-wait-timer wait)
            (run-at-time kargu-lsp--diagnostic-poll-interval
                         kargu-lsp--diagnostic-poll-interval
                         #'kargu-lsp--tick-diagnostic-wait wait))
      (kargu-async-add-cleanup
       task (lambda () (cancel-timer (kargu-lsp--diagnostic-wait-timer wait)))))))

(defun kargu-lsp-wait-diagnostics (file-path callback &optional timeout)
  "Wait for fresh FILE-PATH diagnostics and invoke CALLBACK at most once.
CALLBACK receives (PATH TEXT TIMED-OUT); nil TEXT means unavailable or
invalidated evidence.  TIMEOUT defaults to `kargu-lsp-diag-settle-timeout'.
Return a task owned by the current run; stopping that run cancels its timer
without delivering a stale result.  Unversioned Eglot pushes never certify
that an edited document is clean."
  (let* ((root (kargu-permission-project-root))
         (path (kargu-permission-resolve file-path "lsp path" root))
         (wait (kargu-lsp--make-diagnostic-wait
                :path path :root root :origin (current-buffer)))
         (task (kargu-async-start
                (lambda (text error)
                  (when error (kargu-log 'info "diagnostic wait: %s" error))
                  (funcall callback path text (equal error "Request timed out")))
                :timeout (or timeout kargu-lsp-diag-settle-timeout))))
    (setf (kargu-lsp--diagnostic-wait-task wait) task)
    (funcall (kargu-async-wrap task (lambda () (kargu-lsp--start-diagnostic-wait wait))))
    task))

(provide 'kargu/tools/lsp/settle)
;;; settle.el ends here
