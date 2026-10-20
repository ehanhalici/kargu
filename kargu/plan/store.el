;;; store.el --- Owned implementation plan records -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; One authoritative record per originating chat.  Review buffers and old
;; transcript buttons hold references, never independent decision flags.

;;; Code:

(require 'cl-lib)
(require 'kargu/contract/assert)
(require 'kargu/chat/session)

(cl-defstruct (kargu-plan-record (:constructor kargu-plan--make-record))
  "Plan artifact owned by one captured chat, project and session."
  origin root session buffer (state :pending))

(defvar-local kargu-plan--record nil
  "Owned record in an origin buffer, or its reference in a review buffer.")

(defun kargu-plan-current (&optional buffer)
  "Return the plan belonging to BUFFER, defaulting to current buffer."
  (let ((buffer (or buffer (current-buffer))))
    (and (buffer-live-p buffer)
         (buffer-local-value 'kargu-plan--record buffer))))

(defun kargu-plan-current-p (record)
  "Return non-nil if RECORD still owns its original chat, root and session."
  (when (kargu-plan-record-p record)
    (let ((origin (kargu-plan-record-origin record)))
      (and (buffer-live-p origin)
           (buffer-live-p (kargu-plan-record-buffer record))
           (eq record (kargu-plan-current origin))
           (eq record (kargu-plan-current (kargu-plan-record-buffer record)))
           (equal (kargu-plan-record-root record) (kargu-session-project-root origin))
           (equal (kargu-plan-record-session record) (kargu-chat-session-id origin))))))

(defun kargu-plan-assert-current (record)
  "Return RECORD or refuse a closed, replaced or reassigned plan owner."
  (unless (kargu-plan-current-p record)
    (user-error "Kargu: this plan no longer belongs to the current chat session"))
  record)

(defun kargu-plan-pending-p (record)
  "Return non-nil if RECORD is current and awaits a decision."
  (and (kargu-plan-current-p record) (eq (kargu-plan-record-state record) :pending)))

(defun kargu-plan-create (origin buffer)
  "Replace ORIGIN's plan with a fresh record displayed in review BUFFER."
  (kargu-contract-assert #'buffer-live-p origin)
  (kargu-contract-assert #'buffer-live-p buffer)
  (when-let* ((displayed (kargu-plan-current buffer)))
    (unless (eq origin (kargu-plan-record-origin displayed))
      (user-error "Kargu: this review belongs to another plan owner")))
  (let ((old (kargu-plan-current origin))
        (record (kargu-plan--make-record
                 :origin origin :root (kargu-session-project-root origin)
                 :session (kargu-chat-session-id origin) :buffer buffer)))
    (when old (setf (kargu-plan-record-state old) :superseded))
    (kargu-plan--attach-record origin record)
    (kargu-plan--attach-record buffer record)
    (with-current-buffer buffer
      (setq default-directory (kargu-plan-record-root record)))
    record))

(defun kargu-plan--attach-record (buffer record)
  "Attach RECORD to validated BUFFER with locally owned cleanup hooks."
  (with-current-buffer buffer
    (setq kargu-plan--record record)
    (add-hook 'kill-buffer-hook #'kargu-plan--forget-buffer nil t)
    (add-hook 'change-major-mode-hook #'kargu-plan--forget-buffer nil t)))

(defun kargu-plan--detach-record (buffer record)
  "Detach RECORD and its cleanup hooks from BUFFER if still referenced."
  (when (and (buffer-live-p buffer) (eq record (kargu-plan-current buffer)))
    (with-current-buffer buffer
      (setq kargu-plan--record nil)
      (remove-hook 'kill-buffer-hook #'kargu-plan--forget-buffer t)
      (remove-hook 'change-major-mode-hook #'kargu-plan--forget-buffer t))))

(defun kargu-plan-claim (record)
  "Claim RECORD for dispatch once; return non-nil only from pending state."
  (kargu-plan-assert-current record)
  (when (eq (kargu-plan-record-state record) :pending)
    (setf (kargu-plan-record-state record) :dispatching)
    t))

(defun kargu-plan-complete (record success)
  "Complete RECORD's dispatch, retrying on failure when SUCCESS is nil.
Never restore a decision belonging to a replaced or invalid owner."
  (when (eq (kargu-plan-record-state record) :dispatching)
    (setf (kargu-plan-record-state record)
          (cond ((not (kargu-plan-current-p record)) :cancelled)
                (success :approved)
                (t :pending)))))

(defun kargu-plan-decline (record)
  "Reject pending RECORD once; return non-nil if a decision was taken."
  (kargu-plan-assert-current record)
  (when (eq (kargu-plan-record-state record) :pending)
    (setf (kargu-plan-record-state record) :rejected)
    t))

(defun kargu-plan--forget-buffer ()
  "Release the current plan when its chat or view loses buffer ownership."
  (when-let* ((record (kargu-plan-current)))
    (let ((origin (kargu-plan-record-origin record))
          (view (kargu-plan-record-buffer record)))
      (when (eq record (kargu-plan-current origin))
        (setf (kargu-plan-record-state record) :cancelled)
        (kargu-plan--detach-record origin record)
        (kargu-plan--detach-record view record))
      (kargu-plan--detach-record (current-buffer) record))))

(provide 'kargu/plan/store)
;;; store.el ends here
