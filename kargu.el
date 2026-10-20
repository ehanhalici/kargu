;;; kargu.el --- Agentic AI development assistant for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (plz "0.9"))
;; Keywords: tools, convenience, ai, lsp, debug
;; URL: https://github.com/kargu/kargu

;; This file is not part of GNU Emacs.

;;; Commentary:

;; kargu is an agentic AI coding assistant that turns Emacs
;; itself into the agent runtime.  Instead of shipping a heavyweight
;; indexing daemon like the commercial AI editors, it reuses the
;; packages you already run every day:
;;
;;   * eglot     -> zero-token workspace skeleton, diagnostics and
;;                  symbol lookup tools (the model "sees" your
;;                  project without reading every file)
;;   * dape      -> live call-stack, in-scope variables and
;;                  expression evaluation from a paused DAP session
;;   * magit     -> Git interface, status inspection, and repository tools
;;   * ediff     -> hunk-by-hunk human approval of every AI edit,
;;                  with full rollback
;;   * transient -> the interactive command menu
;;   * plz       -> fully asynchronous HTTP (with SSE streaming);
;;                  the UI thread is never blocked
;;
;; Entry point is `(require 'kargu)' / `M-x kargu-menu'.  Nested
;; files are Magit-style features: `(require 'kargu/loop/machine)'
;; loads `kargu/loop/machine.el'.  Submodules require `kargu/core',
;; not `kargu'.  Only this file puts the package root on `load-path';
;; byte-compile nested files with `-L <package root>'.
;; Load order:
;;
;;   kargu.el                 package header, load-path, requires
;;   kargu/core.el            defgroup, session, log
;;   kargu/config.el          TOML, provider, API key
;;   kargu/json.el            decode/encode (depth 32)
;;   kargu/prompt.el          system prompt parts
;;   kargu/history.el         queue + firewall
;;   kargu/history/compact.el threshold, tail, apply
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

(declare-function kargu-ui-confirm-install "kargu/ui/confirm" ())
(declare-function kargu-diff-install "kargu/tools/diff" ())
(declare-function kargu-chat-plan-install "kargu/chat/plan" ())

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
(require 'kargu/contract/constants)
(require 'kargu/contract/result)
(require 'kargu/contract)
(require 'kargu/state)
(require 'kargu/permission)
(require 'kargu/providers)
(require 'kargu/config)
(require 'kargu/json)
(require 'kargu/tools/process)
(require 'kargu/tools/toolchain)
(require 'kargu/prompt)
(require 'kargu/history)
(require 'kargu/history/compact)
(require 'kargu/fs)
(require 'kargu/api/circuit)
(require 'kargu/api)
(require 'kargu/tools/deps)

;; Tool implementations expose definitions; only composition activates them.
(dolist (adapter '((kargu/tools/lsp . kargu-lsp-register-tools)
                   (kargu/tools/search . kargu-search-register-tools)
                   (kargu/tools/dape . kargu-dape-register-tools)
                   (kargu/files . kargu-file-register-tools)
                   (kargu/tools/diff . kargu-diff-register-tools)
                   (kargu/tools/bash . kargu-bash-register-tools)
                   (kargu/tools/git . kargu-git-register-tools)
                   (kargu/tools/skill . kargu-skill-register-tools)
                   (kargu/tools/webfetch . kargu-webfetch-register-tools)))
  (when (require (car adapter) nil t)
    (funcall (cdr adapter))))

(when (featurep 'kargu/tools/diff) (kargu-diff-install))

(when (and kargu-ui-enabled (require 'kargu/ui/confirm nil t))
  (kargu-ui-confirm-install))
(require 'kargu/loop)
(when (and kargu-ui-enabled (require 'kargu/chat nil t))
  (require 'company nil t)
  (when (require 'kargu/plan nil t)
    (require 'kargu/chat/plan)
    (kargu-chat-plan-install))
  (require 'kargu/ui nil t))

(provide 'kargu)

;;; kargu.el ends here
