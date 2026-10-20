;;; context.el --- Explicit plan ownership and dispatch ports -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Plan owners supply identity validation, dispatch and optional presentation.
;; No concrete chat, loop or model provider is required by this contract.

;;; Code:

(require 'cl-lib)
(require 'kargu/contract/assert)
(require 'kargu/core/log)

(declare-function kargu-plan-record-origin "kargu/plan/store" (record))
(declare-function kargu-plan-record-root "kargu/plan/store" (record))

(cl-defstruct (kargu-plan-context (:constructor kargu-plan-context-create))
  "Captured ROOT/SESSION with validation, admission, dispatch and presentation."
  (root nil :read-only t) (session nil :read-only t)
  (current-p nil :read-only t) (preflight nil :read-only t)
  (dispatch nil :read-only t) (publish nil :read-only t))

(defun kargu-plan-context-for-buffer (origin)
  "Build a non-dispatching default context for headless ORIGIN."
  (kargu-contract-assert #'buffer-live-p origin)
  (kargu-plan-context-create
   :root (with-current-buffer origin
           (file-name-as-directory (file-truename default-directory)))
   :current-p (lambda (record)
                (with-current-buffer (kargu-plan-record-origin record)
                  (equal (kargu-plan-record-root record)
                         (file-name-as-directory (file-truename default-directory)))))))

(defun kargu-plan-context-validate (context)
  "Return valid CONTEXT before changing a plan owner."
  (kargu-contract-assert #'kargu-plan-context-p context)
  (kargu-contract-assert
   (lambda (root) (and (kargu-contract-filepath-p root) (file-name-absolute-p root)))
   (kargu-plan-context-root context))
  (kargu-contract-assert #'functionp (kargu-plan-context-current-p context))
  (dolist (callback (list (kargu-plan-context-preflight context)
                          (kargu-plan-context-dispatch context)
                          (kargu-plan-context-publish context)))
    (kargu-contract-assert #'kargu-contract-callback-p callback))
  context)

(provide 'kargu/plan/context)
;;; context.el ends here
