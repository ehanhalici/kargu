;;; kargu/providers/gmicloud.el --- GMI Cloud provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for GMI Cloud (gmicloud).

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
 :id "gmicloud"
 :name "GMI Cloud"
 :api "https://api.gmi-serving.com/v1"
 :env '("GMICLOUD_API_KEY")
 :models '("moonshotai/Kimi-K2.6" "moonshotai/kimi-k2.7-code-highspeed" "Qwen/Qwen3.7-Max" "openai/gpt-5.5" "anthropic/claude-opus-4.7" "anthropic/claude-opus-4.8" "anthropic/claude-sonnet-4.6" "anthropic/claude-opus-4.6" "zai-org/GLM-5.1-FP8" "zai-org/GLM-5-FP8" "zai-org/GLM-5.2-FP8" "deepseek-ai/DeepSeek-V4-Flash" "deepseek-ai/DeepSeek-V4-Pro")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/gmicloud)

;;; gmicloud.el ends here
