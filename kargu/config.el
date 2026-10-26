;;; config.el --- TOML config, provider, API key -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Facade module for the Kargu configuration subsystem.
;; Requires modular subcomponents under `kargu/config/`:
;;   * `kargu/bridge/config'     -> bounded native file/TOML/schema port
;;   * `kargu/bridge/config-policy' -> owned native publication and selection
;;   * `kargu/config/key'        -> passive native DTO readers
;;   * `kargu/config/schema'     -> UI intent and setup verification
;;   * `kargu/config/worker'     -> cancellable background credential worker
;;   * `kargu/config/connection' -> immutable connection snapshot and lifecycle
;;
;; Public API:
;;   `kargu-config-file', `kargu-edit-config', `kargu-set-provider', `kargu-check-setup',
;;   `kargu-connection-resolve-async', `kargu-connection-redacted-summary'.

;;; Code:

(require 'kargu/config/key)
(require 'kargu/config/schema)
(require 'kargu/config/worker)
(require 'kargu/config/connection)

(provide 'kargu/config)

;;; config.el ends here
