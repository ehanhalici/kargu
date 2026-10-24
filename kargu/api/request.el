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

(declare-function kargu-provider-format "kargu/providers/registry" (id))
(declare-function kargu-provider-extra-headers "kargu/providers/registry" (id))
(declare-function kargu-provider-format-auth "kargu/providers/registry" (format))
(declare-function kargu-provider-format-headers "kargu/providers/registry" (format))

(declare-function kargu-provider-cache-marker-p "kargu/providers/registry" (id))

(defun kargu-api-request-tuning (provider model)
  "Capture raw preferences and exact metadata for native PROVIDER/MODEL policy.
No parameter is selected or wire-shaped in the editor."
  (if (kargu-connection-current)
      (kargu-connection-setting :tuning)
    (let ((effort (kargu-selection-effort)))
      (list (cons "temperature" (or kargu-temperature :json-null))
            (cons "max_tokens" (or kargu-max-tokens :json-null))
            (cons "effort" (if effort (format "%s" effort) :json-null))
            (cons "thinking_budget" (or kargu-thinking-budget :json-null))
            (cons "supported_parameters"
                  (if-let* ((parameters (kargu-model-request-parameters model provider)))
                      (vconcat parameters) :json-null))
            (cons "provider_policy"
                  (or (plist-get (kargu-provider-get provider) :request) :json-empty-object))))))

(defun kargu-api-connection-settings (provider model)
  "Capture metadata and raw preferences once for PROVIDER and MODEL."
  (let ((format (kargu-provider-format provider)))
    (list :format format :wire (kargu-provider-format-record format)
          :metadata (and model (kargu-model-get-metadata model provider))
          :fields (kargu-model-read model provider)
          :tools (kargu-model-supports-tools-p model provider)
          :cache-marker (kargu-provider-cache-marker-p provider)
          :tuning (kargu-api-request-tuning provider model)
          :headers (kargu--api-headers "" provider))))

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

(defun kargu--api-provider-format (provider-name)
  "API format symbol for PROVIDER-NAME, or nil."
  (when (and provider-name (fboundp 'kargu-provider-format))
    (kargu-provider-format provider-name)))

(defun kargu--api-auth-headers (key format)
  "Authorization headers for KEY in FORMAT.
The format record's `:auth' selects `x-api-key' or a bearer token.
An empty KEY sends neither."
  (when (kargu-nonempty key)
    (if (eq (if (kargu-connection-current)
                (plist-get (kargu-connection-setting :wire) :auth)
              (kargu-provider-format-auth format)) 'x-api-key)
        `(("x-api-key" . ,key))
      `(("Authorization" . ,(concat "Bearer " key))))))

(defun kargu--api-session-id ()
  "Session id sent in headers that ask for it."
  (if (fboundp 'kargu-session-id) (kargu-session-id) "default"))

(defun kargu--api-default-headers (format expanded)
  "Format-record headers for FORMAT that EXPANDED does not already set."
  (let (out)
    (dolist (pair (kargu-provider-format-headers format))
      (unless (assoc (car pair) expanded)
        (push (kargu--api-expand-header pair (kargu--api-session-id)) out)))
    (nreverse out)))

(defun kargu--api-expand-header (pair session-id)
  "Return header PAIR with a symbolic value filled in.
`:session' becomes SESSION-ID and `:app-url' becomes `kargu-app-url'."
  (pcase (cdr-safe pair)
    (:session (cons (car pair) session-id))
    (:app-url (cons (car pair) kargu-app-url))
    (_ pair)))

(defun kargu--api-headers (key &optional provider-name)
  "HTTP headers for the active or specified PROVIDER-NAME.
KEY is the resolved secret.  An empty KEY omits Authorization so
local or keyless proxies still work.  Auth and extra headers come
from the provider catalog `:format' and `:extra-headers'."
  (if (kargu-connection-current)
      (append (kargu-config-copy (kargu-connection-setting :headers))
              (kargu--api-auth-headers key (kargu-connection-setting :format)))
    (let* ((sid (kargu--api-session-id))
         (pname (if provider-name
                    (format "%s" provider-name)
                  (if (fboundp 'kargu--provider-name) (kargu--provider-name) "")))
         (pname-lower (downcase (string-trim pname)))
         (format (kargu--api-provider-format pname-lower))
         (extra (and (fboundp 'kargu-provider-extra-headers)
                     (kargu-provider-extra-headers pname-lower)))
         (expanded (and (listp extra)
                        (mapcar (lambda (pair)
                                  (kargu--api-expand-header pair sid))
                                extra))))
    (append
     '(("Content-Type" . "application/json"))
     (kargu--api-auth-headers key format)
     (kargu--api-default-headers format expanded)
     expanded))))

(provide 'kargu/api/request)

;;; request.el ends here
