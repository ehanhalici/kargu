;;; elisp.el --- Emacs Lisp language profile for Kargu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Use Emacs's native xref and imenu support, without an external server.

;;; Code:

(require 'kargu/languages/core)

(defun kargu-language-elisp-toolchain (root)
  "Return ROOT's completed native Emacs Lisp command metadata."
  (kargu-project-probe-toolchain 'emacs-lisp root))

(defconst kargu-language-elisp-spec
  (kargu-make-language-spec
   :id 'emacs-lisp
   :name "Emacs Lisp"
   :priority 10
   :extensions '("el")
   :modes '(emacs-lisp-mode)
   :requires-lsp nil
   :detectors '("Cask" "Eldev" "Eask" (:root-extension "el"))
   :toolchain '(:native "elisp")
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
