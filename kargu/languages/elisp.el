;;; kargu/languages/elisp.el --- Emacs Lisp language profile for Kargu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Emacs Lisp has no language server.  The project root is the
;; directory the user names, not a directory inferred from Eglot.

;;; Code:

(require 'kargu/languages/core)

(defvar kargu-elisp-project-root nil
  "Directory the user chose as the Emacs Lisp project root.")

(defun kargu-language-elisp--present-p (root)
  "Return non-nil when ROOT looks like an Emacs Lisp project."
  (or (kargu-languages--has-file-p root "Cask")
      (kargu-languages--has-file-p root "Eldev")
      (kargu-languages--has-file-p root "Eask")
      (ignore-errors
        (directory-files root nil "\\.el\\'" t))))

(defun kargu-language-elisp-ask-root (&optional peek)
  "Return the Emacs Lisp project root, asking when it is unknown.
PEEK non-nil never asks.  Batch Emacs does not ask.  There is no
language server to infer the root from."
  (cond
   ((and (stringp kargu-elisp-project-root)
         (not (string-empty-p kargu-elisp-project-root))
         (file-directory-p kargu-elisp-project-root))
    (file-name-as-directory (expand-file-name kargu-elisp-project-root)))
   ((or peek noninteractive) nil)
   (t
    (message "kargu: Emacs Lisp has no language server; the project root cannot be taken from Eglot.")
    (let ((dir (read-directory-name
                "Emacs Lisp project root (no language server): "
                nil nil t)))
      (setq kargu-elisp-project-root
            (file-name-as-directory (expand-file-name dir)))
      kargu-elisp-project-root))))

(defun kargu-elisp-set-project-root ()
  "Ask again for the Emacs Lisp project root."
  (interactive)
  (setq kargu-elisp-project-root nil)
  (kargu-language-elisp-ask-root))

(defconst kargu-language-elisp-spec
  (kargu-make-language-spec
   :id 'emacs-lisp
   :name "Emacs Lisp"
   :priority 10
   :extensions '("el")
   :modes '(emacs-lisp-mode lisp-interaction-mode)
   :requires-lsp nil
   :root-fn #'kargu-language-elisp-ask-root
   :detectors (list #'kargu-language-elisp--present-p)
   :toolchain
   '(:build-cmd "emacs -Q --batch -f batch-byte-compile"
     :test-cmd "emacs -Q --batch -l ert -f ert-run-tests-batch-and-exit"
     :lint-cmd "emacs -Q --batch -f check-parens"
     :notes "No language server. The project root is the directory the user names.")
   :debugger
   '(:adapter "none"
     :supports-eval nil
     :supports-method-calls nil
     :eval-guidance
     "Emacs Lisp has no debug adapter in this profile. Use ERT or the Emacs debugger, not debug_eval."
     :variable-inspection-advice
     "Read the definition with read_file. There is no DAP scope.")
   :lsp-notes
   "No language server. Use imenu and read_file for functions, macros, and defcustoms. Do not start Eglot for this language."))

(kargu-language-register kargu-language-elisp-spec)

(provide 'kargu/languages/elisp)

;;; kargu/languages/elisp.el ends here
