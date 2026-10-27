;;; deps.el --- Mandatory toolchain & dependency validation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Validates configured prerequisites; model HTTP itself is owned by Rust.
;; Optional UI, Git and editor adapters do not block unrelated runs.
;; User-configured extra mandatory requirements are still enforced.
;; Project LSP servers are checked only in optional setup diagnostics.
;;
;; If mandatory tools are missing:
;;   * Renders a clear and sensible error banner in the chat / prompt screen
;;   * Blocks prompt submission (kargu-chat-send, kargu-chat-prompt, kargu-loop-send)
;;     until all tools are present.
;;
;; Public API:
;;   `kargu-deps-missing', `kargu-deps-missing-p',
;;   `kargu-deps-format-missing-report', `kargu-deps-assert-all-present'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'kargu/core)
(require 'kargu/languages/core)

(declare-function eglot-current-server "eglot")
(defvar eglot--managed-mode)
(defvar eglot-server-programs)

(defgroup kargu-deps nil
  "Toolchain and dependency validation for Kargu."
  :group 'kargu
  :prefix "kargu-deps-")

(defcustom kargu-deps-mandatory-packages
  nil
  "Packages required before starting a native model run.
UI and editor integrations are optional.  Explicit additions still block
run admission when absent; existing user customization is not rewritten."
  :type '(repeat symbol)
  :group 'kargu-deps)

(defcustom kargu-deps-package-metadata
  '((transient
     :name "transient"
     :purpose "Keyboard-driven interactive menu and control panel interface"
     :hint "M-x package-install RET transient")
    (eglot
     :name "eglot"
     :purpose "Language Server Protocol (LSP) client for code analysis, symbols, and diagnostics"
     :hint "M-x package-install RET eglot")
    (dape
     :name "dape"
     :purpose "Debug Adapter Protocol client (live debugging, stack, variables, eval)"
     :hint "M-x package-install RET dape")
    (magit
     :name "magit"
     :purpose "Git client and repository version control interface"
     :hint "M-x package-install RET magit"))
  "Metadata for mandatory Emacs packages."
  :type 'alist
  :group 'kargu-deps)

(defcustom kargu-deps-mandatory-executables
  nil
  "Executables required before starting a native model run.
The Rust bridge checks its own configured binary at connection startup.
Feature-specific tools such as Git are checked when used,
unless explicitly added as a global requirement."
  :type '(repeat string)
  :group 'kargu-deps)

(defcustom kargu-deps-executable-metadata
  '(("git"
     :name "git"
     :purpose "Git version control system executable (CLI)"
     :hint "Install git via your system package manager (e.g. apt install git / brew install git)")
    ("curl"
     :name "curl"
     :purpose "Optional user-configured HTTP command-line client"
     :hint "Install curl via your system package manager (e.g. apt install curl / brew install curl)"))
  "Metadata for mandatory CLI executables."
  :type 'alist
  :group 'kargu-deps)

(defcustom kargu-deps-check-lsp-server t
  "Whether optional setup diagnostics check the project's LSP server."
  :type 'boolean
  :group 'kargu-deps)

(defcustom kargu-deps-lsp-server-overrides nil
  "Alist mapping language ID to an LSP server plist that replaces the profile's.
Each value has `:name', `:binaries', `:purpose' and `:hint', like the `:lsp'
field of a language profile.  The profiles under `kargu/languages/' supply
the defaults."
  :type 'alist
  :group 'kargu-deps)

(defun kargu-deps--lsp-entry (lang-spec)
  "LSP server plist for LANG-SPEC: a user override, else the profile's own."
  (or (cdr (assq (kargu-language-spec-id lang-spec)
                 kargu-deps-lsp-server-overrides))
      (kargu-language-spec-lsp lang-spec)))

;;;; Detection Helpers ----------------------------------------------------

(defun kargu-deps-package-installed-p (pkg)
  "Return non-nil if Emacs package PKG is installed or built-in."
  (or (featurep pkg)
      (locate-library (symbol-name pkg))
      (and (fboundp 'package-installed-p)
           (ignore-errors (package-installed-p pkg)))))

(defun kargu-deps-executable-status (exe &optional root)
  "Return native EXE observation for ROOT: :present, :missing or :unknown."
  (let* ((view (kargu-project-probe-view root))
         (value (and view (gethash exe (gethash "executables" view) :unknown))))
    (cond ((eq value t) :present) ((eq value :json-false) :missing) (t :unknown))))

(defun kargu-deps-executable-installed-p (exe &optional root)
  "Return non-nil for a completed native EXE observation under ROOT."
  (eq (kargu-deps-executable-status exe root) :present))

(defun kargu-deps--active-eglot-server-p (&optional root)
  "Return non-nil if an active Eglot server is running for ROOT."
  (let ((proj-root (or root (and (fboundp 'kargu-session-project-root)
                                 (kargu-session-project-root)))))
    (cl-some (lambda (b)
               (and (buffer-live-p b)
                    (with-current-buffer b
                      (and (bound-and-true-p eglot--managed-mode)
                           (fboundp 'eglot-current-server)
                           (eglot-current-server)
                           (if proj-root
                               (let ((bf (buffer-file-name b)))
                                 (or (null bf)
                                     (string-prefix-p (expand-file-name proj-root)
                                                      (expand-file-name bf))))
                             t)))))
             (buffer-list))))

(defun kargu-deps-detect-project-language (&optional root)
  "Detect programming language spec for ROOT or active buffer."
  (let* ((proj (or root (and (fboundp 'kargu-session-project-root)
                             (kargu-session-project-root))
                   default-directory))
         (spec (and (fboundp 'kargu-language-detect)
                    (kargu-language-detect proj))))
    (or spec
        (let ((file (or (buffer-file-name)
                        (and (fboundp 'kargu-lsp-context-file)
                             (kargu-lsp-context-file)))))
          (when (and file (fboundp 'kargu-language-detect-by-extension))
            (kargu-language-detect-by-extension file))))))

(defun kargu-deps--check-lsp-server (lang-spec &optional root)
  "Return missing server information for LANG-SPEC in ROOT, or nil."
  (when (and kargu-deps-check-lsp-server
             lang-spec
             (kargu-language-requires-lsp-p lang-spec))
    (let* ((lang-id (kargu-language-spec-id lang-spec))
           (lang-name (kargu-language-spec-name lang-spec))
           (entry (kargu-deps--lsp-entry lang-spec))
           (candidates (and entry (plist-get entry :binaries)))
           (server-name (or (and entry (plist-get entry :name)) (format "%s-lsp" lang-id)))
           (purpose (or (and entry (plist-get entry :purpose))
                        (format "Language Server for %s" lang-name)))
           (hint (or (and entry (plist-get entry :hint))
                     (format "Install an appropriate LSP server for %s" lang-name))))
      (cond
       ;; Active Eglot connection satisfies the requirement
       ((kargu-deps--active-eglot-server-p root)
        nil)
       ;; Any candidate executable found satisfies the requirement
       ((and candidates (cl-some (lambda (exe) (kargu-deps-executable-installed-p exe root)) candidates))
        nil)
       ;; Missing candidate: return report plist
       (candidates
        (list :id lang-id
              :name server-name
              :type 'lsp-server
              :purpose purpose
              :install-hint hint
              :language lang-name))
       ;; If not in our table, check eglot-server-programs if major-mode matches
       (t
        (let ((mode-check (and (boundp 'eglot-server-programs)
                               (kargu-deps--check-eglot-server-programs major-mode))))
          (when (and mode-check (not (plist-get mode-check :installed)))
            (list :id (plist-get mode-check :name)
                  :name (plist-get mode-check :name)
                  :type 'lsp-server
                  :purpose (format "Language Server for %s mode" major-mode)
                  :install-hint (plist-get mode-check :hint)
                  :language lang-name))))))))

(defun kargu-deps--check-eglot-server-programs (major-mode-sym)
  "Check if `eglot-server-programs' specifies a server for MAJOR-MODE-SYM."
  (when (and (boundp 'eglot-server-programs) (symbolp major-mode-sym))
    (let ((contact (cl-some (lambda (entry)
                              (let ((modes (car entry)))
                                (when (if (listp modes)
                                          (memq major-mode-sym modes)
                                        (eq major-mode-sym modes))
                                  (cdr entry))))
                            eglot-server-programs)))
      (cond
       ((listp contact)
        (let ((cmd (car contact)))
          (when (stringp cmd)
            (list :name cmd
                  :installed (kargu-deps-executable-installed-p cmd)
                  :hint (format "Executable '%s' not found on PATH" cmd)))))
       ((stringp contact)
        (list :name contact
              :installed (kargu-deps-executable-installed-p contact)
              :hint (format "Executable '%s' not found on PATH" contact)))))))

;;;; Main Validation Functions --------------------------------------------

(defun kargu-deps-missing (&optional root include-optional packages-only)
  "Return a list of missing dependency plists for ROOT.
Checks editor packages and completed native CLI observations.  PACKAGES-ONLY
skips CLI observations for synchronous admission; owned preparation refreshes
them before the first request.  INCLUDE-OPTIONAL also
checks the project LSP server for setup diagnostics, not run admission.
Each plist contains:
  :id           - Symbol or string identifying the tool
  :name         - Human-readable name string
  :type         - \\='package, \\='executable, or \\='lsp-server
  :purpose      - Explanation of why this tool is mandatory
  :install-hint - Guidance on how to install it"
  (let (missing)
    ;; 1. Check mandatory Emacs packages
    (dolist (pkg kargu-deps-mandatory-packages)
      (unless (kargu-deps-package-installed-p pkg)
        (let* ((meta (cdr (assq pkg kargu-deps-package-metadata)))
               (name (or (and meta (plist-get meta :name)) (symbol-name pkg)))
               (purpose (or (and meta (plist-get meta :purpose)) "Required Emacs package"))
               (hint (or (and meta (plist-get meta :hint))
                         (format "M-x package-install RET %s" pkg))))
          (push (list :id pkg
                      :name name
                      :type 'package
                      :purpose purpose
                      :install-hint hint)
                missing))))

    ;; 2. Check mandatory CLI executables
    (dolist (exe (unless packages-only kargu-deps-mandatory-executables))
      (when (eq (kargu-deps-executable-status exe root) :missing)
        (let* ((meta (cdr (assoc exe kargu-deps-executable-metadata)))
               (name (or (and meta (plist-get meta :name)) exe))
               (purpose (or (and meta (plist-get meta :purpose)) "Required system executable"))
               (hint (or (and meta (plist-get meta :hint))
                         (format "Install '%s' using your system package manager" exe))))
          (push (list :id exe
                      :name name
                      :type 'executable
                      :purpose purpose
                      :install-hint hint)
                missing))))

    ;; 3. Check language-specific LSP server if project language detected
    (when (and include-optional kargu-deps-check-lsp-server)
      (when-let* ((lang-spec (kargu-deps-detect-project-language root))
                  (lsp-missing (kargu-deps--check-lsp-server lang-spec root)))
        (push lsp-missing missing)))

    (nreverse missing)))

(defun kargu-deps-missing-p (&optional root)
  "Return non-nil if any mandatory tool or dependency is missing for ROOT."
  (not (null (kargu-deps-missing root))))

;;;; Formatting & Assertion -----------------------------------------------

(defun kargu-deps-format-missing-report (missing)
  "Format MISSING dependency list into a clear, prominent error banner string."
  (let* ((lines nil)
         (width 78)
         (border (make-string width ?=)))
    (push border lines)
    (push "⚠️  KARGU: MANDATORY TOOLS MISSING" lines)
    (push border lines)
    (push "The following mandatory tools must be available on your system for Kargu" lines)
    (push "to operate. Prompt submission is BLOCKED until all mandatory tools are present." lines)
    (push "" lines)
    (push "Missing Tools:" lines)
    (dolist (item missing)
      (let* ((name (plist-get item :name))
             (type-str (cl-case (plist-get item :type)
                         (package "Emacs Package")
                         (executable "System CLI")
                         (lsp-server "LSP Server")
                         (t "Tool")))
             (purpose (plist-get item :purpose))
             (hint (plist-get item :install-hint)))
        (push (format "  • %s (%s)" name type-str) lines)
        (when purpose
          (push (format "    Purpose: %s" purpose) lines))
        (when hint
          (push (format "    Install: %s" hint) lines))
        (push "" lines)))
    (push "Please install the missing tools and try again (C-c C-c)." lines)
    (push border lines)
    (string-join (nreverse lines) "\n")))

(defun kargu-deps-assert-all-present (&optional root)
  "Signal a `user-error' if any mandatory tools are missing for ROOT."
  (when-let* ((missing (kargu-deps-missing root)))
    (let ((names (string-join (mapcar (lambda (m) (format "%s" (plist-get m :name))) missing) ", ")))
      (user-error "Kargu: cannot send prompt: mandatory tools are missing: %s (please install them first)" names))))

(provide 'kargu/tools/deps)

;;; deps.el ends here
