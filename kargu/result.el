;;; kargu/result.el --- Railway-Oriented Programming (Result / Either) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Result (Either) algebraic data type for Railway-Oriented Programming.
;; Replaces unstructured throw/panic and nested if-else checks with clean,
;; monadic and composable error handling tracks.
;; Public: `kargu-ok`, `kargu-err`, `kargu-ok-p`, `kargu-err-p`,
;; `kargu-result-value`, `kargu-result-error`, `kargu-result-bind`,
;; `kargu-result-map`, `kargu-railway`.

;;; Code:

(require 'cl-lib)

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

(defun kargu-result-error (result)
  "Extract the error message from a failed RESULT, or nil."
  (when (kargu-err-p result)
    (kargu-result-err-message result)))

(defun kargu-result-code (result)
  "Extract the error code from a failed RESULT, or nil."
  (when (kargu-err-p result)
    (kargu-result-err-code result)))

(defun kargu-result-data (result)
  "Extract the error payload data from a failed RESULT, or nil."
  (when (kargu-err-p result)
    (kargu-result-err-data result)))

;;;; Monadic operations ---------------------------------------------------

(defun kargu-result-bind (result fn)
  "Monadic bind (>>=) for RESULT and function FN.
If RESULT is Ok, passes its unwrapped value to FN (which must return a Result).
If RESULT is Err, propagates the Err immediately without calling FN."
  (if (kargu-ok-p result)
      (funcall fn (kargu-result-ok-value result))
    result))

(defun kargu-result-map (result fn)
  "Functor map for RESULT and transformation function FN.
If RESULT is Ok, applies FN to its value and wraps the return in `kargu-ok'.
If RESULT is Err, returns RESULT untouched."
  (if (kargu-ok-p result)
      (kargu-ok (funcall fn (kargu-result-ok-value result)))
    result))

(defun kargu-result-unwrap (result &optional default)
  "Return RESULT value if Ok.  If Err, return DEFAULT or signal an error."
  (cond
   ((kargu-ok-p result)
    (kargu-result-ok-value result))
   (default default)
   (t (error "Unwrap failed on Result: %s" (kargu-result-err-message result)))))

;;;; Railway chaining macro -----------------------------------------------

(defmacro kargu-railway (&rest forms)
  "Execute FORMS in sequential Railway-Oriented steps.
Each binding is (VAR FORM).  If FORM evaluates to an error Result,
execution halts and the error is returned immediately.
The final form is evaluated with all previous variables bound.

Usage:
  (kargu-railway
    (a (compute-step-1))
    (b (compute-step-2 a))
    (kargu-ok (+ a b)))"
  (if (null (cdr forms))
      (car forms)
    (let ((binding (car forms))
          (rest (cdr forms)))
      (if (consp binding)
          (let ((var (car binding))
                (expr (cadr binding)))
            `(kargu-result-bind
              ,expr
              (lambda (,var)
                (kargu-railway ,@rest))))
        `(kargu-result-bind
          ,binding
          (lambda (_)
            (kargu-railway ,@rest)))))))

(provide 'kargu/result)

;;; kargu/result.el ends here
