;;; kargu/providers/abliteration-ai.el --- abliteration.ai provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for abliteration.ai (abliteration-ai).

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
 :id "abliteration-ai"
 :name "abliteration.ai"
 :api "https://api.abliteration.ai/v1"
 :env '("ABLIT_KEY")
 :models '("abliterated-model")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/abliteration-ai)

;;; abliteration-ai.el ends here
