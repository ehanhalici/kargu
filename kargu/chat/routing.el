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

(defvar kargu-chat-buffer-name)

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

(defun kargu-chat-restore-target (root &optional target)
  "Resolve chat ROOT's restore TARGET without choosing another project.
An explicit live TARGET may be uninitialized, but an existing chat must
already belong to ROOT.  With no target, reuse a matching chat or create
a uniquely named buffer; never reuse a foreign default-named buffer."
  (when target
    (unless (buffer-live-p target) (user-error "Kargu: restore target is not live"))
    (unless (with-current-buffer target
              (or (not (derived-mode-p 'kargu-chat-mode))
                  (equal root (file-name-as-directory
                               (file-truename (or kargu-chat--project-root
                                                  (kargu-permission-project-root)))))))
      (user-error "Kargu: restore target belongs to another project")))
  (or target
      (and (derived-mode-p 'kargu-chat-mode)
           (equal root kargu-chat--project-root) (current-buffer))
      (kargu-chat-find-buffer root)
      (progn
        (unless (boundp 'kargu-chat-buffer-name)
          (user-error "Kargu: chat UI is unavailable for session restore"))
        (generate-new-buffer kargu-chat-buffer-name))))

(provide 'kargu/chat/routing)

;;; routing.el ends here
