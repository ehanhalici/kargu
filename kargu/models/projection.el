;;; projection.el --- Passive canonical native model views -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Select native DTOs and detach UI/connection fields.  No metadata parsing,
;; alias inference, override merging, pricing arithmetic or RPC occurs here.

;;; Code:

(require 'kargu/bridge/models/state)
(require 'kargu/json)
(require 'seq)

(defconst kargu-model-projection--bootstrap
  (let ((cell (make-symbol "kargu-empty-native-models"))
        (path (expand-file-name "../../kargu-core/assets/models-empty.json"
                                (file-name-directory (or load-file-name buffer-file-name)))))
    (unless (and (file-regular-p path) (<= (file-attribute-size (file-attributes path)) 16384))
      (error "Missing or oversized native model bootstrap"))
    (with-temp-buffer
      (insert-file-contents path)
      (put cell 'value (json-parse-buffer :object-type 'hash-table :array-type 'array
                                          :null-object :json-null :false-object :json-false)))
    cell)
  "Private native unknown-model projection, checked against Rust by its tests.")

(defun kargu-model-projection--view (&optional application)
  "Borrow APPLICATION's last committed UI view, or the native offline bootstrap.
This internal reader does not authorize a connection, start a core or repair
an uncertain lease.  External callers must receive detached selected fields."
  (let* ((app (or application (kargu-application-context)))
         (service (gethash :native-models (kargu-application-services app))))
    (or (and service (kargu-bridge-models--view service))
        (get kargu-model-projection--bootstrap 'value))))

(defvar kargu-model-projection--indexes (make-hash-table :test #'eq :weakness 'key)
  "Private exact DTO indexes; discarded views never become retained authorities.")

(defun kargu-model-projection--find (records provider id key)
  "Read native RECORDS by PROVIDER/ID in KEY without rescanning each UI row.
Indexes contain only supplied DTO identities, never inferred aliases/policy."
  (when (vectorp records)
    (let* ((indexes (or (gethash records kargu-model-projection--indexes)
                        (puthash records (make-hash-table :test #'equal) kargu-model-projection--indexes)))
           (index (or (gethash key indexes)
                      (let ((index (make-hash-table :test #'equal)))
                        (seq-doseq (record records)
                          (puthash (cons (gethash "provider" record) (gethash key record)) record index))
                        (puthash key index indexes)))))
      (gethash (cons provider id) index))))

(defun kargu-model-projection--entry (view provider model &optional exact)
  "Borrow VIEW's canonical PROVIDER/MODEL entry; EXACT refuses display aliases."
  (let ((records (gethash "records" view)))
    (or (kargu-model-projection--find records provider model "id")
        (unless exact
          (when-let* ((alias (kargu-model-projection--find (gethash "aliases" view) provider model "alias")))
            (kargu-model-projection--find records provider (gethash "id" alias) "id"))))))

(defun kargu-model-projection-fields (entry)
  "Detach ENTRY's already normalized display plist, preserving unknown values."
  (let ((display (gethash "display" entry)))
    (unless (hash-table-p display) (error "Invalid native model display projection"))
    (list :context-window (let ((value (gethash "context-window" display))) (unless (eq value :json-null) value))
          :max-output (let ((value (gethash "max-output" display))) (unless (eq value :json-null) value))
          :reasoning-efforts (let ((value (gethash "reasoning-efforts" display)))
                               (and (vectorp value) (append (kargu-bridge-models--copy value) nil)))
          :vision (eq (gethash "vision" display) t)
          :free (eq (gethash "free" display) t)
          :params (let ((value (gethash "params" display)))
                    (unless (eq value :json-null) (kargu-bridge-models--copy value)))
          :input-cost (let ((value (gethash "input-cost" display)))
                        (unless (eq value :json-null) (kargu-bridge-models--copy value)))
          :price-label (let ((value (gethash "price-label" display)))
                         (unless (eq value :json-null) (kargu-bridge-models--copy value))))))

(defun kargu-model-projection-connection (view provider model &optional omit-metadata)
  "Capture one native VIEW's settings for explicit PROVIDER and MODEL.
Display aliases may select metadata.  Request parameters require exact IDs.
OMIT-METADATA skips copying large inspector text for UI field reads."
  (let* ((provider (downcase (string-trim provider)))
         (model (string-trim (or model "")))
         (exact (kargu-model-projection--entry view provider model t))
         (entry (or exact (kargu-model-projection--entry view provider model)))
         (defaults (gethash "defaults" view))
         (refusal (kargu-model-projection--find (gethash "refusals" view) provider model "id"))
         (alias (unless exact (kargu-model-projection--find (gethash "aliases" view) provider model "alias")))
         (parameters (and exact (gethash "supported_parameters" (gethash "fields" exact)))))
    (unless (and (hash-table-p defaults) (hash-table-p (gethash "display" defaults)))
      (error "Native model defaults unavailable; rebuild kargu-core"))
    (list :metadata-revision (gethash "revision" view)
          :metadata (when (and entry (not omit-metadata))
                      (kargu-json-to-record (kargu-bridge-models--copy (gethash "metadata" entry))))
          :fields (kargu-model-projection-fields (or entry defaults))
          :tools (eq (gethash "tools" (or refusal alias entry defaults)) t)
          :reasoning (eq (gethash "reasoning" (or entry defaults)) t)
          :supported-parameters (if (and parameters (equal (gethash "state" parameters) "known"))
                                    (kargu-bridge-models--copy (gethash "value" parameters)) :json-null))))

(provide 'kargu/models/projection)
;;; projection.el ends here
