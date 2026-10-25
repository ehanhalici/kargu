;;; encode.el --- Model command DTO encoding -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Convert editor containers to JSON types, without interpreting metadata.
;; Already-rounded prices/capacities cannot be recovered: callers must provide
;; decimal text or an exact integer.  Rust alone parses those source lexemes.

;;; Code:

(require 'cl-lib)
(require 'json)

(defun kargu-model-encode-name (name)
  "Return a JSON key for string, keyword or symbol NAME, without interning it."
  (cond ((stringp name) name)
        ((keywordp name) (substring (symbol-name name) 1))
        ((symbolp name) (symbol-name name))
        (t (user-error "Kargu: invalid metadata key"))))

(defun kargu-model-encode-value (value &optional field parent depth)
  "Encode captured VALUE in FIELD/PARENT at DEPTH without numeric coercion."
  (let ((depth (or depth 0)))
    (when (>= depth 32) (user-error "Kargu: metadata nesting limit exceeded"))
    (when (and (consp value) (not (proper-list-p value)))
      (user-error "Kargu: metadata containers must be finite JSON objects or arrays"))
    (when (and (floatp value)
               (or (equal parent "pricing")
                   (member field '("input-cost" "output-cost" "context_length" "context_window"
                                   "inputTokenLimit" "context-window" "max_output" "outputTokenLimit"
                                   "max_completion_tokens" "max-output"))))
      (user-error "Kargu: use exact decimal text or an integer for prices and token limits"))
    (cond
     ((memq value '(t :json-null :json-false)) value)
     ((null value) (if (member field '("supports-tools" "supports_tools" "supports-reasoning" "supports_reasoning"))
                       :json-false :json-null))
     ((or (hash-table-p value) (keywordp (car-safe value))
          (and (consp value) (cl-every (lambda (pair) (and (consp pair) (or (stringp (car pair))
                                                                            (and (symbolp (car pair)) (not (keywordp (car pair))))))) value)))
      (let ((object (make-hash-table :test #'equal)))
        (cl-labels ((entry (key item)
                      (let ((key (kargu-model-encode-name key)))
                        (when (gethash key object) (user-error "Kargu: duplicate metadata key"))
                        (puthash key (kargu-model-encode-value item key (or field parent) (1+ depth)) object))))
          (cond
           ((hash-table-p value) (maphash #'entry value))
           ((keywordp (car-safe value))
            (unless (zerop (% (length value) 2)) (user-error "Kargu: invalid metadata plist"))
            (while value (let ((key (pop value))) (entry key (pop value)))))
           (t (dolist (pair value) (entry (car pair) (cdr pair))))))
        object))
     ((or (vectorp value) (listp value))
      (vconcat (mapcar (lambda (item) (kargu-model-encode-value item nil field (1+ depth))) value)))
     ((symbolp value) (symbol-name value))
     ((or (stringp value) (numberp value)) value)
     (t (user-error "Kargu: unsupported metadata JSON type")))))

(defun kargu-model-encode-command (object)
  "Serialize OBJECT as one captured JSON command; never echo it on failure."
  (condition-case nil
      (json-serialize object :null-object :json-null :false-object :json-false)
    (error (user-error "Kargu: invalid model command JSON"))))

(provide 'kargu/models/encode)
;;; encode.el ends here
