;;; reset.el --- Ordered application reset coordination -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Cancellation and critical state changes are ordered application work.
;; Optional views receive only a final, best-effort lifecycle notification.

;;; Code:

(require 'kargu/core/session)
(require 'kargu/core/observers)
(require 'kargu/application/coordinator)
(require 'kargu/application/mode)

(declare-function kargu-application-active-claim-token "kargu/application/coordinator" (&optional app))
(declare-function kargu-application-claim-session-id "kargu/application/coordinator" (claim))
(declare-function kargu-application-release "kargu/application/coordinator" (app claim))
(declare-function kargu-loop-running-p "kargu/loop" ())
(declare-function kargu-loop-stop "kargu/loop" (&optional reason))
(declare-function kargu-busy-p "kargu/api/http" ())
(declare-function kargu-api-cancel "kargu/api/client" ())
(declare-function kargu-history-reset "kargu/history/protocol" ())
(declare-function kargu-circuit-reset "kargu/api/circuit" ())
(declare-function kargu-state-reset "kargu/state/transitions" ())

(defun kargu-application--foreign-run-p (owner origin)
  "Return non-nil when the active loop run does not belong to OWNER or ORIGIN."
  (when-let* ((run (kargu-application-current-run)))
    (cond
     ((and (listp run) (consp run))
      (when-let* ((has-owner (or (plist-get run :session)
                                 (plist-get run :chat-buffer))))
        (not (or (eq (plist-get run :session) owner)
                 (eq (plist-get run :chat-buffer) origin)))))
     ((stringp run)
      (let* ((app (kargu-application-context))
             (claim (kargu-application-active-claim-token app)))
        (if claim
            (when-let* ((sess (kargu-application-claim-session-id claim)))
              (not (or (equal sess (kargu-session-id owner))
                       (eq sess owner))))
          nil)))
     (t nil))))

(defun kargu-application--foreign-request-p (owner origin)
  "Return non-nil when the active request does not belong to OWNER or ORIGIN."
  (when-let* ((req (kargu-application-current-request))
              ((kargu-logical-request-live-p req))
              (has-owner (or (kargu-logical-request-session req)
                             (kargu-logical-request-origin req))))
    (not (or (eq (kargu-logical-request-session req) owner)
             (eq (kargu-logical-request-origin req) origin)))))

(defun kargu-application--owned-work-active-p (owner origin)
  "Return non-nil when active loop or HTTP work is owned by OWNER or ORIGIN."
  (or (and (fboundp 'kargu-loop-running-p)
           (kargu-loop-running-p)
           (not (kargu-application--foreign-run-p owner origin)))
      (and (fboundp 'kargu-busy-p)
           (kargu-busy-p)
           (not (kargu-application--foreign-request-p owner origin)))))

(defun kargu-application--cancel-session-work (owner origin)
  "Invalidate work owned by OWNER or ORIGIN before resetting session data."
  (cond
   ((and (fboundp 'kargu-loop-running-p)
         (kargu-loop-running-p)
         (not (kargu-application--foreign-run-p owner origin)))
    (kargu-loop-stop "session reset"))
   ((and (fboundp 'kargu-busy-p)
         (kargu-busy-p)
         (not (kargu-application--foreign-request-p owner origin)))
    (unless (fboundp 'kargu-api-cancel)
      (user-error "Kargu: cannot reset while an uncancellable request is active"))
    (kargu-api-cancel))))

(defun kargu-session-reset ()
  "Cancel active work, reset the session and notify optional views in order."
  (interactive)
  (let ((origin (current-buffer)) (owner (kargu-session-context)))
    (kargu-mode-cancel owner)
    (save-current-buffer
      (kargu-application--cancel-session-work owner origin)
      (when (kargu-application--owned-work-active-p owner origin)
        (user-error "Kargu: reset superseded by active work; session data was retained"))
      (unless (and (buffer-live-p origin) (eq owner (kargu-session-context origin)))
        (user-error "Kargu: reset owner changed; replacement data was retained"))
      (let ((foreign-work (or (kargu-application--foreign-run-p owner origin)
                              (kargu-application--foreign-request-p owner origin))))
        (with-current-buffer origin
          (kargu-session-clear)
          (when (fboundp 'kargu-history-reset) (kargu-history-reset))
          (unless foreign-work
            (when-let* ((app (kargu-application-context))
                        (claim (kargu-application-active-claim-token app)))
              (when (or (null (kargu-application-claim-session-id claim))
                        (equal (kargu-application-claim-session-id claim) (kargu-session-id owner)))
                (kargu-application-release app claim)))
            (when (fboundp 'kargu-circuit-reset) (kargu-circuit-reset))
            (when (fboundp 'kargu-state-reset) (kargu-state-reset)))
          (kargu-run-observers 'kargu-session-reset-hook)))
      (message "Kargu session reset"))))

(provide 'kargu/application/reset)
;;; reset.el ends here
