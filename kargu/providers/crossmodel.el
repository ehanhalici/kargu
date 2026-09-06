;;; kargu/providers/crossmodel.el --- CrossModel provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for CrossModel (crossmodel).

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
 :id "crossmodel"
 :name "CrossModel"
 :api "https://api.crossmodel.ai/v1"
 :env '("CROSSMODEL_API_KEY")
 :models '("z-ai/glm-4.7" "z-ai/glm-5.1" "z-ai/glm-5.2" "z-ai/glm-5" "z-ai/glm-5-turbo" "openai/gpt-5.4-nano" "openai/gpt-5.4" "openai/gpt-5.4-mini" "openai/gpt-5.5-pro" "openai/gpt-4o-mini" "openai/gpt-5.5" "xiaomi/mimo-v2.5" "xiaomi/mimo-v2.5-pro" "anthropic/claude-opus-4-7" "anthropic/claude-sonnet-5")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/crossmodel)

;;; crossmodel.el ends here
