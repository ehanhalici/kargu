;;; kargu/providers/io-net.el --- IO.NET provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for IO.NET (io-net).

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
 :id "io-net"
 :name "IO.NET"
 :api "https://api.intelligence.io.solutions/api/v1"
 :models-api "https://api.intelligence.io.solutions/api/v1/models"
 :env '("IOINTELLIGENCE_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/io-net)

;;; io-net.el ends here
