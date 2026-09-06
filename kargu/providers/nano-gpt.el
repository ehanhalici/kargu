;;; kargu/providers/nano-gpt.el --- NanoGPT provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for NanoGPT (nano-gpt).

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
 :id "nano-gpt"
 :name "NanoGPT"
 :api "https://nano-gpt.com/api/v1"
 :env '("NANO_GPT_API_KEY")
 :models '("step-3" "qwen3.5-35b-a3b:thinking" "glm-4.1v-thinking-flashx" "ernie-x1.1-preview" "qwen25-vl-72b-instruct" "gemini-2.0-pro-exp-02-05" "doubao-seed-2-0-lite-260215" "Qwen3.5-27B-Writer-V2-Derestricted" "claude-opus-4-thinking:8192" "qwen3-vl-235b-a22b-thinking" "glm-4-air-0111" "Qwen3.5-27B-Queen-Derestricted" "gemini-2.5-pro-preview-03-25" "brave-research" "qwen-plus")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/nano-gpt)

;;; nano-gpt.el ends here
