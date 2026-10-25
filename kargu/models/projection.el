;;; projection.el --- Passive canonical native model views -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Select native DTOs and detach UI/connection fields.  No metadata parsing,
;; alias inference, override merging, pricing arithmetic or RPC occurs here.

;;; Code:

(require 'kargu/bridge/models/state)
(require 'kargu/json)

(defun kargu-model-projection--find (records provider id key)
  "Read the native RECORDS entry with PROVIDER and ID in KEY."
  (cl-find-if (lambda (record)
                (and (equal (gethash "provider" record) provider)
                     (equal (gethash key record) id))) records))

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

(defun kargu-model-projection-connection (view provider model)
  "Capture one native VIEW's settings for explicit PROVIDER and MODEL.
Display aliases may select metadata.  Request parameters require exact IDs."
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
          :metadata (when entry (kargu-json-to-record (kargu-bridge-models--copy (gethash "metadata" entry))))
          :fields (kargu-model-projection-fields (or entry defaults))
          :tools (eq (gethash "tools" (or refusal alias entry defaults)) t)
          :supported-parameters (if (and parameters (equal (gethash "state" parameters) "known"))
                                    (kargu-bridge-models--copy (gethash "value" parameters)) :json-null))))

(provide 'kargu/models/projection)
;;; projection.el ends here
