;;; toml.el --- TOML parser for Kargu configurations -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Pure Elisp TOML parser tailored for Kargu configuration files.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rx)

(defun kargu--toml-unescape (string)
  "Undo basic TOML escapes in STRING (the inside of a quoted value)."
  (replace-regexp-in-string
   "\\\\\\(.\\)"
   (lambda (m)
     (pcase (aref m 1)
       (?n "\n") (?t "\t") (?r "\r")
       (?\" "\"") (?\\ "\\")
       (_ (substring m 1))))
   string t t))

(defun kargu--toml-array-closed-p (raw)
  "Return non-nil when RAW has an opening and a later closing bracket."
  (let ((open (cl-position ?\[ raw))
        (close (cl-position ?\] raw :from-end t)))
    (and open close (> close open))))

(defun kargu--toml-parse-string-array (raw)
  "Parse a TOML string array RAW like [\"a\", \"b\"] or [`a', `b']."
  (setq raw (or raw ""))
  (let ((open (cl-position ?\[ raw))
        (close (cl-position ?\] raw :from-end t)))
    (when (and open close (> close open))
      (let (items)
        (with-temp-buffer
          (insert (substring raw (1+ open) close))
          (goto-char (point-min))
          (while (re-search-forward
                  "\\(?:\"\\(\\(?:\\\\.\\|[^\"\\\\]\\)*\\)\"\\|'\\([^']*\\)'\\)" nil t)
            (if (match-string 1)
                (push (kargu--toml-unescape (match-string 1)) items)
              (push (match-string 2) items))))
        (nreverse items)))))

(defun kargu--toml-parse-value (raw)
  "Parse a TOML value RAW.
RAW may be a quoted string, single-quoted string, array, or bare token."
  (setq raw (string-trim (or raw "")))
  (cond
   ((string-prefix-p "[" raw)
    (kargu--toml-parse-string-array raw))
   ((string-prefix-p "\"" raw)
    (if (string-match "\\`\"\\(\\(?:\\\\.\\|[^\"\\\\]\\)*\\)\"" raw)
        (kargu--toml-unescape (match-string 1 raw))
      (string-trim raw "\"" "\"")))
   ((string-prefix-p "'" raw)
    (if (string-match "\\`'\\([^']*\\)'" raw)
        (match-string 1 raw)
      (string-trim raw "'" "'")))
   (t
    (let ((bare (car (split-string raw "#" t "[ \t]+"))))
      (and bare (string-trim bare))))))

(defun kargu--provider-plist-put (providers name key value)
  "Set KEY to VALUE on provider NAME in PROVIDERS (alist of name . plist)."
  (let ((cell (assoc name providers)))
    (if cell
        (progn (setcdr cell (plist-put (cdr cell) key value)) providers)
      (cons (cons name (list key value)) providers))))

(defun kargu--read-toml-assign (section key val top-fn provider-fn)
  "Apply KEY=VAL from SECTION via TOP-FN or PROVIDER-FN."
  (if (null section)
      (funcall top-fn key val)
    (pcase key
      ("api" (funcall provider-fn section :api val))
      ("apikey" (funcall provider-fn section :apikey val))
      ("model" (funcall provider-fn section :model val))
      ("models" (when (listp val)
                  (funcall provider-fn section :models val))))))

(defun kargu--toml-read-multiline-array (raw)
  "Read subsequent lines when RAW begins an unclosed array."
  (if (and (string-prefix-p "[" (string-trim raw))
           (not (kargu--toml-array-closed-p raw)))
      (catch 'kargu--toml-array-end
        (while (not (kargu--toml-array-closed-p raw))
          (let ((here (point)))
            (forward-line 1)
            (when (or (eobp) (= (point) here))
              (throw 'kargu--toml-array-end raw))
            (setq raw
                  (concat raw " "
                          (string-trim
                           (buffer-substring
                            (line-beginning-position)
                            (line-end-position)))))))
        raw)
    raw))

(defun kargu--toml-apply-review-mode (top-review-mode)
  "Apply TOP-REVIEW-MODE to `kargu-diff-review-mode' if valid."
  (when (and (stringp top-review-mode) (boundp 'kargu-diff-review-mode))
    (let ((m (intern (downcase (string-trim top-review-mode)))))
      (when (memq m '(auto blocking async))
        (setq kargu-diff-review-mode m)))))

(defun kargu--toml-fallback-default-provider (top-api top-key top-name top-model)
  "Build a default provider from TOP-API, TOP-KEY, TOP-NAME and TOP-MODEL."
  (when (or top-api top-key top-name top-model)
    (list (cons "default"
                (append (and top-api (list :api top-api))
                        (and top-key (list :apikey top-key))
                        (let ((id (or top-model top-name)))
                          (and id (list :models (list id)))))))))

(defconst kargu--toml-provider-section-regexp
  (rx string-start "[provider" (? "s") "."
      (or (group (any "A-Za-z0-9") (* (any "A-Za-z0-9_-")))
          (seq "\"" (group (+ (not (any "\"")))) "\""))
      "]" (* (any " \t")) (? "#" (* nonl)) string-end)
  "Provider section header with an unquoted or quoted name.")

(defconst kargu--toml-assignment-regexp
  (rx string-start (group (any "A-Za-z") (* (any "A-Za-z0-9_")))
      (* (any " \t")) "=" (* (any " \t")) (group (* nonl)) string-end)
  "Configuration key and the raw value assigned to it.")

(defun kargu--toml-read-entries (path top-fn provider-fn)
  "Read PATH, sending entries to TOP-FN and PROVIDER-FN."
  (save-match-data
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (let (section)
        (while (not (eobp))
          (let ((line (string-trim
                       (buffer-substring (line-beginning-position)
                                         (line-end-position)))))
            (cond
             ((or (string-empty-p line) (eq (aref line 0) ?#)))
             ((string-match kargu--toml-provider-section-regexp line)
              (setq section (or (match-string 1 line) (match-string 2 line))))
             ((eq (aref line 0) ?\[) (setq section 'skip))
             ((eq section 'skip))
             ((string-match kargu--toml-assignment-regexp line)
              (let* ((key (match-string 1 line))
                     (raw (kargu--toml-read-multiline-array (match-string 2 line))))
                (kargu--read-toml-assign
                 section key (kargu--toml-parse-value raw) top-fn provider-fn)))))
          (forward-line 1))))))

(defun kargu--read-toml-config (path)
  "Read PATH as kargu TOML; return (:provider :model :providers)."
  (let (top-provider top-model top-name top-api top-key top-review-mode providers)
    (kargu--toml-read-entries
     path
     (lambda (key value)
       (pcase key
         ("provider" (setq top-provider value))
         ("model" (setq top-model value))
         ("name" (setq top-name value))
         ("api" (setq top-api value))
         ("apikey" (setq top-key value))
         ("review_mode" (setq top-review-mode value))))
     (lambda (section key value)
       (setq providers (kargu--provider-plist-put providers section key value))))
    (setq providers
          (or (nreverse providers)
              (kargu--toml-fallback-default-provider top-api top-key top-name top-model)))
    (kargu--toml-apply-review-mode top-review-mode)
    (list :provider (kargu--toml-nonempty top-provider)
          :model (or (kargu--toml-nonempty top-model) (kargu--toml-nonempty top-name))
          :review-mode (kargu--toml-nonempty top-review-mode)
          :providers providers)))

(defun kargu--toml-nonempty (value)
  "Return VALUE when it is a nonempty string."
  (and (stringp value) (not (string-empty-p value)) value))

(provide 'kargu/config/toml)

;;; toml.el ends here
