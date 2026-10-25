;;; store.el --- Native model publication facade -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Explicit updates capture one application's async native publication ticket.
;; Readers select detached fields from its last committed view, never a second
;; model store, alias resolver or override engine.

;;; Code:

(require 'kargu/bridge/models)
(require 'kargu/models/projection)
(require 'kargu/models/encode)

(declare-function kargu-provider-effort-specs "kargu/providers/registry" (id))

(defun kargu-model-store--provider (provider)
  "Encode explicit PROVIDER for its native identity boundary."
  (unless (and provider (or (stringp provider) (symbolp provider)))
    (user-error "Kargu: model metadata requires a provider"))
  (downcase (string-trim (format "%s" provider))))

(defun kargu-model-store--report (_view failure)
  "Report asynchronous publication FAILURE without echoing metadata."
  (when failure (message "Kargu: native model metadata update failed")))

(cl-defun kargu-model-store-submit (provider command &optional callback &key owner valid-p)
  "Capture COMMAND for PROVIDER and return its native publication ticket.
CALLBACK receives (VIEW FAILURE) once.  OWNER and VALID-P guard the producer."
  (let* ((provider (kargu-model-store--provider provider))
         (specs (and (fboundp 'kargu-provider-effort-specs) (kargu-provider-effort-specs provider))))
    (kargu-bridge-models-publish
     (kargu-application-context) provider (kargu-model-encode-command command)
     (if specs (kargu-model-encode-value specs) [])
     (kargu-application-wrap (kargu-application-context) (or callback #'kargu-model-store--report))
     :owner owner :valid-p valid-p)))

(cl-defun kargu-model-store-get (provider id &key exact)
  "Detach ID's last committed metadata under PROVIDER; EXACT refuses aliases."
  (when (and (stringp id) (not (string-empty-p (string-trim id))))
    (when-let* ((entry (kargu-model-projection--entry
                        (kargu-model-projection--view) (kargu-model-store--provider provider)
                        (string-trim id) exact)))
      (kargu-json-to-record (kargu-bridge-models--copy (gethash "metadata" entry))))))

(defun kargu-model-store-settings (provider id &optional view omit-metadata)
  "Detach PROVIDER/ID's fields from immutable VIEW or its UI observation.
OMIT-METADATA avoids copying inspector text in frequently read UI fields."
  (kargu-model-projection-connection (or view (kargu-model-projection--view))
                                     (kargu-model-store--provider provider) id omit-metadata))

(defun kargu-model-store-put (provider id data &optional callback)
  "Capture DATA for PROVIDER's ID; CALLBACK receives (VIEW FAILURE)."
  (kargu-model-store-submit
   provider (kargu-bridge--object "operation" "put" "model" id "metadata"
                                  (if data (kargu-model-encode-value data) (make-hash-table :test #'equal)))
   callback))

(cl-defun kargu-model-store-set-property (provider id &key property value callback owner)
  "Capture PROPERTY/VALUE override for PROVIDER's ID; report via CALLBACK.
Rust resolves aliases and preserves overrides across refreshes.
OWNER guards the inspector's lifetime."
  (let ((property (kargu-model-encode-name property)))
    (kargu-model-store-submit
     provider (kargu-bridge--object "operation" "override" "model" id "property" property
                                    "value" (kargu-model-encode-value value property))
     callback :owner owner)))

(provide 'kargu/models/store)
;;; store.el ends here
