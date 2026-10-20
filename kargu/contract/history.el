;;; history.el --- Owned conversation record -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A session owns one record.  No loading-time conversation is allocated.
;; Message containers are private; strings are borrowed read-only values.

;;; Code:

(require 'cl-lib)
(require 'kargu/contract/assert)

(cl-defstruct (kargu-history (:constructor kargu-history--create))
  "Owned protocol drafts and their derived prompt identity."
  messages-value tail-value system-key-value overlay-value)

(cl-defun kargu-history-create (&key messages)
  "Create an isolated history from MESSAGES, copying lists and vectors.
Drafts may need protocol repair before sending.  Scalar strings are
borrowed read-only, like the provider's immutable message text."
  (kargu-contract-assert #'proper-list-p messages)
  (let ((copy (copy-tree messages t)))
    (kargu-history--create :messages-value copy :tail-value (last copy))))

(provide 'kargu/contract/history)
;;; history.el ends here
