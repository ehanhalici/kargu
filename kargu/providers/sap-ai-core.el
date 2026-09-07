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
 :models-api "https://api.ai.prod.eu-central-1.aws.ml.hana.ondemand.com/v2/models"
 :env '("AICORE_SERVICE_KEY")
 :npm "@jerome-benoit/sap-ai-provider-v2")

(provide 'kargu/providers/sap-ai-core)

;;; sap-ai-core.el ends here
