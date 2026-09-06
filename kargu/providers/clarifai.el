;;; kargu/providers/clarifai.el --- Clarifai provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Clarifai (clarifai).

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
 :id "clarifai"
 :name "Clarifai"
 :api "https://api.clarifai.com/v2/ext/openai/v1"
 :env '("CLARIFAI_PAT")
 :models '("moonshotai/chat-completion/models/Kimi-K2_6" "minimaxai/chat-completion/models/MiniMax-M2_5-high-throughput" "openai/chat-completion/models/gpt-oss-120b-high-throughput" "openai/chat-completion/models/gpt-oss-20b" "mistralai/completion/models/Ministral-3-14B-Reasoning-2512" "mistralai/completion/models/Ministral-3-3B-Reasoning-2512" "deepseek-ai/deepseek-ocr/models/DeepSeek-OCR" "qwen/qwenLM/models/Qwen3-30B-A3B-Thinking-2507" "qwen/qwenLM/models/Qwen3-30B-A3B-Instruct-2507" "qwen/qwenCoder/models/Qwen3-Coder-30B-A3B-Instruct" "arcee_ai/AFM/models/trinity-mini" "clarifai/main/models/mm-poly-8b")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/clarifai)

;;; clarifai.el ends here
