;;; kargu/ui.el --- Transient control menu and UI shell -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Facade module for the Kargu UI subsystem.
;; Requires modular subcomponents under `kargu/ui/`:
;;   * `kargu/ui/notify'    -> sound alerts and notifications
;;   * `kargu/ui/transient' -> interactive transient control panel (`M-x kargu-menu')
;;
;; Public API:
;;   `kargu-menu', `kargu', `kargu-chat', `kargu-notify'.

;;; Code:

(require 'kargu/ui/notify)
(require 'kargu/ui/transient)

;;;; Root entry point -----------------------------------------------------

(defun kargu ()
  "Open the kargu chat directly."
  (interactive)
  (kargu-chat-show))

(defalias 'kargu-chat #'kargu-chat-show)

(provide 'kargu/ui)

;;; kargu/ui.el ends here
