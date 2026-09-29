;;; kargu/contract/result.el --- Railway-Oriented Programming (Result / Either) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Result (Either) algebraic data type for Railway-Oriented Programming.
;; Replaces unstructured throw/panic and nested if-else checks with clean,
;; monadic and composable error handling tracks.
;; Public: `kargu-ok', `kargu-err', `kargu-ok-p', `kargu-err-p',
;; `kargu-result-value'.

;;; Code:

(require 'cl-lib)

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

;;;; Result algebraic data types ------------------------------------------

(cl-defstruct (kargu-result-ok (:constructor kargu-ok (value)))
  "Successful result carrying VALUE."
  value)

(cl-defstruct (kargu-result-err (:constructor kargu-err (message &optional code data)))
  "Failed result carrying MESSAGE, optional numeric/symbol CODE, and DATA."
  message
  code
  data)

(defun kargu-ok-p (result)
  "Return non-nil if RESULT is a successful `kargu-result-ok'."
  (kargu-result-ok-p result))

(defun kargu-err-p (result)
  "Return non-nil if RESULT is an error `kargu-result-err'."
  (kargu-result-err-p result))

(defun kargu-result-value (result)
  "Extract the value from a successful RESULT, or nil."
  (when (kargu-ok-p result)
    (kargu-result-ok-value result)))

(provide 'kargu/contract/result)

;;; kargu/contract/result.el ends here
