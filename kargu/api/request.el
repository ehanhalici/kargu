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
(require 'kargu/api/cache)
(require 'kargu/api/parameters)

(declare-function kargu-provider-format "kargu/providers/registry" (id))
(declare-function kargu-provider-extra-headers "kargu/providers/registry" (id))
(declare-function kargu-provider-format-auth "kargu/providers/registry" (format))
(declare-function kargu-provider-format-headers "kargu/providers/registry" (format))

(declare-function kargu-provider-cache-marker-p "kargu/providers/registry" (id))
(declare-function kargu-provider-reasoning-shape "kargu/providers/registry" (id))


(defun kargu-reasoning-effort-level ()
  "The reasoning effort to send as a string, or nil to send none.
The effective owned choice inherits `kargu-reasoning-effort' by default.
Values nil, \"off\" and the
empty string mean the user chose no effort.  \"none\" is a real level
that some models accept, so it is sent."
  (let* ((selected (kargu-selection-effort))
         (effort (and selected (string-trim (format "%s" selected)))))
    (and effort
         (not (member (downcase effort) '("" "nil" "off")))
         effort)))

(defun kargu-reasoning-budget ()
  "The thinking token budget when it is a positive integer, else nil."
  (and (integerp kargu-thinking-budget)
       (> kargu-thinking-budget 0)
       kargu-thinking-budget))

(defun kargu--build-reasoning-params (&optional provider)
  "Request entries for effort and thinking budget in PROVIDER's wire shape.
The shape comes from the provider's format record (`:reasoning-shape')."
  (let ((effort (kargu-reasoning-effort-level))
        (budget (kargu-reasoning-budget))
        (shape (if (fboundp 'kargu-provider-reasoning-shape)
                   (kargu-provider-reasoning-shape
                    (or provider (kargu--provider-name)))
                 'effort)))
    (pcase shape
      ('thinking
       (and budget
            `(("thinking" . (("type" . "enabled")
                             ("budget_tokens" . ,budget))))))
      ('nested
       (let ((nested (append (and effort `(("effort" . ,effort)))
                             (and budget `(("max_tokens" . ,budget))))))
         (and nested `(("reasoning" . ,nested)))))
      (_ (and effort `(("reasoning_effort" . ,effort)))))))

(defun kargu--payload-merge (payload extra)
  "Merge EXTRA entries into PAYLOAD, replacing keys already present."
  (append (seq-remove (lambda (cell) (assoc (car cell) extra)) payload)
          extra))

(defun kargu--payload-sampling-entries ()
  "Request entries for temperature and the output token cap."
  (kargu-api-request-parameters :model (kargu--model) :provider (kargu--provider-name)
                               :temperature kargu-temperature :max-tokens kargu-max-tokens))

(defun kargu--payload-tools-entries (tools cache-marked)
  "Request entries for the TOOLS vector; none when it is empty.
CACHE-MARKED puts a cache marker on the last tool."
  (when (> (length tools) 0)
    `(("tools" . ,(if cache-marked (kargu-cache-prepare-tools tools) tools))
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
         (cache-marked (kargu-provider-cache-marker-p
                        (downcase (string-trim (format "%s" (kargu--provider-name))))))
         (messages (kargu-history-snapshot history))
         (payload
          (append
           `(("model" . ,(kargu--model))
             ("messages" . ,(vconcat (if cache-marked
                                         (kargu-cache-prepare-messages messages)
                                       messages))))
           (kargu--payload-sampling-entries)
           (kargu--payload-tools-entries tools cache-marked))))
    (dolist (entries (list (kargu--build-reasoning-params)
                           extra))
      (setq payload (kargu--payload-merge payload entries)))
    (when (and (assoc "max_tokens" payload) (assoc "max_completion_tokens" payload))
      (user-error "Kargu: request cannot contain both output token-limit fields"))
    payload))

(defun kargu--api-provider-format (provider-name)
  "API format symbol for PROVIDER-NAME, or nil."
  (when (and provider-name (fboundp 'kargu-provider-format))
    (kargu-provider-format provider-name)))

(defun kargu--api-auth-headers (key format)
  "Authorization headers for KEY in FORMAT.
The format record's `:auth' selects `x-api-key' or a bearer token.
An empty KEY sends neither."
  (when (kargu-nonempty key)
    (if (eq (kargu-provider-format-auth format) 'x-api-key)
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
     expanded)))

(provide 'kargu/api/request)

;;; request.el ends here
