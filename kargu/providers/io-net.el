;;; kargu/providers/io-net.el --- IO.NET provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for IO.NET (io-net).

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
 :id "io-net"
 :name "IO.NET"
 :api "https://api.intelligence.io.solutions/api/v1"
 :env '("IOINTELLIGENCE_API_KEY")
 :models '("meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8" "meta-llama/Llama-3.3-70B-Instruct" "meta-llama/Llama-3.2-90B-Vision-Instruct" "moonshotai/Kimi-K2-Thinking" "moonshotai/Kimi-K2-Instruct-0905" "Qwen/Qwen2.5-VL-32B-Instruct" "Qwen/Qwen3-Next-80B-A3B-Instruct" "Qwen/Qwen3-235B-A22B-Thinking-2507" "openai/gpt-oss-120b" "openai/gpt-oss-20b" "mistralai/Devstral-Small-2505" "mistralai/Magistral-Small-2506" "mistralai/Mistral-Large-Instruct-2411" "mistralai/Mistral-Nemo-Instruct-2407" "Intel/Qwen3-Coder-480B-A35B-Instruct-int4-mixed-ar")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/io-net)

;;; io-net.el ends here
