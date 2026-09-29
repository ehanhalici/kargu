;;; kargu/contract.el --- Ingress contract validation and invariants -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Contract-driven ingress validation engine.
;; Facade module requiring the contract submodules under `kargu/contract/`.

;;; Code:

(require 'kargu/contract/constants)
(require 'kargu/contract/result)
(require 'kargu/contract/types)
(require 'kargu/contract/assert)

(provide 'kargu/contract)

;;; kargu/contract.el ends here
