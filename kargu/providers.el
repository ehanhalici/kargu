;;; kargu/providers.el --- Provider definitions and resolution -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Entry point for kargu provider catalog.
;; Loads the registry and the pre-compiled catalog of 160+ LLM providers.

;;; Code:

(require 'kargu/providers/registry)
(require 'kargu/providers/catalog)
(require 'kargu/providers/params)

(provide 'kargu/providers)

;;; kargu/providers.el ends here
