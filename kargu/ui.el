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

;; Ensure the package root is on `load-path' during compilation.
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

(require 'kargu/ui/notify)
(require 'kargu/ui/transient)

;;;; Root entry point -----------------------------------------------------

(defun kargu ()
  "Open the kargu chat directly."
  (interactive)
  (kargu-chat-show))

(defalias 'kargu-chat #'kargu-chat-show)
(defalias 'kargu-review-diff #'kargu-ui-review-diff)
(defalias 'kargu-rollback #'kargu-ui-rollback)
(defalias 'kargu-rollback-all #'kargu-ui-rollback-all)
(defalias 'kargu-snapshots #'kargu-ui-snapshots)
(defalias 'kargu-pending-reviews #'kargu-ui-pending-reviews)
(defalias 'kargu-stop #'kargu-ui-stop)
(defalias 'kargu-status #'kargu-ui-status)
(defalias 'kargu-open-skeleton #'kargu-ui-open-skeleton)
(defalias 'kargu-find-symbol #'kargu-ui-find-symbol)
(defalias 'kargu-diagnostics #'kargu-ui-diagnostics)
(defalias 'kargu-set-context #'kargu-ui-set-context)
(defalias 'kargu-debug-context #'kargu-ui-debug-context)
(defalias 'kargu-debug-eval #'kargu-ui-debug-eval)
(defalias 'kargu-breakpoints #'kargu-ui-breakpoints)
(defalias 'kargu-choose-model #'kargu-ui-choose-model)
(defalias 'kargu-choose-provider #'kargu-ui-choose-provider)
(defalias 'kargu-toggle-review-mode #'kargu-ui-toggle-review-mode)
(defalias 'kargu-tune #'kargu-tune-menu)

(provide 'kargu/ui)

;;; kargu/ui.el ends here
