;;; kargu/ui/notify.el --- Audio and echo-area notifications -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Sound and echo-area notification system for agent lifecycle events.

;;; Code:

(require 'cl-lib)

;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory (Magit-style kargu/core features).
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

(defcustom kargu-sound-notifications nil
  "When non-nil, play sound or bell when the agent finishes or needs approval."
  :type 'boolean
  :group 'kargu)

(defun kargu-notify-sound (&optional _event)
  "Play an alert tone or ring bell for EVENT (:finish, :error, :permission)."
  (when kargu-sound-notifications
    (ding t)))

(defun kargu-notify (type &optional message)
  "Notify user of TYPE event with optional MESSAGE."
  (kargu-notify-sound type)
  (when message
    (message "kargu [%s]: %s" type message)))

(provide 'kargu/ui/notify)

;;; kargu/ui/notify.el ends here
