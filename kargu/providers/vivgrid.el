;;; kargu/providers/vivgrid.el --- Vivgrid provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Vivgrid (vivgrid).

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
 :id "vivgrid"
 :name "Vivgrid"
 :api "https://api.vivgrid.com/v1"
 :env '("VIVGRID_API_KEY")
 :models '("deepseek-v4-pro" "gpt-5.4-nano" "glm-5.2" "gpt-5.1-codex" "gpt-5.1-codex-max" "gpt-5.3-codex" "gpt-5.6-luna" "gpt-5.6-terra" "gpt-5.4" "gpt-5.4-mini" "gemini-3.1-pro-preview" "gpt-5-mini" "gpt-5.6-sol" "deepseek-v3.2" "gemini-3.1-flash-lite-preview")
 :npm "@ai-sdk/openai")

(provide 'kargu/providers/vivgrid)

;;; vivgrid.el ends here
