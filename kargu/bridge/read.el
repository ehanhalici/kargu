;;; read.el --- Owned native read callbacks -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Editor task/owner lifecycle for native read RPCs; no OS or matching engine.

;;; Code:

(require 'kargu/bridge)
(require 'kargu/async)
(require 'kargu/application/coordinator)
(require 'kargu/core/session)

(defun kargu-bridge-read--elapsed-p (task)
  "Return non-nil when TASK's absolute deadline elapsed before timer dispatch."
  (when-let* ((deadline (kargu-async-task-deadline task)))
    (<= deadline (float-time))))

(defun kargu-bridge-read--result (task result error-data &optional decode)
  "Finish TASK from native RESULT or ERROR-DATA, optionally applying DECODE."
  (cond
   ((kargu-bridge-read--elapsed-p task) (kargu-async-finish task nil "Native read deadline expired"))
   (error-data (kargu-async-finish task nil (gethash "message" error-data "Native read failed")))
   ((and (hash-table-p result) (gethash "outcome" result)
         (not (equal (gethash "outcome" result) "ok")))
    (kargu-async-finish task nil (format "Native read failed (%s): %s"
					 (gethash "outcome" result) (gethash "text" result ""))))
   ((not (and (hash-table-p result) (stringp (gethash "text" result))))
    (kargu-async-finish task nil "Invalid native read result"))
   (t (kargu-async-finish task (if decode (funcall decode result) (gethash "text" result))))))

(defun kargu-bridge-read-task (callback arguments request &optional decode)
  "Deliver CALLBACK through native REQUEST with captured ARGUMENTS.
Keep the parent task, owner buffer and take-once RPC cleanup.
DECODE optionally converts a successful native DTO before delivery."
  (let* ((arguments (json-parse-string
                     (json-serialize arguments :null-object :json-null :false-object :json-false)
                     :object-type 'hash-table :array-type 'array :null-object :json-null :false-object :json-false))
         (owner (current-buffer))
         (mode major-mode)
         (session (kargu-session-context))
         (app (kargu-application-context))
         (current (lambda () (and (buffer-live-p owner)
                                  (with-current-buffer owner
                                    (and (eq mode major-mode) (eq session (kargu-session-context)))))))
         (task (kargu-async-start
                (kargu-application-wrap app
					(lambda (text error-data)
					  (when (funcall current)
					    (funcall callback (if error-data (concat "ERROR: " error-data) text)))))
                :valid-p current)))
    (let ((cancel (lambda () (kargu-async-cancel task))))
      (add-hook 'kill-buffer-hook cancel nil t)
      (add-hook 'change-major-mode-hook cancel nil t)
      (kargu-async-add-cleanup
       task (lambda () (when (buffer-live-p owner)
                         (with-current-buffer owner
                           (remove-hook 'kill-buffer-hook cancel t)
                           (remove-hook 'change-major-mode-hook cancel t))))))
    (when (kargu-async-pending-p task)
      (if (kargu-bridge-read--elapsed-p task)
          (kargu-async-finish task nil "Native read deadline expired")
        (kargu-async-add-cleanup
         task
         (kargu-bridge-ensure
          (kargu-application-wrap app
				  (kargu-async-wrap
				   task (lambda (connection failure)
					  (kargu-bridge-read--dispatch task owner arguments request connection failure decode))))))))
    task))

(defun kargu-bridge-read--dispatch (task owner arguments request connection failure &optional decode)
  "Dispatch REQUEST with ARGUMENTS on CONNECTION for TASK and OWNER.
FAILURE is a startup error; DECODE converts successful DTOs."
  (cond
   ((kargu-bridge-read--elapsed-p task) (kargu-async-finish task nil "Native read deadline expired"))
   (failure (kargu-async-finish task nil "Rust core unavailable; check kargu-bridge-binary-path"))
   (t (let ((id (funcall request connection arguments
			 (kargu-async-wrap task (lambda (result error-data)
                                                  (kargu-bridge-read--result task result error-data decode)))
			 :owner owner)))
	(when id
          (kargu-async-add-cleanup task (lambda () (kargu-bridge-cancel connection id))))))))

(provide 'kargu/bridge/read)
;;; read.el ends here
