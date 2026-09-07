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
 :models-api "https://api-sherlock.cloudferro.com/openai/v1/models"
 :env '("CLOUDFERRO_SHERLOCK_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/cloudferro-sherlock)

;;; cloudferro-sherlock.el ends here
