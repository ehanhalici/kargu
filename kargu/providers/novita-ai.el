;;; kargu/providers/novita-ai.el --- NovitaAI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for NovitaAI (novita-ai).

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
 :id "novita-ai"
 :name "NovitaAI"
 :api "https://api.novita.ai/openai"
 :models-api "https://api.novita.ai/openai/models"
 :env '("NOVITA_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/novita-ai)

;;; novita-ai.el ends here
