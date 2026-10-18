;;; async.el --- Single-delivery asynchronous task lifecycle -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Guard delayed callbacks, deadlines and cancellation with one task state.

;;; Code:

(require 'cl-lib)
(require 'kargu/core)

(defvar kargu-async--pending nil
  "Pending asynchronous tasks, including their run owners.")
(defvar kargu--loop-run nil)
(defvar kargu-async--current-task nil
  "Dynamically bound parent while an asynchronous operation starts or resumes.")

(cl-defstruct (kargu-async-task (:constructor kargu-async--make))
  "One task with a terminal state and a single completion callback."
  (state :pending) callback timer owner valid-p cancel parent buffer)

(cl-defun kargu-async-start (callback &key timeout valid-p cancel)
  "Start a task delivering (VALUE ERROR) to CALLBACK once.
TIMEOUT bounds the whole task.  VALID-P checks captured resources;
CANCEL optionally cancels underlying work when the task is terminated."
  (let ((task (kargu-async--make :callback callback :valid-p valid-p
                                 :cancel cancel :owner kargu--loop-run
                                 :parent kargu-async--current-task
                                 :buffer (current-buffer))))
    (push task kargu-async--pending)
    (condition-case err
        (progn
          (when timeout
            (setf (kargu-async-task-timer task)
                  (run-at-time timeout nil #'kargu-async-finish
                               task nil "Request timed out")))
          task)
      (error
       (kargu-async--close task :cancelled)
       (signal (car err) (cdr err))))))

(defun kargu-async-pending-p (task)
  "Return non-nil when TASK can still deliver a result."
  (and (eq (kargu-async-task-state task) :pending)
       (or (null (kargu-async-task-owner task))
           (eq (kargu-async-task-owner task) kargu--loop-run))))

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

(defun kargu-async-cancel-owner (owner)
  "Cancel all pending tasks owned by OWNER without delivering stale results."
  (dolist (task (copy-sequence kargu-async--pending))
    (when (eq owner (kargu-async-task-owner task))
      (kargu-async--close task :cancelled))))

(provide 'kargu/async)
;;; async.el ends here
