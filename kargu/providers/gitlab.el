;;; kargu/providers/gitlab.el --- GitLab Duo provider definition -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provider definition for GitLab Duo (gitlab).

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
 :id "gitlab"
 :name "GitLab Duo"
 :api "https://gitlab.com/api/v4/ai"
 :env '("GITLAB_TOKEN")
 :models '("duo-chat-opus-4-5" "duo-chat-opus-4-8" "duo-chat-opus-4-7" "duo-chat-gpt-5-2-codex" "duo-chat-fable-5" "duo-chat-gpt-5-5" "duo-chat-opus-4-6" "duo-chat-gpt-5-4" "duo-chat-gpt-5-codex" "duo-chat-gpt-5-4-nano" "duo-chat-sonnet-4-6" "duo-chat-gpt-5-mini" "duo-chat-sonnet-5" "duo-chat-gpt-5-4-mini" "duo-chat-gpt-5-3-codex")
 :npm "gitlab-ai-provider")

(provide 'kargu/providers/gitlab)

;;; gitlab.el ends here
