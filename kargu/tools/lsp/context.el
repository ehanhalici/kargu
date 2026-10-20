;;; context.el --- Eglot context and request routing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Route LSP requests and resolve workspace context.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'kargu/core)
(require 'kargu/json)
(require 'kargu/permission)
(require 'kargu/async)
(require 'eglot nil t)
(require 'imenu nil t)

(declare-function eglot-current-server "eglot")
(declare-function eglot-project "eglot")
(declare-function eglot-uri-to-path "eglot")
(declare-function eglot-path-to-uri "eglot")
(declare-function jsonrpc-async-request "jsonrpc")
(defvar eglot--managed-mode)

(defcustom kargu-lsp-request-timeout 10
  "Seconds an LSP request may run before the tool reports an error."
  :type 'natnum
  :group 'kargu)

(declare-function flymake-diagnostics "flymake")
(declare-function flymake-diagnostic-text "flymake")
(declare-function flymake-diagnostic-beg "flymake")
(declare-function flymake-diagnostic-point "flymake")
(declare-function flymake-diagnostic-type "flymake")
(declare-function flymake-diagnostic-backend "flymake")
(declare-function flymake-diagnostic-buffer "flymake")
(declare-function flymake--project-diagnostics "flymake")
(declare-function flymake-is-running "flymake")

(declare-function kargu-diff--mutating-disabled "kargu/tools/diff" (name))
(declare-function kargu-diff-apply-proposal "kargu/tools/diff/stage" (path contents &optional callback))
(declare-function kargu-diff--describe "kargu/tools/diff/stage" (proposal))
(declare-function kargu-diff--file-text "kargu/tools/diff/stage" (path))
(declare-function kargu-diff-read-file "kargu/tools/diff" (file-path &optional from-line to-line))

;;;; Customization --------------------------------------------------------

(defgroup kargu-lsp nil
  "LSP integration of kargu via Eglot."
  :group 'kargu
  :prefix "kargu-lsp-")

(defcustom kargu-lsp-backend 'eglot
  "Preferred LSP client backend for kargu (uses built-in Eglot)."
  :type '(choice (const :tag "Eglot" eglot))
  :group 'kargu-lsp)

(defun kargu-lsp-backend (&optional _buffer)
  "Return active LSP backend (`eglot')."
  'eglot)

(defcustom kargu-lsp-skeleton-max-symbols 800
  "Total symbol cap in the project skeleton text.
Protects the token budget on huge workspaces."
  :type 'natnum
  :group 'kargu-lsp)

(defcustom kargu-lsp-skeleton-max-per-file 50
  "Per-file symbol cap in the project skeleton text."
  :type 'natnum
  :group 'kargu-lsp)

(defcustom kargu-lsp-skeleton-ttl 120
  "Seconds the project skeleton cache stays fresh."
  :type 'natnum
  :group 'kargu-lsp)

(defcustom kargu-lsp-diag-settle-timeout 3.0
  "Seconds to wait for diagnostics to settle after an edit."
  :type 'number
  :group 'kargu-lsp)

(defcustom kargu-lsp-definition-max-hits 12
  "Maximum locations reported by `kargu-lsp-find-definition'."
  :type 'natnum
  :group 'kargu-lsp)

;;;; Data accessors -------------------------------------------------------

(defun kargu-lsp--field (object field &optional default)
  "Extract FIELD (:keyword or symbol) from LSP OBJECT.
Handles plists, hash tables, and alists.  Return DEFAULT if absent."
  (cond
   ((null object) default)
   ((and (consp object) (plist-member object field))
    (plist-get object field))
   ((hash-table-p object)
    (let ((key (if (keywordp field) (substring (symbol-name field) 1) field)))
      (or (gethash key object)
          (gethash field object)
          default)))
   ((consp object)
    (or (cdr (assq field object))
        (cdr (assoc (if (keywordp field) (substring (symbol-name field) 1) field)
                    object))
        default))
   (t default)))

(defun kargu-lsp--path (object &rest fields)
  "Read successive FIELDS from OBJECT."
  (cl-reduce (lambda (acc field)
               (and acc (kargu-lsp--field acc field)))
             fields :initial-value object))

;;;; Session & context routing --------------------------------------------

(defvar kargu-context-buffer nil
  "Buffer (or file name string) providing the working context.
Used to route LSP requests to the right workspace and default file arguments.")

(defun kargu-set-context-buffer (&optional buffer)
  "Set `kargu-context-buffer' to BUFFER (or current buffer)."
  (interactive)
  (let ((target (or buffer (current-buffer))))
    (setq kargu-context-buffer
          (if (stringp target) target
            (when (buffer-live-p target) target))))
  (kargu-log 'info "context buffer set to %s"
             (if (bufferp kargu-context-buffer)
                 (buffer-name kargu-context-buffer)
               kargu-context-buffer)))

(defun kargu-lsp--context-buffer-live ()
  "Return the live context buffer, or nil."
  (cond
   ((bufferp kargu-context-buffer)
    (when (buffer-live-p kargu-context-buffer)
      kargu-context-buffer))
   ((stringp kargu-context-buffer)
    (let ((buffer (and (file-exists-p kargu-context-buffer)
                       (find-buffer-visiting kargu-context-buffer))))
      (when (buffer-live-p buffer) buffer)))))

(defun kargu-lsp--buffer-managed-p (buffer)
  "Return non-nil when BUFFER is file-backed and managed by Eglot."
  (and (buffer-live-p buffer)
       (buffer-file-name buffer)
       (with-current-buffer buffer
         (and (bound-and-true-p eglot--managed-mode)
              (fboundp 'eglot-current-server)
              (not (null (eglot-current-server)))))))

(defun kargu-lsp--managed-buffers ()
  "Return all file-backed Eglot-managed buffers, most recent first."
  (cl-remove-if-not #'kargu-lsp--buffer-managed-p (buffer-list)))

(defun kargu-lsp--workspace-root ()
  "Return the selected workspace without searching unrelated servers."
  (let ((root (or kargu-permission--override-root
                  (bound-and-true-p kargu-chat--project-root)
                  (with-current-buffer (or (kargu-lsp--context-buffer-live)
                                           (current-buffer))
                    (kargu-permission-context-root)))))
    (file-name-as-directory (file-truename root))))

(defun kargu-lsp--managed-buffer ()
  "Return an Eglot buffer belonging to the selected workspace, or nil."
  (let ((root (kargu-lsp--workspace-root)))
    (cl-find-if
     (lambda (buffer)
       (and (kargu-lsp--buffer-managed-p buffer)
            (let ((server-root
              (with-current-buffer buffer
                (kargu-permission-eglot-server-root (eglot-current-server)))))
         (and server-root
              (equal root (file-name-as-directory
                           (file-truename server-root)))))))
     (delete-dups (cons (or (kargu-lsp--context-buffer-live) (current-buffer))
                        (kargu-lsp--managed-buffers))))))

(defun kargu-lsp-context-file ()
  "Return the context file name, or nil."
  (let ((buffer (kargu-lsp--context-buffer-live)))
    (or (and buffer (buffer-file-name buffer))
        (and (stringp kargu-context-buffer)
             (file-exists-p kargu-context-buffer)
             kargu-context-buffer))))

(defun kargu--eglot-workspace-buffer ()
  "Return the Eglot-managed buffer naming the workspace.
Prefer the current managed buffer, then the most recent managed file
buffer.  Ignore the variable `default-directory' in temporary buffers."
  (kargu-lsp--managed-buffer))

(declare-function kargu-permission-eglot-server-root "kargu/permission/guards" (server))

(defun kargu-lsp-project-root ()
  "Return the connected Eglot server's project root, or nil.
The directory is the one stored on the server.  The user is never
asked, and `default-directory' is not used in its place."
  (let ((buffer (kargu--eglot-workspace-buffer)))
    (when (and (buffer-live-p buffer)
               (fboundp 'eglot-current-server))
      (kargu-permission-eglot-server-root
       (with-current-buffer buffer
         (eglot-current-server))))))

(defun kargu-eglot-connected-p ()
  "Return non-nil when the selected project has a live Eglot buffer."
  (and (kargu-lsp--managed-buffer) t))

(defun kargu-lsp-unavailable-reason ()
  "Return an LSP tool refusal when the project has no connection."
  (unless (kargu-eglot-connected-p)
    "ERROR: LSP is unavailable in this project. Use file/search tools, or Bash in agent mode."))

(defun kargu-lsp-native-elisp-p ()
  "Return non-nil for an Emacs Lisp context in the selected project."
  (let* ((buffer (or (kargu-lsp--context-buffer-live) (current-buffer)))
         (file (buffer-file-name buffer)))
    (and (or (null file)
             (kargu-permission-within-project-p file (kargu-permission-project-root)))
         (with-current-buffer buffer (derived-mode-p 'emacs-lisp-mode)))))

(defun kargu-lsp-symbols-unavailable-reason ()
  "Return a refusal unless native Lisp navigation or Eglot is available."
  (unless (kargu-lsp-native-elisp-p) (kargu-lsp-unavailable-reason)))

;;;; URI helpers & Symbol kinds -------------------------------------------

(defun kargu-lsp--uri-to-path (uri)
  "Convert LSP URI to a local file path."
  (cond
   ((null uri) nil)
   ((fboundp 'eglot-uri-to-path)
    (eglot-uri-to-path uri))
   (t
    (let ((path (replace-regexp-in-string "\\`file://" "" uri)))
      (if (fboundp 'url-unhex-string) (url-unhex-string path) path)))))

(defun kargu-lsp--buffer-uri (&optional buffer)
  "Return the LSP URI of BUFFER (default: current buffer)."
  (let* ((buf (or buffer (current-buffer)))
         (fname (buffer-file-name buf)))
    (cond
     ((and (fboundp 'eglot-path-to-uri) fname)
      (eglot-path-to-uri fname))
     (t
      (when fname (concat "file://" fname))))))

(defconst kargu-lsp--symbol-kinds
  [nil "File" "Module" "Namespace" "Package" "Class" "Method" "Property"
       "Field" "Constructor" "Enum" "Interface" "Function" "Variable"
       "Constant" "String" "Number" "Boolean" "Array" "Object" "Key" "Null"
       "EnumMember" "Struct" "Event" "Operator" "TypeParameter"]
  "LSP SymbolKind names indexed by kind number (1..26).")

(defun kargu-lsp--kind-name (kind)
  "Return a human name for LSP symbol KIND number."
  (if (and (natnump kind) (< kind (length kargu-lsp--symbol-kinds)))
      (aref kargu-lsp--symbol-kinds kind)
    "Symbol"))

;;;; Request dispatcher ---------------------------------------------------

(defun kargu-lsp--request (method params callback &optional buffer)
  "Send METHOD and PARAMS asynchronously from BUFFER.
CALLBACK receives (VALUE ERROR); return a cancellable task immediately."
  (let* ((buf (or buffer (current-buffer)))
         (server (and (buffer-live-p buf)
                      (with-current-buffer buf (eglot-current-server))))
         (tick (and (buffer-live-p buf)
                    (with-current-buffer buf (buffer-chars-modified-tick))))
         (task (kargu-async-start
                callback :timeout kargu-lsp-request-timeout
                :valid-p
                (lambda ()
                  (and (buffer-live-p buf)
                       (with-current-buffer buf
                         (and (eq server (eglot-current-server))
                              (= tick (buffer-chars-modified-tick)))))))))
    (funcall
     (kargu-async-wrap
      task
      (lambda ()
        (unless server (error "No active Eglot server"))
        (with-current-buffer buf
          (jsonrpc-async-request
           server (intern (concat ":" (string-remove-prefix ":" (format "%s" method))))
           params :timeout kargu-lsp-request-timeout
           :success-fn (kargu-async-wrap
                        task (lambda (value) (kargu-async-finish task value)))
           :error-fn (kargu-async-wrap
                      task (lambda (err) (kargu-async-finish task nil (format "%s" err))))
           :timeout-fn (kargu-async-wrap
                        task (lambda () (kargu-async-finish task nil "LSP request timed out"))))))))
    task))

(provide 'kargu/tools/lsp/context)

;;; context.el ends here
