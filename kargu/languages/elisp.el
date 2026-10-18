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

(defconst kargu-language-elisp-spec
  (kargu-make-language-spec
   :id 'emacs-lisp
   :name "Emacs Lisp"
   :priority 10
   :extensions '("el")
   :modes '(emacs-lisp-mode)
   :requires-lsp nil
   :detectors (list #'kargu-language-elisp--present-p)
   :toolchain
   '(:build-cmd "emacs -Q --batch -f batch-byte-compile"
     :test-cmd "emacs -Q --batch -l ert -f ert-run-tests-batch-and-exit"
     :lint-cmd "emacs -Q --batch -f check-parens"
     :notes "Use Emacs's built-in xref for definitions and imenu for file outlines. No external language server is required.")
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
