;;; store.el --- Owned implementation plan records -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; One authoritative record per originating chat.  Review buffers and old
;; transcript buttons hold references, never independent decision flags.

;;; Code:

(require 'cl-lib)
(require 'kargu/chat/session)

(cl-defstruct (kargu-plan-record (:constructor kargu-plan--make-record))
  "Plan artifact owned by one captured chat, project and session."
  origin root session buffer (state :pending))

(defvar kargu-plan--records (make-hash-table :test #'eq)
  "Current plan records keyed by originating buffer; only this module writes.")

(defvar-local kargu-plan--record nil
  "Reference to the record displayed by a review buffer, not a state copy.")

(defun kargu-plan-current (&optional buffer)
  "Return the plan belonging to BUFFER, defaulting to current buffer."
  (let ((buffer (or buffer (current-buffer))))
    (and (buffer-live-p buffer)
         (or (buffer-local-value 'kargu-plan--record buffer)
             (gethash buffer kargu-plan--records)))))

(defun kargu-plan-current-p (record)
  "Return non-nil if RECORD still owns its original chat, root and session."
  (when (kargu-plan-record-p record)
    (let ((origin (kargu-plan-record-origin record)))
      (and (buffer-live-p origin)
           (buffer-live-p (kargu-plan-record-buffer record))
           (eq record (gethash origin kargu-plan--records))
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
  (let ((old (gethash origin kargu-plan--records))
        (record (kargu-plan--make-record
                 :origin origin :root (kargu-session-project-root origin)
                 :session (kargu-chat-session-id origin) :buffer buffer)))
    (when old (setf (kargu-plan-record-state old) :superseded))
    (puthash origin record kargu-plan--records)
    (with-current-buffer buffer
      (setq kargu-plan--record record)
      (setq default-directory (kargu-plan-record-root record)))
    record))

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
  "Release the current buffer's plan ownership when its chat or view closes."
  (when-let* ((record (kargu-plan-current)))
    (let ((origin (kargu-plan-record-origin record)))
      (when (eq record (gethash origin kargu-plan--records))
        (setf (kargu-plan-record-state record) :cancelled)
        (remhash origin kargu-plan--records)))))

(add-hook 'kill-buffer-hook #'kargu-plan--forget-buffer)

(provide 'kargu/plan/store)
;;; store.el ends here
