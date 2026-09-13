;;; kargu/contract/assert.el --- Contract assertions and validation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Ingress and egress assertion operators and railway-oriented validation.

;;; Code:

;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory (Magit-style kargu/core features).
(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'kargu/contract/result)
(require 'kargu/contract/types)

(defun kargu-contract-assert (pred value &optional format-string &rest format-args)
  "Assert that VALUE satisfies PRED at a module boundary.
If PRED returns nil, signal an error with FORMAT-STRING or a standard
contract violation message.  Returns VALUE on success."
  (if (funcall pred value)
      value
    (error "%s"
           (if format-string
               (apply #'format format-string format-args)
             (format "Contract violation: %S does not satisfy %s"
                     value (if (symbolp pred) pred "predicate"))))))

(defun kargu-contract-validate (pred value &optional context)
  "Railway-Oriented validation of VALUE against PRED.
Returns `kargu-ok' with VALUE if valid, or `kargu-err' with an explanation."
  (if (funcall pred value)
      (kargu-ok value)
    (kargu-err
     (format "Contract violation%s: %S does not satisfy %s"
             (if context (format " in %s" context) "")
             value
             (if (symbolp pred) pred "predicate")))))

(provide 'kargu/contract/assert)

;;; kargu/contract/assert.el ends here
