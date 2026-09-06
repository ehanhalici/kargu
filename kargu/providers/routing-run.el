;;; kargu/providers/routing-run.el --- routing.run provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for routing.run (routing-run).

;;; Code:

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

(require 'kargu/providers/registry)

(kargu-register-provider
 :id "routing-run"
 :name "routing.run"
 :api "https://api.routing.run/v1"
 :env '("ROUTING_RUN_API_KEY")
 :models '("kimi-k2.6-nitro" "deepseek-v4-flash" "kimi-k2.7-code" "deepseek-v4-pro" "glm-5.2" "claude-opus-4-8" "gpt-5.6-luna" "gpt-5.6-terra" "glm-5.2-nitro" "kimi-k2.6" "qwen3.5-9b" "claude-sonnet-4-6" "nemotron-3-ultra" "gpt-5.6-sol" "kimi-k2.7-code-nitro")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/routing-run)

;;; routing-run.el ends here
