;;; state.el --- Owned native metadata delivery state -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Publication tickets and immutable observations, not a second model store.
;; Native code alone normalizes fields, resolves aliases and merges overrides.

;;; Code:

(require 'cl-lib)
(require 'kargu/bridge/application)

(defconst kargu-bridge-models--source-limit (* 8 1024 1024)
  "Maximum complete metadata command bytes.")
(defconst kargu-bridge-models--view-limit (* 16 1024 1024)
  "Maximum complete native projection bytes.")

(cl-defstruct (kargu-bridge-models (:constructor kargu-bridge-models--make))
  "One application's native lease, serial delivery queue and committed view."
  app connection scope active queue latest view-cell fault (bytes 0))

(cl-defstruct (kargu-bridge-model-ticket (:constructor kargu-bridge-model-ticket--make))
  "One captured submission and its immutable committed-revision receipt."
  service provider source specs callback valid-p owner cleanup timer waiters
  upload chunks view-cell failure cancel-reason reconcile
  (status :pending) (phase :queued) (offset 0) (position 0) (max-chunk 0)
  (bytes 0) revision total (read-bytes 0) commit-sent released)

(defun kargu-bridge-models--view (service)
  "Borrow SERVICE's private committed DTO for trusted internal delivery."
  (get (kargu-bridge-models-view-cell service) 'value))

(defun kargu-bridge-model-ticket-view (ticket)
  "Return a detached committed TICKET receipt, never its mutable cache storage."
  (kargu-bridge-models--copy (get (kargu-bridge-model-ticket-view-cell ticket) 'value)))

(defun kargu-bridge-models--copy (value)
  "Detach JSON VALUE, including strings and nested mutable containers."
  (cond
   ((stringp value) (copy-sequence value))
   ((hash-table-p value)
    (let ((copy (make-hash-table :test #'equal)))
      (maphash (lambda (key item)
                 (puthash (kargu-bridge-models--copy key)
                          (kargu-bridge-models--copy item) copy)) value)
      copy))
   ((vectorp value) (vconcat (mapcar #'kargu-bridge-models--copy value)))
   ((consp value) (cons (kargu-bridge-models--copy (car value))
			(kargu-bridge-models--copy (cdr value))))
   (t value)))

(defun kargu-bridge-models--current-p (service)
  "Check SERVICE's exact live native owner without starting or rebinding it."
  (and (eq service (gethash :native-models
                            (kargu-application-services (kargu-bridge-models-app service))))
       (eq (kargu-bridge-status (kargu-bridge-models-connection service)) 'ready)
       (when-let* ((scope (kargu-bridge-application-current-scope
                           (kargu-bridge-models-app service)
                           (kargu-bridge-models-connection service))))
         (kargu-bridge-application-scope-equal-p scope (kargu-bridge-models-scope service)))))

(defun kargu-bridge-models--notify (ticket value failure)
  "Finish TICKET's user deliveries exactly once with VALUE or FAILURE."
  (when-let* ((timer (kargu-bridge-model-ticket-timer ticket)))
    (cancel-timer timer)
    (setf (kargu-bridge-model-ticket-timer ticket) nil))
  (when-let* ((cleanup (kargu-bridge-model-ticket-cleanup ticket)))
    (when (buffer-live-p (kargu-bridge-model-ticket-owner ticket))
      (with-current-buffer (kargu-bridge-model-ticket-owner ticket)
        (remove-hook 'kill-buffer-hook cleanup t)
        (remove-hook 'change-major-mode-hook cleanup t)))
    (setf (kargu-bridge-model-ticket-cleanup ticket) nil))
  (let ((callback (kargu-bridge-model-ticket-callback ticket))
        (waiters (kargu-bridge-model-ticket-waiters ticket)))
    (setf (kargu-bridge-model-ticket-callback ticket) nil
          (kargu-bridge-model-ticket-waiters ticket) nil)
    (dolist (waiter (cons (list callback) (nreverse waiters)))
      (let ((function (car waiter)))
        (setcar waiter nil)
        (when function
          (kargu-bridge--callback function (and value (kargu-bridge-models--copy value))
                                  (and failure (kargu-bridge-models--copy failure))))))))

(provide 'kargu/bridge/models/state)
;;; state.el ends here
