;;; kargu/providers/tencent-tokenhub.el --- Tencent TokenHub provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Tencent TokenHub (tencent-tokenhub).

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
 :id "tencent-tokenhub"
 :name "Tencent TokenHub"
 :api "https://tokenhub.tencentmaas.com/v1"
 :env '("TENCENT_TOKENHUB_API_KEY")
 :models '("hy3" "hy3-preview")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/tencent-tokenhub)

;;; tencent-tokenhub.el ends here
