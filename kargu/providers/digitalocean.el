;;; kargu/providers/digitalocean.el --- DigitalOcean provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for DigitalOcean (digitalocean).

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
 :id "digitalocean"
 :name "DigitalOcean"
 :api "https://inference.do-ai.run/v1"
 :models-api "https://inference.do-ai.run/v1/models"
 :env '("DIGITALOCEAN_ACCESS_TOKEN")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/digitalocean)

;;; digitalocean.el ends here
