;;; kargu/providers/sap-ai-core.el --- SAP AI Core provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for SAP AI Core (sap-ai-core).

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
 :id "sap-ai-core"
 :name "SAP AI Core"
 :api "https://api.ai.prod.eu-central-1.aws.ml.hana.ondemand.com/v2"
 :env '("AICORE_SERVICE_KEY")
 :models '("anthropic--claude-4.8-opus" "gemini-3.1-flash-lite" "anthropic--claude-4.6-sonnet" "anthropic--claude-3-sonnet" "anthropic--claude-4-sonnet" "gemini-2.5-pro" "gpt-5" "gemini-2.5-flash" "gemini-3.5-flash" "anthropic--claude-4.5-haiku" "anthropic--claude-3-haiku" "anthropic--claude-4-opus" "anthropic--claude-4.5-sonnet" "anthropic--claude-3.5-sonnet" "anthropic--claude-4.6-opus")
 :npm "@jerome-benoit/sap-ai-provider-v2")

(provide 'kargu/providers/sap-ai-core)

;;; sap-ai-core.el ends here
