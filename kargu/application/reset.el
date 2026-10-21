;;; reset.el --- Ordered application reset coordination -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Cancellation and critical state changes are ordered application work.
;; Optional views receive only a final, best-effort lifecycle notification.

;;; Code:

(require 'kargu/core/session)
(require 'kargu/core/observers)
(require 'kargu/application/mode)

(declare-function kargu-loop-running-p "kargu/loop" ())
(declare-function kargu-loop-stop "kargu/loop" (&optional reason))
(declare-function kargu-busy-p "kargu/api/http" ())
(declare-function kargu-api-cancel "kargu/api/client" ())
(declare-function kargu-history-reset "kargu/history/protocol" ())
(declare-function kargu-circuit-reset "kargu/api/circuit" ())
(declare-function kargu-state-reset "kargu/state/transitions" ())

(defun kargu-application--cancel-session-work ()
  "Invalidate active work before publishing replacement session data."
  (cond
   ((and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
    (kargu-loop-stop "session reset"))
   ((and (fboundp 'kargu-busy-p) (kargu-busy-p))
    (unless (fboundp 'kargu-api-cancel)
      (user-error "Kargu: cannot reset while an uncancellable request is active"))
    (kargu-api-cancel))))

(defun kargu-session-reset ()
  "Cancel active work, reset the session and notify optional views in order."
  (interactive)
  (let ((origin (current-buffer)) (owner (kargu-session-context)))
    (kargu-mode-cancel owner)
    (save-current-buffer
      (kargu-application--cancel-session-work)
      (when (or (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
                (and (fboundp 'kargu-busy-p) (kargu-busy-p)))
        (user-error "Kargu: reset superseded by active work; session data was retained"))
      (unless (and (buffer-live-p origin) (eq owner (kargu-session-context origin)))
        (user-error "Kargu: reset owner changed; replacement data was retained"))
      (with-current-buffer origin
        (kargu-session-clear)
        (when (fboundp 'kargu-history-reset) (kargu-history-reset))
        (when (fboundp 'kargu-circuit-reset) (kargu-circuit-reset))
        (when (fboundp 'kargu-state-reset) (kargu-state-reset))
        (kargu-run-observers 'kargu-session-reset-hook))
      (message "Kargu session reset"))))

(provide 'kargu/application/reset)
;;; reset.el ends here
