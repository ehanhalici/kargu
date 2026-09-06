;;; kargu/providers/fireworks-ai.el --- Fireworks AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Fireworks AI (fireworks-ai).

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
 :id "fireworks-ai"
 :name "Fireworks AI"
 :api "https://api.fireworks.ai/inference/v1"
 :env '("FIREWORKS_API_KEY")
 :models '("accounts/fireworks/routers/kimi-k2p6-turbo" "accounts/fireworks/routers/glm-5p2-fast" "accounts/fireworks/routers/kimi-k2p7-code-fast" "accounts/fireworks/routers/glm-5p1-fast" "accounts/fireworks/routers/kimi-k2p6-fast" "accounts/fireworks/models/deepseek-v4-flash" "accounts/fireworks/models/deepseek-v4-pro" "accounts/fireworks/models/minimax-m2p7" "accounts/fireworks/models/minimax-m3" "accounts/fireworks/models/kimi-k2p6" "accounts/fireworks/models/qwen3p7-plus" "accounts/fireworks/models/glm-5p1" "accounts/fireworks/models/glm-5p2" "accounts/fireworks/models/gpt-oss-120b" "accounts/fireworks/models/gpt-oss-20b")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/fireworks-ai)

;;; fireworks-ai.el ends here
