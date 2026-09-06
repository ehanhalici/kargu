;;; kargu/providers/frogbot.el --- FrogBot provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for FrogBot (frogbot).

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
 :id "frogbot"
 :name "FrogBot"
 :api "https://app.frogbot.ai/api/v1"
 :env '("FROGBOT_API_KEY")
 :models '("minimax-m2-5" "kimi-k2-6" "zai-glm-5-1" "grok-code-fast-1" "gemini-2.5-pro" "gemini-2.5-flash" "gpt-4o" "qwen-3-6-plus" "grok-4-3" "deepseek-v4-pro" "claude-opus-4-7" "grok-4-1-fast-non-reasoning" "minimax-m2-7" "gpt-5-3-codex" "gpt-5-4-nano")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/frogbot)

;;; frogbot.el ends here
