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

(defvar kargu-lsp--workspace-cache (make-hash-table :test #'equal)
  "Workspace symbol snapshots keyed by project, server and query.")

(defun kargu-lsp--workspace-key (query)
  "Return the identity and document-version key for workspace QUERY."
  (let ((buffer (kargu-lsp--managed-buffer)))
    (list (kargu-lsp-project-root) query
          (and buffer (with-current-buffer buffer (eglot-current-server)))
          (mapcar (lambda (buf)
                    (list (buffer-file-name buf)
                          (with-current-buffer buf (buffer-chars-modified-tick))))
                  (kargu-lsp--project-buffers)))))

(defun kargu-lsp--project-buffers ()
  "Return managed buffers belonging to the selected project."
  (let ((root (kargu-lsp--workspace-root)))
    (seq-filter (lambda (buf)
                  (with-current-buffer buf
                    (equal root (when-let* ((dir (kargu-permission-eglot-server-root
                                                 (eglot-current-server))))
                                  (file-name-as-directory (file-truename dir))))))
                (kargu-lsp--managed-buffers))))

(defun kargu-lsp--ws-symbols (query &optional callback)
  "Get workspace QUERY symbols asynchronously through CALLBACK.
Without CALLBACK return only an already collected snapshot."
  (let* ((key (kargu-lsp--workspace-key query))
         (cached (gethash key kargu-lsp--workspace-cache)))
    (if (null callback) cached
      (let ((buffer (kargu-lsp--managed-buffer)))
        (if (not buffer) (funcall callback nil "No project LSP connection")
          (kargu-lsp--request
           :workspace/symbol `(:query ,query)
           (lambda (raw error)
             (let ((items (unless error
                            (delq nil (mapcar #'kargu-lsp--symbol-information-item
                                               (kargu-lsp--seq->list raw))))))
               (unless error
                 (clrhash kargu-lsp--workspace-cache)
                 (puthash key items kargu-lsp--workspace-cache))
               (funcall callback items error)))
           buffer))))))

(declare-function kargu-lsp-get-file-symbols "kargu/tools/lsp/symbols"
                  (file-path &optional callback))

(defun kargu-lsp--doc-symbols (callback)
  "Collect open project document symbols asynchronously for CALLBACK."
  (kargu-lsp--doc-symbols-next
   (seq-take (kargu-lsp--project-buffers) 40) nil callback))

(defun kargu-lsp--doc-symbols-next (buffers items callback)
  "Collect symbols from BUFFERS onto ITEMS and deliver them to CALLBACK."
  (if (null buffers) (funcall callback items nil)
    (let ((path (buffer-file-name (car buffers))))
      (kargu-lsp-get-file-symbols
       path (lambda (symbols error)
              (if error (funcall callback nil error)
                (kargu-lsp--doc-symbols-next
                 (cdr buffers)
                 (append items (mapcar (lambda (sym)
                                        (list path (plist-get sym :start-line)
                                              (plist-get sym :name)
                                              (plist-get sym :kind)))
                                      (kargu-lsp--flatten-symbols symbols)))
                 callback)))))))

(defun kargu-lsp--gather-symbols (callback)
  "Collect project symbols and deliver (ITEMS ERROR) to CALLBACK."
  (kargu-lsp--ws-symbols
   "" (lambda (items _error)
        (if items (funcall callback items nil)
          (kargu-lsp--doc-symbols callback)))))

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

(defun kargu-lsp--merge-symbols (items roots)
  "Combine LSP ITEMS and local imenu snapshots under ROOTS."
  (let ((seen (make-hash-table :test #'equal)) result)
    (dolist (item (append items (kargu-lsp--imenu-symbols roots)))
      (let ((path (car item)) (name (nth 2 item)))
        (when (and (or (null roots)
                       (seq-some (lambda (root) (file-in-directory-p path root)) roots))
                   (not (gethash (cons path name) seen)))
          (puthash (cons path name) t seen)
          (push (list path (nth 1 item) name
                      (kargu-lsp--kind-label (nth 3 item))) result))))
    (nreverse result)))

(defun kargu-lsp-all-symbols (&optional query roots callback)
  "Return cached/local symbols matching QUERY under ROOTS.
With CALLBACK, collect LSP data asynchronously before delivering the list."
  (if (and callback (kargu-eglot-connected-p))
      (kargu-lsp--ws-symbols
       (or query "") (lambda (items _error)
                      (funcall callback (kargu-lsp--merge-symbols items roots))))
    (let ((items (kargu-lsp--merge-symbols (kargu-lsp--ws-symbols (or query "")) roots)))
      (if callback (funcall callback items) items))))

;;;; Skeleton rendering & caching -----------------------------------------

(defvar kargu-lsp--skeleton-cache nil
  "Cached skeleton: plist with :text, :time, :root, :source.")

(defun kargu-lsp--cached-skeleton ()
  "Return the cached skeleton text when still fresh, else nil."
  (when (and kargu-lsp--skeleton-cache
             (stringp (plist-get kargu-lsp--skeleton-cache :text))
             (equal (plist-get kargu-lsp--skeleton-cache :root)
                    (kargu-lsp-project-root))
             (or (not (plist-member kargu-lsp--skeleton-cache :key))
                 (equal (plist-get kargu-lsp--skeleton-cache :key)
                        (kargu-lsp--workspace-key ""))))
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
                    (kargu-lsp--kind-label (nth 3 symbol)) (nth 1 symbol)) lines))
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

(defun kargu-lsp--compute-skeleton (callback)
  "Collect the skeleton asynchronously and deliver text to CALLBACK."
  (let* ((root (kargu-lsp-project-root))
         (key (kargu-lsp--workspace-key ""))
         (task (kargu-async-start
                (lambda (value error)
                  (funcall callback (if error (concat "ERROR: " error) value)))
                :timeout kargu-lsp-request-timeout)))
    (funcall
     (kargu-async-wrap
      task (lambda ()
             (kargu-lsp--gather-symbols
              (kargu-async-wrap
               task
               (lambda (items error)
                 (cond
                  (error (kargu-async-finish task nil error))
                  ((not (equal key (kargu-lsp--workspace-key "")))
                   (kargu-async-finish task nil "Workspace changed; retry the outline"))
                  (t
                   (let ((text (kargu-lsp--render-skeleton root "workspace/document" items)))
                     (setq kargu-lsp--skeleton-cache
                           (list :text text :time (current-time) :root root :key key))
                     (kargu-async-finish task text))))))))))))

(defun kargu-lsp--show-skeleton (text)
  "Display the skeleton TEXT in a dedicated buffer."
  (with-current-buffer (get-buffer-create "*kargu-skeleton*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert text)
      (goto-char (point-min)))
    (special-mode))
  (pop-to-buffer (get-buffer "*kargu-skeleton*")))

(defun kargu-lsp-build-skeleton (&optional refresh callback)
  "Return the cached project outline, or collect it for CALLBACK.
REFRESH invalidates the snapshot.  Interactive use collects and displays it."
  (interactive "P")
  (when refresh (setq kargu-lsp--skeleton-cache nil))
  (let ((done (or callback (and (called-interactively-p 'any)
                                #'kargu-lsp--show-skeleton)))
        (cached (kargu-lsp--cached-skeleton)))
    (cond
     ((null done) cached)
     (cached (funcall done cached))
     (t (kargu-lsp--compute-skeleton done)))))

(provide 'kargu/tools/lsp/skeleton)

;;; skeleton.el ends here
