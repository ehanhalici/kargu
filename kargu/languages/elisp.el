;;; elisp.el --- Emacs Lisp language profile for Kargu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Use Emacs's native xref and imenu support, without an external server.

;;; Code:

(require 'kargu/languages/core)

(defun kargu-language-elisp--present-p (root)
  "Check for Emacs Lisp project markers in ROOT."
  (or (kargu-languages--has-file-p root "Cask")
      (kargu-languages--has-file-p root "Eldev")
      (kargu-languages--has-file-p root "Eask")
      (ignore-errors
        (directory-files root nil "\\.el\\'" t))))

(defun kargu-language-elisp--file-command (arguments)
  "Return an Emacs command applying ARGUMENTS to actual project Lisp files."
  (format "find . -path './.git' -prune -o -type f -name '*.el' -exec emacs -Q --batch %s {} +"
          arguments))

(defun kargu-language-elisp-toolchain (root)
  "Return validation commands for actual Lisp files and a runner in ROOT."
  (let ((runner (seq-find (lambda (path) (file-regular-p (expand-file-name path root)))
                          '("tests/run-tests.el" "test/run-tests.el")))
        (lint '(progn
                 (dolist (file command-line-args-left)
                   (with-temp-buffer
                     (insert-file-contents file)
                     (emacs-lisp-mode)
                     (check-parens)))
                 (setq command-line-args-left nil))))
    (list :build-cmd (kargu-language-elisp--file-command "-L . -f batch-byte-compile")
          :test-cmd (and runner
                         (concat "emacs -Q --batch -L . --eval "
                                 (shell-quote-argument "(progn (require 'package) (package-initialize))")
                                 " -l " (shell-quote-argument runner)))
          :lint-cmd (kargu-language-elisp--file-command
                     (concat "--eval " (shell-quote-argument (prin1-to-string lint))))
          :notes (concat
                  "Use native xref and imenu, not an external language server. "
                  "Build and parenthesis checks target project .el files. "
                  (if runner "The test command loads the existing project runner."
                    "No conventional ERT runner was found; read project instructions to select tests. Never treat zero loaded tests as verification.")))))

(defconst kargu-language-elisp-spec
  (kargu-make-language-spec
   :id 'emacs-lisp
   :name "Emacs Lisp"
   :priority 10
   :extensions '("el")
   :modes '(emacs-lisp-mode)
   :requires-lsp nil
   :detectors (list #'kargu-language-elisp--present-p)
   :toolchain #'kargu-language-elisp-toolchain
   :debugger
   '(:adapter "none"
     :supports-eval nil
     :supports-method-calls nil
     :eval-guidance
     "Emacs Lisp has no debug adapter in this profile. Use ERT or the Emacs debugger, not debug_eval."
     :variable-inspection-advice
     "Read the definition with read_file. There is no DAP scope.")
   :lsp-notes
   "Emacs Lisp uses native xref definitions and imenu symbols. Verify changes with byte compilation, Checkdoc and project ERT tests.")
  "Language profile using Emacs's native Lisp navigation tools.")

(kargu-language-register kargu-language-elisp-spec)

(provide 'kargu/languages/elisp)

;;; elisp.el ends here
