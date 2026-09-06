;;; kargu/providers/cloudferro-sherlock.el --- CloudFerro Sherlock provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for CloudFerro Sherlock (cloudferro-sherlock).

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
 :id "cloudferro-sherlock"
 :name "CloudFerro Sherlock"
 :api "https://api-sherlock.cloudferro.com/openai/v1"
 :env '("CLOUDFERRO_SHERLOCK_API_KEY")
 :models '("meta-llama/Llama-3.3-70B-Instruct" "openai/gpt-oss-120b" "speakleash/Bielik-11B-v3.0-Instruct" "speakleash/Bielik-11B-v2.6-Instruct" "MiniMaxAI/MiniMax-M2.5")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/cloudferro-sherlock)

;;; cloudferro-sherlock.el ends here
