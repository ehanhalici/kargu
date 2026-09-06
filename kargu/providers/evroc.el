;;; kargu/providers/evroc.el --- evroc provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for evroc (evroc).

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
 :id "evroc"
 :name "evroc"
 :api "https://models.think.evroc.com/v1"
 :env '("EVROC_API_KEY")
 :models '("moonshotai/Kimi-K2.6" "google/gemma-4-26B-A4B-it" "Qwen/Qwen3-Embedding-8B" "Qwen/Qwen3-Reranker-4B" "Qwen/Qwen3.6-35B-A3B-FP8" "Qwen/Qwen3-VL-30B-A3B-Instruct" "openai/gpt-oss-120b" "openai/whisper-large-v3-turbo" "openai/whisper-large-v3" "mistralai/Mistral-Medium-3.5-128B" "mistralai/Voxtral-Small-24B-2507" "nvidia/Llama-3.3-70B-Instruct-FP8" "evroc/roc" "KBLab/kb-whisper-large" "intfloat/multilingual-e5-large-instruct")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/evroc)

;;; evroc.el ends here
