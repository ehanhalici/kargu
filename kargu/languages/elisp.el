;;; kargu/languages/elisp.el --- Emacs Lisp language profile for Kargu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Emacs Lisp uses the same Eglot session as every other language.
;; The project root is that server's project.  The user is not asked
;; for a directory.

;;; Code:

(require 'kargu/languages/core)

(defun kargu-language-elisp--present-p (root)
  "Return non-nil when ROOT looks like an Emacs Lisp project."
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
   :detectors (list #'kargu-language-elisp--present-p)
   :toolchain
   '(:build-cmd "emacs -Q --batch -f batch-byte-compile"
     :test-cmd "emacs -Q --batch -l ert -f ert-run-tests-batch-and-exit"
     :lint-cmd "emacs -Q --batch -f check-parens"
     :notes "Start Eglot in a project file before asking kargu to read or edit Emacs Lisp.")
   :debugger
   '(:adapter "none"
     :supports-eval nil
     :supports-method-calls nil
     :eval-guidance
     "Emacs Lisp has no debug adapter in this profile. Use ERT or the Emacs debugger, not debug_eval."
     :variable-inspection-advice
     "Read the definition with read_file. There is no DAP scope.")
   :lsp
   '(:name "ellsp"
     :binaries ("ellsp")
     :purpose "Language Server for Emacs Lisp (symbols, diagnostics, and navigation)"
     :hint "Install ellsp, visit a project file, then M-x eglot")
   :lsp-notes
   "Emacs Lisp symbols come from the connected language server: functions, macros, and defcustoms."))

(kargu-language-register kargu-language-elisp-spec)

(provide 'kargu/languages/elisp)

;;; kargu/languages/elisp.el ends here
