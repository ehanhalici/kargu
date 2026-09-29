;;; kargu/ui/notify.el --- Audio and echo-area notifications -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Sound and echo-area notification system for agent lifecycle events.

;;; Code:

(require 'cl-lib)

(require 'kargu/core)

(defvar kargu-sound-notifications)

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
