;;; file-window.el --- Canonical file line windows -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Decode tool aliases once.  Missing bounds are not malformed bounds.

;;; Code:

(require 'cl-lib)
(require 'kargu/contract/assert)

(cl-defstruct (kargu-file-window (:constructor kargu-file-window--create))
  "A validated 1-based inclusive FROM/TO range; nil TO means through EOF."
  (from 1 :read-only t) (to nil :read-only t))

(cl-defun kargu-file-window-create (&key from to limit offset)
  "Validate FROM, TO, LIMIT and legacy OFFSET into one line window.
OFFSET is the legacy 1-based alias for FROM; only its zero value maps to
the first line.  LIMIT also applies without FROM.  An explicit TO and
LIMIT select their intersection.  Reject conflicting start aliases."
  (dolist (entry (list (cons 'from from) (cons 'to to) (cons 'limit limit)))
    (unless (or (null (cdr entry))
                (and (integerp (cdr entry)) (> (cdr entry) 0)))
      (error "Invalid %s: expected a positive integer" (car entry))))
  (unless (or (null offset) (natnump offset))
    (error "Invalid offset: expected a non-negative integer"))
  (let* ((alias (and offset (max 1 offset)))
         (first (or from alias 1))
         (last (and limit (+ first limit -1)))
         (end (cond ((and last to) (min last to)) (last) (t to))))
    (when (and from alias (/= from alias))
      (error "Conflicting from_line and offset"))
    (when (and end (< end first))
      (error "To_line (%d) is before from_line (%d)" end first))
    (kargu-file-window--create :from first :to end)))

(provide 'kargu/contract/file-window)
;;; file-window.el ends here
