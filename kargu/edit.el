;;; edit.el --- Optional editing and change-evidence ports -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Consumers need change evidence and guarded proposals, not a concrete
;; diff/review implementation.  Composition installs optional providers.
;; No provider means no tracked changes and, critically, no editing grant.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/contract/assert)
(require 'kargu/contract/result)

(cl-defstruct (kargu-change-query (:constructor kargu-change-query-create))
  "A change-evidence OPERATION and its borrowed path or opaque VALUE."
  (operation nil :read-only t) (value nil :read-only t))

(cl-defstruct (kargu-edit-request (:constructor kargu-edit-request-create))
  "A PATH/CONTENT proposal; CALLBACK receives its final description once."
  (path nil :read-only t) (content nil :read-only t) (callback nil :read-only t))

(defun kargu-query-changes (_query)
  "Handle a change QUERY through an optional provider; default to none."
  nil)

(defun kargu-edit-changes (operation &optional value)
  "Query change-evidence OPERATION with its optional VALUE.
Absence of evidence is not a successful diagnostic verification."
  (unless (memq operation '(:available :pending :modified :capture :baseline :consume
                            :consume-file :reset :abort))
    (error "Unknown change-evidence operation: %S" operation))
  (when (memq operation '(:capture :consume-file))
    (kargu-contract-assert #'kargu-contract-filepath-p value))
  (let ((result (kargu-query-changes
                 (kargu-change-query-create :operation operation :value value))))
    (pcase operation
      (:available (kargu-contract-assert (lambda (x) (memq x '(nil t))) result))
      ((or :pending :modified)
       (kargu-contract-assert
        (lambda (paths) (and (proper-list-p paths)
                            (cl-every #'kargu-contract-filepath-p paths))) result)))
    result))

(defun kargu-edit-submit (request)
  "Reject edit REQUEST when no guarded editing provider is installed."
  (let ((message "ERROR: editing provider unavailable; nothing was changed"))
    (if-let* ((callback (kargu-edit-request-callback request)))
        (funcall callback message)
      message)))

(cl-defun kargu-edit-propose (path content &key callback)
  "Propose CONTENT at PATH; deliver a description to CALLBACK when supplied."
  (kargu-contract-assert #'kargu-contract-filepath-p path)
  (kargu-contract-assert #'stringp content)
  (kargu-contract-assert #'kargu-contract-callback-p callback)
  (let* ((delivered nil)
         (result
          (kargu-edit-submit
           (kargu-edit-request-create
            :path path :content content
            :callback (when callback
                        (lambda (result)
                          (unless delivered
                            (kargu-contract-assert #'stringp result)
                            (setq delivered t)
                            (funcall callback result))))))))
    (unless callback (kargu-contract-assert #'stringp result))
    result))

(cl-defun kargu-edit-submit-plan (service plan &key callback)
  "Submit transaction PLAN to edit SERVICE with optional CALLBACK.
When no editing provider is installed, reject with unavailable error."
  (ignore service plan)
  (let ((result (kargu-err "ERROR: editing provider unavailable; nothing was changed" :unavailable)))
    (if callback
        (funcall callback result)
      result)))

(provide 'kargu/edit)
;;; edit.el ends here
