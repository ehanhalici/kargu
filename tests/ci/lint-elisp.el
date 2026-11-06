;;; lint-elisp.el --- Source checks with disposable bytecode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; File names are passed after -- on the command line, relative to the root.
;; Run under -Q; explicitly supply the CI package load path when needed.

;;; Code:

(require 'cl-lib)
(require 'bytecomp)
(require 'checkdoc)
(require 'kargu)
(require 'tests/test-helpers)

(let ((files (delete "--" command-line-args-left))
      (directory (make-temp-file "kargu-ci-bytecode-" t))
      (byte-compile-error-on-warn t))
  (setq command-line-args-left nil)
  (unwind-protect
      (let ((byte-compile-dest-file-function
             (lambda (file)
               (expand-file-name
                (concat (secure-hash 'sha256 file) ".elc") directory))))
        (dolist (file files)
          (with-temp-buffer
            (insert-file-contents file)
            (emacs-lisp-mode)
            (check-parens))
          (unless (byte-compile-file file)
            (error "Byte compilation failed: %s" file))
          (cl-letf (((symbol-function 'checkdoc-error)
                     (lambda (_point text)
                       (error "Checkdoc failed for %s: %s" file text))))
            (checkdoc-file file))))
    (delete-directory directory t)))

;;; lint-elisp.el ends here
