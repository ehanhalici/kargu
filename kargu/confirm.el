;;; confirm.el --- UI-independent confirmation port -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Consumers describe a confirmation; presentation is an optional adapter.
;; Without an adapter, decisions always reject, stop or cancel.  Loading
;; this contract does not load a view or allocate pending UI requests.

;;; Code:

(require 'cl-lib)
(require 'kargu/contract/assert)
(require 'kargu/async)

(defvar kargu-execution--current)

(defvar kargu-confirm--mock-decision nil
  "Dynamically bound decision for UI adapter tests, never a headless grant.")

(cl-defstruct (kargu-confirmation (:constructor kargu-confirm--request))
  "A presentation operation and borrowed read-only confirmation options."
  (operation :prompt :read-only t)
  (options nil :read-only t))

(defun kargu-present-confirmation (request)
  "Present confirmation REQUEST through an optional adapter.
Adapters own pending UI resources and must deliver the decision once."
  (when (eq (kargu-confirmation-operation request) :prompt)
    (let ((options (kargu-confirmation-options request)))
      (funcall (plist-get options :on-decision)
               (or (plist-get options :default-action) :stop)))))

(defun kargu-confirm (&rest options)
  "Request an asynchronous decision described by OPTIONS.
Use the existing :actions, :on-decision and presentation field names.
The default action must be :reject, :stop or :cancel, never approval."
  (unless (and (proper-list-p options) (cl-evenp (length options)))
    (error "Confirmation options must be a property list"))
  (kargu-contract-assert #'functionp (plist-get options :on-decision))
  (unless (memq (plist-get options :default-action) '(nil :reject :stop :cancel))
    (error "Confirmation fallback must reject, stop or cancel"))
  (if kargu-execution--current
      (kargu-confirm--owned options)
    (kargu-present-confirmation (kargu-confirm--request :options options))))

(defun kargu-confirm--owned (options)
  "Present OPTIONS with a child task owning only its opaque UI handle."
  (let* ((callback (plist-get options :on-decision))
         (task (kargu-async-start (lambda (decision _error) (funcall callback decision))))
         (owned (plist-put (copy-sequence options) :on-decision
                           (kargu-async-wrap task
                                             (lambda (decision) (kargu-async-finish task decision)))))
         (handle (condition-case err
                     (kargu-present-confirmation (kargu-confirm--request :options owned))
                   (error (kargu-async-cancel task) (signal (car err) (cdr err))))))
    (when handle
      (kargu-async-add-cleanup task (lambda () (kargu-cancel-confirmation handle))))
    handle))

(defun kargu-dismiss-confirmations ()
  "Dismiss pending confirmations through the active presentation adapter."
  (kargu-present-confirmation (kargu-confirm--request :operation :dismiss)))

(defun kargu-cancel-confirmation (handle)
  "Cancel only the pending confirmation owned by opaque HANDLE."
  (kargu-present-confirmation
   (kargu-confirm--request :operation :cancel :options (list :handle handle))))

(provide 'kargu/confirm)
;;; confirm.el ends here
