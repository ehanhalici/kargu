;;; kargu/providers/ovhcloud.el --- OVHcloud AI Endpoints provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for OVHcloud AI Endpoints (ovhcloud).

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
 :id "ovhcloud"
 :name "OVHcloud AI Endpoints"
 :api "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1"
 :env '("OVHCLOUD_API_KEY")
 :models '("qwen3-coder-30b-a3b-instruct" "qwen3-32b" "qwen3guard-gen-8b" "qwen3guard-gen-0.6b" "meta-llama-3_3-70b-instruct" "mistral-small-3.2-24b-instruct-2506" "qwen2.5-vl-72b-instruct" "gpt-oss-120b" "mistral-7b-instruct-v0.3" "mistral-nemo-instruct-2407" "qwen3.6-27b" "qwen3.5-9b" "qwen3.5-397b-a17b" "gpt-oss-20b")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/ovhcloud)

;;; ovhcloud.el ends here
