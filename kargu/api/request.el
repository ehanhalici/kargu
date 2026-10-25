;;; request.el --- Chat request payload and headers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Build transport-independent request data from the provider catalog.

;;; Code:

(require 'kargu/core)
(require 'kargu/contract/result)
(require 'kargu/application/budget)
(require 'kargu/config)
(require 'kargu/history)
(require 'kargu/api/tools)
(require 'kargu/models/store)

(declare-function kargu-provider-format "kargu/providers/registry" (id))
(declare-function kargu-provider-extra-headers "kargu/providers/registry" (id))
(declare-function kargu-model-get-metadata "kargu/api/catalog" (id &optional provider))
(declare-function kargu-model-read "kargu/api/catalog" (&optional model-id provider))
(declare-function kargu-model-request-parameters "kargu/api/catalog" (model-id provider))
(declare-function kargu-model-supports-tools-p "kargu/api/catalog" (&optional model-id provider))

(declare-function kargu-provider-cache-marker-p "kargu/providers/registry" (id))

(defun kargu-api-request-tuning (provider model &optional supported-parameters)
  "Capture raw preferences and exact metadata for native PROVIDER/MODEL policy.
SUPPORTED-PARAMETERS supplies metadata for a new settings capture.
No parameter is selected or wire-shaped in the editor."
  (if (kargu-connection-current)
      (kargu-connection-setting :tuning)
    (let ((effort (kargu-selection-effort)))
      (list (cons "temperature" (or kargu-temperature :json-null))
            (cons "max_tokens" (or kargu-max-tokens :json-null))
            (cons "effort" (if effort (format "%s" effort) :json-null))
            (cons "thinking_budget" (or kargu-thinking-budget :json-null))
            (cons "supported_parameters"
                  (or supported-parameters
                      (if-let* ((parameters (kargu-model-request-parameters model provider)))
                          (vconcat parameters) :json-null)))
            (cons "provider_policy"
                  (or (plist-get (kargu-provider-get provider) :request) :json-empty-object))))))

(defun kargu-api-connection-settings (provider model &optional metadata-view)
  "Capture PROVIDER/MODEL settings from immutable native METADATA-VIEW.
Without an explicit view, only the last committed UI observation is read.
Real connection preparation supplies its captured native ticket's receipt."
  (let* ((format (kargu-provider-format provider))
         (projection (kargu-model-store-settings provider model metadata-view))
               (tuning (kargu-config-copy (kargu-api-request-tuning
                                           provider model (plist-get projection :supported-parameters)))))
          (setcdr (assoc "supported_parameters" tuning) (plist-get projection :supported-parameters))
          (append projection
                  (list :format format :wire (kargu-provider-format-record format)
                        :cache-marker (kargu-provider-cache-marker-p provider)
                  :tuning tuning :header-overrides (kargu-provider-extra-headers provider)))))

(defun kargu--payload-merge (payload extra)
  "Merge EXTRA entries into PAYLOAD, replacing keys already present."
  (append (seq-remove (lambda (cell) (assoc (car cell) extra)) payload)
          extra))


(defun kargu--payload-tools-entries (tools)
  "Return canonical TOOLS entries without evaluating native cache policy."
  (when (> (length tools) 0)
    `(("tools" . ,tools)
      ("tool_choice" . "auto"))))

(defun kargu--build-payload (&rest extra)
  "Assemble the chat-completions request payload.
EXTRA is a list of additional (KEY . VALUE) conses that replace or add
entries (e.g. (\"stream\" . t)).  The \"tools\" array is only included when
at least one tool is VISIBLE after `kargu--tools-visible-p' filtering."
  (kargu-api-build-payload (kargu-history-context) extra))

(defun kargu-api-build-payload (history &optional extra)
  "Build a payload snapshot from HISTORY and optional EXTRA entries."
  (let* ((tools (kargu--build-tools-vector))
         (messages (kargu-history-snapshot history))
         (payload
          (append
           `(("model" . ,(kargu--model))
             ("messages" . ,(vconcat messages)))
           (kargu--payload-tools-entries tools))))
    (kargu--payload-merge payload extra)))

(defun kargu-api-auth-intent (key &optional provider)
  "Capture raw KEY and header bindings for native auth at PROVIDER.
The editor resolves credentials; Rust chooses and constructs HTTP headers."
  (let ((overrides (if (kargu-connection-current)
                       (kargu-connection-setting :header-overrides)
                     (kargu-provider-extra-headers (or provider (kargu--provider-name))))))
    (list (cons "key" (or key :json-null))
          (cons "extra_headers" (or overrides :json-empty-object))
          (cons "session" (if (fboundp 'kargu-session-id) (kargu-session-id) "default"))
          (cons "app_url" kargu-app-url))))

(provide 'kargu/api/request)

;;; request.el ends here
