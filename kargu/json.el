;;; json.el --- JSON encode/decode and text coerce -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Wire objects are hash tables and arrays are vectors.  Native agent
;; records use explicit adapter conversion rather than wire type guesses.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'kargu/core)

;;;; JSON helpers ---------------------------------------------------------

(defun kargu--object-p (object)
  "Return non-nil if OBJECT is a typed JSON object or native record.
Native records use alists with string or symbol keys.  This predicate
is not used to infer the wire type of arbitrary lists."
  (or (hash-table-p object)
      (and (consp object)
           (cl-every (lambda (cell)
                       (and (consp cell)
                            (or (stringp (car cell)) (symbolp (car cell)))))
                     object))))

(defun kargu-json-to-record (object)
  "Copy typed JSON OBJECT into native agent records.
Nonempty objects become alists; empty objects remain hash tables.
Arrays stay vectors, so nested arrays never become ambiguous lists."
  (cond
   ((hash-table-p object)
    (if (zerop (hash-table-count object)) (copy-hash-table object)
      (let (record)
        (maphash (lambda (key value)
                   (push (cons key (kargu-json-to-record value)) record)) object)
        (nreverse record))))
   ((vectorp object)
    (vconcat (mapcar #'kargu-json-to-record object)))
   ((consp object)
    (cons (kargu-json-to-record (car object))
          (kargu-json-to-record (cdr object))))
   (t object)))

(defun kargu-seq-to-list (seq)
  "Normalize a JSON array (vector, list, or single value) to a list.
If SEQ is nil, return nil."
  (cond
   ((vectorp seq) (append seq nil))
   ((listp seq) seq)
   (seq (list seq))
   (t nil)))

(defun kargu--json-decode (string)
  "Decode JSON STRING into hash tables with string keys and vectors.
JSON null and false become :json-null and :json-false respectively.
Empty objects and empty arrays retain their distinct wire types."
  (json-parse-string string :object-type 'hash-table :array-type 'array
                     :null-object :json-null :false-object :json-false))

(defun kargu--json-decode-safe (string)
  "Decode JSON STRING, logging failures and returning nil."
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
VALUE retains the explicit JSON object, array or scalar type.
Trailing tokens after the first value (`{}{\"a\":1}`) are not
accepted; use `kargu--json-decode-last-value-checked' for those."
  (let ((s (and (stringp string) (string-trim string))))
    (and s (not (string-empty-p s))
         (kargu--json-whole-string-p s)
         (cons 'ok (kargu--json-decode s)))))

(defun kargu--json-whole-string-p (string)
  "Non-nil when STRING is exactly one JSON value (no trailing tokens)."
  (and (stringp string)
       (let ((s (string-trim string)))
         (and (not (string-empty-p s))
              (condition-case nil
                  (with-temp-buffer
                    (insert s)
                    (goto-char (point-min))
                    (json-parse-buffer)
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
object.  An empty object remains a hash table."
  (when (and (stringp string) (not (string-empty-p (string-trim string))))
    (condition-case nil
        (with-temp-buffer
          (insert string)
          (goto-char (point-min))
          (let (last-start last-end)
            (while (progn (skip-chars-forward " \t\n\r") (not (eobp)))
              (setq last-start (point))
              (json-parse-buffer)
              (setq last-end (point)))
            (when last-start
              (cons 'ok
                    (kargu--json-decode
                     (buffer-substring-no-properties last-start last-end))))))
      (error nil))))

(defun kargu--json-decode-lenient (string)
  "Decode STRING; on concatenated JSON keep the last value.
Return (ok . VALUE) or nil; VALUE retains its JSON type."
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

(defconst kargu--json-max-depth 32
  "Maximum nesting depth for JSON encode and text coerce.")

(defun kargu-json--wire-value (object depth)
  "Validate and copy typed OBJECT at DEPTH for native JSON serialization."
  (when (>= depth kargu--json-max-depth) (error "JSON nesting exceeds depth limit"))
  (cond
   ((hash-table-p object)
    (let ((copy (make-hash-table :test #'equal)))
      (maphash (lambda (key value)
                 (unless (stringp key) (error "JSON object keys must be strings"))
                 (puthash key (kargu-json--wire-value value (1+ depth)) copy)) object)
      copy))
   ((vectorp object)
    (vconcat (mapcar (lambda (value) (kargu-json--wire-value value (1+ depth))) object)))
   ((null object) :json-null)
   ((or (stringp object) (numberp object) (memq object '(t :json-null :json-false))) object)
   (t (error "Ambiguous JSON value; use hash tables and vectors: %S" (type-of object)))))

(defun kargu--json-encode (object)
  "Encode typed JSON OBJECT with the native serializer.
Objects must be string-keyed hash tables and arrays must be vectors.
Lisp lists are refused, not guessed to be objects or arrays."
  (decode-coding-string
   (json-serialize (kargu-json--wire-value object 0)
                   :null-object :json-null :false-object :json-false)
   'utf-8))

(defun kargu-json--record-value (object depth)
  "Convert native record OBJECT at DEPTH to explicit wire types.
Native records declare alists as objects and other lists as arrays.
Arbitrary nested array data must already use vectors."
  (let ((depth (or depth 0)))
    (cond
     ((>= depth kargu--json-max-depth) (error "JSON nesting exceeds depth limit"))
     ((or (eq object :json-empty-object)
          (eq object :empty-object)
          (and (consp object) (eq (car object) :json-empty-object)))
      (make-hash-table :test #'equal))
     ((hash-table-p object) (kargu-json--wire-value object depth))
     ((kargu--object-p object)
      (let ((table (make-hash-table :test #'equal)))
        (dolist (cell object)
          (puthash (if (symbolp (car cell)) (symbol-name (car cell)) (car cell))
                   (kargu-json--record-value (cdr cell) (1+ depth)) table))
        table))
     ((or (vectorp object) (consp object))
      (vconcat (mapcar (lambda (value)
                        (kargu-json--record-value value (1+ depth))) object)))
     (t object))))

(defun kargu-json-encode-record (record)
  "Encode native agent RECORD through the explicit alist adapter.
Use `kargu--json-encode' for typed wire data, not this adapter.
Decoded arrays stay vectors, including string matrices."
  (kargu--json-encode (kargu-json--record-value record 0)))

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
     ((stringp value) (kargu-nonempty value))
     ((numberp value) nil)
     ((>= depth kargu--json-max-depth) "[truncated]")
     ((vectorp value)
      (kargu--coerce-text (append value nil) (1+ depth)))
     ((kargu--object-p value)
      (or (kargu--coerce-text (kargu-aget value "text") (1+ depth))
          (kargu--coerce-text (kargu-aget value "output_text") (1+ depth))
          (kargu--coerce-text (kargu-aget value "summary") (1+ depth))
          (kargu--coerce-text (kargu-aget value "content") (1+ depth))))
     ((listp value)
      (let ((bits (delq nil (mapcar (lambda (elt)
                                      (kargu--coerce-text elt (1+ depth)))
                                    value))))
        (and bits (kargu-nonempty (mapconcat #'identity bits "")))))
     (t nil))))

(defun kargu--content-text (obj)
  "Non-empty plain `content' of OBJ, never reasoning fields."
  (and obj (not (eq obj :json-null))
       (kargu--coerce-text (kargu-aget obj "content"))))

(defun kargu--reasoning-text (obj)
  "Non-empty reasoning / thinking text of OBJ, or nil."
  (when (and obj (not (eq obj :json-null)))
    (or (kargu--coerce-text (kargu-aget obj "reasoning_content"))
        (kargu--coerce-text (kargu-aget obj "reasoning"))
        (kargu--coerce-text (kargu-aget obj "reasoning_details"))
        (kargu--coerce-text (kargu-aget obj "thinking"))
        (kargu--coerce-text (kargu-aget obj "thought")))))

(defun kargu--json-get (obj key)
  "Read KEY from OBJ, also accepting an interned symbol key."
  (or (kargu-aget obj key)
      (and (stringp key) (kargu-aget obj (intern key)))))

(defun kargu--json-decode-object (string)
  "Decode JSON STRING to a typed object with string keys, or nil."
  (kargu--json-decode-safe string))

(defun kargu--provider-error-text (obj)
  "Extract a concise provider error string from decoded JSON OBJ."
  (let ((err (or (and (kargu--object-p obj) (kargu--json-get obj "error"))
                 obj)))
    (cond
     ((null err) nil)
     ((stringp err) (kargu-nonempty err))
     ((not (kargu--object-p err)) nil)
     (t
      (let* ((msg (or (kargu--coerce-text (kargu--json-get err "message"))
                      (kargu--coerce-text (kargu--json-get err "msg"))))
             (code (kargu--json-get err "code"))
             (type (kargu--json-get err "type"))
             (meta (kargu--json-get err "metadata"))
             (meta-text
              (cond
               ((stringp meta) (kargu-nonempty meta))
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

;;; json.el ends here
