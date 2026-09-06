;;; kargu/providers/the-grid-ai.el --- The Grid AI provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for The Grid AI (the-grid-ai).

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
 :id "the-grid-ai"
 :name "The Grid AI"
 :api "https://api.thegrid.ai/v1"
 :env '("THEGRIDAI_API_KEY")
 :models '("agent-prime" "agent-max" "text-standard" "code-prime" "text-prime" "code-max" "agent-standard" "text-max" "code-standard")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/the-grid-ai)

;;; the-grid-ai.el ends here
