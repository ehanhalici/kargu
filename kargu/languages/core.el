;;; kargu/languages/core.el --- Multi-language support architecture -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Central registry and abstraction for language-specific toolchains,
;; LSP nuances, build/test commands, and debugger adapter constraints.
;;
;; Supported languages: C, C++, Rust, Go, Haskell, OCaml, Java, Python.
;; Public API:
;;   `kargu-language-register', `kargu-language-get',
;;   `kargu-language-detect', `kargu-language-detect-by-extension',
;;   `kargu-language-active', `kargu-language-prompt-guidance',
;;   `kargu-language-eval-hint'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

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

(require 'kargu/core)
(require 'kargu/fs)

(declare-function kargu-fs-has-file-p "kargu/fs" (root filename))

;;;; Language Specification Structure ---------------------------------------

(cl-defstruct (kargu-language-spec (:constructor kargu-make-language-spec))
  "Encapsulation of all characteristics and rules for a programming language."
  id                            ; Symbol: e.g. 'rust, 'c, 'cpp, 'golang, etc.
  name                          ; Human-readable string: "Rust", "C++"
  priority                      ; Integer priority for detection order (higher = earlier)
  extensions                    ; List of file extensions without dot: ("rs")
  detectors                     ; List of filenames or functions taking ROOT -> non-nil
  toolchain                     ; Plist: :build-cmd, :test-cmd, :lint-cmd, :notes
  debugger                      ; Plist: :adapter, :supports-eval, :supports-method-calls,
                                ;        :eval-guidance, :common-eval-pitfalls,
                                ;        :variable-inspection-advice
  lsp-notes)                    ; String: notes about symbols, outlines, and edits

;;;; Registry --------------------------------------------------------------

(defvar kargu-languages--registry (make-hash-table :test #'eq)
  "Map of language ID symbol -> `kargu-language-spec'.")

(defun kargu-language-register (spec)
  "Register SPEC in `kargu-languages--registry'."
  (cl-check-type spec kargu-language-spec)
  (puthash (kargu-language-spec-id spec) spec kargu-languages--registry)
  spec)

(defun kargu-language-get (id)
  "Return `kargu-language-spec' for ID symbol, or nil."
  (gethash id kargu-languages--registry))

(defun kargu-language-list ()
  "Return all registered language specs ordered by descending priority."
  (let (specs)
    (maphash (lambda (_k v) (push v specs)) kargu-languages--registry)
    (sort specs (lambda (a b)
                  (> (or (kargu-language-spec-priority a) 0)
                     (or (kargu-language-spec-priority b) 0))))))

;;;; Detection -------------------------------------------------------------

(defalias 'kargu-languages--has-file-p #'kargu-fs-has-file-p)

(defun kargu-language-detect (root)
  "Detect the primary language spec for ROOT by evaluating registered specs.
Returns matching `kargu-language-spec', or nil."
  (let ((specs (kargu-language-list))
        (matched nil))
    (dolist (spec specs)
      (unless matched
        (let ((detectors (kargu-language-spec-detectors spec)))
          (when (cl-some (lambda (d)
                           (cond
                            ((functionp d) (funcall d root))
                            ((stringp d) (kargu-languages--has-file-p root d))
                            (t nil)))
                         detectors)
            (setq matched spec)))))
    matched))

(defun kargu-language-detect-by-extension (file-path)
  "Return language spec matching extension of FILE-PATH, or nil."
  (when (and (stringp file-path) (not (string-empty-p file-path)))
    (let* ((ext (downcase (or (file-name-extension file-path) "")))
           (specs (kargu-language-list)))
      (cl-find-if (lambda (spec)
                    (member ext (kargu-language-spec-extensions spec)))
                  specs))))

(defun kargu-language-active (&optional root)
  "Return the active language spec for ROOT or current buffer context.
First checks ROOT detectors, then the visiting file buffer extension,
or defaults to nil."
  (let* ((r (or root
                (and (fboundp 'kargu--project-root)
                     (ignore-errors (kargu--project-root)))
                default-directory))
         (detected (and r (kargu-language-detect r))))
    (or detected
        (and buffer-file-name (kargu-language-detect-by-extension buffer-file-name)))))

;;;; Guidance & Error Formatting -------------------------------------------

(defun kargu-language-prompt-guidance (spec)
  "Generate XML/markdown instruction block for SPEC for system prompt injection."
  (if (null spec)
      ""
    (let* ((name (kargu-language-spec-name spec))
           (tc (kargu-language-spec-toolchain spec))
           (dbg (kargu-language-spec-debugger spec))
           (lsp (kargu-language-spec-lsp-notes spec))
           (eval-guide (plist-get dbg :eval-guidance))
           (var-guide (plist-get dbg :variable-inspection-advice)))
      (concat
       (format "<language_profile language=\"%s\">\n" name)
       (format "  Build / Compile: %s\n" (or (plist-get tc :build-cmd) "(none)"))
       (format "  Test Command:    %s\n" (or (plist-get tc :test-cmd) "(none)"))
       (when (plist-get tc :notes)
         (format "  Toolchain Notes: %s\n" (plist-get tc :notes)))
       (format "  Debug Adapter:   %s\n" (or (plist-get dbg :adapter) "dape default"))
       (if (plist-get dbg :supports-method-calls)
         "  Debug Evaluation: Full expression evaluation supported (variables, attributes/fields, function & method calls).\n"
         "  Debug Evaluation: Static data access ONLY (variables, direct fields `x.field`, indexing `x[i]`, pointer dereference). Do NOT call functions or methods with parentheses `()`.\n")
       (when var-guide
         (format "  Variable Inspection: %s\n" var-guide))
       (when eval-guide
         (format "  Evaluation Rules: %s\n" eval-guide))
       (when lsp
         (format "  Code & Symbols: %s\n" lsp))
       "</language_profile>\n"))))

(defun kargu-language-eval-hint (spec expr &optional err-msg)
  "Return an actionable remediation hint for EXPR or ERR-MSG in SPEC."
  (when (and spec (kargu-language-spec-p spec))
    (let* ((dbg (kargu-language-spec-debugger spec))
           (pitfalls (plist-get dbg :common-eval-pitfalls)))
      (when (eq (car-safe pitfalls) 'quote)
        (setq pitfalls (cadr pitfalls)))
      (cl-some (lambda (pair)
                 (when (eq (car-safe pair) 'quote)
                   (setq pair (cadr pair)))
                 (when (consp pair)
                   (let ((pat (car pair))
                         (hint (cdr pair)))
                     (when (or (and (stringp err-msg) (string-match-p pat err-msg))
                               (and (stringp expr) (string-match-p pat expr)))
                       hint))))
               pitfalls))))

(provide 'kargu/languages/core)

;;; kargu/languages/core.el ends here
