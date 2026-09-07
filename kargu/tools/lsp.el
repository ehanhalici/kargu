;;; kargu/tools/lsp.el --- LSP skeleton, diagnostics, xref -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; LSP skeleton, diagnostics, and xref tools.
;; Requires: `kargu/core', `kargu/api' (lsp-mode is optional).
;; Public: `kargu-lsp-build-skeleton', `kargu-lsp-get-diagnostics',
;; `kargu-lsp-find-definition', `kargu--project-root',
;; `kargu--resolve-path'.
;;
;; The LSP tool layer: gives the model zero-token access to the
;; project structure that lsp-mode already maintains.
;;
;;  * `lsp_project_skeleton' — one compact text tree of every file
;;    and its symbols, obtained through `workspace/symbol' (or a
;;    `documentSymbol' fallback over open buffers).  The model orients
;;    itself without reading files: ~90% token savings.
;;
;;  * `lsp_diagnostics' — compile/lint errors with line numbers and
;;    severity, read from lsp-mode's diagnostics store (with flymake
;;    and flycheck fallbacks).  This powers the self-healing loop.
;;
;;  * `lsp_find_symbol' — definition sites for a symbol name, via
;;    `workspace/symbol' and, as a fallback, an occurrence-based
;;    `textDocument/definition' request.
;;
;; Representation notes (verified against lsp-mode 8 sources):
;;   * lsp-mode decodes JSON objects as plists when `lsp-use-plists'
;;     is set (env LSP_USE_PLISTS) and as hash tables otherwise, so
;;     every field access goes through `kargu-lsp--field',
;;     which handles both.
;;   * Arrays may arrive as lists or vectors; always normalize with
;;     `kargu-lsp--seq->list'.
;;   * `lsp-request' is synchronous and signals on error/timeout; it
;;     is called with an LSP-managed buffer current so the request is
;;     routed to the right workspace.
;;
;; The module soft-requires lsp-mode: tools are registered even when
;; lsp-mode is absent, and fail with a helpful string instead.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory (Magit-style kargu/core features).
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
(require 'kargu/api)
(require 'kargu/permission)
(require 'lsp-mode nil t)
(require 'imenu nil t)

(declare-function flymake-diagnostics "flymake")
(declare-function flymake-diagnostic-text "flymake")
(declare-function flymake-diagnostic-beg "flymake")
(declare-function flymake-diagnostic-point "flymake")
(declare-function flymake-diagnostic-type "flymake")
(declare-function flycheck-current-errors "flycheck")
(declare-function flycheck-error-level "flycheck")
(declare-function flycheck-error-line "flycheck")
(declare-function flycheck-error-column "flycheck")
(declare-function flycheck-error-checker "flycheck")
(declare-function flycheck-error-message "flycheck")
(declare-function flycheck-buffer "flycheck")
(declare-function flycheck-mode "flycheck" (&optional arg))
(declare-function flycheck-running-p "flycheck")
(declare-function flycheck-get-checker-for-buffer "flycheck")

;;;; Customization --------------------------------------------------------

(defgroup kargu-lsp nil
  "LSP integration of kargu."
  :group 'kargu
  :prefix "kargu-lsp-")

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
  "Seconds `kargu-lsp-wait-diagnostics' waits for the language
server to republish diagnostics after an edit."
  :type 'number
  :group 'kargu-lsp)

(defcustom kargu-lsp-definition-max-hits 12
  "Maximum locations reported by `kargu-lsp-find-definition'."
  :type 'natnum
  :group 'kargu-lsp)

;;;; Dual-representation accessors ---------------------------------------

(defun kargu-lsp--field (object field &optional default)
  "Extract FIELD (a keyword like :name) from LSP OBJECT.
lsp-mode represents JSON objects as plists or hash tables
depending on `lsp-use-plists'; both are handled, alists too as a
defensive measure.  Return DEFAULT (nil) when the field is absent."
  (cond
   ((null object) default)
   ((hash-table-p object)
    (let ((key (if (keywordp field) (substring (symbol-name field) 1) field)))
      (or (gethash key object)
          (gethash field object)
          default)))
   ((and (consp object) (plist-member object field))
    (plist-get object field))
   ((consp object)
    (or (cdr (assq field object))
        (cdr (assoc (if (keywordp field) (substring (symbol-name field) 1)
                      field)
                    object))
        default))
   (t default)))

(defun kargu-lsp--path (object &rest fields)
  "Thread OBJECT through successive `kargu-lsp--field' calls."
  (cl-reduce (lambda (acc field)
               (and acc (kargu-lsp--field acc field)))
             fields :initial-value object))

(defun kargu-lsp--seq->list (seq)
  "Normalize a JSON array (list, vector or single value) to a list."
  (cond
   ((vectorp seq) (append seq nil))
   ((listp seq) seq)
   (seq (list seq))
   (t nil)))

;;;; Session & context routing --------------------------------------------

(defvar kargu-context-buffer nil
  "Buffer (or file name string) providing the working context.
Used to route LSP requests to the right workspace and to default
file arguments of tools.  Set via `kargu-set-context-buffer'
or automatically (the most recent LSP-managed file buffer wins).
Other kargu modules (diff, loop, ui) read this variable.")

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
  "Return non-nil when BUFFER is file-backed and LSP-managed."
  (and (fboundp 'lsp-workspaces)
       (buffer-live-p buffer)
       (buffer-file-name buffer)
       (with-current-buffer buffer
         (and (boundp 'lsp--buffer-workspaces)
              lsp--buffer-workspaces))))

(defun kargu-lsp--managed-buffers ()
  "Return all file-backed LSP-managed buffers, most recent first."
  (when (fboundp 'lsp-workspaces)
    (cl-remove-if-not #'kargu-lsp--buffer-managed-p (buffer-list))))

(defun kargu-lsp--managed-buffer ()
  "Return the buffer used to route LSP requests, or nil.
Priority: a managed context buffer, then any managed buffer, then
the context buffer itself (its LSP error will be surfaced)."
  (or (let ((buffer (kargu-lsp--context-buffer-live)))
        (and buffer (kargu-lsp--buffer-managed-p buffer) buffer))
      (car (kargu-lsp--managed-buffers))
      (kargu-lsp--context-buffer-live)))

(defun kargu-lsp--with-session (fn)
  "Call FN with an LSP-managed buffer current; return FN's result.
Signal an `error' (with a user-facing message) when no LSP session
is usable, so tool executors surface the problem to the model."
  (let ((buffer (kargu-lsp--managed-buffer)))
    (if (null buffer)
        (error "No active LSP session: run M-x lsp in a project buffer (or set `kargu-context-buffer')")
      (with-current-buffer buffer
        (funcall fn)))))

(defun kargu--context-file ()
  "Return the context file name, or nil."
  (let ((buffer (kargu-lsp--context-buffer-live)))
    (or (and buffer (buffer-file-name buffer))
        (and (stringp kargu-context-buffer)
             (file-exists-p kargu-context-buffer)
             kargu-context-buffer))))

(defun kargu--project-root ()
  "Return the project root directory of the working context."
  (condition-case-unless-debug _err
      (let ((buffer (or (kargu-lsp--context-buffer-live)
                        (car (kargu-lsp--managed-buffers)))))
        (if (buffer-live-p buffer)
            (with-current-buffer buffer
              (or (when (fboundp 'lsp-workspace-root)
                    (let ((ws (lsp-workspace-root)))
                      (and ws (file-name-as-directory ws))))
                  (when (fboundp 'project-root)
                    (let ((project (project-current)))
                      (and project (project-root project))))
                  default-directory))
          default-directory))
    (error default-directory)))

(defun kargu--resolve-path (path)
  "Expand PATH (absolute or project-relative) to an absolute name
and assert that it is within the project root."
  (cond
   ((and (stringp path) (not (string-empty-p (string-trim path)))
         (file-name-absolute-p path))
    (let ((abs (expand-file-name path)))
      (if (fboundp 'kargu-permission-assert-within-project)
          (kargu-permission-assert-within-project abs nil "lsp path")
        abs)))
   ((and (stringp path) (not (string-empty-p (string-trim path))))
    (let ((abs (expand-file-name path (kargu--project-root))))
      (if (fboundp 'kargu-permission-assert-within-project)
          (kargu-permission-assert-within-project abs nil "lsp path")
        abs)))
   (t (error "path must be a non-empty string"))))

;;;; URI helpers ----------------------------------------------------------

(defun kargu-lsp--uri-to-path (uri)
  "Convert LSP URI to a local file path."
  (cond
   ((and uri (fboundp 'lsp--uri-to-path)) (lsp--uri-to-path uri))
   (uri
    (let ((path (replace-regexp-in-string "\\`file://" "" uri)))
      (if (fboundp 'url-unhex-string) (url-unhex-string path) path)))
   (t nil)))

(defun kargu-lsp--buffer-uri (&optional buffer)
  "Return the LSP URI of BUFFER (default: current buffer)."
  (if (fboundp 'lsp--buffer-uri)
      (if buffer (with-current-buffer buffer (lsp--buffer-uri))
        (lsp--buffer-uri))
    (let ((path (buffer-file-name (or buffer (current-buffer)))))
      (when path (concat "file://" path)))))

;;;; Symbol kinds ---------------------------------------------------------

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

;;;; Symbol gathering (skeleton data) --------------------------------------

(defun kargu-lsp--symbol-information-item (item)
  "Convert one SymbolInformation ITEM to (PATH LINE NAME KIND)."
  (let* ((name (kargu-lsp--field item :name))
         (kind (kargu-lsp--field item :kind))
         (location (kargu-lsp--field item :location))
         (uri (kargu-lsp--field location :uri))
         (line (kargu-lsp--path location :range :start :line)))
    (when (and name uri)
      (list (kargu-lsp--uri-to-path uri)
            (1+ (or line 0))
            name
            kind))))

(defun kargu-lsp--ws-symbols (query)
  "Return flat ((PATH LINE NAME KIND)...) for QUERY via workspace/symbol.
Return nil when the server rejects the query or returns nothing
(fallbacks apply upstream).  Must run with an LSP buffer current."
  (condition-case-unless-debug err
      (let ((items (kargu-lsp--seq->list
                    (lsp-request "workspace/symbol" `(:query ,query)))))
        (delq nil (mapcar #'kargu-lsp--symbol-information-item items)))
    (error
     (kargu-log 'warn "workspace/symbol %S failed: %s"
                      query (error-message-string err))
     nil)))

(defun kargu-lsp--doc-symbol-walk (items path)
  "Flatten documentSymbol ITEMS (nested children) for PATH.
Handles both DocumentSymbol (:range, :children) and flat
SymbolInformation (:location) shapes."
  (cl-loop for item in (kargu-lsp--seq->list items)
           for name = (kargu-lsp--field item :name)
           for kind = (kargu-lsp--field item :kind)
           for line = (or (kargu-lsp--path item :range :start :line)
                          (kargu-lsp--path item :location :range
                                                 :start :line))
           when (and name path)
           append (cons (list path (1+ (or line 0)) name kind)
                        (kargu-lsp--doc-symbol-walk
                         (kargu-lsp--field item :children) path))))

(defun kargu-lsp--doc-symbols ()
  "Gather symbols via textDocument/documentSymbol over open LSP buffers.
Weaker fallback for servers that reject the empty workspace/symbol
query: covers only buffers currently open in Emacs."
  (let (acc (count 0))
    (dolist (buffer (kargu-lsp--managed-buffers))
      (when (< count 40)
        (let ((path (buffer-file-name buffer)))
          (condition-case-unless-debug _err
              (with-current-buffer buffer
                (let ((items (kargu-lsp--seq->list
                              (lsp-request "textDocument/documentSymbol"
                                           `(:textDocument
                                             (:uri ,(kargu-lsp--buffer-uri)))))))
                  (setq acc (nconc acc
                                   (kargu-lsp--doc-symbol-walk
                                    items path))
                        count (1+ count))))
            (error nil)))))
    acc))

(defun kargu-lsp--gather-symbols ()
  "Return (SOURCE . ITEMS) for the skeleton, or signal an error.
Primary source is `workspace/symbol' with an empty query (the
whole workspace); fallback is `documentSymbol' over open buffers."
  (kargu-lsp--with-session
   (lambda ()
     (let ((ws (kargu-lsp--ws-symbols "")))
       (if ws
           (cons "workspace/symbol" ws)
         (kargu-log 'warn
                          "skeleton: empty workspace/symbol query gave nothing; \
falling back to documentSymbol over open buffers")
         (let ((doc (kargu-lsp--doc-symbols)))
           (if doc
               (cons "textDocument/documentSymbol (open buffers only)" doc)
              (error "No symbols available: workspace/symbol returned nothing \
and no LSP file buffers are open"))))))))

(defun kargu-lsp--imenu-walk (alist path &optional category)
  "Flatten imenu ALIST into a list of (PATH LINE NAME KIND).
CATEGORY is the inherited submenu title."
  (let (acc)
    (dolist (item alist)
      (when (consp item)
        (let ((name (car item))
              (val (cdr item)))
          (unless (or (not (stringp name))
                      (string= name "*Rescan*"))
            (cond
             ((and (listp val) (consp (car-safe val)))
              (setq acc (nconc acc (kargu-lsp--imenu-walk val path name))))
             (t
              (let* ((pos (cond
                           ((markerp val) (marker-position val))
                           ((integerp val) val)
                           ((and (consp val) (integerp (car val))) (car val))
                           ((and (consp val) (markerp (car val))) (marker-position (car val)))
                           (t nil)))
                     (line (cond
                            ((and (markerp val) (marker-buffer val))
                             (with-current-buffer (marker-buffer val)
                               (line-number-at-pos val)))
                            ((and pos (numberp pos))
                             (condition-case nil
                                 (if (and (<= (point-min) pos) (<= pos (point-max)))
                                     (line-number-at-pos pos)
                                   (max 1 (/ pos 40)))
                               (error 1)))
                            (t 1)))
                     (raw-kind (or category "Symbol"))
                     (kind (cond
                            ((string-match-p "Variable" raw-kind) "Variable")
                            ((string-match-p "Function" raw-kind) "Function")
                            ((string-match-p "Type" raw-kind) "Type")
                            ((string-match-p "Class" raw-kind) "Class")
                            ((string-match-p "Struct" raw-kind) "Struct")
                            ((string-match-p "Method" raw-kind) "Method")
                            (t raw-kind))))
                (when (and line name)
                  (push (list path line name kind) acc)))))))))
    (nreverse acc)))

(defun kargu-lsp--imenu-symbols (&optional roots)
  "Gather symbols via `imenu' from open file-visiting buffers.
If ROOTS is provided, only include buffers under ROOTS."
  (let (acc)
    (dolist (buf (buffer-list))
      (let ((path (buffer-file-name buf)))
        (when (and path (file-regular-p path))
          (when (or (null roots)
                    (cl-some (lambda (root) (file-in-directory-p path root)) roots))
            (condition-case nil
                (with-current-buffer buf
                  (when (or (bound-and-true-p imenu-create-index-function)
                            (derived-mode-p 'prog-mode))
                    (require 'imenu nil t)
                    (let ((index (ignore-errors (imenu--make-index-alist t))))
                      (when index
                        (setq acc (nconc acc (kargu-lsp--imenu-walk index path)))))))
              (error nil))))))
    acc))

(defun kargu-lsp-all-symbols (&optional query roots)
  "Return flat list of ((PATH LINE NAME KIND) ...) matching optional QUERY.
Combines LSP symbols (if active) with Emacs `imenu' across ROOTS."
  (let ((seen (make-hash-table :test #'equal))
        acc)
    ;; 1. Try LSP
    (condition-case nil
        (let ((buf (kargu-lsp--managed-buffer)))
          (when (buffer-live-p buf)
            (with-current-buffer buf
              (let ((lsp-items (or (kargu-lsp--ws-symbols (or query ""))
                                   (kargu-lsp--doc-symbols))))
                (dolist (item lsp-items)
                  (let* ((path (nth 0 item))
                         (line (nth 1 item))
                         (name (nth 2 item))
                         (kind (if (fboundp 'kargu-lsp--kind-name)
                                   (kargu-lsp--kind-name (nth 3 item))
                                 (format "%s" (or (nth 3 item) "Symbol"))))
                         (key (cons path name)))
                    (unless (gethash key seen)
                      (puthash key t seen)
                      (push (list path line name kind) acc))))))))
      (error nil))
    ;; 2. Add imenu symbols
    (dolist (item (kargu-lsp--imenu-symbols roots))
      (let* ((path (nth 0 item))
             (line (nth 1 item))
             (name (nth 2 item))
             (kind (nth 3 item))
             (key (cons path name)))
        (unless (gethash key seen)
          (puthash key t seen)
          (push (list path line name kind) acc))))
    (nreverse acc)))

;;;; Skeleton rendering & caching ------------------------------------------

(defvar kargu-lsp--skeleton-cache nil
  "Cached skeleton: plist with :text, :time, :root, :source.")

(defun kargu-lsp--cached-skeleton ()
  "Return the cached skeleton text when still fresh, else nil."
  (when (and kargu-lsp--skeleton-cache
             (stringp (plist-get kargu-lsp--skeleton-cache :text)))
    (let ((age (- (float-time)
                  (float-time (plist-get kargu-lsp--skeleton-cache :time)))))
      (when (< age kargu-lsp-skeleton-ttl)
        (plist-get kargu-lsp--skeleton-cache :text)))))

(defun kargu-lsp--render-skeleton (root source items)
  "Render ITEMS ((PATH LINE NAME KIND)...) as the skeleton text.
Group by file in O(N) via a hash table, and drop symbols whose
path is outside ROOT (std, crates.io, rustup, etc.) using
`file-in-directory-p'."
  (let ((by-file (make-hash-table :test #'equal))
        (root-dir (file-name-as-directory (expand-file-name root)))
        (total 0))
    (dolist (item items)
      (let ((path (car item)))
        (when (and (stringp path)
                   (ignore-errors
                     (file-in-directory-p (expand-file-name path)
                                          root-dir)))
          (puthash path (cons item (gethash path by-file)) by-file)
          (setq total (1+ total)))))
    (let (file-list)
      (maphash (lambda (path syms)
                 (push (cons path (nreverse syms)) file-list))
               by-file)
      (setq file-list
            (sort file-list (lambda (a b) (string< (car a) (car b)))))
      (let* ((shown-symbols 0)
             (lines (list (format "# Project skeleton (LSP: %s)" source)
                          (format "# root: %s" root)
                          (format "# %d files, %d symbols"
                                  (hash-table-count by-file) total))))
        (dolist (entry file-list)
          (when (< shown-symbols kargu-lsp-skeleton-max-symbols)
            (let* ((path (car entry))
                   (symbols (sort (cdr entry)
                                  (lambda (a b) (< (nth 1 a) (nth 1 b)))))
                   (rel (file-relative-name path root))
                   (shown (seq-take symbols kargu-lsp-skeleton-max-per-file))
                   (hidden (- (length symbols) (length shown))))
              (setq shown-symbols (+ shown-symbols (length shown)))
              (push (concat rel ":") lines)
              (dolist (sym shown)
                (push (format "  %s (%s) :%d"
                              (nth 2 sym)
                              (kargu-lsp--kind-name (nth 3 sym))
                              (nth 1 sym))
                      lines))
              (when (> hidden 0)
                (push (format "  ... (%d more hidden)" hidden) lines))
              (when (>= shown-symbols kargu-lsp-skeleton-max-symbols)
                (push (format "# symbol cap reached (%d); ask the user to raise \
`kargu-lsp-skeleton-max-symbols' for full coverage"
                              kargu-lsp-skeleton-max-symbols)
                      lines)))))
        (string-join (nreverse (delq nil lines)) "\n")))))

(defun kargu-lsp--compute-skeleton ()
  "Build the skeleton text; return text or an \"ERROR: ...\" string."
  (condition-case-unless-debug err
      (let* ((data (kargu-lsp--gather-symbols))
             (source (car data))
             (items (cdr data))
             (root (kargu--project-root)))
        (kargu-log 'info "skeleton built: %d symbols via %s"
                         (length items) source)
        (kargu-lsp--render-skeleton root source items))
    (error
     (kargu-log 'warn "skeleton failed: %s" (error-message-string err))
     (format "ERROR: %s" (error-message-string err)))))

(defun kargu-lsp--show-skeleton (text)
  "Display the skeleton TEXT in a dedicated buffer."
  (with-current-buffer (get-buffer-create "*kargu-skeleton*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert text)
      (goto-char (point-min)))
    (special-mode))
  (pop-to-buffer (get-buffer "*kargu-skeleton*")))

(defun kargu-lsp-build-skeleton (&optional refresh)
  "Return the project skeleton text, cached per `kargu-lsp-skeleton-ttl'.
REFRESH non-nil bypasses and resets the cache.  Interactively
(prefix argument) the skeleton is also displayed in a buffer."
  (interactive "P")
  (when refresh
    (setq kargu-lsp--skeleton-cache nil))
  (let ((text (or (kargu-lsp--cached-skeleton)
                  (kargu-lsp--compute-skeleton))))
    (when (and text
               (not (string-prefix-p "ERROR:" text))
               (not (kargu-lsp--cached-skeleton)))
      (setq kargu-lsp--skeleton-cache
            (list :text text
                  :time (current-time)
                  :root (kargu--project-root))))
    (when (called-interactively-p 'any)
      (if (and text (string-prefix-p "ERROR:" text))
          (message "%s" text)
        (kargu-lsp--show-skeleton text)))
    text))

;;;; Diagnostics -----------------------------------------------------------

(defun kargu-lsp--workspace-diags (path)
  "Raw LSP diagnostic lists for PATH across session workspaces, or nil.
Reads lsp-mode's diagnostics store: a hash table per workspace,
keyed by (case-fixed) file path, populated on publishDiagnostics."
  (when (fboundp 'lsp-workspaces)
    (let ((buffer (kargu-lsp--managed-buffer)))
      (when buffer
        (with-current-buffer buffer
          (let ((key (if (fboundp 'lsp--fix-path-casing)
                         (lsp--fix-path-casing path)
                       path)))
            (cl-loop for workspace in (lsp-workspaces)
                     for diags = (and (fboundp 'lsp--workspace-diagnostics)
                                      (gethash key
                                               (lsp--workspace-diagnostics
                                                workspace)))
                     when diags
                     append (kargu-lsp--seq->list diags))))))))

(defun kargu-lsp--flymake-diags (path)
  "Normalized flymake diagnostics for PATH, or nil."
  (when (and (fboundp 'flymake-diagnostics)
             (fboundp 'flymake-diagnostic-text))
    (let ((buffer (find-buffer-visiting path)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (delq nil
                (mapcar
                 (lambda (d)
                   (let* ((beg (if (fboundp 'flymake-diagnostic-beg)
                                   (flymake-diagnostic-beg d)
                                 (flymake-diagnostic-point d)))
                          (pos (if (consp beg) (car beg) beg))
                          (type (flymake-diagnostic-type d)))
                     (when (number-or-marker-p pos)
                       (list :severity (pcase type
                                         ((or :error 'flymake-error 'e) 1)
                                         ((or :warning 'flymake-warning 'w) 2)
                                         (_ 3))
                             :line (line-number-at-pos pos)
                             :character 1
                             :source "flymake"
                             :message (flymake-diagnostic-text d)))))
                 (flymake-diagnostics))))))))

(defun kargu-lsp--flycheck-diags (path)
  "Normalized flycheck diagnostics for PATH, or nil."
  (when (fboundp 'flycheck-current-errors)
    (let ((buffer (find-buffer-visiting path)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (delq nil
                (mapcar
                 (lambda (e)
                   (let* ((level (and (fboundp 'flycheck-error-level)
                                      (flycheck-error-level e)))
                          (checker (and (fboundp 'flycheck-error-checker)
                                        (flycheck-error-checker e)))
                          (col (and (fboundp 'flycheck-error-column)
                                    (flycheck-error-column e)))
                          (line (and (fboundp 'flycheck-error-line)
                                     (flycheck-error-line e)))
                          (msg (and (fboundp 'flycheck-error-message)
                                    (flycheck-error-message e))))
                     (list :severity (if (eq level 'error) 1
                                       (if (eq level 'warning) 2 3))
                           :line (or line 0)
                           :character (or col 1)
                           :source (if checker
                                       (format "flycheck (%s)" checker)
                                     "flycheck")
                           :message (or msg (and level (symbol-name level)) "unknown"))))
                 (flycheck-current-errors))))))))

(defun kargu-lsp--normalize-diag (raw)
  "Normalize one raw LSP diagnostic RAW to a plist."
  (list :severity (or (kargu-lsp--field raw :severity) 1)
        :line (1+ (or (kargu-lsp--path raw :range :start :line) 0))
        :character (1+ (or (kargu-lsp--path raw :range :start
                                                 :character)
                           0))
        :source (kargu-lsp--field raw :source)
        :message (kargu-lsp--field raw :message)))

(defun kargu-lsp--diagnostics-data (file-path)
  "Return normalized diagnostics for FILE-PATH as a list of plists
(:severity :line :character :message :source), sorted by severity
then line.  Combines diagnostics from LSP, Flymake, and Flycheck."
  (let* ((path (kargu--resolve-path file-path))
         (lsp-raw (kargu-lsp--workspace-diags path))
         (lsp-data (and lsp-raw (delq nil (mapcar #'kargu-lsp--normalize-diag lsp-raw))))
         (flymake-data (kargu-lsp--flymake-diags path))
         (flycheck-data (kargu-lsp--flycheck-diags path))
         (combined (append lsp-data flymake-data flycheck-data))
         (seen (make-hash-table :test 'equal))
         (data nil))
    (dolist (d combined)
      (let ((key (format "%s:%s:%s"
                         (plist-get d :line)
                         (plist-get d :severity)
                         (plist-get d :message))))
        (unless (gethash key seen)
          (puthash key t seen)
          (push d data))))
    (sort (nreverse data)
          (lambda (a b)
            (if (= (plist-get a :severity) (plist-get b :severity))
                (< (plist-get a :line) (plist-get b :line))
              (< (plist-get a :severity) (plist-get b :severity)))))))

(defun kargu-lsp--severity-label (severity)
  "Return a short label for LSP diagnostic SEVERITY."
  (pcase severity
    (1 "error") (2 "warning") (3 "info") (4 "hint")
    (_ "note")))

(defun kargu-lsp-format-diagnostics (file-path data)
  "Render DATA (from `kargu-lsp--diagnostics-data') as text."
  (if (null data)
      (format "%s: no diagnostics (clean)" file-path)
    (concat
     (format "%s — %d diagnostic(s)\n" file-path (length data))
     (mapconcat
      (lambda (d)
        (format "  [%s] L%d:C%d: %s%s"
                (kargu-lsp--severity-label (plist-get d :severity))
                (plist-get d :line)
                (plist-get d :character)
                (plist-get d :message)
                (if (plist-get d :source)
                    (format " (source: %s)" (plist-get d :source))
                  "")))
      data "\n"))))

(defun kargu-lsp-get-diagnostics (file-path)
  "Return a text report of diagnostics for FILE-PATH.
When the file is not open in Emacs, say so: language servers only
report for files they know."
  (interactive (list (read-file-name "Diagnostics for file: ")))
  (let* ((path (kargu--resolve-path file-path))
         (open (find-buffer-visiting path))
         (data (kargu-lsp--diagnostics-data path))
         (text
          (cond
           ((and (not data) (not open))
            (format "%s: no diagnostics available (file is not open in \
Emacs; open it or use the file reading tool, then retry)" path))
           (t (kargu-lsp-format-diagnostics path data)))))
    (when (called-interactively-p 'any)
      (message "%s" text))
    text))

(defun kargu-lsp-wait-diagnostics (file-path callback &optional timeout)
  "Asynchronously wait for diagnostics of FILE-PATH to settle.
CALLBACK is called with (PATH TEXT TIMEOUT-P) once the language
server or Flycheck has stabilized.  Uses timers only — the UI thread
is never blocked.  The agent loop uses this after edits before
judging a change."
  (let* ((path (kargu--resolve-path file-path))
         (buf (find-buffer-visiting path))
         (has-checker-p
          (and buf
               (buffer-live-p buf)
               (with-current-buffer buf
                 (or (bound-and-true-p lsp-mode)
                     (bound-and-true-p flymake-mode)
                     (bound-and-true-p flycheck-mode)
                     (and (fboundp 'flycheck-get-checker-for-buffer)
                          (flycheck-get-checker-for-buffer)))))))
    ;; If buffer has a valid Flycheck checker and flycheck is available, enable flycheck-mode
    (when (and buf (buffer-live-p buf) (fboundp 'flycheck-mode))
      (with-current-buffer buf
        (when (and (fboundp 'flycheck-get-checker-for-buffer)
                   (flycheck-get-checker-for-buffer))
          (unless (bound-and-true-p flycheck-mode)
            (ignore-errors (flycheck-mode 1)))
          (when (and (bound-and-true-p flycheck-mode) (fboundp 'flycheck-buffer))
            (ignore-errors (flycheck-buffer))))))
    (let* ((timeout (or timeout kargu-lsp-diag-settle-timeout))
           (start (float-time))
           (last-snapshot nil)
           (polls 0))
      (if (not has-checker-p)
          ;; No active checker in buffer: return diagnostics immediately without artificial delay
          (funcall callback path (kargu-lsp-get-diagnostics path) nil)
        (cl-labels
            ((tick ()
               (let* ((flycheck-busy (and buf
                                          (buffer-live-p buf)
                                          (with-current-buffer buf
                                            (and (bound-and-true-p flycheck-mode)
                                                 (fboundp 'flycheck-running-p)
                                                 (flycheck-running-p)))))
                      (timed-out (>= (- (float-time) start) timeout))
                      (snapshot (kargu-lsp--diagnostics-data path)))
                 (setq polls (1+ polls))
                 (if (or timed-out
                         (and (not flycheck-busy)
                              (>= polls 1)
                              (null snapshot))
                         (and (not flycheck-busy)
                              (>= polls 2)
                              (equal snapshot last-snapshot)))
                     (funcall callback
                              path
                              (kargu-lsp-get-diagnostics path)
                              timed-out)
                   (setq last-snapshot snapshot)
                   (run-at-time 0.25 nil #'tick)))))
          (run-at-time 0.25 nil #'tick))))))

;;;; Find definition -------------------------------------------------------

(defun kargu-lsp--loc-uri (loc)
  "URI of a Location or LocationLink LOC."
  (or (kargu-lsp--field loc :targetUri)
      (kargu-lsp--field loc :uri)))

(defun kargu-lsp--loc-line (loc)
  "1-based line of a Location or LocationLink LOC."
  (1+ (or (kargu-lsp--path loc :targetSelectionRange :start :line)
          (kargu-lsp--path loc :range :start :line)
          0)))

(defun kargu-lsp--ws-definitions (symbol-name)
  "Definition candidates for SYMBOL-NAME via workspace/symbol.
Must run with an LSP buffer current."
  (let* ((items (kargu-lsp--ws-symbols symbol-name))
         (exact (cl-remove-if-not
                 (lambda (item) (equal (nth 2 item) symbol-name))
                 items))
         (hits (seq-take (or exact items)
                         kargu-lsp-definition-max-hits)))
    (when hits
      (concat
       (format "Definition candidates for `%s':\n" symbol-name)
       (mapconcat
        (lambda (item)
          (format "  %s:%d  (%s)" (nth 0 item) (nth 1 item)
                  (kargu-lsp--kind-name (nth 3 item))))
        hits "\n")
       (when (and items (null exact))
         "\n(no exact name match; fuzzy candidates listed)")))))

(defun kargu-lsp--definitions-via-occurrence (symbol-name)
  "Fallback: find an occurrence of SYMBOL-NAME in an open LSP buffer
and issue textDocument/definition from that position."
  (cl-loop for buffer in (kargu-lsp--managed-buffers)
           for found = (with-current-buffer buffer
                         (save-excursion
                           (save-restriction
                             (widen)
                             (goto-char (point-min))
                             (when (re-search-forward
                                    (concat "\\_<"
                                            (regexp-quote symbol-name)
                                            "\\_>")
                                    nil t)
                               (list (line-number-at-pos (point))
                                     (- (point)
                                        (line-beginning-position)))))))
           when found
           return (with-current-buffer buffer
                    ;; NB: LSP positions are 0-based; UTF-16 columns are
                    ;; approximated by Emacs character offsets.
                    (let* ((line (1- (nth 0 found)))
                           (character (nth 1 found))
                           (raw (kargu-lsp--seq->list
                                 (lsp-request
                                  "textDocument/definition"
                                  `(:textDocument
                                    (:uri ,(kargu-lsp--buffer-uri))
                                    :position (:line ,line
                                                     :character ,character)))))
                           (hits (delq nil
                                       (mapcar (lambda (loc)
                                                 (let ((uri (kargu-lsp--loc-uri loc)))
                                                   (when uri
                                                     (format "  %s:%d"
                                                             (kargu-lsp--uri-to-path
                                                              uri)
                                                             (kargu-lsp--loc-line
                                                              loc)))))
                                               raw))))
                      (when hits
                        (concat
                         (format "Definition(s) of `%s' (from an occurrence in %s):\n"
                                 symbol-name (buffer-file-name buffer))
                         (string-join (seq-take hits
                                                kargu-lsp-definition-max-hits)
                                      "\n")))))))

(defun kargu-lsp-find-definition (symbol-name)
  "Return text describing the definition sites of SYMBOL-NAME."
  (interactive "sSymbol: ")
  (let ((text
         (condition-case-unless-debug err
             (kargu-lsp--with-session
              (lambda ()
                (or (kargu-lsp--ws-definitions symbol-name)
                    (kargu-lsp--definitions-via-occurrence
                     symbol-name)
                    (format "No definition found for `%s' in the workspace"
                            symbol-name))))
           (error
            (kargu-log 'warn "find-definition: %s"
                             (error-message-string err))
            (format "ERROR: %s" (error-message-string err))))))
    (when (called-interactively-p 'any)
      (message "%s" text))
    text))

;;;; Tool registration -----------------------------------------------------

(defun kargu-lsp-register-tools ()
  "Register the LSP tools with the kargu tool registry."
  (kargu-register-tool
   "lsp_project_skeleton"
   "Get a compact map of the whole project: every file with its symbols (functions, types, classes, constants) and line numbers. Use this FIRST to orient yourself; it is far cheaper than reading files."
   '(("type" . "object")
     ("properties" . :json-empty-object))
   (lambda (_args) (kargu-lsp-build-skeleton)))
  (kargu-register-tool
   "lsp_diagnostics"
   "Get compiler and linter diagnostics (errors, warnings) for one source file, with line numbers, messages and severity. Works on files open in Emacs. Call this after editing a file to verify it still compiles cleanly."
   '(("type" . "object")
     ("properties" . (("file_path" . (("type" . "string")
                                      ("description" . "Absolute or project-relative path of the file to check. Defaults to the current context file."))))))
   (lambda (args)
     (let ((path (or (kargu--tool-file-path args)
                     (kargu--context-file))))
       (if (and path (not (string-empty-p path)))
           (kargu-lsp-get-diagnostics path)
         "ERROR: no file_path given and no context file set"))))
  (kargu-register-tool
   "lsp_find_symbol"
   "Locate where a named symbol (function, type, variable) is defined in the workspace. Returns file:line for each definition candidate."
   '(("type" . "object")
     ("properties" . (("symbol_name" . (("type" . "string")
                                        ("description" . "Name of the symbol to look up, e.g. the function or type name.")))))
     ("required" . ["symbol_name"]))
   (lambda (args)
     (let ((name (kargu--tool-arg args "symbol_name" "symbolName" "symbol")))
       (if (or (null name) (string-empty-p name))
           "ERROR: symbol_name is required"
         (kargu-lsp-find-definition name))))))

(kargu-lsp-register-tools)

(provide 'kargu/tools/lsp)

;;; kargu/tools/lsp.el ends here
