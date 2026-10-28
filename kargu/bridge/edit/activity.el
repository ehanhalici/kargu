;;; activity.el --- Issued editor activity ownership -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; One physical editor activity across all applications and connection epochs.
;; Acquisition/settlement observers outlive UI cancellation.  Revocation and EOF
;; cannot release a running handler: only its actual unwind proves quiescence.
;; This is IO ownership, not another permission gate.  Rust issues the authority.
;; Positive receipts are not yet connected; entered handlers settle as unknown.

;;; Code:

(require 'map)
(require 'kargu/bridge/edit)

(defconst kargu-bridge-edit-activity--timeout 30
  "Seconds before revoking activity, without dropping its acquisition observer.")
(defconst kargu-bridge-edit-activity--token-pattern
  (rx string-start "editor_issue_" (= 8 (in "0-9a-f")) "-"
      (= 4 (in "0-9a-f")) "-" (= 4 (in "0-9a-f")) "-"
      (= 4 (in "0-9a-f")) "-" (= 12 (in "0-9a-f")) string-end)
  "Canonical native issuance token spelling.")
(defvar kargu-bridge-edit-activity--active nil
  "Physical writer fence shared by every connection; never reset on reconnect.")
(define-error 'kargu-bridge-edit-activity-busy "Previous editor activity has not drained")

(cl-defstruct (kargu-bridge-edit-activity
               (:constructor kargu-bridge-edit-activity--make))
  "One issued observer and synchronous editor handler's actual lifetime."
  artifact application connection epoch scope origin preparation edit revision digest
  buffer cleanup timer handler callback valid-p token notice-token observation failure
  (state :acquiring) revoked)

(defun kargu-bridge-edit-activity--object (fields)
  "Encode detached transport FIELDS as an object."
  (map-into fields 'hash-table))

(defun kargu-bridge-edit-activity--fault (status)
  "Construct a source-free local error with STATUS."
  (kargu-bridge-edit-activity--object
   `(("code" . -32000) ("message" . "Editor activity did not complete normally")
     ("data" . ,(kargu-bridge-edit-activity--object `(("status" . ,status)))))))

(defun kargu-bridge-edit-activity--arguments (activity)
  "Return exact ACTIVITY correlation, independent of the current connection."
  (kargu-bridge-edit-activity--object
   `(("origin_id" . ,(kargu-bridge-edit-activity-origin activity))
     ("edit_id" . ,(kargu-bridge-edit-activity-edit activity))
     ("revision" . ,(kargu-bridge-edit-activity-revision activity)))))

(defun kargu-bridge-edit-activity--call (activity method arguments callback)
  "Keep ACTIVITY's METHOD/ARGUMENTS observer until CALLBACK or actual EOF."
  (kargu-bridge-call
   (kargu-bridge-edit-activity-connection activity) method
   (kargu-bridge-edit-activity--object
    `(("scope" . ,(kargu-bridge-edit-activity-scope activity)) ("arguments" . ,arguments)))
   callback :timeout :unlimited))

(defun kargu-bridge-edit-activity--owner-live-p (activity)
  "Check ACTIVITY ownership without invoking caller code."
  (and (eq activity kargu-bridge-edit-activity--active)
       (eq (kargu-bridge-edit-activity-state activity) :running)
       (not (kargu-bridge-edit-activity-revoked activity))
       (not (kargu-bridge-edit-artifact-released (kargu-bridge-edit-activity-artifact activity)))
       (eq (kargu-bridge-status (kargu-bridge-edit-activity-connection activity)) 'ready)
       (equal (kargu-bridge-edit-activity-epoch activity)
              (kargu-bridge-connection-epoch (kargu-bridge-edit-activity-connection activity)))
       (buffer-live-p (kargu-bridge-edit-activity-buffer activity))
       (kargu-bridge-application-scope-equal-p
        (kargu-bridge-edit-activity-scope activity)
        (kargu-bridge-application-current-scope
         (kargu-bridge-edit-activity-application activity)
         (kargu-bridge-edit-activity-connection activity)))))

(defun kargu-bridge-edit-activity-live-p (activity)
  "Whether ACTIVITY's exact issued owner still permits a new primitive entry."
  (and (kargu-bridge-edit-activity--owner-live-p activity)
       (condition-case nil
           (with-current-buffer (kargu-bridge-edit-activity-buffer activity)
             (or (null (kargu-bridge-edit-activity-valid-p activity))
                 (funcall (kargu-bridge-edit-activity-valid-p activity))))
         ((error quit) nil))
       (kargu-bridge-edit-activity--owner-live-p activity)))

(defun kargu-bridge-edit-activity--finish (activity native failure)
  "Finish quiescent ACTIVITY after NATIVE settlement or definitive FAILURE."
  (unless (eq (kargu-bridge-edit-activity-state activity) :finished)
    (when (timerp (kargu-bridge-edit-activity-timer activity))
      (cancel-timer (kargu-bridge-edit-activity-timer activity)))
    (when (buffer-live-p (kargu-bridge-edit-activity-buffer activity))
      (with-current-buffer (kargu-bridge-edit-activity-buffer activity)
        (remove-hook 'kill-buffer-hook (kargu-bridge-edit-activity-cleanup activity) t)
        (remove-hook 'change-major-mode-hook (kargu-bridge-edit-activity-cleanup activity) t)))
    (let ((callback (kargu-bridge-edit-activity-callback activity))
          (result (list :observation (kargu-bridge-edit-activity-observation activity) :native native)))
      (setf (kargu-bridge-edit-activity-state activity) :finished
            (kargu-bridge-edit-activity-callback activity) nil
            (kargu-bridge-edit-activity-handler activity) nil
            (kargu-bridge-edit-activity-valid-p activity) nil
            (kargu-bridge-edit-activity-cleanup activity) nil
            (kargu-bridge-edit-activity-observation activity) nil
            (kargu-bridge-edit-activity-timer activity) nil)
      (when (eq activity kargu-bridge-edit-activity--active)
        (setq kargu-bridge-edit-activity--active nil))
      (condition-case nil
          (funcall callback result (or failure (kargu-bridge-edit-activity-failure activity)))
        ((error quit) (message "Kargu editor activity observer failed"))))))

(defun kargu-bridge-edit-activity-cancel (activity)
  "Revoke ACTIVITY without discarding a late token or claiming quiescence."
  (unless (or (eq (kargu-bridge-edit-activity-state activity) :finished)
              (kargu-bridge-edit-activity-revoked activity))
    (setf (kargu-bridge-edit-activity-revoked activity) t
          (kargu-bridge-edit-activity-failure activity)
          (kargu-bridge-edit-activity--fault "cancelled"))
    (when (eq (kargu-bridge-status (kargu-bridge-edit-activity-connection activity)) 'ready)
      (kargu-bridge-edit-activity--call
       activity "edit/abort"
       (kargu-bridge-edit-activity--object
        `(("origin_id" . ,(kargu-bridge-edit-activity-origin activity))
          ("preparation_id" . ,(kargu-bridge-edit-activity-preparation activity))))
       #'ignore))))

(defun kargu-bridge-edit-activity-disconnect (connection)
  "Revoke CONNECTION's activity; retain a running handler until its unwind."
  (let ((activity kargu-bridge-edit-activity--active))
    (when (and activity (eq connection (kargu-bridge-edit-activity-connection activity)))
      (setf (kargu-bridge-edit-activity-revoked activity) t
            (kargu-bridge-edit-activity-failure activity)
            (kargu-bridge-edit-activity--fault "outcome_unknown"))
      (unless (eq (kargu-bridge-edit-activity-state activity) :running)
        (kargu-bridge-edit-activity--finish activity nil
                                            (kargu-bridge-edit-activity-failure activity))))))

(defun kargu-bridge-edit-activity-revoke (connection params)
  "Observe a native revocation PARAMS on its original CONNECTION."
  (let ((activity kargu-bridge-edit-activity--active))
    (when (and activity (hash-table-p params)
               (eq connection (kargu-bridge-edit-activity-connection activity))
               (equal (gethash "edit_id" params) (kargu-bridge-edit-activity-edit activity))
               (equal (gethash "origin_id" params) (kargu-bridge-edit-activity-origin activity))
               (stringp (gethash "issued_token" params))
               (or (null (kargu-bridge-edit-activity-token activity))
                   (equal (gethash "issued_token" params) (kargu-bridge-edit-activity-token activity))))
      (setf (kargu-bridge-edit-activity-notice-token activity) (copy-sequence (gethash "issued_token" params)))
      (kargu-bridge-edit-activity-cancel activity))))

(defun kargu-bridge-edit-activity--settle (activity effect)
  "Report EFFECT only after ACTIVITY's handler has actually unwound."
  (setf (kargu-bridge-edit-activity-state activity) :settling)
  (if (not (eq (kargu-bridge-status (kargu-bridge-edit-activity-connection activity)) 'ready))
      (kargu-bridge-edit-activity--drain activity)
    (let ((arguments (kargu-bridge-edit-activity--arguments activity)))
      (puthash "issued_token" (kargu-bridge-edit-activity-token activity) arguments)
      (puthash "effect" effect arguments)
      (kargu-bridge-edit-activity--call
       activity "edit/quiescent" arguments
       (lambda (native failure)
         (when (eq (kargu-bridge-edit-activity-state activity) :settling)
           (if (and (null failure) (hash-table-p native)
                    (equal (gethash "edit_id" native) (kargu-bridge-edit-activity-edit activity))
                    (equal (gethash "state" native) "quiescent")
                    (equal (gethash "effect" native) effect)
                    (eq (gethash "journal_committed" native) t))
               (kargu-bridge-edit-activity--finish activity native nil)
             (kargu-bridge-edit-activity--drain activity))))))))

(defun kargu-bridge-edit-activity--drain (activity)
  "Drain ACTIVITY's original connection after unconfirmed protocol settlement."
  (unless (eq (kargu-bridge-edit-activity-state activity) :finished)
    (setf (kargu-bridge-edit-activity-state activity) :settling
          (kargu-bridge-edit-activity-failure activity)
          (kargu-bridge-edit-activity--fault "outcome_unknown"))
    (if (eq (kargu-bridge-status (kargu-bridge-edit-activity-connection activity)) 'closed)
	(kargu-bridge-edit-activity-disconnect (kargu-bridge-edit-activity-connection activity))
      (kargu-bridge-stop (kargu-bridge-edit-activity-connection activity)))))

(defun kargu-bridge-edit-activity--run (activity)
  "Run ACTIVITY's synchronous handler at most once under the physical fence."
  (setf (kargu-bridge-edit-activity-state activity) :running)
  (let ((effect "not_dispatched"))
    (unwind-protect
        (condition-case nil
            (when (kargu-bridge-edit-activity-live-p activity)
              (setq effect "outcome_unknown")
              (setf (kargu-bridge-edit-activity-observation activity)
                    (funcall (kargu-bridge-edit-activity-handler activity)
                             (lambda () (kargu-bridge-edit-activity-live-p activity)))))
          ((error quit)
           (setf (kargu-bridge-edit-activity-failure activity)
                 (kargu-bridge-edit-activity--fault "outcome_unknown"))))
      (kargu-bridge-edit-activity--settle activity effect))))

(defun kargu-bridge-edit-activity--acquired (activity result failure)
  "Adopt ACTIVITY's exact native RESULT or FAILURE, including after cancellation."
  (when (eq (kargu-bridge-edit-activity-state activity) :acquiring)
    (cond
     (failure (kargu-bridge-edit-activity--finish activity nil failure))
     ((and (hash-table-p result) (equal (gethash "state" result) "issued")
           (equal (gethash "edit_id" result) (kargu-bridge-edit-activity-edit activity))
           (eql (gethash "revision" result) (kargu-bridge-edit-activity-revision activity))
           (equal (gethash "preflight_digest" result) (kargu-bridge-edit-activity-digest activity))
           (stringp (gethash "issued_token" result))
           (string-match-p kargu-bridge-edit-activity--token-pattern (gethash "issued_token" result))
           (or (null (kargu-bridge-edit-activity-notice-token activity))
               (equal (gethash "issued_token" result) (kargu-bridge-edit-activity-notice-token activity))))
      (setf (kargu-bridge-edit-activity-token activity) (copy-sequence (gethash "issued_token" result)))
      (kargu-bridge-edit-activity--run activity))
     (t
      ;; A malformed issuance is not proof the native grant was never issued.
      (kargu-bridge-edit-activity--drain activity)))))

(cl-defun kargu-bridge-edit-activity-start
    (artifact &key edit-id revision preflight-digest journal-directory handler callback valid-p
              (buffer (current-buffer)))
  "Acquire ARTIFACT's EDIT-ID/REVISION issuance and run synchronous HANDLER.
PREFLIGHT-DIGEST is the native complete-preflight fingerprint.
JOURNAL-DIRECTORY is trusted editor configuration.
HANDLER receives a live issuance predicate;
it must return only after every editor effect stops, including hook unwinds.
CALLBACK receives (RAW-OBSERVATIONS ERROR) after native settlement or EOF.
VALID-P and BUFFER guard the originating source.  The returned activity can be
revoked with `kargu-bridge-edit-activity-cancel'; its observer survives
that call."
  (when kargu-bridge-edit-activity--active (signal 'kargu-bridge-edit-activity-busy nil))
  (unless (and (functionp handler) (functionp callback) (buffer-live-p buffer)
               (stringp edit-id) (integerp revision) (> revision 0)
               (stringp preflight-digest) (stringp journal-directory)
               (or (null valid-p) (functionp valid-p)))
    (error "Invalid editor activity arguments"))
  (let ((activity (kargu-bridge-edit-activity--make
                   :edit (copy-sequence edit-id) :revision revision :digest (copy-sequence preflight-digest)
                   :buffer buffer :handler handler :callback callback :valid-p valid-p)))
    (kargu-bridge-edit-activity--capture activity artifact)
    (setq kargu-bridge-edit-activity--active activity)
    (condition-case nil
        (kargu-bridge-edit-activity--begin activity (copy-sequence journal-directory))
      ((error quit) (kargu-bridge-edit-activity--drain activity)))
    activity))

(defun kargu-bridge-edit-activity--capture (activity artifact)
  "Detach ARTIFACT's original native identities into ACTIVITY before yielding."
  (let ((scope (kargu-bridge-edit-artifact-scope artifact)))
    (setf (kargu-bridge-edit-activity-artifact activity) artifact
          (kargu-bridge-edit-activity-application activity) (kargu-bridge-edit-artifact-application artifact)
          (kargu-bridge-edit-activity-connection activity) (kargu-bridge-edit-artifact-connection artifact)
          (kargu-bridge-edit-activity-epoch activity)
          (copy-sequence (kargu-bridge-connection-epoch (kargu-bridge-edit-artifact-connection artifact)))
          (kargu-bridge-edit-activity-scope activity)
          (kargu-bridge-edit-activity--object
           `(("application_id" . ,(copy-sequence (gethash "application_id" scope)))
             ("session_id" . ,(copy-sequence (gethash "session_id" scope)))))
          (kargu-bridge-edit-activity-origin activity) (copy-sequence (kargu-bridge-edit-artifact-origin artifact))
          (kargu-bridge-edit-activity-preparation activity) (copy-sequence (kargu-bridge-edit-artifact-id artifact)))))

(defun kargu-bridge-edit-activity--begin (activity directory)
  "Attach ACTIVITY source cleanup and request issuance into private DIRECTORY."
  (let ((cleanup (lambda () (kargu-bridge-edit-activity-cancel activity))))
    (setf (kargu-bridge-edit-activity-cleanup activity) cleanup
          (kargu-bridge-edit-activity-timer activity)
          (run-at-time kargu-bridge-edit-activity--timeout nil cleanup))
    (with-current-buffer (kargu-bridge-edit-activity-buffer activity)
      (add-hook 'kill-buffer-hook cleanup nil t)
      (add-hook 'change-major-mode-hook cleanup nil t)))
  (let ((arguments (kargu-bridge-edit-activity--arguments activity)))
    (puthash "journal_directory" directory arguments)
    (condition-case nil
        (kargu-bridge-edit-activity--call
         activity "edit/issue" arguments
         (lambda (result failure) (kargu-bridge-edit-activity--acquired activity result failure)))
      ((error quit)
       (kargu-bridge-edit-activity--drain activity)))))

(provide 'kargu/bridge/edit/activity)
;;; activity.el ends here
