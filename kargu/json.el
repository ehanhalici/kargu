;;; kargu/json.el --- JSON encode/decode and text coerce -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Alist JSON with a depth cap of 32.  Public helpers: `kargu--json-encode', `kargu--json-decode', `kargu--coerce-text'.
;; Requires: `kargu/core'.

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

;;;; JSON helpers ---------------------------------------------------------

(defconst kargu--json-supports-key-type
  (condition-case nil
      (progn
        ;; `{}` decodes to nil (empty alist); ignore the value, we
        ;; only care whether `:key-type string' is accepted.
        (ignore
         (json-parse-string
          "{}"
          :object-type 'alist
          :array-type 'list
          :key-type 'string
          :null-object :json-null
          :false-object :json-false))
        t)
    (error nil))
  "Non-nil when `json-parse-string' accepts `:key-type string'.
Some Emacs 30 builds (notably certain Nix packages) reject that
keyword and treat `string' as a leftover argument, which made
every SSE chunk look like invalid JSON.")

(defun kargu--object-p (object)
  "Return non-nil if OBJECT is an alist encoding a JSON object.
A JSON object is a list whose every element is a (KEY . VALUE)
cons with a string or symbol KEY.  Lists of alists (parsed JSON
arrays of objects) are deliberately NOT objects, which is what
disambiguates arrays from objects in `kargu--json-encode'."
  (and (consp object)
       (cl-every (lambda (cell)
                   (and (consp cell)
                        (or (stringp (car cell)) (symbolp (car cell)))))
                 object)))

(defun kargu--json-stringify-keys (object)
  "Return OBJECT with JSON object keys converted to strings.
Walks alists and arrays recursively so `kargu--aget' (string
keys) works even when the parser interned keys as symbols."
  (cond
   ((kargu--object-p object)
    (mapcar (lambda (cell)
              (cons (if (symbolp (car cell))
                        (symbol-name (car cell))
                      (car cell))
                    (kargu--json-stringify-keys (cdr cell))))
            object))
   ((vectorp object)
    (vconcat (mapcar #'kargu--json-stringify-keys object)))
   ((listp object)
    (mapcar #'kargu--json-stringify-keys object))
   (t object)))

(defun kargu-seq-to-list (seq)
  "Normalize a JSON array (vector, list, or single value) to a list.
If SEQ is nil, return nil."
  (cond
   ((vectorp seq) (append seq nil))
   ((listp seq) seq)
   (seq (list seq))
   (t nil)))

(defun kargu--json-parse-raw (string)
  "Parse JSON STRING to alists/lists with the working parser flags."
  (if kargu--json-supports-key-type
      (json-parse-string string
                         :object-type 'alist
                         :array-type 'list
                         :key-type 'string
                         :null-object :json-null
                         :false-object :json-false)
    (json-parse-string string
                       :object-type 'alist
                       :array-type 'list
                       :null-object :json-null
                       :false-object :json-false)))

(defun kargu--json-decode (string)
  "Decode JSON STRING into alists with string keys.
Arrays become lists, booleans become :json-false / t, JSON null
becomes :json-null.  This mirrors the conventions used by
`json-parse-string' and keeps round-tripping through
`kargu--json-encode' lossless.

When the native parser rejects `:key-type string', keys are
interned as symbols and then rewritten to strings."
  (let ((raw (kargu--json-parse-raw string)))
    (if kargu--json-supports-key-type
        raw
      (kargu--json-stringify-keys raw))))

(defun kargu--json-decode-safe (string)
  "Like `kargu--json-decode' but return nil on failure."
  (condition-case-unless-debug err
      (kargu--json-decode string)
    (error
     (kargu-log 'warn "bad JSON (%s): %s"
                      (error-message-string err)
                      (if kargu-log-wire
                          (kargu--log-limit (or string ""))
                        (truncate-string-to-width (or string "") 160)))
     (kargu--log-block "bad JSON input" (or string ""))
     nil)))

(defun kargu--json-decode-checked (string)
  "Return (ok . VALUE) when STRING is exactly one JSON value, else nil.
VALUE may be nil: an empty JSON object `{}` decodes to nil.
Trailing tokens after the first value (`{}{\"a\":1}`) are not
accepted; use `kargu--json-decode-last-value-checked' for those."
  (let ((s (and (stringp string) (string-trim string))))
    (and s (not (string-empty-p s))
         (kargu--json-whole-string-p s)
         (cons 'ok (kargu--json-decode s)))))

(declare-function json-read "json" ())

(defun kargu--json-whole-string-p (string)
  "Non-nil when STRING is exactly one JSON value (no trailing tokens)."
  (and (stringp string)
       (let ((s (string-trim string)))
         (and (not (string-empty-p s))
              (condition-case nil
                  (with-temp-buffer
                    (insert s)
                    (goto-char (point-min))
                    (json-read)
                    (skip-chars-forward " \t\n\r")
                    (eobp))
                (error nil))))))

(defun kargu--json-complete-value-string-p (string)
  "Non-nil when STRING is exactly one JSON object or array."
  (and (stringp string)
       (let ((s (string-trim string)))
         (and (or (string-prefix-p "{" s) (string-prefix-p "[" s))
              (kargu--json-whole-string-p s)))))

(defun kargu--json-decode-last-value-checked (string)
  "Return (ok . VALUE) for the last JSON value in STRING, or nil.
Concatenated values such as `{}{\"file_path\":\"x\"}` keep the last
object.  VALUE may be nil when that last value is `{}`."
  (when (and (stringp string) (not (string-empty-p (string-trim string))))
    (condition-case nil
        (with-temp-buffer
          (insert string)
          (goto-char (point-min))
          (let (last-start last-end)
            (while (progn (skip-chars-forward " \t\n\r") (not (eobp)))
              (setq last-start (point))
              (json-read)
              (setq last-end (point)))
            (when last-start
              (cons 'ok
                    (kargu--json-decode
                     (buffer-substring-no-properties last-start last-end))))))
      (error nil))))

(defun kargu--json-decode-lenient (string)
  "Decode STRING; on concatenated JSON keep the last value.
Return (ok . VALUE) or nil.  VALUE may be nil for `{}`."
  (let ((trimmed (and (stringp string) (string-trim string))))
    (cond
     ((or (null trimmed) (string-empty-p trimmed)) '(ok . nil))
     ((kargu--json-decode-checked trimmed))
     ((kargu--json-decode-last-value-checked trimmed))
     (t
      (kargu-log 'warn "bad JSON: %s"
                       (if kargu-log-wire
                           (kargu--log-limit trimmed)
                         (truncate-string-to-width trimmed 160)))
      (kargu--log-block "bad JSON input" (or string ""))
      nil))))

(defun kargu--json-encode-key (key)
  "Encode an object KEY (string or symbol) as a JSON string."
  (cond
   ((stringp key) (json-encode-string key))
   ((symbolp key) (json-encode-string (symbol-name key)))
   (t (json-encode-string (format "%s" key)))))

(defconst kargu--json-max-depth 32
  "Maximum nesting depth for JSON encode and text coerce.")

(defun kargu--json-encode (object &optional depth)
  "Encode OBJECT to a JSON string.
Optional DEPTH tracks nesting; beyond `kargu--json-max-depth'
the value is replaced by a short string so circular or
pathologically nested input cannot blow the stack.
Conventions:
  * JSON objects are alists (string or symbol keys);
  * JSON arrays are vectors, or proper lists that are not
    objects (see `kargu--object-p');
  * nil / t / :json-null / :json-false round-trip to
    null / true / null / false.
This encoder exists because histories mix data we built
(alist-based) with data decoded from responses (list-based), and
plain `json-encode' cannot tell a list of alists from an alist."
  (let ((depth (or depth 0)))
    (cond
     ((>= depth kargu--json-max-depth) "\"[truncated]\"")
     ((or (eq object :json-empty-object)
          (eq object :empty-object)
          (and (consp object) (eq (car object) :json-empty-object)))
      "{}")
     ((null object) "null")
     ((eq object t) "true")
     ((eq object :json-false) "false")
     ((eq object :json-null) "null")
     ((stringp object) (json-encode-string object))
     ((numberp object) (json-encode object))
     ((keywordp object) (json-encode-string (substring (symbol-name object) 1)))
     ((vectorp object)
      (concat "[" (mapconcat (lambda (elt)
                               (kargu--json-encode elt (1+ depth)))
                             object ",") "]"))
     ((kargu--object-p object)
      (concat "{"
              (mapconcat (lambda (cell)
                           (concat (kargu--json-encode-key (car cell))
                                   ":"
                                   (kargu--json-encode (cdr cell) (1+ depth))))
                         object ",")
              "}"))
     ((listp object)
      (concat "[" (mapconcat (lambda (elt)
                               (kargu--json-encode elt (1+ depth)))
                             object ",") "]"))
     (t (json-encode-string (format "%s" object))))))

(defun kargu--coerce-text (value &optional depth)
  "Return a non-empty string extracted from VALUE, or nil.
VALUE may be a plain string, JSON null, or OpenAI/OpenRouter
content parts (a list or vector of alists with `text',
`output_text' or `summary').  Numbers and empty strings
are ignored.  Optional DEPTH caps nesting at
`kargu--json-max-depth'."
  (let ((depth (or depth 0)))
    (cond
     ((null value) nil)
     ((eq value :json-null) nil)
     ((eq value :json-false) nil)
     ((stringp value) (kargu--nonempty value))
     ((numberp value) nil)
     ((>= depth kargu--json-max-depth) "[truncated]")
     ((vectorp value)
      (kargu--coerce-text (append value nil) (1+ depth)))
     ((kargu--object-p value)
      (or (kargu--coerce-text (kargu--aget value "text") (1+ depth))
          (kargu--coerce-text (kargu--aget value "output_text") (1+ depth))
          (kargu--coerce-text (kargu--aget value "summary") (1+ depth))
          (kargu--coerce-text (kargu--aget value "content") (1+ depth))))
     ((listp value)
      (let ((bits (delq nil (mapcar (lambda (elt)
                                      (kargu--coerce-text elt (1+ depth)))
                                    value))))
        (and bits (kargu--nonempty (mapconcat #'identity bits "")))))
     (t nil))))

(defun kargu--content-text (obj)
  "Non-empty plain `content' of OBJ, never reasoning fields."
  (and obj (not (eq obj :json-null))
       (kargu--coerce-text (kargu--aget obj "content"))))

(defun kargu--reasoning-text (obj)
  "Non-empty reasoning / thinking text of OBJ, or nil."
  (when (and obj (not (eq obj :json-null)))
    (or (kargu--coerce-text (kargu--aget obj "reasoning_content"))
        (kargu--coerce-text (kargu--aget obj "reasoning"))
        (kargu--coerce-text (kargu--aget obj "reasoning_details"))
        (kargu--coerce-text (kargu--aget obj "thinking"))
        (kargu--coerce-text (kargu--aget obj "thought")))))

(defun kargu--visible-text (obj)
  "User-visible assistant text from message or delta OBJ.
Only `content' is returned.  Reasoning fields stay off the
chat timeline; use `kargu--reasoning-text' for logs."
  (kargu--content-text obj))

(defun kargu--json-get (obj key)
  "Like `kargu--aget' but also try KEY interned as a symbol."
  (or (kargu--aget obj key)
      (and (stringp key) (kargu--aget obj (intern key)))))

(defun kargu--json-decode-object (string)
  "Decode JSON STRING to an alist with string keys, or nil."
  (kargu--json-decode-safe string))

(defun kargu--provider-error-text (obj)
  "Extract a concise provider error string from decoded JSON OBJ."
  (let ((err (or (and (kargu--object-p obj) (kargu--json-get obj "error"))
                 obj)))
    (cond
     ((null err) nil)
     ((stringp err) (kargu--nonempty err))
     ((not (kargu--object-p err)) nil)
     (t
      (let* ((msg (or (kargu--coerce-text (kargu--json-get err "message"))
                      (kargu--coerce-text (kargu--json-get err "msg"))))
             (code (kargu--json-get err "code"))
             (type (kargu--json-get err "type"))
             (meta (kargu--json-get err "metadata"))
             (meta-text
              (cond
               ((stringp meta) (kargu--nonempty meta))
               ((kargu--object-p meta)
                (or (kargu--coerce-text (kargu--json-get meta "raw"))
                    (kargu--coerce-text (kargu--json-get meta "message"))
                    (kargu--coerce-text (kargu--json-get meta "provider_name"))))
               (t nil)))
             (bits (delq nil
                         (list (and type (format "[%s]" type))
                               (and code (format "(%s)" code))
                               msg
                               meta-text))))
        (and bits (mapconcat #'identity bits " ")))))))

(provide 'kargu/json)

;;; kargu/json.el ends here
