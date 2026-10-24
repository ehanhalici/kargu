;;; api.el --- Chat send, models, connection test -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Facade module for the Kargu API subsystem.
;; Requires modular subcomponents under `kargu/api/`:
;;   * `kargu/api/circuit'   -> circuit breaker (:closed, :open, :half-open)
;;   * `kargu/api/http'      -> owned delivery/budget/retry facade for Rust HTTP
;;   * Rust core            -> HTTP, SSE parsing and stream reconstruction
;;   * `kargu/api/response'  -> OpenAI chat-completion response decoding
;;   * `kargu/api/tools'     -> tool-call JSON encoding and schema conversion
;;   * `kargu/api/catalog'   -> dynamic model catalog querying, caching, metadata
;;   * `kargu/api/client'    -> high-level send, cancel, and ping operations
;; Selection commands autoload their separate chat adapter when called.
;;
;; Public API:
;;   `kargu-api-send', `kargu-api-cancel', `kargu-api-list-models',
;;   `kargu-set-model', `kargu-test-connection', `kargu-model-info',
;;   `kargu-model-get-prop', `kargu-model-set-prop', `kargu-model-edit-prop'.

;;; Code:

(require 'kargu/api/circuit)
(require 'kargu/api/http)
(require 'kargu/api/response)
(require 'kargu/api/tools)
(require 'kargu/api/catalog)
(require 'kargu/api/client)

(autoload 'kargu-set-model "kargu/api/select" nil t)
(autoload 'kargu-switch-provider-and-model "kargu/api/select" nil t)
(autoload 'kargu-chat-select-provider "kargu/api/select" nil t)
(autoload 'kargu-chat-select-mode-company "kargu/api/select" nil t)
(autoload 'kargu-chat-select-provider-company "kargu/api/select" nil t)
(autoload 'kargu-chat-select-model-company "kargu/api/select" nil t)
(autoload 'kargu-chat-select-effort-company "kargu/api/select" nil t)
(autoload 'kargu-api-select "kargu/api/select")

(provide 'kargu/api)

;;; api.el ends here
