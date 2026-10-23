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
  "Compatibility index of detached or unmigrated tasks, not native run children.")
(defvar kargu--loop-run nil)
(defvar kargu-async--current-task nil
  "Dynamically bound parent while an asynchronous operation starts or resumes.")
(defvar kargu-execution--current nil)
(declare-function kargu-execution-app "kargu/application/execution" (context))
(declare-function kargu-execution-call "kargu/application/execution" (context function &rest args))
(declare-function kargu-execution-live-p "kargu/application/execution" (context))

(cl-defstruct (kargu-async-task (:constructor kargu-async--make))
  "One task with a terminal state, resource cleanup stack, and single completion callback."
  (id (format "task-%s-%06x"
              (format-time-string "%Y%m%d%H%M%S")
              (random #xffffff)) :read-only t)
  (state :pending) callback timer owner valid-p cancel parent buffer deadline owner-run owner-claim
  children context)

(defun kargu-async--deadline (parent timeout deadline)
  "Return the earliest deadline from PARENT, relative TIMEOUT and DEADLINE."
  (let ((limits (delq nil (list deadline
                                (and timeout (> timeout 0) (+ (float-time) timeout))
                                (and parent (kargu-async-task-deadline parent))))))
    (when limits (apply #'min limits))))

(cl-defun kargu-async-start
    (callback &key timeout valid-p cancel
              (owner (if kargu-execution--current
                         (kargu-execution-app kargu-execution--current) kargu--loop-run))
              (parent kargu-async--current-task) (buffer (current-buffer)) deadline)
  "Start a task delivering (VALUE ERROR) to CALLBACK once.
TIMEOUT bounds the whole task in seconds.  DEADLINE sets an absolute timestamp.
VALID-P checks captured resources;
CANCEL optionally cancels underlying work when the task is terminated.
OWNER binds the task to an execution owner (defaults to current run).
PARENT links to a parent task (defaults to `kargu-async--current-task').
BUFFER captures the origin buffer (defaults to `current-buffer')."
  (let* ((deadline (kargu-async--deadline parent timeout deadline))
         (delay (when deadline (max 0 (- deadline (float-time)))))
         (app (and (fboundp 'kargu-application-p) (kargu-application-p owner) owner))
         (task (kargu-async--make :callback callback :valid-p valid-p
                                  :cancel cancel :owner owner :parent parent :buffer buffer
                                  :owner-run (and app (kargu-application-current-run app))
                                  :owner-claim (and app (kargu-application-active-claim-token app))
                                  :context (and owner kargu-execution--current)
                                  :deadline deadline)))
    (unless (kargu-async-task-context task) (push task kargu-async--pending))
    (when parent (push task (kargu-async-task-children parent)))
    (condition-case err
        (progn
          (if (and parent (not (kargu-async-pending-p parent)))
              (kargu-async--close task :cancelled)
            (when delay
              (setf (kargu-async-task-timer task)
                    (run-at-time delay nil #'kargu-async-finish
                                 task nil "Request timed out"))))
          task)
      (error
       (kargu-async--close task :cancelled)
       (signal (car err) (cdr err))))))

(defun kargu-async-pending-p (task)
  "Return non-nil when TASK can still deliver a result."
  (and (eq (kargu-async-task-state task) :pending)
       (or (null (kargu-async-task-context task))
           (kargu-execution-live-p (kargu-async-task-context task)))
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
    (unless (kargu-async-task-context task)
      (setq kargu-async--pending (delq task kargu-async--pending)))
    (when-let* ((parent (kargu-async-task-parent task)))
      (setf (kargu-async-task-children parent)
            (delq task (kargu-async-task-children parent))))
    (dolist (child (kargu-async-task-children task))
      (kargu-async--close child :cancelled))
    (setf (kargu-async-task-children task) nil)
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
            (if-let* ((context (kargu-async-task-context task)))
                (kargu-execution-call context (kargu-async-task-callback task) value error)
              (funcall (kargu-async-task-callback task) value error))))
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
        (when live
          (cond
           ((not (buffer-live-p (kargu-async-task-buffer task)))
            (setq value nil error "Origin buffer was closed"))
           ((and (kargu-async-task-valid-p task)
                 (not (funcall (kargu-async-task-valid-p task))))
            (setq value nil error "Connection or document changed")))
          (kargu-async--deliver task value error))))))

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
                  (if-let* ((context (kargu-async-task-context task)))
                      (kargu-execution-call context
                                            (lambda ()
                                              (let ((kargu-async--current-task task))
                                                (apply function args))))
                    (apply function args)))))
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
              (and (stringp owner) (stringp (kargu-async-task-owner task))
                   (equal owner (kargu-async-task-owner task))))
      (kargu-async--close task :cancelled))))

(provide 'kargu/async)
;;; async.el ends here
