;;; kargu.el --- Agentic AI development assistant for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (plz "0.9") (transient "0.7") (lsp-mode "8.0") (dape "0.10"))
;; Keywords: tools, convenience, ai, lsp, debug
;; URL: https://github.com/kargu/kargu

;; This file is not part of GNU Emacs.

;;; Commentary:

;; kargu is an agentic AI coding assistant that turns Emacs
;; itself into the agent runtime.  Instead of shipping a heavyweight
;; indexing daemon like the commercial AI editors, it reuses the
;; packages you already run every day:
;;
;;   * lsp-mode  -> zero-token workspace skeleton, diagnostics and
;;                  symbol lookup tools (the model "sees" your
;;                  project without reading every file)
;;   * dape      -> live call-stack, in-scope variables and
;;                  expression evaluation from a paused DAP session
;;   * ediff     -> hunk-by-hunk human approval of every AI edit,
;;                  with full rollback
;;   * transient -> the interactive command menu
;;   * plz       -> fully asynchronous HTTP (with SSE streaming);
;;                  the UI thread is never blocked
;;
;; Entry point is `(require 'kargu)' / `M-x kargu-menu'.  Nested
;; files are Magit-style features: `(require 'kargu/loop/machine)'
;; loads `kargu/loop/machine.el'.  Submodules require `kargu/core',
;; not `kargu'.  Each nested file puts the package root (the
;; directory that contains `kargu.el') on `load-path' so byte-comp
;; and native-comp work when Emacs compiles from a subdirectory.
;; Load order:
;;
;;   kargu.el                 package header, load-path, requires
;;   kargu/core.el            defgroup, session, log
;;   kargu/config.el          TOML, provider, API key
;;   kargu/json.el            decode/encode (depth 32)
;;   kargu/prompt.el          system prompt parts
;;   kargu/history.el         queue + firewall
;;   kargu/history-compact.el threshold, tail, apply
;;   kargu/fs.el              skip-dirs + bounded walk
;;   kargu/api.el             send, cancel, models
;;   kargu/api/*.el           response, tools, http, stream
;;   kargu/prompt/*.txt       provider-specific base prompts
;;   kargu/tools/*.el         search, lsp, dape, diff, bash, skill, webfetch
;;   kargu/loop.el            run plist, send/stop
;;   kargu/loop/*.el          machine, compact, tools, heal
;;   kargu/chat.el            buffer, send, sidebar
;;   kargu/chat/*.el          @ company, synthetic Read
;;   kargu/ui.el              transient menu
;;
;; API key resolution order:
;;   1. `kargu-api-key' (defcustom override)
;;   2. active provider `apikey' in local TOML
;;      (~/.config/kargu/config.toml or ~/.emacs.d/kargu.toml)
;;   3. environment (OPENROUTER_API_KEY / OPENAI_API_KEY by host)
;;   4. auth-source, host taken from the provider `api' URL
;;
;; Quick start:
;;
;;   (add-to-list 'load-path "/path/to/kargu/")
;;   (require 'kargu)
;;   M-x kargu-edit-config            ; create/edit the local TOML
;;   M-x kargu-check-setup            ; verify key + packages
;;   M-x kargu-set-provider           ; pick a TOML [providers.*] table
;;   M-x kargu-set-model              ; pick from that provider's models
;;   M-x kargu-test-connection        ; ping the active endpoint
;;   M-x kargu-menu                   ; main entry point (ui.el)

;;; Code:

;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory (Magit-style kargu/core features).
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

(require 'kargu/core)
(require 'kargu/constants)
(require 'kargu/result)
(require 'kargu/contract)
(require 'kargu/permission)
(require 'kargu/providers)
(require 'kargu/config)
(require 'kargu/json)
(require 'kargu/tools/toolchain)
(require 'kargu/prompt)
(require 'kargu/history)
(require 'kargu/history/compact)
(require 'kargu/history-compact)
(require 'kargu/fs)
(require 'kargu/api/circuit)
(require 'kargu/api)
(require 'kargu/tools/lsp)
(require 'kargu/tools/search)
(require 'kargu/tools/dape)
(require 'kargu/tools/diff)
(require 'kargu/tools/bash)
(require 'kargu/tools/git)
(require 'kargu/tools/skill)
(require 'kargu/tools/webfetch)
(require 'kargu/loop)
(require 'kargu/chat)
(require 'kargu/plan)
(require 'kargu/ui)

(provide 'kargu)

;;; kargu.el ends here
