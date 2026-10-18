;;; skeleton.el --- Project symbols and skeleton cache -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Collect project symbols and render a bounded workspace outline.

;;; Code:

(require 'kargu/tools/lsp/context)

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
             (stringp (plist-get kargu-lsp--skeleton-cache :text))
             (equal (plist-get kargu-lsp--skeleton-cache :root)
                    (kargu-lsp-project-root)))
    (let ((age (- (float-time)
                  (float-time (plist-get kargu-lsp--skeleton-cache :time)))))
      (when (< age kargu-lsp-skeleton-ttl)
        (plist-get kargu-lsp--skeleton-cache :text)))))

(defun kargu-lsp--group-project-symbols (root items)
  "Group symbol ITEMS by file inside project ROOT."
  (let ((by-file (make-hash-table :test #'equal))
        (root-dir (file-name-as-directory (expand-file-name root))))
    (dolist (item items)
      (when (and (stringp (car item))
                 (file-in-directory-p (expand-file-name (car item)) root-dir))
        (push item (gethash (car item) by-file))))
    by-file))

(defun kargu-lsp--skeleton-file-lines (root path symbols limit)
  "Render SYMBOLS in PATH relative to ROOT, showing at most LIMIT items."
  (let* ((ordered (sort (copy-sequence symbols)
                        (lambda (a b) (< (nth 1 a) (nth 1 b)))))
         (shown (seq-take ordered limit))
         (hidden (- (length ordered) (length shown)))
         (lines (list (concat (file-relative-name path root) ":"))))
    (dolist (symbol shown)
      (push (format "  %s (%s) :%d" (nth 2 symbol)
                    (kargu-lsp--kind-name (nth 3 symbol)) (nth 1 symbol)) lines))
    (when (> hidden 0)
      (push (format "  ... (%d more hidden)" hidden) lines))
    (cons (length shown) lines)))

(defun kargu-lsp--render-skeleton (root source items)
  "Render symbol ITEMS for ROOT with the origin label SOURCE."
  (let* ((by-file (kargu-lsp--group-project-symbols root items))
         (paths (sort (hash-table-keys by-file) #'string<))
         (total (cl-loop for symbols being the hash-values of by-file
                         sum (length symbols)))
         (shown 0)
         (lines (list (format "# %d files, %d symbols" (length paths) total)
                      (format "# root: %s" root)
                      (format "# Project skeleton (LSP: %s)" source))))
    (dolist (path paths)
      (when (< shown kargu-lsp-skeleton-max-symbols)
        (let* ((limit (min kargu-lsp-skeleton-max-per-file
                           (- kargu-lsp-skeleton-max-symbols shown)))
               (section (kargu-lsp--skeleton-file-lines
                         root path (gethash path by-file) limit)))
          (cl-incf shown (car section))
          (setq lines (nconc (cdr section) lines))
          (when (>= shown kargu-lsp-skeleton-max-symbols)
            (push (format "# symbol cap reached (%d); raise `kargu-lsp-skeleton-max-symbols' for more"
                          kargu-lsp-skeleton-max-symbols) lines)))))
    (string-join (nreverse lines) "\n")))

(defun kargu-lsp--compute-skeleton ()
  "Build the skeleton text; return text or an \"ERROR: ...\" string."
  (condition-case-unless-debug err
      (let* ((data (kargu-lsp--gather-symbols))
             (source (car data))
             (items (cdr data))
             (root (kargu-lsp-project-root)))
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
                  :root (kargu-lsp-project-root))))
    (when (called-interactively-p 'any)
      (if (and text (string-prefix-p "ERROR:" text))
          (message "%s" text)
        (kargu-lsp--show-skeleton text)))
    text))

(provide 'kargu/tools/lsp/skeleton)

;;; skeleton.el ends here
