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
(require 'kargu/plan/context)
(require 'kargu/async)

(declare-function kargu-session-context "kargu/core/session" (&optional buffer))
(declare-function kargu-bridge-status "kargu/bridge" ())
(declare-function kargu-bridge-plan-create "kargu/bridge/plan" (session text callback))
(declare-function kargu-bridge-plan-revise "kargu/bridge/plan" (session plan-id revision text callback))
(declare-function kargu-bridge-plan-claim "kargu/bridge/plan" (session plan-id revision hash callback))
(declare-function kargu-bridge-plan-complete "kargu/bridge/plan" (session plan-id success callback))
(declare-function kargu-bridge-plan-reject "kargu/bridge/plan" (session plan-id revision callback))

(cl-defstruct (kargu-plan-record (:constructor kargu-plan--make-record))
  "Plan artifact owned by one captured chat, project and session."
  origin context buffer dispatch-task (state :pending)
  id (revision 1) content-hash (native nil))

(defun kargu-plan-record-root (record)
  "Return RECORD's captured project root without a second writable copy."
  (kargu-plan-context-root (kargu-plan-record-context record)))

(defun kargu-plan-record-session (record)
  "Return RECORD's captured session identity without a second writable copy."
  (kargu-plan-context-session (kargu-plan-record-context record)))

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
           (funcall (kargu-plan-context-current-p (kargu-plan-record-context record))
                    record)))))

(defun kargu-plan-assert-current (record)
  "Return RECORD or refuse a closed, replaced or reassigned plan owner."
  (unless (kargu-plan-current-p record)
    (user-error "Kargu: this plan no longer belongs to the current chat session"))
  record)

(defun kargu-plan-pending-p (record)
  "Return non-nil if RECORD is current and awaits a decision."
  (and (kargu-plan-current-p record) (eq (kargu-plan-record-state record) :pending)))

(defun kargu-plan-create (origin buffer &optional context)
  "Replace ORIGIN's plan in review BUFFER using explicit or default CONTEXT."
  (kargu-contract-assert #'buffer-live-p origin)
  (kargu-contract-assert #'buffer-live-p buffer)
  (when-let* ((displayed (kargu-plan-current buffer)))
    (unless (eq origin (kargu-plan-record-origin displayed))
      (user-error "Kargu: this review belongs to another plan owner")))
  (let* ((old (kargu-plan-current origin))
         (plan-text (with-current-buffer buffer
                      (save-restriction
                        (widen)
                        (string-trim (buffer-substring-no-properties (point-min) (point-max))))))
         (plan-hash (secure-hash 'sha256 plan-text))
         (plan-id (format "plan_%s" (md5 (format "%s-%s-%s" origin (buffer-chars-modified-tick) (float-time)))))
         (record (kargu-plan--make-record
                  :origin origin :buffer buffer
                  :context (kargu-plan-context-validate
                            (or context (kargu-plan-context-for-buffer origin)))
                  :id plan-id :revision 1 :content-hash plan-hash)))
    (when old
      (setf (kargu-plan-record-state old) :superseded)
      (kargu-plan-cancel-dispatch old))
    (kargu-plan--attach-record origin record)
    (kargu-plan--attach-record buffer record)
    (with-current-buffer buffer
      (setq default-directory (kargu-plan-record-root record)))
    (when-let* ((session (kargu-plan--native-session origin)))
      (kargu-bridge-plan-create
       session plan-text
       (lambda (plan-dto error-data)
         (if error-data
             (kargu-log 'warn "Native plan create error: %s" error-data)
           (kargu-plan--adopt record plan-dto)
           ;; Only a record the core created may be revised, claimed or settled.
           (setf (kargu-plan-record-native record) t)
           (kargu-plan--sync-text record)))))
    record))

(defun kargu-plan--native-session (origin)
  "Return ORIGIN's session when the native plan port is reachable now."
  (when (and (fboundp 'kargu-bridge-status) (eq (kargu-bridge-status) 'ready))
    (require 'kargu/bridge/plan)
    (kargu-session-context origin)))

(defun kargu-plan--adopt (record plan-dto)
  "Adopt the core's id, revision and content hash from PLAN-DTO into RECORD."
  (when plan-dto
    (when-let* ((id (plist-get plan-dto :id))) (setf (kargu-plan-record-id record) id))
    (when-let* ((rev (plist-get plan-dto :revision))) (setf (kargu-plan-record-revision record) rev))
    (when-let* ((hash (plist-get plan-dto :content-hash)))
      (setf (kargu-plan-record-content-hash record) hash))))

(defun kargu-plan--text (record)
  "Return RECORD's review text as the core hashes it."
  (with-current-buffer (kargu-plan-record-buffer record)
    (save-restriction
      (widen)
      (string-trim (buffer-substring-no-properties (point-min) (point-max))))))

(defun kargu-plan--sync-text (record)
  "Send RECORD's current review text to the core when it differs from its hash.
The core owns the revision and hash; its acknowledgement is adopted."
  (when-let* (((eq (kargu-plan-record-state record) :pending))
              ((kargu-plan-record-native record))
              ((buffer-live-p (kargu-plan-record-buffer record)))
              (text (kargu-plan--text record))
              ((not (equal (secure-hash 'sha256 text) (kargu-plan-record-content-hash record))))
              (session (kargu-plan--native-session (kargu-plan-record-origin record))))
    (kargu-bridge-plan-revise
     session (kargu-plan-record-id record) (kargu-plan-record-revision record) text
     (lambda (plan-dto error-data)
       (if error-data
           (kargu-log 'warn "Native plan revise error: %s" error-data)
         (kargu-plan--adopt record plan-dto))))))

(defun kargu-plan--after-change (&rest _args)
  "Notify plan record when review buffer content changes."
  (when-let* ((record (kargu-plan-current)))
    (if (kargu-plan-record-native record)
        (kargu-plan--sync-text record)
      ;; A record the core never created keeps its local edition count.
      (let ((hash (secure-hash 'sha256 (kargu-plan--text record))))
        (when (and (eq (kargu-plan-record-state record) :pending)
                   (not (equal hash (kargu-plan-record-content-hash record))))
          (setf (kargu-plan-record-content-hash record) hash)
          (cl-incf (kargu-plan-record-revision record)))))))

(defun kargu-plan--attach-record (buffer record)
  "Attach RECORD to validated BUFFER with locally owned cleanup hooks."
  (with-current-buffer buffer
    (setq kargu-plan--record record)
    (add-hook 'kill-buffer-hook #'kargu-plan--forget-buffer nil t)
    (add-hook 'change-major-mode-hook #'kargu-plan--forget-buffer nil t)
    (when (eq buffer (kargu-plan-record-buffer record))
      (add-hook 'after-change-functions #'kargu-plan--after-change nil t))))

(defun kargu-plan--detach-record (buffer record)
  "Detach RECORD and its cleanup hooks from BUFFER if still referenced."
  (when (and (buffer-live-p buffer) (eq record (kargu-plan-current buffer)))
    (with-current-buffer buffer
      (setq kargu-plan--record nil)
      (remove-hook 'kill-buffer-hook #'kargu-plan--forget-buffer t)
      (remove-hook 'change-major-mode-hook #'kargu-plan--forget-buffer t)
      (remove-hook 'after-change-functions #'kargu-plan--after-change t))))

(defun kargu-plan-claim (record)
  "Claim RECORD for dispatch once; return non-nil only from pending state."
  (kargu-plan-assert-current record)
  (when (eq (kargu-plan-record-state record) :pending)
    (setf (kargu-plan-record-state record) :dispatching)
    (when-let* (((kargu-plan-record-native record))
                (session (kargu-plan--native-session (kargu-plan-record-origin record)))
                (plan-id (kargu-plan-record-id record))
                (rev (kargu-plan-record-revision record))
                (hash (kargu-plan-record-content-hash record)))
      (kargu-bridge-plan-claim
       session plan-id rev hash
       (lambda (_reply error-data)
         (when error-data
           (kargu-log 'warn "Native plan claim error: %s" error-data)))))
    t))

(defun kargu-plan-complete (record success)
  "Complete RECORD's dispatch, retrying on failure when SUCCESS is nil.
Never restore a decision belonging to a replaced or invalid owner."
  (when (eq (kargu-plan-record-state record) :dispatching)
    (setf (kargu-plan-record-state record)
          (cond ((not (kargu-plan-current-p record)) :cancelled)
                (success :approved)
                (t :pending)))
    (when-let* (((kargu-plan-record-native record))
                (session (kargu-plan--native-session (kargu-plan-record-origin record)))
                (plan-id (kargu-plan-record-id record)))
      (kargu-bridge-plan-complete
       session plan-id success
       (lambda (_reply error-data)
         (when error-data
           (kargu-log 'warn "Native plan complete error: %s" error-data)))))))

(defun kargu-plan-cancel-dispatch (record)
  "Cancel RECORD's pending dispatch and its owned preparation resources."
  (when-let* ((task (kargu-plan-record-dispatch-task record)))
    (setf (kargu-plan-record-dispatch-task record) nil)
    (kargu-async-cancel task)))

(defun kargu-plan-decline (record)
  "Reject pending RECORD once; return non-nil if a decision was taken."
  (kargu-plan-assert-current record)
  (when (eq (kargu-plan-record-state record) :pending)
    (setf (kargu-plan-record-state record) :rejected)
    (when-let* (((kargu-plan-record-native record))
                (session (kargu-plan--native-session (kargu-plan-record-origin record)))
                (plan-id (kargu-plan-record-id record))
                (rev (kargu-plan-record-revision record)))
      (kargu-bridge-plan-reject
       session plan-id rev
       (lambda (_reply error-data)
         (when error-data
           (kargu-log 'warn "Native plan reject error: %s" error-data)))))
    t))

(defun kargu-plan--forget-buffer ()
  "Release the current plan when its chat or view loses buffer ownership."
  (when-let* ((record (kargu-plan-current)))
    (let ((origin (kargu-plan-record-origin record))
          (view (kargu-plan-record-buffer record)))
      (when (eq record (kargu-plan-current origin))
        (setf (kargu-plan-record-state record) :cancelled)
        (kargu-plan-cancel-dispatch record)
        (kargu-plan--detach-record origin record)
        (kargu-plan--detach-record view record))
      (kargu-plan--detach-record (current-buffer) record))))

(provide 'kargu/plan/store)
;;; store.el ends here
