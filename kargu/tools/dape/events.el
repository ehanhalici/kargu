;;; events.el --- Connection-bearing debugger notifications -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Dape's global UI hooks omit the emitting adapter.  Observe its event
;; dispatcher instead, after the adapter state has been updated.

;;; Code:

(require 'kargu/core/log)

(defvar kargu-dape--event-generations (make-hash-table :test #'eq :weakness 'key)
  "State notification generation for each live adapter identity.")

(defun kargu-dape-event-generation (connection)
  "Return CONNECTION's state generation without retaining a discarded adapter."
  (gethash connection kargu-dape--event-generations 0))

(defvar kargu-dape-event-hook nil
  "Hook receiving (CONNECTION EVENT) after a Dape state notification.
Consumers must check their captured adapter and asynchronous task lifetime.")

(defun kargu-dape--observe-event (connection event _body)
  "Publish CONNECTION's state EVENT after Dape has handled its BODY."
  (save-match-data
    (when (memq event '(initialized stopped continued exited terminated))
      (puthash connection (1+ (kargu-dape-event-generation connection)) kargu-dape--event-generations)
      (run-hook-wrapped
       'kargu-dape-event-hook
       (lambda (listener)
         (condition-case err
             (funcall listener connection event)
           (error (kargu-log 'warn "Debugger event listener: %s" (error-message-string err))))
         nil)))))

(with-eval-after-load 'dape
  (when (fboundp 'kargu-dape--observe-event)
    (advice-add 'dape-handle-event :after #'kargu-dape--observe-event)))

(defun kargu/tools/dape/events-unload-function ()
  "Remove debugger event observation when this feature is unloaded."
  (advice-remove 'dape-handle-event #'kargu-dape--observe-event)
  nil)

(provide 'kargu/tools/dape/events)
;;; events.el ends here
