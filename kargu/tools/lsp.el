;;; kargu/tools/lsp.el --- LSP skeleton, diagnostics, xref via Eglot -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; LSP skeleton, diagnostics, xref, and AST/symbol manipulation via Eglot.
;; Requires: `kargu/core', `kargu/api', `kargu/permission', `eglot'.
;;
;; Tools provided:
;;  * `lsp_project_skeleton' — compact structural outline of the project
;;    via `workspace/symbol' (or `documentSymbol' fallback).
;;  * `lsp_diagnostics' — compiler and linter diagnostics for a file
;;    or across the entire project (via Flymake).
;;  * `lsp_find_symbol' — definition locations for a named symbol.
;;  * `read_file_symbols' — language-agnostic outline of symbols and line
;;    ranges in a file via `textDocument/documentSymbol' + imenu fallback.
;;  * `read_symbol' — body of a specific symbol extracted without loading
;;    the whole file.
;;  * `edit_by_lsp' / `edit_symbol' — surgical symbol replacement using
;;    exact AST / LSP line ranges.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'kargu/core)
(require 'kargu/json)
(require 'kargu/api)
(require 'kargu/permission)
(require 'eglot nil t)
(require 'imenu nil t)

(declare-function eglot-current-server "eglot")
(declare-function eglot-project "eglot")
(declare-function eglot-uri-to-path "eglot")
(declare-function eglot-path-to-uri "eglot")
(declare-function eglot--request "eglot")
(declare-function jsonrpc-request "jsonrpc")
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
(declare-function kargu-diff-apply-proposal "kargu/tools/diff" (path contents &optional callback))
(declare-function kargu-diff--describe "kargu/tools/diff" (proposal))
(declare-function kargu-diff--file-text "kargu/tools/diff/stage" (path))
(declare-function kargu-diff-read-file "kargu/tools/diff" (file-path &optional from-line to-line))
(declare-function kargu-seq-to-list "kargu/json" (seq))

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
  "Seconds `kargu-lsp-wait-diagnostics' waits for the language
server to republish diagnostics after an edit."
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
  "Thread OBJECT through successive `kargu-lsp--field' calls."
  (cl-reduce (lambda (acc field)
               (and acc (kargu-lsp--field acc field)))
             fields :initial-value object))

(defalias 'kargu-lsp--seq->list #'kargu-seq-to-list)

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

(defun kargu-lsp--managed-buffer ()
  "Return the buffer used to route LSP requests, or nil.
Priority: a managed context buffer, then any managed buffer, then
the context buffer itself."
  (or (let ((buffer (kargu-lsp--context-buffer-live)))
        (and buffer (kargu-lsp--buffer-managed-p buffer) buffer))
      (car (kargu-lsp--managed-buffers))
      (kargu-lsp--context-buffer-live)))

(defun kargu-lsp--with-session (fn)
  "Call FN with an Eglot-managed buffer current; return FN's result.
Signal an `error' when no Eglot session is usable."
  (let ((buffer (kargu-lsp--managed-buffer)))
    (if (null buffer)
        (error "No active LSP session: run M-x eglot in a project buffer (or set `kargu-context-buffer')")
      (with-current-buffer buffer
        (funcall fn)))))

(defun kargu--context-file ()
  "Return the context file name, or nil."
  (let ((buffer (kargu-lsp--context-buffer-live)))
    (or (and buffer (buffer-file-name buffer))
        (and (stringp kargu-context-buffer)
             (file-exists-p kargu-context-buffer)
             kargu-context-buffer))))

(defconst kargu-eglot-required-message
  "kargu: Eglot is not connected to a language server. Visit a project file, start Eglot, then open kargu again."
  "Error shown when this project has no live Eglot connection.")

(defun kargu--eglot-workspace-buffer ()
  "Return the Eglot-managed buffer that names the workspace, or nil.
The current buffer wins when Eglot manages it.  Otherwise the most
recent managed file buffer.  `default-directory' is not consulted:
a chat or temporary buffer must not hide the server's project."
  (or (and (kargu-lsp--buffer-managed-p (current-buffer))
           (current-buffer))
      (car (kargu-lsp--managed-buffers))))

(declare-function kargu-permission--eglot-server-root "kargu/permission/guards" (server))

(defun kargu--project-root ()
  "Return the connected Eglot server's project root, or nil.
The directory is the one stored on the server.  The user is never
asked, and `default-directory' is not used in its place."
  (let ((buffer (kargu--eglot-workspace-buffer)))
    (when (and (buffer-live-p buffer)
               (fboundp 'eglot-current-server))
      (kargu-permission--eglot-server-root
       (with-current-buffer buffer
         (eglot-current-server))))))

(defun kargu-eglot-connected-p ()
  "Return non-nil when Eglot manages a file.
The current buffer's directory does not matter.  A server started
in the project counts even if this buffer is a chat or lives under
`temporary-file-directory'."
  (consp (kargu-lsp--managed-buffers)))

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

(defun kargu-lsp--timeout-p (err)
  "Non-nil when ERR is an LSP request that ran out of time."
  (string-match-p "[Tt]imed? ?out" (error-message-string err)))

(defun kargu-lsp--eglot-request (server method params timeout)
  "Call `eglot--request' for SERVER, METHOD and PARAMS, bounded by TIMEOUT.
A build that takes keyword arguments gets :timeout; an older build gets
TIMEOUT as the optional positional argument."
  (let ((args (help-function-arglist 'eglot--request t)))
    (if (or (memq '&key args) (memq '&rest args))
        (eglot--request server method params :timeout timeout)
      (eglot--request server method params timeout))))

(defun kargu-lsp--request (method params &optional buffer)
  "Send an LSP request with METHOD and PARAMS in BUFFER (or current) using Eglot.
The call stays synchronous and gives up after `kargu-lsp-request-timeout'."
  (let* ((buf (or buffer (current-buffer))))
    (with-current-buffer buf
      (let ((server (and (fboundp 'eglot-current-server)
                         (eglot-current-server)))
            (kw-method (cond
                        ((keywordp method) method)
                        ((symbolp method) (intern (concat ":" (symbol-name method))))
                        ((stringp method)
                         (intern (concat ":" (replace-regexp-in-string "\\`:" "" method))))
                        (t (intern (format ":%s" method)))))
            (timeout kargu-lsp-request-timeout))
        (unless server
          (error "No active Eglot server in buffer %s" (buffer-name buf)))
        (condition-case err
            (if (fboundp 'eglot--request)
                (kargu-lsp--eglot-request server kw-method params timeout)
              (jsonrpc-request server kw-method params :timeout timeout))
          (error
           (if (kargu-lsp--timeout-p err)
               (error "LSP request timed out after %s seconds" timeout)
             (signal (car err) (cdr err)))))))))

;;;; Symbol gathering (skeleton data) -------------------------------------

(defun kargu-lsp--symbol-information-item (item)
  "Convert one SymbolInformation or WorkspaceSymbol ITEM to (PATH LINE NAME KIND)."
  (let* ((name (kargu-lsp--field item :name))
         (kind (kargu-lsp--field item :kind))
         (location (kargu-lsp--field item :location))
         (uri (or (kargu-lsp--field location :uri)
                  (kargu-lsp--field location :targetUri)
                  (kargu-lsp--field item :uri)))
         (line (or (kargu-lsp--path location :range :start :line)
                   (kargu-lsp--path location :targetRange :start :line)
                   (kargu-lsp--path location :targetSelectionRange :start :line)
                   (kargu-lsp--path item :range :start :line))))
    (when (and name uri)
      (list (kargu-lsp--uri-to-path uri)
            (1+ (or line 0))
            name
            kind))))

(defun kargu-lsp--ws-symbols (query)
  "Return flat ((PATH LINE NAME KIND)...) for QUERY via workspace/symbol."
  (condition-case-unless-debug err
      (let ((items (kargu-lsp--seq->list
                    (kargu-lsp--request :workspace/symbol `(:query ,query)))))
        (delq nil (mapcar #'kargu-lsp--symbol-information-item items)))
    (error
     (kargu-log 'warn "workspace/symbol %S failed: %s"
                query (error-message-string err))
     nil)))

(defun kargu-lsp--doc-symbol-walk (items path)
  "Flatten documentSymbol ITEMS (nested children) for PATH."
  (cl-loop for item in (kargu-lsp--seq->list items)
           for name = (kargu-lsp--field item :name)
           for kind = (kargu-lsp--field item :kind)
           for line = (or (kargu-lsp--path item :range :start :line)
                          (kargu-lsp--path item :location :range :start :line))
           when (and name path)
           append (cons (list path (1+ (or line 0)) name kind)
                        (kargu-lsp--doc-symbol-walk
                         (kargu-lsp--field item :children) path))))

(defun kargu-lsp--doc-symbols ()
  "Gather symbols via textDocument/documentSymbol over open Eglot buffers."
  (let (acc (count 0))
    (dolist (buffer (kargu-lsp--managed-buffers))
      (when (< count 40)
        (let ((path (buffer-file-name buffer)))
          (condition-case-unless-debug _err
              (with-current-buffer buffer
                (let ((items (kargu-lsp--seq->list
                              (kargu-lsp--request :textDocument/documentSymbol
                                                  `(:textDocument
                                                    (:uri ,(kargu-lsp--buffer-uri buffer)))
                                                  buffer))))
                  (setq acc (nconc acc (kargu-lsp--doc-symbol-walk items path))
                        count (1+ count))))
            (error nil)))))
    acc))

(defun kargu-lsp--gather-symbols ()
  "Return (SOURCE . ITEMS) for the skeleton, or signal an error."
  (kargu-lsp--with-session
   (lambda ()
     (let ((ws (kargu-lsp--ws-symbols "")))
       (if ws
           (cons "workspace/symbol" ws)
         (kargu-log 'warn "skeleton: workspace/symbol empty; falling back to documentSymbol")
         (let ((doc (kargu-lsp--doc-symbols)))
           (if doc
               (cons "textDocument/documentSymbol (open buffers only)" doc)
             (error "No symbols available: workspace/symbol returned nothing and no Eglot buffers are open"))))))))

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
                (let ((syms (kargu-lsp--imenu-document-symbols buf)))
                  (dolist (s (kargu-lsp--flatten-symbols syms))
                    (push (list path
                                (plist-get s :start-line)
                                (plist-get s :name)
                                (plist-get s :kind))
                          acc)))
              (error nil))))))
    (nreverse acc)))

(defun kargu-lsp-all-symbols (&optional query roots)
  "Return flat list of ((PATH LINE NAME KIND) ...) matching optional QUERY.
Combines LSP symbols with Emacs `imenu' across ROOTS."
  (let ((seen (make-hash-table :test #'equal))
        acc)
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
                         (kind (kargu-lsp--kind-name (nth 3 item)))
                         (key (cons path name)))
                    (unless (gethash key seen)
                      (puthash key t seen)
                      (push (list path line name kind) acc))))))))
      (error nil))
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

;;;; Skeleton rendering & caching -----------------------------------------

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
  "Render ITEMS ((PATH LINE NAME KIND)...) as the skeleton text."
  (let ((by-file (make-hash-table :test #'equal))
        (root-dir (file-name-as-directory (expand-file-name root)))
        (total 0))
    (dolist (item items)
      (let ((path (car item)))
        (when (and (stringp path)
                   (ignore-errors
                     (file-in-directory-p (expand-file-name path) root-dir)))
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
                (push (format "# symbol cap reached (%d); raise `kargu-lsp-skeleton-max-symbols' for more"
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
the skeleton is also displayed in a buffer."
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

;;;; Diagnostics ----------------------------------------------------------

(defun kargu-lsp--flymake-diags (path)
  "Normalized Flymake diagnostics for PATH, or nil."
  (when (and (fboundp 'flymake-diagnostics)
             (fboundp 'flymake-diagnostic-text))
    (let ((buffer (find-buffer-visiting path)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let ((source (if (kargu-lsp--buffer-managed-p buffer) "eglot" "flymake")))
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
                                           ((or :error 'flymake-error 'e :flymake-error) 1)
                                           ((or :warning 'flymake-warning 'w :flymake-warning) 2)
                                           (_ 3))
                               :line (line-number-at-pos pos)
                               :character 1
                               :source source
                               :message (flymake-diagnostic-text d)))))
                   (flymake-diagnostics)))))))))

(defun kargu-lsp--diagnostics-data (file-path)
  "Return normalized diagnostics for FILE-PATH as a list of plists
(:severity :line :character :message :source), sorted by severity then line."
  (let* ((path (kargu-permission-resolve file-path "lsp path"))
         (combined (kargu-lsp--flymake-diags path))
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
  "Return a text report of diagnostics for FILE-PATH."
  (interactive (list (read-file-name "Diagnostics for file: ")))
  (let* ((path (kargu-permission-resolve file-path "lsp path"))
         (open (find-buffer-visiting path))
         (data (kargu-lsp--diagnostics-data path))
         (text
          (cond
           ((and (not data) (not open))
            (format "%s: no diagnostics available (file is not open in Emacs; open it or use read_file first)" path))
           (t (kargu-lsp-format-diagnostics path data)))))
    (when (called-interactively-p 'any)
      (message "%s" text))
    text))

(defun kargu-lsp--extract-flymake-diag (diag)
  "Extract (:file :severity :line :character :source :message) from Flymake DIAG."
  (let* ((locus (or (and (fboundp 'flymake-diagnostic-buffer)
                         (flymake-diagnostic-buffer diag))
                    (and (fboundp 'flymake--diag-locus)
                         (flymake--diag-locus diag))))
         (file (cond
                ((bufferp locus)
                 (when (buffer-live-p locus)
                   (or (buffer-file-name locus) (buffer-name locus))))
                ((stringp locus) locus)
                (t nil)))
         (beg (if (fboundp 'flymake-diagnostic-beg)
                  (flymake-diagnostic-beg diag)
                (and (fboundp 'flymake-diagnostic-point)
                     (flymake-diagnostic-point diag))))
         (pos (if (consp beg) (car beg) beg))
         (line (cond
                ((and (bufferp locus) (buffer-live-p locus) (number-or-marker-p pos))
                 (with-current-buffer locus
                   (save-excursion
                     (goto-char (if (markerp pos) (marker-position pos) pos))
                     (line-number-at-pos))))
                ((numberp pos) (if (> pos 1000000) 1 pos))
                (t 1)))
         (type (and (fboundp 'flymake-diagnostic-type) (flymake-diagnostic-type diag)))
         (text (and (fboundp 'flymake-diagnostic-text) (flymake-diagnostic-text diag)))
         (backend (and (fboundp 'flymake-diagnostic-backend) (flymake-diagnostic-backend diag)))
         (source (cond
                  ((stringp backend) backend)
                  ((symbolp backend) (symbol-name backend))
                  (t "eglot"))))
    (when (and file text)
      (list :file (expand-file-name file)
            :severity (pcase type
                        ((or :error 'flymake-error 'e :flymake-error) 1)
                        ((or :warning 'flymake-warning 'w :flymake-warning) 2)
                        (_ 3))
            :line line
            :character 1
            :source source
            :message text))))

(defun kargu-lsp--collect-project-diagnostics (root)
  "Collect raw diagnostics across the project ROOT from Flymake and open buffers.
Nil when ROOT is not a directory string."
  (if (not (stringp root))
      nil
    (let* ((all-diags nil)
         (flymake-proj (when (fboundp 'flymake--project-diagnostics)
                         (condition-case _err
                             (let ((default-directory root))
                               (flymake--project-diagnostics
                                (and (fboundp 'project-current)
                                     (project-current nil root))))
                           (error nil))))
         (open-proj-diags
          (cl-loop for buf in (buffer-list)
                   for fn = (buffer-file-name buf)
                   when (and fn (string-prefix-p root (expand-file-name fn)))
                   append (cl-loop for d in (kargu-lsp--diagnostics-data fn)
                                   collect (append (list :file (expand-file-name fn)) d)))))
    (dolist (d flymake-proj)
      (let ((extracted (kargu-lsp--extract-flymake-diag d)))
        (when extracted
          (push extracted all-diags))))
    (dolist (d open-proj-diags)
      (push d all-diags))
    all-diags)))

(defun kargu-lsp--group-diagnostics-by-file (all-diags)
  "Deduplicate and group ALL-DIAGS by file.
Return a list `(TOTAL-COUNT BY-FILE-HASH)'."
  (let ((by-file (make-hash-table :test 'equal))
        (seen (make-hash-table :test 'equal))
        (total-count 0))
    (dolist (d all-diags)
      (let* ((file (plist-get d :file))
             (key (format "%s:%s:%s:%s"
                          file
                          (plist-get d :line)
                          (plist-get d :severity)
                          (plist-get d :message))))
        (unless (gethash key seen)
          (puthash key t seen)
          (cl-incf total-count)
          (puthash file (cons d (gethash file by-file)) by-file))))
    (list total-count by-file)))

(defun kargu-lsp--format-file-diagnostic-section (root file items)
  "Format diagnostic ITEMS for FILE relative to ROOT."
  (let* ((sorted-items
          (sort (copy-sequence items)
                (lambda (a b)
                  (if (= (plist-get a :severity) (plist-get b :severity))
                      (< (plist-get a :line) (plist-get b :line))
                    (< (plist-get a :severity) (plist-get b :severity))))))
         (err-count (cl-count-if (lambda (d) (= (plist-get d :severity) 1)) sorted-items))
         (warn-count (cl-count-if (lambda (d) (= (plist-get d :severity) 2)) sorted-items))
         (rel-file (if (string-prefix-p root file)
                       (substring file (length root))
                     file)))
    (concat
     (format "== %s (%d diagnostic%s%s) ==\n"
             rel-file
             (length sorted-items)
             (if (= (length sorted-items) 1) "" "s")
             (cond
              ((and (> err-count 0) (> warn-count 0))
               (format ": %d error%s, %d warning%s"
                       err-count (if (= err-count 1) "" "s")
                       warn-count (if (= warn-count 1) "" "s")))
              ((> err-count 0)
               (format ": %d error%s" err-count (if (= err-count 1) "" "s")))
              ((> warn-count 0)
               (format ": %d warning%s" warn-count (if (= warn-count 1) "" "s")))
              (t "")))
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
      sorted-items "\n"))))

(defun kargu-lsp--format-project-diagnostics (root total-count by-file)
  "Format aggregated diagnostics for ROOT given TOTAL-COUNT and BY-FILE table."
  (if (zerop total-count)
      (format "[Project Clean] No compile or linter diagnostics found across the project (root: %s)." root)
    (let* ((files (hash-table-keys by-file))
           (sorted-files
            (sort files
                  (lambda (a b)
                    (let ((a-has-err (cl-some (lambda (d) (= (plist-get d :severity) 1)) (gethash a by-file)))
                          (b-has-err (cl-some (lambda (d) (= (plist-get d :severity) 1)) (gethash b by-file))))
                      (cond
                       ((and a-has-err (not b-has-err)) t)
                       ((and (not a-has-err) b-has-err) nil)
                       (t (string< a b)))))))
           (sections
            (mapcar (lambda (f)
                      (kargu-lsp--format-file-diagnostic-section root f (gethash f by-file)))
                    sorted-files)))
      (concat
       (format "Project diagnostics (root: %s) — %d diagnostic%s across %d file%s:\n\n"
               root total-count (if (= total-count 1) "" "s")
               (length sorted-files) (if (= (length sorted-files) 1) "" "s"))
       (string-join sections "\n\n")))))

(defun kargu-lsp-get-project-diagnostics ()
  "Scan and return a text report of diagnostics across the entire project.
Aggregates diagnostics from Flymake project diagnostics and all open
project buffers."
  (interactive)
  (let* ((root (kargu--project-root))
         (all-diags (kargu-lsp--collect-project-diagnostics root))
         (grouped (kargu-lsp--group-diagnostics-by-file all-diags))
         (total-count (nth 0 grouped))
         (by-file (nth 1 grouped))
         (text (kargu-lsp--format-project-diagnostics root total-count by-file)))
    (when (called-interactively-p 'any)
      (message "%s" text))
    text))

(defun kargu-lsp--buffer-has-checker-p (buf)
  "Return non-nil if BUF has Flymake or an Eglot-managed syntax checker."
  (and buf (buffer-live-p buf)
       (or (kargu-lsp--buffer-managed-p buf)
           (with-current-buffer buf
             (bound-and-true-p flymake-mode)))))

(defun kargu-lsp--checker-busy-p (buf)
  "Return non-nil if Flymake is currently running on BUF."
  (and buf (buffer-live-p buf)
       (with-current-buffer buf
         (and (bound-and-true-p flymake-mode)
              (fboundp 'flymake-is-running)
              (flymake-is-running)))))

(defun kargu-lsp-wait-diagnostics (file-path callback &optional timeout)
  "Asynchronously wait for diagnostics of FILE-PATH to settle.
CALLBACK is called with (PATH TEXT TIMEOUT-P) once Flymake has stabilized."
  (let* ((path (kargu-permission-resolve file-path "lsp path"))
         (buf (find-buffer-visiting path))
         (has-checker-p (kargu-lsp--buffer-has-checker-p buf))
         (timeout (or timeout kargu-lsp-diag-settle-timeout))
         (start (float-time))
         (last-snapshot nil)
         (polls 0))
    (if (not has-checker-p)
        (funcall callback path (kargu-lsp-get-diagnostics path) nil)
      (cl-labels
          ((tick ()
             (let* ((busy (kargu-lsp--checker-busy-p buf))
                    (timed-out (>= (- (float-time) start) timeout))
                    (snapshot (kargu-lsp--diagnostics-data path)))
               (setq polls (1+ polls))
               (if (or timed-out
                       (and (not busy) (>= polls 1) (null snapshot))
                       (and (not busy) (>= polls 2) (equal snapshot last-snapshot)))
                   (funcall callback path (kargu-lsp-get-diagnostics path) timed-out)
                 (setq last-snapshot snapshot)
                 (run-at-time 0.25 nil #'tick)))))
        (run-at-time 0.25 nil #'tick)))))

;;;; Find definition ------------------------------------------------------

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
  "Definition candidates for SYMBOL-NAME via workspace/symbol."
  (let* ((items (kargu-lsp--ws-symbols symbol-name))
         (exact (cl-remove-if-not
                 (lambda (item) (equal (nth 2 item) symbol-name))
                 items))
         (hits (seq-take (or exact items) kargu-lsp-definition-max-hits)))
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
  "Fallback: find an occurrence of SYMBOL-NAME and issue textDocument/definition."
  (cl-loop for buffer in (kargu-lsp--managed-buffers)
           for found = (with-current-buffer buffer
                         (save-excursion
                           (save-restriction
                             (widen)
                             (goto-char (point-min))
                             (when (re-search-forward
                                    (concat "\\_<" (regexp-quote symbol-name) "\\_>")
                                    nil t)
                               (list (line-number-at-pos (point))
                                     (- (point) (line-beginning-position)))))))
           when found
           return (with-current-buffer buffer
                    (let* ((line (1- (nth 0 found)))
                           (character (nth 1 found))
                           (raw (kargu-lsp--seq->list
                                 (kargu-lsp--request
                                  :textDocument/definition
                                  `(:textDocument (:uri ,(kargu-lsp--buffer-uri buffer))
                                    :position (:line ,line :character ,character))
                                  buffer)))
                           (hits (delq nil
                                       (mapcar (lambda (loc)
                                                 (let ((uri (kargu-lsp--loc-uri loc)))
                                                   (when uri
                                                     (format "  %s:%d"
                                                             (kargu-lsp--uri-to-path uri)
                                                             (kargu-lsp--loc-line loc)))))
                                               raw))))
                      (when hits
                        (concat
                         (format "Definition(s) of `%s' (from an occurrence in %s):\n"
                                 symbol-name (buffer-file-name buffer))
                         (string-join (seq-take hits kargu-lsp-definition-max-hits) "\n")))))))

(defun kargu-lsp-find-definition (symbol-name)
  "Return text describing the definition sites of SYMBOL-NAME."
  (interactive "sSymbol: ")
  (let ((text
         (condition-case-unless-debug err
             (kargu-lsp--with-session
              (lambda ()
                (or (kargu-lsp--ws-definitions symbol-name)
                    (kargu-lsp--definitions-via-occurrence symbol-name)
                    (format "No definition found for `%s' in the workspace" symbol-name))))
           (error
            (kargu-log 'warn "find-definition: %s" (error-message-string err))
            (format "ERROR: %s" (error-message-string err))))))
    (when (called-interactively-p 'any)
      (message "%s" text))
    text))

;;;; Document symbols, outline, reading and surgical editing --------------

(defun kargu-lsp--kind-label (kind-num)
  "Symbol kind name for a numeric or string KIND-NUM."
  (cond
   ((numberp kind-num) (kargu-lsp--kind-name kind-num))
   ((stringp kind-num) kind-num)
   (t "Symbol")))

(defun kargu-lsp--inclusive-end (start-line end-0 end-char)
  "1-based inclusive end line.
LSP END-0 is exclusive.  A character of 0 means the range stops
at the start of that line, so the previous line is the last one
included.  END-0 itself is then the 1-based index of that line."
  (cond
   ((not (numberp end-0)) start-line)
   ((and (numberp end-char) (<= end-char 0))
    (max start-line end-0))
   (t (max start-line (1+ end-0)))))

(defun kargu-lsp--symbol-plist (item)
  "Normalized plist for one LSP document symbol ITEM, or nil."
  (let* ((name (kargu-lsp--field item :name))
         (start-0 (or (kargu-lsp--path item :range :start :line)
                      (kargu-lsp--path item :location :range :start :line)))
         (end-0 (or (kargu-lsp--path item :range :end :line)
                    (kargu-lsp--path item :location :range :end :line)))
         (end-char (or (kargu-lsp--path item :range :end :character)
                       (kargu-lsp--path item :location :range :end :character)))
         (start-line (if start-0 (1+ start-0) 1))
         (children-raw (kargu-lsp--field item :children)))
    (when name
      (list :name name
            :kind (kargu-lsp--kind-label (kargu-lsp--field item :kind))
            :start-line start-line
            :end-line (kargu-lsp--inclusive-end start-line end-0 end-char)
            :detail (kargu-lsp--field item :detail)
            :children (and children-raw
                           (kargu-lsp--parse-document-symbols children-raw))))))

(defun kargu-lsp--parse-document-symbols (raw)
  "Parse LSP documentSymbol RAW (vector or list) into normalized symbol plists.
Each plist has keys :name, :kind, :start-line, :end-line, :detail, :children."
  (let (acc)
    (dolist (item (kargu-lsp--seq->list raw))
      (when-let* ((plist (kargu-lsp--symbol-plist item)))
        (push plist acc)))
    (nreverse acc)))

(defun kargu-lsp--imenu-kind (raw-kind &optional pos)
  "Convert RAW-KIND string into a normalized LSP SymbolKind name.
If RAW-KIND is nil and POS is non-nil, inspects buffer text at POS."
  (cond
   ((and (null raw-kind) pos)
    (save-excursion
      (goto-char pos)
      (cond
       ((looking-at-p "\\s-*(\\(?:defun\\|defmacro\\|defsubst\\|cl-defun\\)") "Function")
       ((looking-at-p "\\s-*(\\(?:defvar\\|defcustom\\|defconst\\)") "Variable")
       ((looking-at-p "\\s-*(\\(?:defclass\\|cl-defstruct\\)") "Class")
       (t "Symbol"))))
   ((null raw-kind) "Symbol")
   ((string-match-p "\\`\\(?:Variables?\\|Constants?\\|Fields?\\)\\'" raw-kind) "Variable")
   ((string-match-p "\\`\\(?:Functions?\\|Defuns?\\|Methods?\\)\\'" raw-kind) "Function")
   ((string-match-p "\\`\\(?:Types?\\|TypeDefs?\\)\\'" raw-kind) "Type")
   ((string-match-p "\\`\\(?:Classes?\\)\\'" raw-kind) "Class")
   ((string-match-p "\\`\\(?:Structs?\\|Structures?\\)\\'" raw-kind) "Struct")
   ((string-match-p "\\`\\(?:Enums?\\)\\'" raw-kind) "Enum")
   ((string-match-p "\\`\\(?:Interfaces?\\)\\'" raw-kind) "Interface")
   ((string-match-p "\\`\\(?:Modules?\\|Namespaces?\\|Packages?\\)\\'" raw-kind) "Module")
   ((string-match-p "\\`\\(?:Macros?\\)\\'" raw-kind) "Function")
   (t raw-kind)))

(defun kargu-lsp--imenu-walk (items &optional cat)
  "Recursively walk imenu ITEMS under category CAT to produce symbol plists."
  (let (acc)
    (dolist (it items)
      (when (consp it)
        (let ((name (car it))
              (val (cdr it)))
          (unless (or (not (stringp name)) (string= name "*Rescan*"))
            (if (and (listp val) (consp (car-safe val)))
                (setq acc (nconc acc (kargu-lsp--imenu-walk val name)))
              (let* ((pos (cond
                           ((markerp val) (marker-position val))
                           ((integerp val) val)
                           ((and (consp val) (integerp (car val))) (car val))
                           ((and (consp val) (markerp (car val))) (marker-position (car val)))
                           (t nil)))
                     (line (and pos (numberp pos) (line-number-at-pos pos)))
                     (kind (kargu-lsp--imenu-kind cat pos)))
                (when (and line (> line 0))
                  (let ((end-line
                         (save-excursion
                           (goto-char pos)
                           (condition-case nil
                               (progn
                                 (end-of-defun)
                                 (let* ((raw-end (line-number-at-pos (point)))
                                        (e (if (and (bolp) (> raw-end line))
                                               (1- raw-end)
                                             raw-end)))
                                   (if (and (>= e line) (<= e (count-lines (point-min) (point-max))))
                                       e
                                     line)))
                             (error line)))))
                    (push (list :name name
                                :kind kind
                                :start-line line
                                :end-line (max line end-line)
                                :detail nil
                                :children nil)
                          acc)))))))))
    acc))

(defun kargu-lsp--imenu-document-symbols (buffer)
  "Extract document symbols from BUFFER using `imenu'.
Returns a sorted list of plists with keys :name, :kind, :start-line,
and :end-line."
  (with-current-buffer buffer
    (require 'imenu nil t)
    (let* ((index (condition-case nil
                      (imenu--make-index-alist t)
                    (error nil)))
           (res (kargu-lsp--imenu-walk index)))
      (sort res (lambda (a b)
                  (if (= (plist-get a :start-line) (plist-get b :start-line))
                      (< (plist-get a :end-line) (plist-get b :end-line))
                    (< (plist-get a :start-line) (plist-get b :start-line))))))))

(defun kargu-lsp-get-file-symbols (file-path)
  "Retrieve document symbols for FILE-PATH via Eglot or `imenu'."
  (let* ((path (kargu-permission-resolve file-path "lsp path"))
         (buf (or (find-buffer-visiting path)
                  (find-file-noselect path)))
         symbols)
    (unless (file-regular-p path)
      (error "File does not exist or is not a regular file: %s" path))
    ;; 1. Try Eglot textDocument/documentSymbol
    (when (and (buffer-live-p buf) (kargu-lsp--buffer-managed-p buf))
      (condition-case-unless-debug err
          (with-current-buffer buf
            (let ((raw (kargu-lsp--request
                        :textDocument/documentSymbol
                        `(:textDocument (:uri ,(kargu-lsp--buffer-uri buf)))
                        buf)))
              (when raw
                (setq symbols (kargu-lsp--parse-document-symbols raw)))))
        (error
         (kargu-log 'warn "documentSymbol failed for %s: %s; falling back to imenu"
                    path (error-message-string err)))))
    ;; 2. Fall back to imenu
    (unless symbols
      (when (buffer-live-p buf)
        (setq symbols (kargu-lsp--imenu-document-symbols buf))))
    symbols))

(defun kargu-lsp-format-symbols-outline (file-path symbols)
  "Render SYMBOLS tree as a compact outline string for FILE-PATH."
  (if (null symbols)
      (format "File: %s (no symbols found; use read_file with from_line/to_line to read content)"
              file-path)
    (let* ((count 0)
           (format-item
            (lambda (fn item depth)
              (setq count (1+ count))
              (let* ((name (plist-get item :name))
                     (kind (or (plist-get item :kind) "Symbol"))
                     (s-line (plist-get item :start-line))
                     (e-line (plist-get item :end-line))
                     (detail (plist-get item :detail))
                     (children (plist-get item :children))
                     (indent (make-string (* depth 2) ?\s))
                     (bullet (if (= depth 0) "• " "- "))
                     (range (if (and e-line (> e-line s-line))
                                (format "lines %d-%d" s-line e-line)
                              (format "line %d" s-line)))
                     (line (format "  %s%s %s %s [%s]%s"
                                   indent bullet kind name range
                                   (if (and detail (not (string-empty-p detail)))
                                       (format " (%s)" detail)
                                     "")))
                     (child-lines
                      (when children
                        (mapconcat (lambda (child)
                                     (funcall fn fn child (1+ depth)))
                                   children
                                   "\n"))))
                (if (and child-lines (not (string-empty-p child-lines)))
                    (concat line "\n" child-lines)
                  line))))
           (body (mapconcat (lambda (sym)
                              (funcall format-item format-item sym 0))
                            symbols
                            "\n")))
      (format "File: %s (%d symbol(s) found)\n%s"
              file-path count body))))

(defun kargu-lsp-read-file-symbols (file-path)
  "Return a language-agnostic symbol outline for FILE-PATH."
  (let* ((path (kargu-permission-resolve file-path "lsp path"))
         (symbols (kargu-lsp-get-file-symbols path)))
    (kargu-lsp-format-symbols-outline path symbols)))

(defun kargu-lsp--flatten-symbols (symbols &optional container)
  "Flatten hierarchical SYMBOLS tree into a flat list of symbol plists."
  (let (acc)
    (dolist (sym symbols)
      (let* ((children (plist-get sym :children))
             (name (plist-get sym :name))
             (entry (if container
                        (plist-put (copy-sequence sym) :container container)
                      sym)))
        (push entry acc)
        (when children
          (setq acc (nconc (nreverse (kargu-lsp--flatten-symbols children name)) acc)))))
    (nreverse acc)))

(defun kargu-lsp--symbol-named-p (symbol symbol-name)
  "Non-nil when SYMBOL's name or container-qualified name is SYMBOL-NAME."
  (or (equal (plist-get symbol :name) symbol-name)
      (string-equal-ignore-case (plist-get symbol :name) symbol-name)
      (let ((cont (plist-get symbol :container)))
        (and cont
             (or (equal (format "%s.%s" cont (plist-get symbol :name)) symbol-name)
                 (equal (format "%s::%s" cont (plist-get symbol :name)) symbol-name))))))

(defun kargu-lsp--kind-matches-p (symbol kind)
  "Non-nil when SYMBOL's kind equals KIND, ignoring case."
  (string-equal-ignore-case (or (plist-get symbol :kind) "") kind))

(defun kargu-lsp--find-symbol-in-list (symbols symbol-name &optional kind)
  "Find symbol matching SYMBOL-NAME and optional KIND in flat SYMBOLS list.
A kind does not widen the search to every symbol of that kind."
  (let ((named (cl-remove-if-not
                (lambda (symbol) (kargu-lsp--symbol-named-p symbol symbol-name))
                symbols)))
    (cond
     ((null named) nil)
     ((and kind (not (string-empty-p (string-trim kind))))
      (cl-remove-if-not
       (lambda (symbol) (kargu-lsp--kind-matches-p symbol kind))
       named))
     (t named))))

(defun kargu-lsp-read-symbol (file-path symbol-name &optional kind)
  "Read the implementation body of SYMBOL-NAME in FILE-PATH."
  (let* ((path (kargu-permission-resolve file-path "lsp path"))
         (symbols (kargu-lsp-get-file-symbols path))
         (flat (kargu-lsp--flatten-symbols symbols))
         (matches (kargu-lsp--find-symbol-in-list flat symbol-name kind)))
    (cond
     ((null matches)
      (let ((avail (if flat
                       (mapconcat
                        (lambda (s)
                          (format "  • %s %s [%s]"
                                  (plist-get s :kind)
                                  (plist-get s :name)
                                  (if (> (plist-get s :end-line) (plist-get s :start-line))
                                      (format "lines %d-%d" (plist-get s :start-line) (plist-get s :end-line))
                                    (format "line %d" (plist-get s :start-line)))))
                        (seq-take flat 30)
                        "\n")
                     "  (no symbols found in file)")))
        (format "ERROR: Symbol '%s'%s not found in %s.\nAvailable symbols:\n%s"
                symbol-name (if kind (format " (kind: %s)" kind) "") path avail)))
     (t
      (let* ((sym (car matches))
             (s-line (plist-get sym :start-line))
             (e-line (plist-get sym :end-line)))
        (require 'kargu/tools/diff nil t)
        (if (fboundp 'kargu-diff-read-file)
            (kargu-diff-read-file path s-line e-line)
          (format "(symbol %s lines %d-%d)" symbol-name s-line e-line)))))))

(defun kargu-lsp--format-missing-symbol-error (symbol-name path flat kind)
  "Format error message when SYMBOL-NAME is not found in PATH."
  (let ((avail (if flat
                   (mapconcat
                    (lambda (s)
                      (format "  • %s %s [%s]"
                              (plist-get s :kind)
                              (plist-get s :name)
                              (if (> (plist-get s :end-line) (plist-get s :start-line))
                                  (format "lines %d-%d" (plist-get s :start-line) (plist-get s :end-line))
                                (format "line %d" (plist-get s :start-line)))))
                    (seq-take flat 30)
                    "\n")
                 "  (no symbols found in file)")))
    (format "ERROR: Symbol '%s'%s not found in %s.\nAvailable symbols:\n%s"
            symbol-name (if kind (format " (kind: %s)" kind) "") path avail)))

(defun kargu-lsp--format-ambiguous-symbol-error (symbol-name matches)
  "Error string listing MATCHES for the ambiguous SYMBOL-NAME."
  (format "ERROR: Symbol '%s' is ambiguous (%d matches); nothing was edited. Repeat the call with `kind' or a qualified name (Container.name). Candidates:\n%s"
          symbol-name (length matches)
          (mapconcat
           (lambda (s)
             (format "  • %s %s (lines %d-%d)"
                     (plist-get s :kind) (plist-get s :name)
                     (plist-get s :start-line) (plist-get s :end-line)))
           matches "\n")))

(defun kargu-lsp--splice-symbol-content (raw-text s-line e-line new-content)
  "Replace lines S-LINE to E-LINE in RAW-TEXT with NEW-CONTENT."
  (let* ((file-lines (split-string raw-text "\n"))
         (total (length file-lines))
         (s-idx (1- s-line))
         (e-idx (1- e-line)))
    (when (or (< s-idx 0) (> s-idx total))
      (error "Symbol start line %d out of range (total lines %d)" s-line total))
    (let* ((before-lines (seq-take file-lines s-idx))
           (after-lines (nthcdr (min total (1+ e-idx)) file-lines))
           (clean-content (and new-content (string-trim-right new-content "[\r\n]+")))
           (new-lines (if (or (null clean-content) (string-empty-p clean-content))
                          nil
                        (split-string clean-content "\n")))
           (combined (append before-lines new-lines after-lines))
           (new-full-text (string-join combined "\n")))
      (when (and (string-suffix-p "\n" raw-text)
                 (not (string-suffix-p "\n" new-full-text)))
        (setq new-full-text (concat new-full-text "\n")))
      new-full-text)))

(defun kargu-lsp--apply-symbol-replacement (path sym new-full-text s-line e-line reason)
  "Apply NEW-FULL-TEXT to PATH replacing SYM (lines S-LINE to E-LINE)."
  (when (and (stringp reason) (not (string-empty-p reason)))
    (message "kargu edit_by_lsp proposal for %s (%s): %s" path (plist-get sym :name) reason)
    (kargu-log 'info "lsp: edit_by_lsp reason: %s" reason))
  (let ((prop (kargu-diff-apply-proposal path new-full-text)))
    (format "Edit of %s `%s` (lines %d-%d) in %s:\n%s"
            (plist-get sym :kind) (plist-get sym :name)
            s-line e-line path
            (kargu-diff--describe prop))))

(defun kargu-lsp-edit-symbol (file-path symbol-name new-content &optional kind reason)
  "Replace the body of SYMBOL-NAME in FILE-PATH with NEW-CONTENT.
NEW-CONTENT is staged through `kargu-diff-apply-proposal'."
  (or (and (fboundp 'kargu-diff--mutating-disabled)
           (or (kargu-diff--mutating-disabled "edit_by_lsp")
               (kargu-diff--mutating-disabled "edit_symbol")))
      (let* ((path (kargu-permission-resolve file-path "lsp path"))
             (symbols (kargu-lsp-get-file-symbols path))
             (flat (kargu-lsp--flatten-symbols symbols))
             (matches (kargu-lsp--find-symbol-in-list flat symbol-name kind)))
        (cond
         ((not (file-exists-p path))
          (format "ERROR: file does not exist: %s" path))
         ((null matches)
          (kargu-lsp--format-missing-symbol-error symbol-name path flat kind))
         ((cdr matches)
          (kargu-lsp--format-ambiguous-symbol-error symbol-name matches))
         (t
          (let* ((sym (car matches))
                 (s-line (plist-get sym :start-line))
                 (e-line (plist-get sym :end-line))
                 (raw-text (or (and (fboundp 'kargu-diff--file-text)
                                    (kargu-diff--file-text path))
                               (with-temp-buffer
                                 (insert-file-contents path)
                                 (buffer-string))))
                 (new-full-text (kargu-lsp--splice-symbol-content raw-text s-line e-line new-content)))
            (kargu-lsp--apply-symbol-replacement path sym new-full-text s-line e-line reason)))))))

;;;; Tool registration ----------------------------------------------------

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
   "Get compiler and linter diagnostics (errors, warnings) from LSP via Flymake. Pass 'file_path' to inspect a specific file, or OMIT 'file_path' (pass empty or no arguments) to scan the ENTIRE PROJECT for all compile and lint errors across all project files. Always call this after editing or building to verify zero compilation errors."
   '(("type" . "object")
     ("properties" . (("file_path" . (("type" . "string")
                                       ("description" . "Optional. Absolute or project-relative path of a specific file to check. When omitted or empty, runs a project-wide diagnostic scan across all project files."))))))
   (lambda (args)
     (let ((path (kargu--tool-file-path args)))
       (if (and path (not (string-empty-p (string-trim path))))
           (kargu-lsp-get-diagnostics path)
         (kargu-lsp-get-project-diagnostics)))))
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
         (kargu-lsp-find-definition name)))))
  (kargu-register-tool
   "read_file_symbols"
   "Get a language-agnostic outline of symbols (functions, classes, structs, methods, enums, types) and their exact line ranges in a file using LSP documentSymbol. ALWAYS use this BEFORE reading a large file to inspect its structure and avoid wasting tokens."
   '(("type" . "object")
     ("properties" . (("file_path" . (("type" . "string")
                                       ("description" . "Absolute or project-relative path of the file to inspect."))))))
   (lambda (args)
     (let ((path (kargu--tool-file-path args)))
       (if (not (kargu-nonempty path))
           (kargu--tool-missing-file-path args)
         (condition-case-unless-debug err
             (kargu-lsp-read-file-symbols path)
           (error (format "ERROR: %s" (error-message-string err))))))))
  (kargu-register-tool
   "read_symbol"
   "Read the exact implementation body of a specific symbol (function, method, class, struct, type) by name from a file. Uses LSP/imenu line ranges to fetch only the relevant code without loading the full file."
   '(("type" . "object")
     ("properties" . (("file_path" . (("type" . "string")
                                       ("description" . "Absolute or project-relative path of the file.")))
                      ("symbol" . (("type" . "string")
                                    ("description" . "Name of the symbol (function, method, class, struct, type) to read.")))
                      ("kind" . (("type" . "string")
                                 ("description" . "Optional symbol kind filter (e.g. Function, Method, Class, Struct, Type).")))))
     ("required" . ["file_path" "symbol"]))
   (lambda (args)
     (let ((path (kargu--tool-file-path args))
           (sym (kargu--tool-arg args "symbol" "symbol_name" "symbolName" "name"))
           (kind (kargu--tool-arg args "kind" "symbol_kind" "symbolKind")))
       (cond
        ((not (kargu-nonempty path))
         (kargu--tool-missing-file-path args))
        ((or (null sym) (string-empty-p (string-trim sym)))
         "ERROR: symbol is required")
        (t
         (condition-case-unless-debug err
             (kargu-lsp-read-symbol path sym kind)
           (error (format "ERROR: %s" (error-message-string err)))))))))
  (kargu-register-tool
   "edit_by_lsp"
   "Replace the entire implementation body or definition of a specific symbol (function, method, class, struct, type) in a source file with new content. Uses exact language-agnostic LSP/imenu symbol line boundaries. ALWAYS PREFER THIS over edit_file for modifying existing code definitions across all programming languages."
   '(("type" . "object")
     ("properties" . (("file_path" . (("type" . "string")
                                       ("description" . "Absolute or project-relative path of the file to edit.")))
                      ("symbol" . (("type" . "string")
                                    ("description" . "Name of the symbol (function, method, class, struct, type) to replace.")))
                      ("new_content" . (("type" . "string")
                                         ("description" . "New code to replace the entire symbol body/definition with (use empty string to delete).")))
                      ("kind" . (("type" . "string")
                                 ("description" . "Optional symbol kind filter (e.g. Function, Method, Class, Struct, Type).")))
                      ("reason" . (("type" . "string")
                                    ("description" . "Optional explanation for the change.")))))
     ("required" . ["file_path" "symbol" "new_content"]))
   (lambda (args)
     (let ((path (kargu--tool-file-path args))
           (sym (kargu--tool-arg args "symbol" "symbol_name" "symbolName" "name"))
           (new (kargu--tool-arg-string args "new_content" "newContent" "content" "new_string" "newString" "code"))
           (kind (kargu--tool-arg args "kind" "symbol_kind" "symbolKind"))
           (reason (kargu--tool-arg args "reason")))
       (cond
        ((not (kargu-nonempty path))
         (kargu--tool-missing-file-path args))
        ((or (null sym) (string-empty-p (string-trim sym)))
         "ERROR: symbol is required")
        ((null new)
         "ERROR: new_content is required")
        (t
         (condition-case-unless-debug err
             (kargu-lsp-edit-symbol path sym new kind reason)
           (error (format "ERROR: %s" (error-message-string err)))))))))
  (kargu-register-tool-alias "edit_symbol" "edit_by_lsp")
  (kargu-register-tool-alias "edit_with_lsp" "edit_by_lsp")
  (kargu-register-tool-alias "edit_by_symbol" "edit_by_lsp")
  (kargu-register-tool-alias "read_file_outline" "read_file_symbols")
  (kargu-register-tool-alias "file_symbols" "read_file_symbols")
  (kargu-register-tool-alias "outline" "read_file_symbols")
  (kargu-register-tool-alias "file_outline" "read_file_symbols")
  (kargu-register-tool-alias "get_symbol" "read_symbol")
  (kargu-register-tool-alias "symbol_body" "read_symbol")
  (kargu-register-tool-alias "read_symbol_body" "read_symbol"))

(kargu-lsp-register-tools)

(provide 'kargu/tools/lsp)

;;; kargu/tools/lsp.el ends here
