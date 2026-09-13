;;; kargu/api.el --- Chat send, models, connection test -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Facade module for the Kargu API subsystem.
;; Requires modular subcomponents under `kargu/api/`:
;;   * `kargu/api/circuit'   -> circuit breaker (:closed, :open, :half-open)
;;   * `kargu/api/http'      -> asynchronous HTTP transport via plz
;;   * `kargu/api/stream'    -> SSE streaming parser and accumulator
;;   * `kargu/api/response'  -> OpenAI chat-completion response decoding
;;   * `kargu/api/tools'     -> tool-call JSON encoding and schema conversion
;;   * `kargu/api/catalog'   -> dynamic model catalog querying, caching, metadata
;;   * `kargu/api/select'    -> interactive Company selection popups at point
;;   * `kargu/api/client'    -> high-level send, cancel, and ping operations
;;
;; Public API:
;;   `kargu-api-send', `kargu-api-cancel', `kargu-api-list-models',
;;   `kargu-set-model', `kargu-test-connection', `kargu-model-info'.

;;; Code:

;; Ensure the package root is on `load-path' during compilation.
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

(require 'kargu/api/circuit)
(require 'kargu/api/http)
(require 'kargu/api/stream)
(require 'kargu/api/response)
(require 'kargu/api/tools)
(require 'kargu/api/catalog)
(require 'kargu/api/select)
(require 'kargu/api/client)

(provide 'kargu/api)

;;; kargu/api.el ends here
