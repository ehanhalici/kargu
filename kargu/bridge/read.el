;;; read.el --- Owned native read callbacks -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Editor task/owner lifecycle for native read RPCs; no OS or matching engine.

;;; Code:

(require 'kargu/bridge)
(require 'kargu/async)

(defun kargu-bridge-read--result (task result error-data)
  "Finish TASK from typed native RESULT or ERROR-DATA, never display prefixes."
  (cond
   (error-data (kargu-async-finish task nil (gethash "message" error-data "Native read failed")))
   ((and (hash-table-p result) (gethash "outcome" result)
         (not (equal (gethash "outcome" result) "ok")))
    (kargu-async-finish task nil (format "Native read failed (%s): %s"
                                       (gethash "outcome" result) (gethash "text" result ""))))
   ((not (and (hash-table-p result) (stringp (gethash "text" result))))
    (kargu-async-finish task nil "Invalid native read result"))
   (t (kargu-async-finish task (gethash "text" result)))))

(defun kargu-bridge-read-task (callback arguments request)
  "Deliver CALLBACK through native REQUEST with captured ARGUMENTS.
Keep the parent task, owner buffer and take-once RPC cleanup."
  (let* ((owner (current-buffer))
         (task (kargu-async-start
                (lambda (text error-data)
                  (funcall callback (if error-data (concat "ERROR: " error-data) text))))))
    (kargu-async-add-cleanup
     task
     (kargu-bridge-ensure
      (kargu-async-wrap
       task
       (lambda (connection failure)
         (kargu-bridge-read--dispatch task owner arguments request connection failure)))))
    task))

(defun kargu-bridge-read--dispatch (task owner arguments request connection failure)
  "Dispatch REQUEST with ARGUMENTS on CONNECTION for TASK and OWNER.
FAILURE is a startup error; a failed start never invokes a fallback."
  (if failure
      (kargu-async-finish task nil "Rust core unavailable; check kargu-bridge-binary-path")
    (let ((id (funcall request connection arguments
                       (kargu-async-wrap task (lambda (result error-data)
                                                (kargu-bridge-read--result task result error-data)))
                       :owner owner)))
      (when id
        (kargu-async-add-cleanup task (lambda () (kargu-bridge-cancel connection id)))))))

(provide 'kargu/bridge/read)
;;; read.el ends here
