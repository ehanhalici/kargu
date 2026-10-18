;;; lsp.el --- LSP tools via Eglot -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Compatibility entry point for context, symbols, diagnostics and tools.

;;; Code:

(require 'kargu/tools/lsp/context)
(require 'kargu/tools/lsp/skeleton)
(require 'kargu/tools/lsp/diagnostics)
(require 'kargu/tools/lsp/symbols)
(require 'kargu/tools/lsp/register)



(provide 'kargu/tools/lsp)

;;; lsp.el ends here
