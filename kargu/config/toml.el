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

(defvar kargu--toml-source-path nil
  "Configuration path dynamically bound while parsing TOML.")

(defconst kargu--toml-top-keys
  '("provider" "model" "name" "api" "apikey" "review_mode")
  "Supported top-level configuration keys.")

(defconst kargu--toml-provider-keys '("api" "apikey" "model" "models")
  "Supported keys in each provider table.")

(defun kargu--toml-error (message)
  "Signal a source-located TOML error with MESSAGE, never including values."
  (error "TOML %s:%d: %s" kargu--toml-source-path (line-number-at-pos) message))

(defun kargu--toml-unescape (string)
  "Undo basic TOML escapes in STRING (the inside of a quoted value)."
  (let ((case-fold-search nil))
    (replace-regexp-in-string
   (rx "\\" (group (or (seq "u" (= 4 xdigit)) (seq "U" (= 8 xdigit)) anything)))
   (lambda (m)
     (pcase (aref m 1)
       (?b "\b") (?f "\f") (?n "\n") (?t "\t") (?r "\r")
       (?\" "\"") (?\\ "\\")
       ((or ?u ?U)
        (let ((code (string-to-number (substring m 2) 16)))
          (unless (and (<= code #x10ffff) (not (<= #xd800 code #xdfff)))
            (kargu--toml-error "Invalid Unicode escape"))
          (char-to-string code)))
       (_ (kargu--toml-error "Unsupported string escape"))))
     string t t)))

(defconst kargu--toml-basic-string-regexp
  (rx "\"" (group (* (or (not (any "\"\\\n\r")) (seq "\\" nonl)))) "\"")
  "Single-line basic TOML string including escaped quotes.")

(defconst kargu--toml-literal-string-regexp
  (rx "'" (group (* (not (any "'\n\r")))) "'")
  "Single-line literal TOML string.")

(defun kargu--toml-read-string ()
  "Read a supported TOML string at point and advance past it."
  (when (or (looking-at-p (rx "\"\"\"")) (looking-at-p (rx "'''")))
    (kargu--toml-error "Multiline strings are not supported"))
  (let ((basic (eq (char-after) ?\")))
    (unless (looking-at (if basic kargu--toml-basic-string-regexp
                         kargu--toml-literal-string-regexp))
      (kargu--toml-error "Expected a complete quoted string"))
    (let ((raw (match-string-no-properties 1)) (end (match-end 0)))
      (when (seq-some (lambda (char) (or (< char 9) (<= 10 char 31) (= char 127))) raw)
        (kargu--toml-error "Unescaped control character in string"))
      (let ((value (if basic (kargu--toml-unescape raw) raw)))
        (goto-char end)
        value))))

(defun kargu--toml-array-whitespace ()
  "Skip whitespace and comments between array elements."
  (while (progn
           (skip-chars-forward " \t\r\n")
           (when (eq (char-after) ?#) (forward-line 1) t))))

(defun kargu--toml-read-string-array ()
  "Read a string array at point, enforcing separators and closing brackets."
  (forward-char 1)
  (let ((state :value) items)
    (catch 'finished
      (while t
        (kargu--toml-array-whitespace)
        (pcase (char-after)
          (?\] (forward-char 1) (throw 'finished (nreverse items)))
          (?, (unless (eq state :separator) (kargu--toml-error "Unexpected comma"))
              (forward-char 1) (setq state :value))
          ((or ?\" ?')
           (unless (eq state :value) (kargu--toml-error "Missing array comma"))
           (push (kargu--toml-read-string) items)
           (setq state :separator))
          (_ (kargu--toml-error "Expected a string element or closing bracket")))))))

(defun kargu--toml-read-value ()
  "Read one supported configuration value at point."
  (skip-chars-forward " \t")
  (pcase (char-after)
    ((or ?\" ?') (kargu--toml-read-string))
    (?\[ (kargu--toml-read-string-array))
    (_ (kargu--toml-error "Expected a quoted string or string array"))))

(defun kargu--provider-plist-put (providers name key value)
  "Set KEY to VALUE on provider NAME in PROVIDERS (alist of name . plist)."
  (let ((cell (assoc name providers)))
    (if cell
        (progn (setcdr cell (plist-put (cdr cell) key value)) providers)
      (cons (cons name (list key value)) providers))))

(cl-defun kargu--read-toml-assign (section key val &key top-fn provider-fn)
  "Apply KEY=VAL from SECTION via TOP-FN or PROVIDER-FN."
  (unless (member key (if section kargu--toml-provider-keys kargu--toml-top-keys))
    (kargu--toml-error "Unsupported configuration key"))
  (unless (if (equal key "models") (and (listp val) (cl-every #'stringp val))
            (stringp val))
    (kargu--toml-error "Incorrect configuration value type"))
  (when (and (equal key "review_mode") (not (member val '("auto" "async" "blocking"))))
    (kargu--toml-error "Invalid review_mode"))
  (if (null section)
      (funcall top-fn key val)
    (pcase key
      ("api" (funcall provider-fn section :api val))
      ("apikey" (funcall provider-fn section :apikey val))
      ("model" (funcall provider-fn section :model val))
      ("models" (when (listp val)
                  (funcall provider-fn section :models val))))))

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
      (* (any " \t")) "=" (* (any " \t")))
  "Configuration key and the raw value assigned to it.")

(defun kargu--toml-read-entries (path top-fn provider-fn &optional text)
  "Read PATH or supplied TEXT, passing entries to TOP-FN and PROVIDER-FN."
  (save-match-data
    (with-temp-buffer
      (if text (insert text) (insert-file-contents path))
      (goto-char (point-min))
      (let ((kargu--toml-source-path path)
            (case-fold-search nil)
            (seen (make-hash-table :test #'equal)) section)
        (while (not (eobp))
          (skip-chars-forward " \t")
          (let ((line (string-trim
                       (buffer-substring (line-beginning-position)
                                         (line-end-position)))))
            (cond
             ((or (string-empty-p line) (eq (aref line 0) ?#)))
             ((string-match kargu--toml-provider-section-regexp line)
              (setq section (or (match-string 1 line) (match-string 2 line)))
              (when (gethash (list :table section) seen)
                (kargu--toml-error "Duplicate provider table"))
              (puthash (list :table section) t seen))
             ((eq (aref line 0) ?\[) (kargu--toml-error "Unsupported table"))
             ((string-match kargu--toml-assignment-regexp line)
              (let ((key (match-string 1 line)) (offset (match-end 0)))
                (when (gethash (cons section key) seen)
                  (kargu--toml-error "Duplicate configuration key"))
                (puthash (cons section key) t seen)
                (forward-char offset)
                (kargu--read-toml-assign
                 section key (kargu--toml-read-value) :top-fn top-fn :provider-fn provider-fn)
                (skip-chars-forward " \t\r")
                (unless (or (eolp) (eq (char-after) ?#))
                  (kargu--toml-error "Trailing content after value"))))
             (t (kargu--toml-error "Unsupported configuration syntax"))))
          (forward-line 1))))))

(defun kargu--read-toml-config (path &optional text)
  "Parse PATH or supplied TEXT as TOML without changing runtime settings."
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
       (setq providers (kargu--provider-plist-put providers section key value)))
     text)
    (setq providers
          (or (nreverse providers)
              (kargu--toml-fallback-default-provider top-api top-key top-name top-model)))
    (list :provider (kargu--toml-nonempty top-provider)
          :model (or (kargu--toml-nonempty top-model) (kargu--toml-nonempty top-name))
          :review-mode (kargu--toml-nonempty top-review-mode)
          :providers providers)))

(defun kargu--toml-nonempty (value)
  "Return VALUE when it is a nonempty string."
  (and (stringp value) (not (string-empty-p value)) value))

(provide 'kargu/config/toml)

;;; toml.el ends here
