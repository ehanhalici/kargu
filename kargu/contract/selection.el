;;; selection.el --- Immutable session selection value -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Explicit provider/model choices and the effort override form one value.
;; Inherited configuration is distinct from explicitly disabled reasoning.

;;; Code:

(require 'cl-lib)
(require 'kargu/contract/assert)

(defconst kargu-selection-default-effort (make-symbol "configured-effort")
  "Uninterned inheritance tag, distinct from every provider effort name.")

(cl-defstruct (kargu-selection (:constructor kargu-selection--create))
  "Immutable choices; the default effort tag inherits configuration."
  (provider-value nil :read-only t) (model-value nil :read-only t)
  (effort-value kargu-selection-default-effort :read-only t))

(cl-defun kargu-selection-create (&key provider model (effort kargu-selection-default-effort))
  "Validate and copy explicit PROVIDER, MODEL and EFFORT into one value."
  (dolist (id (list provider model))
    (kargu-contract-assert
     (lambda (value) (or (null value) (kargu-contract-non-empty-string-p value))) id))
  (kargu-contract-assert (lambda (value) (or (null value) (symbolp value))) effort)
  (kargu-selection--create :provider-value (and provider (copy-sequence provider))
                           :model-value (and model (copy-sequence model))
                           :effort-value effort))

(provide 'kargu/contract/selection)
;;; selection.el ends here
