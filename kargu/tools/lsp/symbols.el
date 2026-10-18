;;; symbols.el --- Symbol lookup, reading and editing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Resolve definitions and read or replace individual source symbols.

;;; Code:

(require 'kargu/tools/lsp/context)
(require 'kargu/tools/lsp/skeleton)

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

(provide 'kargu/tools/lsp/symbols)

;;; symbols.el ends here
