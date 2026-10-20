;;; symbols.el --- Symbol lookup, reading and editing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Resolve definitions and read or replace individual source symbols.

;;; Code:

(require 'kargu/tools/lsp/context)
(require 'kargu/tools/lsp/skeleton)
(require 'xref)
(require 'elisp-mode)

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

(defun kargu-lsp--format-definitions (symbol-name items)
  "Describe ITEMS matching SYMBOL-NAME, or return nil when none exist."
  (let* ((exact (seq-filter (lambda (item) (equal (nth 2 item) symbol-name)) items))
         (hits (seq-take (or exact items) kargu-lsp-definition-max-hits)))
    (when hits
      (concat (format "Definition candidates for `%s':\n" symbol-name)
              (mapconcat (lambda (item)
                           (format "  %s:%d  (%s)" (car item) (nth 1 item)
                                   (kargu-lsp--kind-label (nth 3 item))))
                         hits "\n")
              (unless exact "\n(no exact name match; fuzzy candidates listed)")))))

(defun kargu-lsp--symbol-occurrence (name)
  "Find a local occurrence of NAME in this project's managed buffers."
  (save-match-data
    (cl-loop for buf in (kargu-lsp--project-buffers)
             for position =
             (with-current-buffer buf
               (save-excursion
                 (save-restriction
                   (widen)
                   (goto-char (point-min))
                   (when (re-search-forward (concat "\\_<" (regexp-quote name) "\\_>") nil t)
                     (list :line (1- (line-number-at-pos (match-beginning 0)))
                           :character (- (match-beginning 0) (line-beginning-position)))))))
             when position return (cons buf position))))

(defun kargu-lsp--definitions-via-occurrence (name callback)
  "Request the definition of an occurrence of NAME for CALLBACK."
  (let ((occurrence (kargu-lsp--symbol-occurrence name)))
    (if (null occurrence)
        (funcall callback (format "No definition found for `%s'" name))
      (let ((buf (car occurrence)))
        (kargu-lsp--request
         :textDocument/definition
         `(:textDocument (:uri ,(kargu-lsp--buffer-uri buf)) :position ,(cdr occurrence))
         (lambda (raw error)
           (funcall
            callback
            (if error (concat "ERROR: " error)
              (let ((locations (if (kargu-lsp--loc-uri raw) (list raw)
                                 (kargu-seq-to-list raw))))
                (concat
                 (format "Definition(s) of `%s':\n" name)
                 (mapconcat (lambda (loc)
                              (format "  %s:%d" (kargu-lsp--uri-to-path (kargu-lsp--loc-uri loc))
                                      (kargu-lsp--loc-line loc)))
                            (seq-take locations kargu-lsp-definition-max-hits) "\n"))))))
         buf)))))

(defun kargu-lsp--elisp-definition-items (name)
  "Resolve NAME through native xref without loading or leaving the project."
  (save-match-data
    (save-excursion
      (let ((root (kargu-permission-project-root))
            (enable-local-variables :safe) (enable-local-eval nil)
            (enable-dir-local-variables nil) items)
        (dolist (xref (xref-backend-definitions 'elisp name))
          (let* ((location (xref-item-location xref))
                 (file (xref-location-group location)))
            (when (and (stringp file) (file-name-absolute-p file)
                       (file-in-directory-p file root))
              (let ((marker (xref-location-marker location)))
                (unwind-protect
                    (with-current-buffer (marker-buffer marker)
                      (push (list file (line-number-at-pos marker) name "Symbol") items))
                  (set-marker marker nil))))))
        (nreverse items)))))

(defun kargu-lsp--elisp-definition (name)
  "Describe native xref or local imenu definitions of NAME."
  (or (kargu-lsp--format-definitions
       name (or (kargu-lsp--elisp-definition-items name)
                (seq-filter (lambda (item) (equal name (nth 2 item)))
                            (kargu-lsp--imenu-symbols
                             (list (kargu-permission-project-root))))))
      (format "No definition found for `%s' in this project" name)))

(defun kargu-lsp-find-definition (symbol-name &optional callback)
  "Describe definition sites of SYMBOL-NAME without blocking.
CALLBACK receives fresh results; interactive use reports them on completion."
  (interactive "sSymbol: ")
  (let ((done (or callback (and (called-interactively-p 'any)
                                (lambda (text) (message "%s" text))))))
    (cond
     ((kargu-lsp-native-elisp-p)
      (let ((text (kargu-lsp--elisp-definition symbol-name)))
        (if done (funcall done text) text)))
     ((null done)
      (kargu-lsp--format-definitions symbol-name (kargu-lsp--ws-symbols symbol-name)))
     (t (kargu-lsp--ws-symbols
       symbol-name
       (lambda (items _error)
         (let ((text (kargu-lsp--format-definitions symbol-name items)))
           (if text (funcall done text)
             (kargu-lsp--definitions-via-occurrence symbol-name done)))))))))

;;;; Document symbols, outline, reading and surgical editing --------------

(defun kargu-lsp--kind-label (kind-num)
  "Symbol kind name for a numeric or string KIND-NUM."
  (cond
   ((numberp kind-num) (kargu-lsp--kind-name kind-num))
   ((stringp kind-num) kind-num)
   (t "Symbol")))

(defun kargu-lsp--inclusive-end (start-line end-0 end-char)
  "Return the inclusive end line from START-LINE, END-0 and END-CHAR."
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
    (dolist (item (kargu-seq-to-list raw))
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

(defvar kargu-lsp--file-symbol-cache (make-hash-table :test #'eq :weakness 'key)
  "Document symbols keyed by buffer, server and modification tick.")

(defun kargu-lsp--symbol-buffer (file-path)
  "Resolve FILE-PATH safely and return its visiting buffer."
  (let ((path (kargu-permission-resolve file-path "lsp path")))
    (unless (file-regular-p path) (error "Not a regular file: %s" path))
    (or (find-buffer-visiting path)
        (let ((enable-local-variables :safe) (enable-local-eval nil)
              (enable-dir-local-variables nil))
          (find-file-noselect path)))))

(defun kargu-lsp--cached-file-symbols (buffer)
  "Return a valid cached symbol snapshot for BUFFER."
  (with-current-buffer buffer
    (let ((entry (gethash buffer kargu-lsp--file-symbol-cache)))
      (when (and entry
                 (eq (plist-get entry :server)
                     (and (fboundp 'eglot-current-server) (eglot-current-server)))
                 (equal (plist-get entry :tick) (buffer-chars-modified-tick)))
        (plist-get entry :symbols)))))

(defun kargu-lsp-get-file-symbols (file-path &optional callback)
  "Get document symbols for FILE-PATH without waiting for a server.
With CALLBACK, deliver (SYMBOLS ERROR) from an asynchronous request.
Without CALLBACK, return a cached or local imenu snapshot only."
  (let* ((buf (kargu-lsp--symbol-buffer file-path))
         (native (with-current-buffer buf (derived-mode-p 'emacs-lisp-mode)))
         (cached (unless native (kargu-lsp--cached-file-symbols buf))))
    (cond
     ((null callback) (or cached (kargu-lsp--imenu-document-symbols buf)))
     (cached (funcall callback cached nil))
     ((or native (not (kargu-lsp--buffer-managed-p buf)))
      (funcall callback (kargu-lsp--imenu-document-symbols buf) nil))
     (t
      (kargu-lsp--request
       :textDocument/documentSymbol
       `(:textDocument (:uri ,(kargu-lsp--buffer-uri buf)))
       (lambda (raw error)
         (if error
             (funcall callback nil error)
           (let ((symbols (or (kargu-lsp--parse-document-symbols raw)
                              (kargu-lsp--imenu-document-symbols buf))))
             (puthash buf (list :server (with-current-buffer buf (eglot-current-server))
                                :tick (with-current-buffer buf (buffer-chars-modified-tick))
                                :symbols symbols)
                      kargu-lsp--file-symbol-cache)
             (funcall callback symbols nil))))
       buf)))))

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

(defun kargu-lsp-read-file-symbols (file-path &optional callback)
  "Return an outline for FILE-PATH, or deliver it asynchronously to CALLBACK."
  (let ((path (kargu-permission-resolve file-path "lsp path")))
    (if callback
        (kargu-lsp-get-file-symbols
         path (lambda (symbols error)
                (funcall callback
                         (if error (concat "ERROR: " error)
                           (kargu-lsp-format-symbols-outline path symbols)))))
      (kargu-lsp-format-symbols-outline path (kargu-lsp-get-file-symbols path)))))

(defun kargu-lsp--flatten-symbols (symbols &optional container)
  "Flatten SYMBOLS while retaining their optional CONTAINER."
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

(cl-defun kargu-lsp--read-symbol (path symbols &key name kind)
  "Read NAME of KIND from the SYMBOLS snapshot in PATH."
  (let* ((flat (kargu-lsp--flatten-symbols symbols))
         (matches (kargu-lsp--find-symbol-in-list flat name kind)))
    (if (null matches)
        (kargu-lsp--format-missing-symbol-error name path flat kind)
      (let ((sym (car matches)))
        (kargu-diff-read-file path (plist-get sym :start-line)
                              (plist-get sym :end-line))))))

(defun kargu-lsp-read-symbol (file-path symbol-name &optional kind callback)
  "Read SYMBOL-NAME in FILE-PATH, optionally filtered by KIND.
With CALLBACK, fetch symbols asynchronously and deliver the text once."
  (let ((path (kargu-permission-resolve file-path "lsp path")))
    (if callback
        (kargu-lsp-get-file-symbols
         path (lambda (symbols error)
                (funcall callback
                         (if error (concat "ERROR: " error)
                           (kargu-lsp--read-symbol path symbols
                                                  :name symbol-name :kind kind)))))
      (kargu-lsp--read-symbol path (kargu-lsp-get-file-symbols path)
                             :name symbol-name :kind kind))))

(defun kargu-lsp--format-missing-symbol-error (symbol-name path flat kind)
  "Describe a missing SYMBOL-NAME in PATH using FLAT candidates and KIND."
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

(cl-defun kargu-lsp--replace-symbol (path symbols &key name content kind reason callback)
  "Replace NAME of KIND from SYMBOLS in PATH with CONTENT.
REASON describes the proposal.  CALLBACK receives its final review outcome."
  (let* ((flat (kargu-lsp--flatten-symbols symbols))
         (matches (kargu-lsp--find-symbol-in-list flat name kind))
         (error (cond
                 ((null matches) (kargu-lsp--format-missing-symbol-error name path flat kind))
                 ((cdr matches) (kargu-lsp--format-ambiguous-symbol-error name matches)))))
    (if error
        (if callback (funcall callback error) error)
      (let* ((symbol (car matches))
             (text (kargu-lsp--splice-symbol-content
                    (kargu-diff--file-text path) (plist-get symbol :start-line)
                    (plist-get symbol :end-line) content))
             (describe (lambda (outcome)
                         (format "Edit of %s `%s` in %s:\n%s"
                                 (plist-get symbol :kind) name path
                                 (kargu-diff--describe outcome)))))
        (when reason (kargu-log 'info "symbol edit: %s" reason))
        (if callback
            (kargu-diff-apply-proposal path text
                                      (lambda (outcome) (funcall callback (funcall describe outcome))))
          (funcall describe (kargu-diff-apply-proposal path text)))))))

(cl-defun kargu-lsp-edit-symbol (file-path symbol-name new-content &optional kind reason callback)
  "Replace SYMBOL-NAME in FILE-PATH with NEW-CONTENT.
KIND narrows matches; REASON describes the proposal.  CALLBACK waits
for asynchronous symbol collection and human review when required."
  (let ((blocked (kargu-diff--mutating-disabled "edit_by_lsp"))
        (path (kargu-permission-resolve file-path "lsp path")))
    (cond
     (blocked (if callback (funcall callback blocked) blocked))
     (callback
      (kargu-lsp-get-file-symbols
       path (lambda (symbols error)
              (if error (funcall callback (concat "ERROR: " error))
                (kargu-lsp--replace-symbol
                 path symbols :name symbol-name :content new-content
                 :kind kind :reason reason :callback callback)))))
     (t (kargu-lsp--replace-symbol
         path (kargu-lsp-get-file-symbols path) :name symbol-name
         :content new-content :kind kind :reason reason)))))

(provide 'kargu/tools/lsp/symbols)

;;; symbols.el ends here
