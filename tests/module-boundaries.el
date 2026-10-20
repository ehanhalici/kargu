;;; module-boundaries.el --- Legacy facade dependency budget -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Existing broad imports are migration debt, not permission for new imports.
;; Remove entries as consumers migrate; never refresh this list to hide drift.

;;; Code:

(defconst kargu-module-test--legacy-dependencies
  '((kargu/core
     kargu/api/catalog
     kargu/api/circuit
     kargu/api/client
     kargu/api/http
     kargu/api/request
     kargu/api/response
     kargu/api/retry
     kargu/api/sse
     kargu/api/stream
     kargu/api/tool-calls
     kargu/api/tools
     kargu/api/wire
     kargu/chat
     kargu/chat/attach
     kargu/chat/complete
     kargu/chat/header
     kargu/chat/prompt
     kargu/chat/select
     kargu/chat/session
     kargu/chat/session/storage
     kargu/chat/transcript
     kargu/chat/tune
     kargu/config/key
     kargu/config/schema
     kargu/history/compact
     kargu/history/protocol
     kargu/history/repair
     kargu/languages/core
     kargu/loop
     kargu/loop/compact
     kargu/loop/heal
     kargu/loop/machine
     kargu/loop/tools
     kargu/loop/ui
     kargu/plan/dispatch
     kargu/prompt
     kargu/providers/registry
     kargu/tools/bash
     kargu/tools/dape/session
     kargu/tools/dape/workspace
     kargu/tools/deps
     kargu/tools/diff
     kargu/tools/diff/review
     kargu/tools/diff/stage
     kargu/tools/diff/track
     kargu/tools/git
     kargu/tools/lsp/context
     kargu/tools/search
     kargu/tools/skill
     kargu/tools/webfetch
     kargu/ui/confirm
     kargu/ui/notify
     kargu/ui/transient)
    (kargu/api
     kargu/chat
     kargu/chat/tune
     kargu/loop
     kargu/loop/compact
     kargu/loop/machine
     kargu/loop/tools
     kargu/loop/ui
     kargu/tools/bash
     kargu/tools/diff
     kargu/tools/git
     kargu/tools/search
     kargu/tools/skill
     kargu/tools/webfetch
     kargu/ui/transient))
  "Exact consumers still allowed to require legacy facade features.")

(provide 'tests/module-boundaries)
;;; module-boundaries.el ends here
