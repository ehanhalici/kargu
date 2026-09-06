;;; kargu/providers/submodel.el --- submodel provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for submodel (submodel).

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
 :id "submodel"
 :name "submodel"
 :api "https://llm.submodel.ai/v1"
 :env '("SUBMODEL_INSTAGEN_ACCESS_KEY")
 :models '("Qwen/Qwen3-235B-A22B-Thinking-2507" "Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8" "Qwen/Qwen3-235B-A22B-Instruct-2507" "openai/gpt-oss-120b" "zai-org/GLM-4.5-FP8" "zai-org/GLM-4.5-Air" "deepseek-ai/DeepSeek-V3-0324" "deepseek-ai/DeepSeek-R1-0528" "deepseek-ai/DeepSeek-V3.1")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/submodel)

;;; submodel.el ends here
