;;; data.el --- Pure scalar and record helpers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Compatibility helpers for native records and text.  No application,
;; state, session, configuration or UI is initialized by loading this file.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rx)

(defun kargu-aget (alist key &optional default)
  "Return the value for string KEY in ALIST or a hash table, or DEFAULT.
Safely handles malformed records, dotted pairs, and non-object data."
  (cond
   ((hash-table-p alist) (gethash key alist default))
   ((and (consp alist) (listp (cdr alist)))
      (condition-case nil
          (alist-get key alist default nil #'equal)
        (error default)))
   (t default)))

(defun kargu-nonempty (value)
  "VALUE if it is a non-empty string, else nil."
  (and (stringp value) (not (string-empty-p value)) value))

(defalias 'kargu--aget #'kargu-aget)
(defalias 'kargu--nonempty #'kargu-nonempty)

(defun kargu-to-int (value &optional default)
  "Coerce VALUE to an integer, or return DEFAULT (defaults to nil).
Handles integers, floats (rounded), and integer strings."
  (cond
   ((integerp value) value)
   ((floatp value)
    (condition-case nil (round value)
      (arith-error default)))
   ((stringp value)
    (let ((trimmed (string-trim value)))
      (if (string-match-p
           (rx string-start (opt (any "+-")) (+ digit) string-end) trimmed)
          (string-to-number trimmed)
        default)))
   (t default)))

(defun kargu-cap-text (text limit &optional label)
  "TEXT cut to LIMIT characters, with a one-line note when it was cut.
The note names LABEL (default \"text\") and the original length.  A
non-natural LIMIT leaves TEXT alone.  This is the one wording for a cut
that is not the model-bound tool output (see `kargu--truncate-for-model')."
  (if (and (natnump limit) (> (length text) limit))
      (concat (substring text 0 limit)
              (format "\n... [%s truncated: %d of %d chars shown]"
                      (or label "text") limit (length text)))
    text))

(provide 'kargu/core/data)
;;; data.el ends here
