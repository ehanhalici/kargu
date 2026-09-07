;;; kargu/providers/nearai.el --- NEAR AI Cloud provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for NEAR AI Cloud (nearai).

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
 :id "nearai"
 :name "NEAR AI Cloud"
 :api "https://cloud-api.near.ai/v1"
 :models-api "https://cloud-api.near.ai/v1/models"
 :env '("NEARAI_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/nearai)

;;; nearai.el ends here
