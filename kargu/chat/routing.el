;;; routing.el --- Project-aware chat buffer lookup -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Find existing chat buffers by project, never by a globally fixed name.

;;; Code:

(require 'cl-lib)
(require 'kargu/permission/guards)

(defvar-local kargu-chat--project-root nil
  "Canonical project root owning the current chat buffer.")

(defun kargu-chat-find-buffer (&optional project-root)
  "Return an existing chat for PROJECT-ROOT, or nil without a matching chat.
Default to the caller's current project.  Never create a buffer or choose
an unrelated project's default-named chat."
  (let ((root (file-name-as-directory
               (file-truename (or project-root (kargu-permission-project-root))))))
    (cl-find-if
     (lambda (buffer)
       (with-current-buffer buffer
         (and (derived-mode-p 'kargu-chat-mode)
              (equal root (or kargu-chat--project-root
                              (kargu-permission-project-root buffer))))))
     (buffer-list))))

(provide 'kargu/chat/routing)

;;; routing.el ends here
