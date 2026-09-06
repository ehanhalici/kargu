;;; kargu/providers/nearai.el --- NEAR AI Cloud provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for NEAR AI Cloud (nearai).

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
 :id "nearai"
 :name "NEAR AI Cloud"
 :api "https://cloud-api.near.ai/v1"
 :env '("NEARAI_API_KEY")
 :models '("google/gemini-3.1-flash-lite" "google/gemma-4-31B-it" "google/gemini-2.5-pro" "google/gemini-2.5-flash" "google/gemini-3.5-flash" "google/gemini-3-pro" "google/gemini-2.5-flash-lite" "Qwen/Qwen3-Embedding-0.6B" "Qwen/Qwen3-Reranker-0.6B" "Qwen/Qwen3.6-35B-A3B-FP8" "Qwen/Qwen3.5-122B-A10B" "Qwen/Qwen3-30B-A3B-Instruct-2507" "Qwen/Qwen3-VL-30B-A3B-Instruct" "openai/o3" "openai/gpt-5")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/nearai)

;;; nearai.el ends here
