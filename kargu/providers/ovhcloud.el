;;; kargu/providers/ovhcloud.el --- OVHcloud AI Endpoints provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for OVHcloud AI Endpoints (ovhcloud).

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
 :id "ovhcloud"
 :name "OVHcloud AI Endpoints"
 :api "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1"
 :models-api "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1/models"
 :env '("OVHCLOUD_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/ovhcloud)

;;; ovhcloud.el ends here
