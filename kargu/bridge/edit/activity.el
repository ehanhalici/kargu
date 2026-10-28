;;; activity.el --- Issued editor activity ownership -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; One physical editor activity across all applications and connection epochs.
;; Acquisition/settlement observers outlive UI cancellation.  Revocation and EOF
;; cannot release a running handler: only its actual unwind proves quiescence.
;; This is IO ownership, not another permission gate.  Rust issues the authority.
;; Raw written/final facts stream under this fence.  Native verification and
;; journal joins determine the result; handler failures settle as unknown.

;;; Code:

(require 'map)
(require 'kargu/bridge/edit)
(require 'kargu/bridge/edit/document)

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

(defun kargu-bridge-edit-activity--receipt-changes (observation)
  "Normalize OBSERVATION into a list of change structs, or nil."
  (cond
   ((kargu-bridge-edit-document-change-p observation)
    (list observation))
   ((and (proper-list-p observation)
         (consp observation)
         (cl-every #'kargu-bridge-edit-document-change-p observation))
    observation)
   ((and (vectorp observation)
         (> (length observation) 0)
         (cl-every #'kargu-bridge-edit-document-change-p observation))
    (append observation nil))
   (t nil)))

(defconst kargu-bridge-edit-activity--receipt-bytes (* 32 1024 1024)
  "Maximum detached written/final receipt bytes for the single physical writer.")
(defconst kargu-bridge-edit-activity--receipt-part-bytes (* 4 1024 1024)
  "Native byte ceiling for each receipt text part.")
(defconst kargu-bridge-edit-activity--receipt-files 256
  "Maximum native file observations per receipt.")
(defconst kargu-bridge-edit-activity--receipt-chunk-bytes (* 32 1024)
  "Native ceiling for an individual receipt append.")
(defconst kargu-bridge-edit-activity--receipt-envelope-bytes 768
  "Reserved frame bytes for correlation and receipt append metadata.")

(cl-defstruct (kargu-bridge-edit-activity-file
               (:constructor kargu-bridge-edit-activity-file--make))
  "Detached receipt metadata and bounded UTF-8 text for one editor file."
  observation written after)
(cl-defstruct (kargu-bridge-edit-activity-stream
               (:constructor kargu-bridge-edit-activity-stream--make))
  "One ACK-driven receipt cursor; chunks are constructed only as sent."
  files total (file 0) (stage :file) (offset 0))

(defun kargu-bridge-edit-activity--receipt-bytes (text)
  "Detach TEXT as bounded UTF-8 receipt bytes, allowing absent text parts."
  (when text
    (unless (and (stringp text)
                 (<= (length text) kargu-bridge-edit-activity--receipt-part-bytes))
      (error "Editor receipt text exceeds its limit"))
    (let ((bytes (encode-coding-string text 'utf-8-unix)))
      (when (> (length bytes) kargu-bridge-edit-activity--receipt-part-bytes)
        (error "Editor receipt text exceeds its limit"))
      bytes)))

(defun kargu-bridge-edit-activity--build-receipt-queue (changes)
  "Build a bounded receipt cursor.
CHANGES supplies the detached platform observations."
  (unless (<= (length changes) kargu-bridge-edit-activity--receipt-files)
    (error "Editor receipt has too many files"))
  (let ((total-bytes 0) (index 0) files)
    (dolist (change changes)
      (let* ((after (kargu-bridge-edit-document-change-after change))
             (written (kargu-bridge-edit-activity--receipt-bytes
                       (kargu-bridge-edit-document-change-written change)))
             (final (kargu-bridge-edit-activity--receipt-bytes
                     (and (kargu-bridge-edit-document-p after)
                          (kargu-bridge-edit-document-text after)))))
        (setq total-bytes (+ total-bytes (length written) (length final)))
        (when (> total-bytes kargu-bridge-edit-activity--receipt-bytes)
          (error "Editor receipt exceeds its aggregate byte limit"))
        (push (kargu-bridge-edit-activity-file--make
               :observation (kargu-bridge-edit-document-observation change index)
               :written written :after final) files)
        (setq index (1+ index))))
    (kargu-bridge-edit-activity-stream--make :files (nreverse files) :total index)))

(defun kargu-bridge-edit-activity--receipt-advance (stream)
  "Advance STREAM after a metadata ACK or completed text part."
  (setf (kargu-bridge-edit-activity-stream-offset stream) 0)
  (pcase (kargu-bridge-edit-activity-stream-stage stream)
    (:file (setf (kargu-bridge-edit-activity-stream-stage stream) :written))
    (:written (setf (kargu-bridge-edit-activity-stream-stage stream) :after))
    (:after
     (setf (kargu-bridge-edit-activity-stream-files stream)
           (cdr (kargu-bridge-edit-activity-stream-files stream))
           (kargu-bridge-edit-activity-stream-file stream)
           (1+ (kargu-bridge-edit-activity-stream-file stream))
           (kargu-bridge-edit-activity-stream-stage stream)
           (if (kargu-bridge-edit-activity-stream-files stream) :file :commit)))))

(defun kargu-bridge-edit-activity--receipt-result-p (stream receipt)
  "Check native RECEIPT's transport shape for STREAM without deriving outcomes."
  (and (hash-table-p receipt)
       (member (gethash "outcome" receipt)
               '("applied_full" "applied_partial" "not_applied" "outcome_unknown"))
       (eql (gethash "files_total" receipt) (kargu-bridge-edit-activity-stream-total stream))
       (integerp (gethash "files_applied" receipt))
       (<= 0 (gethash "files_applied" receipt) (gethash "files_total" receipt))
       (vectorp (gethash "files" receipt))
       (= (length (gethash "files" receipt)) (gethash "files_total" receipt))
       (cl-loop for file across (gethash "files" receipt) for index from 0
                always (and (hash-table-p file) (eql (gethash "file" file) index)
                            (member (gethash "outcome" file)
                                    '("applied" "unchanged" "partial" "not_applied" "outcome_unknown"))))))

(defun kargu-bridge-edit-activity--receipt-ack-p (stream input native)
  "Check NATIVE ACK against STREAM's exact outstanding INPUT."
  (and (hash-table-p native)
       (eql (gethash "file" native) (kargu-bridge-edit-activity-stream-file stream))
       (pcase (gethash "action" input)
         ("file" (and (eq (gethash "recorded" native) t)
                      (eql (gethash "files_received" native)
                           (1+ (kargu-bridge-edit-activity-stream-file stream)))
                      (eql (gethash "files_total" native)
                           (kargu-bridge-edit-activity-stream-total stream))))
         ("append"
          (let* ((file (car (kargu-bridge-edit-activity-stream-files stream)))
                 (bytes (if (equal (gethash "part" input) "written")
                            (kargu-bridge-edit-activity-file-written file)
                          (kargu-bridge-edit-activity-file-after file)))
                 (end (+ (gethash "offset" input)
                         (string-bytes (encode-coding-string (gethash "text" input) 'utf-8-unix)))))
            (and (equal (gethash "part" native) (gethash "part" input))
                 (eql (gethash "next_offset" native) end)
                 (eq (gethash "complete" native) (if (= end (length bytes)) t :json-false)))))
         (_ nil))))

(defun kargu-bridge-edit-activity--receipt-send (activity stream input)
  "Send one receipt INPUT and retain ACTIVITY/STREAM through its exact ACK."
  (let ((arguments (kargu-bridge-edit-activity--arguments activity)))
    (puthash "issued_token" (kargu-bridge-edit-activity-token activity) arguments)
    (puthash "input" input arguments)
    (kargu-bridge-edit-activity--call
     activity "edit/receipt" arguments
     (lambda (native failure)
       (when (eq (kargu-bridge-edit-activity-state activity) :settling)
         (condition-case nil
             (cond
              (failure (kargu-bridge-edit-activity--drain activity))
              ((equal (gethash "action" input) "commit")
               (kargu-bridge-edit-activity--receipt-complete activity stream native))
              ((kargu-bridge-edit-activity--receipt-ack-p stream input native)
               (if (equal (gethash "action" input) "file")
                   (kargu-bridge-edit-activity--receipt-advance stream)
                 (setf (kargu-bridge-edit-activity-stream-offset stream) (gethash "next_offset" native)))
               (kargu-bridge-edit-activity--pump-receipt activity stream))
              (t (kargu-bridge-edit-activity--drain activity)))
           ((error quit) (kargu-bridge-edit-activity--drain activity))))))))

(defun kargu-bridge-edit-activity--receipt-complete (activity stream native)
  "Adopt NATIVE receipt from STREAM for quiescent ACTIVITY."
  (if (and (hash-table-p native)
           (equal (gethash "edit_id" native) (kargu-bridge-edit-activity-edit activity))
           (equal (gethash "state" native) "quiescent")
           (eq (gethash "journal_committed" native) t)
           (kargu-bridge-edit-activity--receipt-result-p stream (gethash "receipt" native)))
      (progn
        ;; UI cancellation cannot replace an authoritative completed-write result.
        (setf (kargu-bridge-edit-activity-failure activity) nil)
        (kargu-bridge-edit-activity--finish activity native nil))
    (kargu-bridge-edit-activity--drain activity)))

(defun kargu-bridge-edit-activity--receipt-append (activity stream)
  "Send one bounded text append for ACTIVITY/STREAM, or advance an empty part."
  (let* ((file (car (kargu-bridge-edit-activity-stream-files stream)))
         (written (eq (kargu-bridge-edit-activity-stream-stage stream) :written))
         (bytes (if written (kargu-bridge-edit-activity-file-written file)
                  (kargu-bridge-edit-activity-file-after file)))
         (offset (kargu-bridge-edit-activity-stream-offset stream))
         (frame (kargu-bridge-connection-frame-limit (kargu-bridge-edit-activity-connection activity)))
         (page (min kargu-bridge-edit-activity--receipt-chunk-bytes
                    (/ (- frame kargu-bridge-edit-activity--receipt-envelope-bytes) 6))))
    (unless (>= page 4) (error "Editor receipt frame is too small"))
    (if (>= offset (length bytes))
        (progn (kargu-bridge-edit-activity--receipt-advance stream)
               (kargu-bridge-edit-activity--pump-receipt activity stream))
      (let ((end (min (length bytes) (+ offset page))))
        (while (and (< end (length bytes)) (= (logand (aref bytes end) #xc0) #x80))
          (setq end (1- end)))
        (kargu-bridge-edit-activity--receipt-send
         activity stream (kargu-bridge-edit-activity--object
                          `(("action" . "append") ("file" . ,(kargu-bridge-edit-activity-stream-file stream))
                            ("part" . ,(if written "written" "after")) ("offset" . ,offset)
                            ("text" . ,(decode-coding-string (substring bytes offset end) 'utf-8-unix)))))))))

(defun kargu-bridge-edit-activity--pump-receipt (activity stream)
  "Pump STREAM under ACTIVITY's fence, including after source revocation."
  (unless (eq (kargu-bridge-edit-activity-state activity) :finished)
    (if (or (not (eq (kargu-bridge-edit-activity-state activity) :settling))
            (not (eq (kargu-bridge-status (kargu-bridge-edit-activity-connection activity)) 'ready)))
        (kargu-bridge-edit-activity--drain activity)
      (pcase (kargu-bridge-edit-activity-stream-stage stream)
        (:file (kargu-bridge-edit-activity--receipt-send
                activity stream (kargu-bridge-edit-activity--object
                                 `(("action" . "file")
                                   ("observation" . ,(kargu-bridge-edit-activity-file-observation
                                                      (car (kargu-bridge-edit-activity-stream-files stream))))))))
        ((or :written :after) (kargu-bridge-edit-activity--receipt-append activity stream))
        (:commit (kargu-bridge-edit-activity--receipt-send
                  activity stream (kargu-bridge-edit-activity--object '(("action" . "commit")))))
        (_ (kargu-bridge-edit-activity--drain activity))))))

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
      (let* ((obs (kargu-bridge-edit-activity-observation activity))
             (changes (and (null (kargu-bridge-edit-activity-failure activity))
                           (kargu-bridge-edit-activity--receipt-changes obs))))
        (if changes
            (progn
              (setf (kargu-bridge-edit-activity-state activity) :settling)
              (condition-case nil
                  (kargu-bridge-edit-activity--pump-receipt
                   activity (kargu-bridge-edit-activity--build-receipt-queue changes))
                ((error quit) (kargu-bridge-edit-activity--drain activity))))
          (kargu-bridge-edit-activity--settle activity effect))))))

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
