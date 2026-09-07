;;; kargu/providers/atomic-chat.el --- Atomic Chat provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for Atomic Chat (atomic-chat).

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
 :id "atomic-chat"
 :name "Atomic Chat"
 :api "http://127.0.0.1:1337/v1"
 :models-api "http://127.0.0.1:1337/v1/models"
 :env '("ATOMIC_CHAT_API_KEY")
 :npm "@ai-sdk/openai-compatible")

(provide 'kargu/providers/atomic-chat)

;;; atomic-chat.el ends here
