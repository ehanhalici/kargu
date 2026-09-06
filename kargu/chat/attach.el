;;; kargu/chat/attach.el --- Synthetic Read for @ file mentions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; `@path' mentions become one `insert-file-contents' and a Read-tool
;; transcript (or a compact reference for long files).
;; Requires: `kargu/core', `kargu/tools/diff', `kargu/tools/lsp'.
;; Public internal: `kargu-chat--expand-prompt'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
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
(require 'kargu/tools/diff)
(require 'kargu/tools/lsp)

(defvar kargu-chat-attach-max-lines 150)
(declare-function kargu-chat--completion-roots "kargu/chat/complete")


(defun kargu-chat--symbol-mention-p (token)
  "Return non-nil if TOKEN looks like a symbol mention ('file::symbol')."
  (string-match-p "::" token))

(defun kargu-chat--file-mention-p (token)
  "Return non-nil if TOKEN looks like a file path, not a symbol or bare name."
  (and (not (kargu-chat--symbol-mention-p token))
       (or (string-match-p "/" token)
           (string-match-p "\\.[A-Za-z0-9]+\\'" token))))

(defun kargu-chat--clean-at-token (raw)
  "Strip enclosing brackets, quotes, and trailing punctuation from RAW mention."
  (let ((s (string-trim (or raw "")))
        (changed t))
    (while (string-prefix-p "@" s)
      (setq s (substring s 1)))
    (while changed
      (setq changed nil)
      (let ((len (length s)))
        ;; 1. Pair stripping
        (while (or (and (> (length s) 1) (string-prefix-p "[" s) (string-suffix-p "]" s))
                   (and (> (length s) 1) (string-prefix-p "(" s) (string-suffix-p ")" s))
                   (and (> (length s) 1) (string-prefix-p "<" s) (string-suffix-p ">" s))
                   (and (> (length s) 1) (string-prefix-p "{" s) (string-suffix-p "}" s))
                   (and (> (length s) 1) (string-prefix-p "\"" s) (string-suffix-p "\"" s))
                   (and (> (length s) 1) (string-prefix-p "'" s) (string-suffix-p "'" s))
                   (and (> (length s) 1) (string-prefix-p "`" s) (string-suffix-p "`" s)))
          (setq s (substring s 1 -1)))
        ;; 2. Trailing punctuation stripping
        (while (and (> (length s) 0)
                    (memq (aref s (1- (length s)))
                          '(?, ?: ?\; ?\) ?\] ?\} ?> ?. ?\" ?\' ?\`)))
          (setq s (substring s 0 (1- (length s)))))
        ;; 3. Leading unmatched quotes or brackets stripping
        (while (and (> (length s) 0)
                    (memq (aref s 0)
                          '(?\" ?\' ?\` ?\[ ?\( ?\< ?\{)))
          (setq s (substring s 1)))
        (unless (= len (length s))
          (setq changed t))))
    (string-trim s)))

(defun kargu-chat--at-tokens (prompt)
  "Return @mention bodies in PROMPT, without the leading `@'."
  (let (acc)
    (with-temp-buffer
      (insert (or prompt ""))
      (goto-char (point-min))
      (while (re-search-forward "@\\([^[:space:]]+\\)" nil t)
        (let ((cleaned (kargu-chat--clean-at-token (match-string-no-properties 1))))
          (when (not (string-empty-p cleaned))
            (push cleaned acc)))))
    (nreverse acc)))

(defun kargu-chat--resolve-mention-file (mention)
  "Resolve file MENTION (no leading `@') to an absolute path, or nil."
  (let ((roots (kargu-chat--completion-roots))
        found)
    (cl-labels
        ((try (rel root)
           (let ((abs (expand-file-name rel root)))
             (when (file-regular-p abs)
               abs))))
      (dolist (root roots)
        (unless found
          (setq found (try mention root))))
      (when (and (not found)
                 (string-match "\\`[^/]+/\\(.+\\)\\'" mention))
        (let ((rest (match-string 1 mention)))
          (dolist (root roots)
            (unless found
              (setq found (try rest root))))))
      (when (not found)
        (let ((abs (ignore-errors (kargu--resolve-path mention))))
          (when (and abs (file-regular-p abs))
            (setq found abs))))
      found)))

(defun kargu-chat--fence-lang (path)
  "Markdown fence language tag for PATH's extension."
  (pcase (downcase (or (file-name-extension path) ""))
    ("el" "elisp")
    ("rs" "rust")
    ("py" "python")
    ("js" "javascript")
    ("ts" "typescript")
    ("tsx" "tsx")
    ("jsx" "jsx")
    ("md" "markdown")
    ("toml" "toml")
    ("json" "json")
    ((or "c" "h") "c")
    ((or "cc" "cpp" "hh" "hpp") "cpp")
    ("go" "go")
    ("rb" "ruby")
    ((or "sh" "bash") "bash")
    (ext ext)))

(defun kargu-chat--called-read (abs)
  "Synthetic Read-tool header for file ABS."
  (format "Called the Read tool with %s"
          (json-encode `(("file_path" . ,abs)))))

(defun kargu-chat--reference-block (abs)
  "Compact `@' attachment that points at ABS without inlining it."
  (format
   "%s\n<referenced_file path=\"%s\">\n  (File is long. Use the `read_file' tool to inspect specific lines as needed.)\n</referenced_file>\n"
   (kargu-chat--called-read abs)
   abs))

(defun kargu-chat--dump-buffer-numbered ()
  "Numbered dump of the current buffer; `forward-line' always progresses."
  (let ((n 0)
        lines)
    (goto-char (point-min))
    (while (not (eobp))
      (setq n (1+ n))
      (push (format "%d | %s" n
                    (buffer-substring (line-beginning-position)
                                      (line-end-position)))
            lines)
      (let ((pos (point)))
        (when (or (/= (forward-line 1) 0)
                  (<= (point) pos))
          (goto-char (point-max)))))
    (string-join (nreverse lines) "\n")))

(defun kargu-chat--dump-lines (abs from to)
  "Return lines FROM to TO of file ABS formatted with line numbers."
  (with-temp-buffer
    (insert-file-contents abs)
    (let ((n 0)
          lines)
      (goto-char (point-min))
      (while (not (eobp))
        (setq n (1+ n))
        (when (and (>= n from) (<= n to))
          (push (format "%d | %s" n
                        (buffer-substring (line-beginning-position)
                                          (line-end-position)))
                lines))
        (let ((pos (point)))
          (when (or (/= (forward-line 1) 0)
                    (<= (point) pos))
            (goto-char (point-max)))))
      (string-join (nreverse lines) "\n"))))

(defun kargu-chat--extract-symbol-range (abs sym-name)
  "Return (START-LINE . END-LINE) for SYM-NAME in file ABS."
  (with-temp-buffer
    (insert-file-contents abs)
    (let ((buffer-file-name abs))
      (condition-case nil
          (delay-mode-hooks
            (set-auto-mode t))
        (error nil)))
    (goto-char (point-min))
    (let (found-pos)
      (let ((case-fold-search nil))
        (when (or (re-search-forward
                   (format "\\(?:defun\\|defmacro\\|defvar\\|defcustom\\|defconst\\|defclass\\|cl-defun\\|cl-defmethod\\)[ \t\n]+\\(?:'\\)?%s\\b"
                           (regexp-quote sym-name))
                   nil t)
                  (re-search-forward
                   (format "\\(?:func\\|function\\|fn\\|def\\|class\\|struct\\|interface\\|type\\|var\\|const\\|let\\|val\\)[ \t\n]+\\(?:[A-Za-z0-9_.*&]+[ \t\n]+\\)?%s\\b"
                           (regexp-quote sym-name))
                   nil t)
                  (re-search-forward
                   (format "\\b%s\\b[ \t]*[:=(]" (regexp-quote sym-name))
                   nil t)
                  (re-search-forward
                   (format "\\b%s\\b" (regexp-quote sym-name))
                   nil t))
          (setq found-pos (match-beginning 0))))
      (when found-pos
        (goto-char found-pos)
        (beginning-of-line)
        (let ((def-line (line-number-at-pos (point)))
              (start-line (line-number-at-pos (point)))
              end-line)
          (cond
           ;; Lisp-like: try forward-sexp
           ((derived-mode-p 'emacs-lisp-mode 'lisp-mode 'scheme-mode 'clojure-mode)
            (condition-case nil
                (save-excursion
                  (goto-char found-pos)
                  (beginning-of-defun)
                  (setq start-line (line-number-at-pos))
                  (forward-sexp 1)
                  (setq end-line (line-number-at-pos)))
              (error nil)))
           ;; Brace languages (C, C++, Go, Rust, Java, JS, TS, etc.)
           ((save-excursion
              (goto-char found-pos)
              (search-forward "{" (line-end-position 3) t))
            (condition-case nil
                (save-excursion
                  (goto-char found-pos)
                  (search-forward "{" nil t)
                  (backward-char 1)
                  (forward-list 1)
                  (setq end-line (line-number-at-pos)))
              (error nil)))
           ;; Python / indentation-based
           ((derived-mode-p 'python-mode 'python-ts-mode)
            (save-excursion
              (goto-char found-pos)
              (forward-line 1)
              (let ((last-line def-line))
                (while (and (not (eobp))
                            (or (looking-at "^[ \t]*$")
                                (> (current-indentation) 0)))
                  (unless (looking-at "^[ \t]*$")
                    (setq last-line (line-number-at-pos)))
                  (forward-line 1))
                (setq end-line last-line)))))
          (unless (and end-line (>= end-line start-line))
            (setq end-line (min (count-lines (point-min) (point-max))
                                (+ start-line 35))))
          (cons start-line end-line))))))

(defun kargu-chat--attach-symbol-block (mention)
  "Attachment for symbol MENTION ('file::symbol') with line-numbered snippet."
  (let* ((parts (split-string mention "::"))
         (file-part (car parts))
         (sym-part (cadr parts))
         (abs (kargu-chat--resolve-mention-file file-part)))
    (cond
     ((null abs)
      (format "<attached_symbol path=\"%s\" symbol=\"%s\">\n(file not found)\n</attached_symbol>\n"
              file-part sym-part))
     ((not (file-readable-p abs))
      (format "<attached_symbol path=\"%s\" symbol=\"%s\">\n(file not readable)\n</attached_symbol>\n"
              abs sym-part))
     (t
      (let ((range (kargu-chat--extract-symbol-range abs sym-part)))
        (if (null range)
            (format "<attached_symbol path=\"%s\" symbol=\"%s\">\n(symbol %s not found in file)\n</attached_symbol>\n"
                    abs sym-part sym-part)
          (let* ((from (car range))
                 (to (cdr range))
                 (dump (kargu-chat--dump-lines abs from to)))
            (format "%s\n(file %s, symbol %s, lines %d-%d)\n%s\n"
                    (kargu-chat--called-read abs)
                    abs sym-part from to dump))))))))

(defun kargu-chat--numbered-attach (abs)
  "Numbered file dump for ABS, matching `read_file' output."
  (with-temp-buffer
    (insert-file-contents abs)
    (format "(file %s)\n%s" abs (kargu-chat--dump-buffer-numbered))))

(defun kargu-chat--attach-block (mention cap)
  "Attachment for MENTION as a synthetic `read_file' transcript.
The file is read at most once.  Files longer than
`kargu-chat-attach-max-lines' (or larger than CAP) are
referenced rather than inlined."
  (let ((abs (kargu-chat--resolve-mention-file mention)))
    (cond
     ((null abs)
      (format "<code_selection path=\"%s\">\n(not found)\n</code_selection>\n"
              mention))
     ((not (file-readable-p abs))
      (format "<code_selection path=\"%s\">\n(not readable)\n</code_selection>\n"
              mention))
     (t
      (let* ((attrs (file-attributes abs))
             (size (and attrs (file-attribute-size attrs)))
             (max-lines (or kargu-chat-attach-max-lines 150)))
        (if (and size cap (> size cap))
            (kargu-chat--reference-block abs)
          (with-temp-buffer
            (insert-file-contents abs)
            (let ((nlines (count-lines (point-min) (point-max))))
              (if (> nlines max-lines)
                  (kargu-chat--reference-block abs)
                (format "%s\n(file %s, lines 1-%d of %d)\n%s\n"
                        (kargu-chat--called-read abs)
                        abs nlines nlines
                        (kargu-chat--dump-buffer-numbered)))))))))))

(defun kargu-chat--expand-prompt (prompt)
  "Wrap PROMPT as `<user_query>' plus `@path' attachments for the model.
`@file::symbol' mentions attach the symbol definition with line numbers.
Short file mentions become a synthetic Read transcript.  Longer files
stay a compact reference.  The chat buffer still shows the unwrapped prompt."
  (let* ((all-tokens (delete-dups (kargu-chat--at-tokens prompt)))
         (sym-mentions (cl-remove-if-not #'kargu-chat--symbol-mention-p all-tokens))
         (file-mentions (cl-remove-if-not #'kargu-chat--file-mention-p all-tokens))
         (cap kargu-diff-read-max-chars)
         (query (format "<user_query>\n%s\n</user_query>" prompt)))
    (if (and (null sym-mentions) (null file-mentions))
        query
      (concat query "\n\n<attached_files>\n"
              (mapconcat #'kargu-chat--attach-symbol-block
                         sym-mentions "")
              (mapconcat (lambda (m) (kargu-chat--attach-block m cap))
                         file-mentions "")
              "</attached_files>\n"))))


(provide 'kargu/chat/attach)

;;; kargu/chat/attach.el ends here
