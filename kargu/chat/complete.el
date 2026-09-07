;;; kargu/chat/complete.el --- @ company for files and LSP symbols -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Company backend for `@' mentions in the chat prompt.
;; Requires: `kargu/core', `kargu/fs', `kargu/tools/lsp'.
;; Public: `kargu-chat-company'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project nil t)
(require 'company nil t)
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
(require 'kargu/fs)
(require 'kargu/tools/lsp)

(defvar kargu-context-buffer nil)
(defvar kargu-chat-max-listed-files 2000)
(defvar kargu-chat--files-cache nil
  "Cache of project files for `@' completion.
Format: (:roots ROOTS :time TIME :files FILES).")
(defvar kargu-chat--prompt-marker nil)
(declare-function kargu-chat--in-input-p "kargu/chat")
(declare-function company-begin-backend "company")
(declare-function company-manual-begin "company")

(defun kargu-chat--at-prefix ()
  "Return the `@mention' prefix at point, or nil."
  (when (and (kargu-chat--in-input-p)
             (markerp kargu-chat--prompt-marker))
    (let ((end (point))
          (floor (marker-position kargu-chat--prompt-marker)))
      (save-excursion
        (let ((start (progn
                       (skip-chars-backward "^[:space:]\n" floor)
                       (point))))
          (when (and (< start end)
                     (>= start floor)
                     (eq (char-after start) ?@))
            (buffer-substring-no-properties start end)))))))

(defun kargu-chat--maybe-company ()
  "Start company after an `@' mention in the prompt."
  (when (and (fboundp 'company-manual-begin)
             (kargu-chat--at-prefix))
    (when (boundp 'company-backend)
      (setq company-backend nil))
    (ignore-errors (company-manual-begin))))

(defun kargu-chat--completion-root ()
  "Project root used for `@' file completion."
  (or (and (fboundp 'kargu--project-root)
           (ignore-errors (kargu--project-root)))
      (let ((buf (cond
                  ((and (boundp 'kargu-context-buffer)
                        (bufferp kargu-context-buffer)
                        (buffer-live-p kargu-context-buffer))
                   kargu-context-buffer)
                  ((and (boundp 'kargu-context-buffer)
                        (stringp kargu-context-buffer))
                   (or (get-file-buffer kargu-context-buffer)
                       (get-buffer kargu-context-buffer))))))
        (and (buffer-live-p buf)
             (with-current-buffer buf
               (when (fboundp 'project-current)
                 (let ((project (project-current)))
                   (and project (project-root project)))))))
      default-directory))

(defun kargu-chat--completion-roots ()
  "Project roots to search: context, visiting buffers, known projects."
  (let (roots)
    (cl-labels ((add (dir)
                  (when (and (stringp dir) (file-directory-p dir))
                    (push (file-name-as-directory (expand-file-name dir))
                          roots))))
      (add (kargu-chat--completion-root))
      (dolist (buf (buffer-list))
        (let ((file (buffer-file-name buf)))
          (when file
            (with-current-buffer buf
              (if (and (fboundp 'project-current) (project-current))
                  (add (project-root (project-current)))
                (add (file-name-directory file)))))))
      (delete-dups roots))))

(defun kargu-chat--walk-files (dir)
  "Recursively list up to `kargu-chat-max-listed-files' under DIR."
  (kargu-fs-walk dir kargu-chat-max-listed-files))

(defun kargu-chat--project-absolute-files (root)
  "Absolute file paths in the project at ROOT, capped.
Prefers `project-files' when a project is found and does not also
walk the tree.  Falls back to a bounded walk otherwise."
  (let ((default-directory root)
        (cap (or kargu-chat-max-listed-files 2000))
        (project (and (fboundp 'project-current)
                      (fboundp 'project-files)
                      (project-current nil root))))
    (if project
        (let (kept)
          (catch 'full
            (dolist (f (project-files project))
              (let ((abs (expand-file-name f)))
                (unless (or (kargu-fs-skipped-path-p abs)
                            (kargu-fs-ignore-file-p abs))
                  (push abs kept)
                  (when (>= (length kept) cap)
                    (throw 'full t))))))
          (nreverse kept))
      (kargu-chat--walk-files root))))

(defun kargu-chat--collect-files (roots)
  "Relative display paths for files under ROOTS.
When several roots are searched, each path is prefixed with the
root directory name so `@rust/src/lib.rs' is findable."
  (let* ((multi (cdr roots))
         (seen (make-hash-table :test #'equal))
         acc)
    (dolist (root roots)
      (let ((label (file-name-nondirectory (directory-file-name root))))
        (dolist (abs (kargu-chat--project-absolute-files root))
          (let ((key (expand-file-name abs)))
            (unless (or (gethash key seen)
                        (kargu-fs-ignore-file-p key))
              (puthash key t seen)
              (let ((rel (file-relative-name abs root)))
                (push (if (and multi (not (string-empty-p label)))
                          (concat label "/" rel)
                        rel)
                      acc)))))))
    (dolist (buf (buffer-list))
      (let ((file (buffer-file-name buf)))
        (when file
          (let ((key (expand-file-name file)))
            (unless (gethash key seen)
              (puthash key t seen)
              (push (kargu-chat--visiting-display-name file roots) acc))))))
    (nreverse acc)))

(defun kargu-chat--visiting-display-name (file roots)
  "Display path for a visiting FILE relative to ROOTS if possible."
  (let ((file (expand-file-name file))
        found)
    (dolist (root roots)
      (when (and (not found) (file-in-directory-p file root))
        (let* ((label (file-name-nondirectory (directory-file-name root)))
               (rel (file-relative-name file root)))
          (setq found (if (cdr roots)
                          (concat label "/" rel)
                        rel)))))
    (or found (file-name-nondirectory file))))

(defun kargu-chat--listed-files ()
  "Cached relative file paths for `@' completion."
  (condition-case nil
      (let* ((roots (kargu-chat--completion-roots))
             (now (float-time))
             (cache kargu-chat--files-cache))
        (if (and cache
                 (equal (plist-get cache :roots) roots)
                 (< (- now (plist-get cache :time)) 8.0))
            (plist-get cache :files)
          (let ((files (kargu-chat--collect-files roots)))
            (setq kargu-chat--files-cache
                  (list :roots roots :time now :files files))
            files)))
    (error nil)))

(defun kargu-chat--flex-indices (query string)
  "Return match indices of QUERY chars in STRING, or nil.
QUERY and STRING should already be downcased."
  (let ((qi 0)
        (qlen (length query))
        (i 0)
        (slen (length string))
        acc)
    (while (and (< i slen) (< qi qlen))
      (when (eq (aref query qi) (aref string i))
        (push i acc)
        (setq qi (1+ qi)))
      (setq i (1+ i)))
    (when (= qi qlen)
      (nreverse acc))))

(defun kargu-chat--flex-chunks (query string)
  "Return (START . END) highlight chunks of QUERY in STRING, or nil."
  (let ((idxs (kargu-chat--flex-indices (downcase query) (downcase string))))
    (when idxs
      (let (chunks start prev)
        (dolist (i idxs)
          (cond
           ((null start) (setq start i prev i))
           ((= i (1+ prev)) (setq prev i))
           (t
            (push (cons start (1+ prev)) chunks)
            (setq start i prev i))))
        (when start
          (push (cons start (1+ prev)) chunks))
        (nreverse chunks)))))

(defun kargu-chat--flex-score (query path)
  "Sort key for QUERY against PATH (lower is better).  Nil if no match."
  (let* ((q (downcase (or query "")))
         (p (downcase path))
         (base (downcase (file-name-nondirectory path))))
    (cond
     ((string-empty-p q) 50)
     ((string= base q) 0)
     ((string-prefix-p q base) 1)
     ((cl-search q base) 2)
     ((string-prefix-p q p) 3)
     ((cl-search q p) 4)
     ((kargu-chat--flex-indices q base)
      (let ((idx (kargu-chat--flex-indices q base)))
        (+ 10 (- (car (last idx)) (car idx) (length q) -1))))
     ((kargu-chat--flex-indices q p)
      (let ((idx (kargu-chat--flex-indices q p)))
        (+ 20 (- (car (last idx)) (car idx) (length q) -1))))
     (t nil))))

(defun kargu-chat--match-property (query body)
  "Company `match' chunks for QUERY inside BODY, offset by the leading `@'."
  (let* ((base (file-name-nondirectory body))
         (chunks
          (or (and (not (string-empty-p base))
                   (let ((c (kargu-chat--flex-chunks query base)))
                     (when c
                       (let ((off (- (length body) (length base))))
                         (mapcar (lambda (pair)
                                   (cons (+ off (car pair))
                                         (+ off (cdr pair))))
                                 c)))))
              (kargu-chat--flex-chunks query body))))
    (mapcar (lambda (pair)
              (cons (1+ (car pair)) (1+ (cdr pair))))
            (or chunks nil))))

(defun kargu-chat--file-candidates (query)
  "File mention candidates fuzzy-matching QUERY (without the leading `@')."
  (condition-case nil
      (let* ((q (or query ""))
             (scored
              (let (acc)
                (dolist (rel (or (kargu-chat--listed-files) nil))
                  (let ((score (kargu-chat--flex-score q rel)))
                    (when score
                      (push (cons score rel) acc))))
                acc)))
        (setq scored (cl-sort scored #'< :key #'car))
        (cl-loop for (_score . rel) in scored
                 for n from 0
                 until (>= n 50)
                 collect
                 (let ((cand (concat "@" rel)))
                   (propertize cand
                               'kargu-kind 'file
                               'kargu-ann "file"
                               'kargu-match (kargu-chat--match-property q rel)))))
    (error nil)))

(defun kargu-chat--symbol-candidates (query)
  "Symbol mention candidates matching QUERY (without the leading `@').
Formatted as `@file::symbol' (e.g., `@main.go::CalcTotal').
QUERY can match the symbol name, the file path, or both if QUERY contains `::'."
  (condition-case nil
      (let* ((root (kargu-chat--completion-root))
             (roots (kargu-chat--completion-roots))
             (q (or query ""))
             (has-delim (string-match-p "::" q))
             (file-q (and has-delim (car (split-string q "::"))))
             (sym-q (and has-delim (or (cadr (split-string q "::")) "")))
             (all-symbols (if (fboundp 'kargu-lsp-all-symbols)
                              (kargu-lsp-all-symbols (if has-delim sym-q q) roots)
                            nil))
             scored)
        (dolist (item all-symbols)
          (let* ((path (nth 0 item))
                 (line (nth 1 item))
                 (name (nth 2 item))
                 (kind (nth 3 item))
                 (rel (or (and path root (ignore-errors (file-relative-name path root)))
                          (and path (file-name-nondirectory path))
                          ""))
                 (cand-str (concat rel "::" name))
                 score)
            (if has-delim
                (let ((f-score (if (string-empty-p file-q) 0 (kargu-chat--flex-score file-q rel)))
                      (s-score (if (string-empty-p sym-q) 0 (kargu-chat--flex-score sym-q name))))
                  (when (and f-score s-score)
                    (setq score (+ (* f-score 2) s-score))))
              (let ((name-score (and name (kargu-chat--flex-score q name)))
                    (full-score (and cand-str (kargu-chat--flex-score q cand-str))))
                (cond
                 (name-score
                  (setq score name-score))
                 (full-score
                  (setq score (+ full-score 30))))))
            (when (and score name (not (string-empty-p rel)))
              (push (list score name kind rel line path cand-str) scored))))
        (setq scored (cl-sort scored #'< :key #'car))
        (cl-loop for (_score _name kind _rel line _path cand-str) in scored
                 for n from 0
                 until (>= n 40)
                 collect
                 (let ((cand (concat "@" cand-str)))
                   (propertize
                    cand
                    'kargu-kind 'symbol
                    'kargu-ann (format "%s :%s" kind (or line "?"))
                    'kargu-match (kargu-chat--match-property (if has-delim sym-q q) cand-str)))))
    (error nil)))

(defun kargu-chat--at-candidates (prefix)
  "Company candidates for PREFIX, a string beginning with `@'."
  (let ((q (if (string-prefix-p "@" prefix) (substring prefix 1) prefix)))
    (if (string-match-p "::" q)
        (or (kargu-chat--symbol-candidates q) nil)
      (append (kargu-chat--file-candidates q)
              (or (kargu-chat--symbol-candidates q) nil)))))

(defun kargu-chat-company (command &optional arg &rest _ignored)
  "Company backend for `@' file and LSP symbol mentions in the chat prompt.
Matching is fuzzy (flex): `@lib.rs' completes `rust/src/lib.rs'."
  (interactive (list 'interactive))
  (cl-case command
    (interactive (company-begin-backend 'kargu-chat-company))
    (prefix (kargu-chat--at-prefix))
    (candidates (kargu-chat--at-candidates arg))
    (annotation (or (get-text-property 0 'kargu-ann arg) ""))
    (match (or (get-text-property 0 'kargu-match arg) 0))
    (ignore-case t)
    (no-cache t)
    (duplicates t)
    (sorted t)))


(provide 'kargu/chat/complete)

;;; kargu/chat/complete.el ends here
