;;; kargu/providers/ambient.el --- Ambient provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Ambient (ambient).

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
 :id "ambient"
 :name "Ambient"
 :api "https://api.ambient.xyz/v1"
 :env '("AMBIENT_API_KEY")
 :models '("moonshotai/kimi-k2.7-code" "moonshotai/kimi-k2.6" "zai-org/GLM-5.1-FP8" "zai-org/GLM-5.2-FP8")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/ambient)

;;; ambient.el ends here
