;;; async.el --- Single-delivery asynchronous task lifecycle -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Guard delayed callbacks, deadlines and cancellation with one task state.

;;; Code:

(require 'cl-lib)
(require 'kargu/core/log)

(declare-function kargu-application-p "kargu/application/coordinator" (object))
(declare-function kargu-application-current-run "kargu/application/coordinator" (&optional app))
(declare-function kargu-application-work-active-p "kargu/application/coordinator" (&optional app))
(declare-function kargu-application-active-claim-token "kargu/application/coordinator" (app))

(defvar kargu-async--pending nil
  "Pending asynchronous tasks, including their run owners.")
(defvar kargu--loop-run nil)
(defvar kargu-async--current-task nil
  "Dynamically bound parent while an asynchronous operation starts or resumes.")

(cl-defstruct (kargu-async-task (:constructor kargu-async--make))
  "One task with a terminal state, resource cleanup stack, and single completion callback."
  (id (format "task-%s-%06x"
              (format-time-string "%Y%m%d%H%M%S")
              (random #xffffff)) :read-only t)
  (state :pending) callback timer owner valid-p cancel parent buffer deadline owner-run owner-claim)

(cl-defun kargu-async-start
    (callback &key timeout valid-p cancel (owner kargu--loop-run)
              (parent kargu-async--current-task) (buffer (current-buffer)) deadline)
  "Start a task delivering (VALUE ERROR) to CALLBACK once.
TIMEOUT bounds the whole task in seconds.  DEADLINE sets an absolute timestamp.
VALID-P checks captured resources;
CANCEL optionally cancels underlying work when the task is terminated.
OWNER binds the task to an execution owner (defaults to current run).
PARENT links to a parent task (defaults to `kargu-async--current-task').
BUFFER captures the origin buffer (defaults to `current-buffer')."
  (let* ((effective-owner owner)
         (effective-parent parent)
         (effective-buffer buffer)
         (effective-deadline (or deadline
                                 (when (and timeout (> timeout 0))
                                   (+ (float-time) timeout))))
         (effective-timeout (or timeout
                                (when effective-deadline
                                  (max 0.001 (- effective-deadline (float-time))))))
         (task (kargu-async--make :callback callback :valid-p valid-p
                                  :cancel cancel :owner effective-owner
                                  :parent effective-parent
                                  :buffer effective-buffer
                                  :owner-run (and (fboundp 'kargu-application-p)
                                                  (kargu-application-p effective-owner)
                                                  (kargu-application-current-run effective-owner))
                                  :owner-claim (and (fboundp 'kargu-application-p)
                                                    (kargu-application-p effective-owner)
                                                    (kargu-application-active-claim-token effective-owner))
                                  :deadline effective-deadline)))
    (push task kargu-async--pending)
    (condition-case err
        (progn
          (when effective-timeout
            (setf (kargu-async-task-timer task)
                  (run-at-time effective-timeout nil #'kargu-async-finish
                               task nil "Request timed out")))
          task)
      (error
       (kargu-async--close task :cancelled)
       (signal (car err) (cdr err))))))

(defun kargu-async-pending-p (task)
  "Return non-nil when TASK can still deliver a result."
  (and (eq (kargu-async-task-state task) :pending)
       (let ((owner (kargu-async-task-owner task)))
         (cond
          ((null owner) t)
          ((consp owner) (eq owner kargu--loop-run))
          ((and (fboundp 'kargu-application-p) (kargu-application-p owner))
           (and (kargu-application-work-active-p owner)
                (eq (kargu-async-task-owner-claim task)
                    (kargu-application-active-claim-token owner))
                (eq (kargu-async-task-owner-run task)
                    (kargu-application-current-run owner))))
          ((and (stringp owner)
                (string-prefix-p "run-" owner))
           (and (fboundp 'kargu-application-current-run)
                (equal owner (kargu-application-current-run))))
          ((eq owner kargu--loop-run) t)
          (t t)))))

(defun kargu-async-add-cleanup (task function)
  "Register resource cleanup FUNCTION for TASK without replacing earlier cleanup.
If TASK has already ended, release the newly acquired resource immediately."
  (if (kargu-async-pending-p task)
      (let ((previous (kargu-async-task-cancel task)))
        (setf (kargu-async-task-cancel task)
              (lambda ()
                (unwind-protect (funcall function)
                  (when previous (funcall previous))))))
    (funcall function)))

(defun kargu-async--close (task state)
  "Close TASK in terminal STATE and release its resources."
  (when (eq (kargu-async-task-state task) :pending)
    (setf (kargu-async-task-state task) state)
    (setq kargu-async--pending (delq task kargu-async--pending))
    (dolist (child (copy-sequence kargu-async--pending))
      (when (eq task (kargu-async-task-parent child))
	(kargu-async--close child :cancelled)))
    (when-let* ((timer (kargu-async-task-timer task)))
      (cancel-timer timer)
      (setf (kargu-async-task-timer task) nil))
    (when-let* ((cancel (kargu-async-task-cancel task)))
      (condition-case err (save-match-data (funcall cancel))
	(error (kargu-log 'warn "async cleanup: %s" (error-message-string err)))))))

(defun kargu-async--deliver (task value error)
  "Deliver TASK's VALUE or ERROR, attributing callback failures to its parent."
  (let ((parent (kargu-async-task-parent task)))
    (condition-case failure
        (with-current-buffer (if (buffer-live-p (kargu-async-task-buffer task))
                                 (kargu-async-task-buffer task) (current-buffer))
          (let ((kargu-async--current-task parent))
            (funcall (kargu-async-task-callback task) value error)))
      (error
       (kargu-log 'error "Async continuation failed: %s" (error-message-string failure))
       (when (and parent (kargu-async-pending-p parent))
         (kargu-async-finish parent nil (error-message-string failure)))))))

(defun kargu-async-finish (task value &optional error)
  "Deliver VALUE or ERROR for TASK, provided its owner is still active."
  (save-match-data
    (when (eq (kargu-async-task-state task) :pending)
      (let ((live (kargu-async-pending-p task)))
        (kargu-async--close task (if live :done :cancelled))
        (when live (kargu-async--deliver task value error))))))

(defun kargu-async-wrap (task function)
  "Return a delayed callback that guards FUNCTION with TASK's lifetime."
  (lambda (&rest args)
    (save-match-data
      (when (kargu-async-pending-p task)
        (condition-case err
            (if (and (kargu-async-task-valid-p task)
                     (not (funcall (kargu-async-task-valid-p task))))
                (kargu-async-finish task nil "Connection or document changed")
              (let ((kargu-async--current-task task))
                (unless (buffer-live-p (kargu-async-task-buffer task))
                  (error "Origin buffer was closed"))
                (with-current-buffer (kargu-async-task-buffer task)
                  (apply function args))))
          (error
           (if (kargu-async-pending-p task)
               (kargu-async-finish task nil (error-message-string err))
             (kargu-log 'warn "Async operation failed after delivery: %s"
                        (error-message-string err)))))))))

(defun kargu-async-cancel (task)
  "Cancel only TASK and its children, silently releasing owned resources."
  (kargu-async--close task :cancelled))

(defun kargu-async-cancel-owner (owner)
  "Cancel all pending tasks owned by OWNER without delivering stale results."
  (dolist (task (copy-sequence kargu-async--pending))
    (when (or (eq owner (kargu-async-task-owner task))
              (equal owner (kargu-async-task-owner task)))
      (kargu-async--close task :cancelled))))

(provide 'kargu/async)
;;; async.el ends here
