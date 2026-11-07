;;; attach.el --- Synthetic Read for @ file mentions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Rust's lexer finds `@' mentions.  File and line mentions are read and
;; rendered by Rust through the shared native read port (live buffers from
;; RAM); symbol mentions still use the Elisp extractor (todo 4.4).
;; Requires: `kargu/core', `kargu/tools/diff'.
;; Public internal: `kargu-chat--expand-prompt' (async).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rx)
(require 'json)
(require 'kargu/core)
(require 'kargu/permission)
(require 'kargu/files)
(require 'kargu/files/async)
(require 'kargu/bridge/mentions)

(defvar kargu-chat-attach-max-lines 150)
(declare-function kargu-chat--completion-roots "kargu/chat/complete")


(cl-defun kargu-chat--resolve-mention-file
    (mention &key (roots (kargu-chat--completion-roots)))
  "Resolve file MENTION (no leading `@') under ROOTS to a path, or nil."
  (let (found)
    (cl-labels
        ((try (rel root)
           (let ((abs (expand-file-name rel root)))
             (when (and (file-regular-p abs)
                        (kargu-permission-within-project-p abs root))
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
        (let ((abs (ignore-errors (kargu-permission-resolve mention "mention"))))
          (when (and abs (file-regular-p abs))
            (setq found abs))))
      found)))

(defun kargu-chat--called-read (abs)
  "Synthetic Read-tool header for file ABS."
  (format "Called the Read tool with %s"
          (json-encode `(("file_path" . ,abs)))))

(defun kargu-chat--dump-buffer-lines (&optional from to)
  "Return lines of current buffer from 1-based FROM to TO with line numbers.
If FROM or TO is nil, processes entire buffer."
  (let ((n 0)
        lines)
    (goto-char (point-min))
    (while (not (eobp))
      (setq n (1+ n))
      (when (or (and (null from) (null to))
                (and (or (null from) (>= n from))
                     (or (null to) (<= n to))))
        (push (format "%d | %s" n
                      (buffer-substring (line-beginning-position)
                                        (line-end-position)))
              lines))
      (let ((pos (point)))
        (when (or (/= (forward-line 1) 0)
                  (<= (point) pos))
          (goto-char (point-max)))))
    (string-join (nreverse lines) "\n")))

(defun kargu-chat--dump-lines (abs from to)
  "Return lines FROM to TO of file ABS formatted with line numbers."
  (with-temp-buffer
    (insert-file-contents abs)
    (kargu-chat--dump-buffer-lines from to)))

(defconst kargu-chat--symbol-search-patterns
  (list
   (rx (or "defun" "defmacro" "defvar" "defcustom" "defconst"
           "defclass" "cl-defun" "cl-defmethod")
       (+ (any " \t\n")) (opt "'") "%s" word-boundary)
   (rx (or "func" "function" "fn" "def" "class" "struct" "interface"
           "type" "var" "const" "let" "val")
       (+ (any " \t\n")) (opt (+ (any alnum "_.*&")) (+ (any " \t\n")))
       "%s" word-boundary)
   (rx word-boundary "%s" word-boundary (* (any " \t")) (any ":=("))
   (rx word-boundary "%s" word-boundary))
  "Definition-first search templates for a quoted symbol name.")

(defun kargu-chat--find-symbol-pos (sym-name)
  "Locate SYM-NAME without changing point or the caller's match data."
  (save-match-data
    (save-excursion
      (let ((case-fold-search nil)
            (quoted (regexp-quote sym-name)))
        (cl-loop for pattern in kargu-chat--symbol-search-patterns
                 do (goto-char (point-min))
                 thereis (and (re-search-forward (format pattern quoted) nil t)
                              (match-beginning 0)))))))

(defconst kargu-chat--symbol-fallback-lines 35
  "Maximum extra lines attached when structural symbol bounds are unavailable.")

(defun kargu-chat--python-symbol-end (found-pos)
  "Return the last nonblank body line of the Python symbol at FOUND-POS."
  (save-excursion
    (goto-char found-pos)
    (beginning-of-line)
    (let ((indent (current-indentation))
          (last-line (line-number-at-pos)))
      (forward-line 1)
      (while (and (not (eobp))
                  (or (save-excursion (skip-chars-forward " \t") (eolp))
                      (> (current-indentation) indent)))
        (unless (save-excursion (skip-chars-forward " \t") (eolp))
          (setq last-line (line-number-at-pos)))
        (forward-line 1))
      last-line)))

(defun kargu-chat--compute-symbol-bounds (found-pos)
  "Return (START-LINE . END-LINE) of the symbol at FOUND-POS."
  (save-excursion
    (goto-char found-pos)
    (beginning-of-line)
    (let ((start-line (line-number-at-pos)) end-line)
      (cond
       ((derived-mode-p 'emacs-lisp-mode 'lisp-mode 'scheme-mode 'clojure-mode)
        (condition-case nil
            (progn
              (beginning-of-defun)
              (setq start-line (line-number-at-pos))
              (forward-sexp 1)
              (setq end-line (line-number-at-pos)))
          (scan-error nil)))
       ((derived-mode-p 'python-mode 'python-ts-mode)
        (setq end-line (kargu-chat--python-symbol-end found-pos)))
       ((save-excursion
          (goto-char found-pos)
          (search-forward "{" (line-end-position 3) t))
        (condition-case nil
            (progn
              (goto-char found-pos)
              (search-forward "{" nil t)
              (backward-char 1)
              (forward-list 1)
              (setq end-line (line-number-at-pos)))
          (scan-error nil))))
      (unless (and end-line (>= end-line start-line))
        (setq end-line (min (count-lines (point-min) (point-max))
                            (+ start-line kargu-chat--symbol-fallback-lines))))
      (cons start-line end-line))))

(defun kargu-chat--extract-symbol-range (abs sym-name)
  "Return (START-LINE . END-LINE) for SYM-NAME in file ABS."
  (with-temp-buffer
    (insert-file-contents abs)
    (let ((buffer-file-name abs))
      (condition-case nil
          (delay-mode-hooks
            (set-auto-mode t))
        (error nil)))
    (let ((found-pos (kargu-chat--find-symbol-pos sym-name)))
      (when found-pos
        (kargu-chat--compute-symbol-bounds found-pos)))))

(cl-defun kargu-chat--attach-symbol-block
    (mention &key (roots (kargu-chat--completion-roots)))
  "Attach symbol MENTION ('file::symbol') from ROOTS with line numbers."
  (let* ((parts (split-string mention "::"))
         (file-part (car parts))
         (sym-part (cadr parts))
         (abs (kargu-chat--resolve-mention-file file-part :roots roots)))
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

(defun kargu-chat--span-mentions (spans)
  "Return SPANS' distinct file and symbol mentions as (FILES . SYMBOLS).
SPANS are native lexer DTOs.  A whole-file mention is its path string and a
line-range mention is (PATH FROM . TO); a symbol mention is `path::symbol'.
Other native target kinds are resolved elsewhere."
  (let (files symbols)
    (mapc (lambda (span)
            (let* ((target (gethash "target" span))
                   (path (and (hash-table-p target) (gethash "path" target))))
              (pcase (and (hash-table-p target) (gethash "type" target))
                ((or "legacy_path" "file")
                 (when (stringp path) (cl-pushnew path files :test #'equal)))
                ("line_range"
                 (let ((from (gethash "start" target)) (to (gethash "end" target)))
                   (when (and (stringp path) (natnump from) (natnump to))
                     (cl-pushnew (cons path (cons from to)) files :test #'equal))))
                ("legacy_file_symbol"
                 (let ((symbol (gethash "symbol" target)))
                   (when (and (stringp path) (stringp symbol))
                     (cl-pushnew (concat path "::" symbol) symbols :test #'equal)))))))
          spans)
    (cons (nreverse files) (nreverse symbols))))

(defun kargu-chat--file-block (mention text)
  "Render file MENTION's native read TEXT as a synthetic Read transcript.
A native refusal keeps its payload-free reason and attaches no content."
  (let ((path (if (consp mention) (car mention) mention)))
    (if (string-prefix-p "ERROR: " text)
        (format "<code_selection path=\"%s\">\n(%s)\n</code_selection>\n"
                path (substring text (length "ERROR: ")))
      (format "%s\n%s\n" (kargu-chat--called-read path) text))))

(defun kargu-chat--file-window (mention)
  "Return the line window Rust should read for file MENTION.
Whole files are limited to `kargu-chat-attach-max-lines'; Rust renders and
reports the excerpt bounds."
  (if (consp mention)
      (kargu-file-window-create :from (cadr mention) :to (cddr mention))
    (kargu-file-window-create :limit (max 1 (or kargu-chat-attach-max-lines 150)))))

(defun kargu-chat--read-file-mentions (files callback)
  "Read FILES in order through the native read port; CALLBACK gets the blocks.
Live unsaved buffers are read from RAM by the shared port; disk, decoding,
root confinement and excerpts are Rust's.  No Elisp file read happens here."
  (let ((blocks nil) (pending files))
    (cl-labels
        ((next ()
           (if (null pending)
               (funcall callback (apply #'concat (nreverse blocks)))
             (let ((mention (pop pending)))
               (kargu-file-read-async
                (if (consp mention) (car mention) mention)
                (kargu-chat--file-window mention)
                (lambda (text)
                  (push (kargu-chat--file-block mention text) blocks)
                  (next)))))))
      (next))))

(defun kargu-chat--expand-mentions (prompt spans callback)
  "Wrap PROMPT as `<user_query>' plus attachments for native SPANS.
CALLBACK receives the text.  `@file::symbol' mentions attach the symbol
definition with line numbers; file and line mentions attach Rust-rendered
excerpts.  The chat buffer still shows the unwrapped prompt."
  (let* ((mentions (kargu-chat--span-mentions spans))
         (file-mentions (car mentions))
         (sym-mentions (cdr mentions))
         (query (format "<user_query>\n%s\n</user_query>" prompt)))
    (if (and (null sym-mentions) (null file-mentions))
        (funcall callback query)
      (let* ((roots (kargu-chat--completion-roots))
             (symbols (mapconcat (lambda (m) (kargu-chat--attach-symbol-block m :roots roots))
                                 sym-mentions "")))
        (kargu-chat--read-file-mentions
         file-mentions
         (lambda (files)
           (funcall callback (concat query "\n\n<attached_files>\n" symbols files
                                     "</attached_files>\n"))))))))

(cl-defun kargu-chat--expand-prompt (prompt callback &key parent valid-p)
  "Expand PROMPT for the model, then call CALLBACK with (TEXT FAILURE).
Rust's lexer decides which spans are mentions; a prompt without `@' needs no
parse.  PARENT and VALID-P bound the native parse task."
  (if (not (string-search "@" prompt))
      (kargu-chat--expand-mentions prompt [] (lambda (text) (funcall callback text nil)))
    (kargu-bridge-mentions-parse
     prompt
     (lambda (spans failure)
       (if failure
           (funcall callback nil failure)
         (kargu-chat--expand-mentions prompt spans (lambda (text) (funcall callback text nil)))))
     :parent parent :valid-p valid-p)))

(provide 'kargu/chat/attach)

;;; attach.el ends here
