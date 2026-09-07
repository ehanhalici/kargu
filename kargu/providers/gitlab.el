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
 :models-api "https://gitlab.com/api/v4/ai/models"
 :env '("GITLAB_TOKEN")
 :npm "gitlab-ai-provider")

(provide 'kargu/providers/gitlab)

;;; gitlab.el ends here
