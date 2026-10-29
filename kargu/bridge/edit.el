;;; edit.el --- Bounded native proposal preparation transport -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Upload detached text with exact byte offsets and one outstanding frame.
;; A preparation handle permits paged reads only.  It cannot authorize a write.

;;; Code:

(require 'kargu/async)
(require 'kargu/bridge/application)

(require 'rx)
(defconst kargu-bridge-edit--text-bytes (* 4 1024 1024)
  "Maximum bytes in one native text part.")
(defconst kargu-bridge-edit--upload-bytes (* 16 1024 1024)
  "Maximum bytes retained by one native preparation reservation.")
(defconst kargu-bridge-edit--chunk-bytes (* 32 1024)
  "Maximum text bytes in one upload frame before negotiated framing.")
(defconst kargu-bridge-edit--file-count 256
  "Maximum native patch targets.")
(defconst kargu-bridge-edit--hunk-count 4096
  "Maximum native patch hunks.")
(defconst kargu-bridge-edit--timeout 30.0
  "Absolute preparation task lifetime in seconds.")
(defconst kargu-bridge-edit--hash-pattern (rx string-start (= 64 (in "0-9a-f")) string-end)
  "Canonical native content hash spelling.")
(defconst kargu-bridge-edit--methods
  '((:begin . "edit/begin") (:append . "edit/append") (:prepare . "edit/prepare")
    (:read . "edit/read") (:abort . "edit/abort") (:inspect . "edit/inspect")
    (:targets . "edit/targets") (:document . "edit/document") (:files . "edit/files")
    (:authorize . "edit/authorize") (:decision . "edit/decision")
    (:revise . "edit/revise") (:preflight . "edit/preflight")
    (:rollback . "edit/rollback"))
  "Closed native edit wire method names.")

(cl-defstruct (kargu-bridge-edit-artifact
               (:constructor kargu-bridge-edit-artifact--make))
  "One connection-bound, read-only native proposal handle."
  application connection scope origin id descriptor released (page-bytes kargu-bridge-edit--chunk-bytes))

(cl-defstruct (kargu-bridge-edit-transfer
               (:constructor kargu-bridge-edit-transfer--make))
  "Owned transport state, detached before the first asynchronous boundary."
  task artifact arguments parts (action :prepare) (offset 0) (page-bytes kargu-bridge-edit--chunk-bytes) handed)

(defun kargu-bridge-edit--arguments (artifact)
  "Return the exact ticket arguments for ARTIFACT."
  (kargu-bridge--object "origin_id" (kargu-bridge-edit-artifact-origin artifact)
                        "preparation_id" (kargu-bridge-edit-artifact-id artifact)))

(defun kargu-bridge-edit--call (artifact method arguments callback)
  "Call METHOD with ARGUMENTS for ARTIFACT and deliver CALLBACK."
  (kargu-bridge-call
   (kargu-bridge-edit-artifact-connection artifact)
   (or (alist-get method kargu-bridge-edit--methods) (error "Unknown edit method"))
   (kargu-bridge--object "scope" (kargu-bridge-application--copy-scope
                                  (kargu-bridge-edit-artifact-scope artifact))
                         "arguments" arguments)
   callback))

(defun kargu-bridge-edit-release (artifact)
  "Release only ARTIFACT's native preparation on its existing connection."
  (unless (kargu-bridge-edit-artifact-released artifact)
    (setf (kargu-bridge-edit-artifact-released artifact) t)
    (when (and (kargu-bridge-edit-artifact-id artifact)
               (eq (kargu-bridge-status (kargu-bridge-edit-artifact-connection artifact)) 'ready))
      (kargu-bridge-edit--call artifact :abort
                               (kargu-bridge-edit--arguments artifact) #'ignore))))

(defun kargu-bridge-edit--current-p (artifact)
  "Check ARTIFACT's exact application lease without acquiring another one."
  (and (not (kargu-bridge-edit-artifact-released artifact))
       (kargu-bridge-application-scope-equal-p
        (kargu-bridge-edit-artifact-scope artifact)
        (kargu-bridge-application-current-scope
         (kargu-bridge-edit-artifact-application artifact)
         (kargu-bridge-edit-artifact-connection artifact)))))

(defun kargu-bridge-edit--task-current-p (task)
  "Check TASK's captured source, deadline and optional document guard."
  (and (kargu-async-pending-p task)
       (buffer-live-p (kargu-async-task-buffer task))
       (< (float-time) (kargu-async-task-deadline task))
       (condition-case nil
           (with-current-buffer (kargu-async-task-buffer task)
             (or (null (kargu-async-task-valid-p task)) (funcall (kargu-async-task-valid-p task))))
         ((error quit) nil))))

(defun kargu-bridge-edit--live-p (transfer)
  "Check TRANSFER's task, absolute deadline and captured lease."
  (and (kargu-bridge-edit--task-current-p (kargu-bridge-edit-transfer-task transfer))
       (kargu-bridge-edit--current-p (kargu-bridge-edit-transfer-artifact transfer))))

(defun kargu-bridge-edit--fail (transfer failure)
  "Finish TRANSFER with FAILURE while its cleanup revokes its exact ticket."
  (kargu-async-finish (kargu-bridge-edit-transfer-task transfer) nil failure))

(defun kargu-bridge-edit--guard (transfer callback)
  "Guard CALLBACK with TRANSFER ownership and deadline verification."
  (lambda (value failure)
    (cond
     (failure (kargu-bridge-edit--fail transfer failure))
     ((not (kargu-bridge-edit--live-p transfer))
      (kargu-bridge-edit--fail transfer (kargu-bridge--fault "stale_edit_preparation")))
     (t (condition-case nil (funcall callback value)
          ((error quit)
           (kargu-bridge-edit--fail transfer (kargu-bridge--fault "invalid_edit_preparation"))))))))

(defun kargu-bridge-edit--deliver (transfer &optional descriptor)
  "Transfer the prepared handle to TRANSFER's caller with optional DESCRIPTOR."
  (let ((artifact (kargu-bridge-edit-transfer-artifact transfer)))
    (when descriptor (setf (kargu-bridge-edit-artifact-descriptor artifact) descriptor))
    (setf (kargu-bridge-edit-transfer-handed transfer) t)
    (kargu-async-finish (kargu-bridge-edit-transfer-task transfer) artifact)))

(defun kargu-bridge-edit--prepared (transfer value)
  "Adopt VALUE as TRANSFER's immutable read-only descriptor."
  (let* ((artifact (kargu-bridge-edit-transfer-artifact transfer))
         (inspect (eq (kargu-bridge-edit-transfer-action transfer) :inspect))
         (count (and (hash-table-p value) (gethash "file_count" value)))
         (batch (and (integerp count) (<= 1 count kargu-bridge-edit--file-count)
                     (integerp (gethash "hunks_total" value)) (<= 0 (gethash "hunks_total" value) kargu-bridge-edit--hunk-count))))
    (unless (and (hash-table-p value)
                 (equal (gethash "preparation_id" value) (kargu-bridge-edit-artifact-id artifact))
                 (eq (gethash "applied" value) :json-false)
                 (if inspect (and batch (eq (gethash "inspected" value) t))
                   (or (and batch (eq (gethash "batch" value) t))
                       (cl-every (lambda (key) (let ((hash (gethash key value)))
						 (and (stringp hash)
                                                      (string-match-p kargu-bridge-edit--hash-pattern hash))))
                                 '("base_hash" "proposed_hash")))))
      (error "Invalid proposal descriptor"))
    (kargu-bridge-edit--deliver transfer value)))

(defun kargu-bridge-edit--send-part (transfer part offset)
  "Send PART's next exact-offset frame for TRANSFER starting at OFFSET."
  (let* ((artifact (kargu-bridge-edit-transfer-artifact transfer))
         (bytes (cdr part))
         (end (min (length bytes) (+ offset (kargu-bridge-edit-transfer-page-bytes transfer))))
         (arguments (kargu-bridge-edit--arguments artifact)))
    ;; Owned UTF-8 bytes must never end inside a continuation sequence.
    (while (and (< end (length bytes)) (= (logand (aref bytes end) #xc0) #x80))
      (setq end (1- end)))
    (puthash "part" (car part) arguments)
    (puthash "offset" offset arguments)
    (puthash "text" (decode-coding-string (substring bytes offset end) 'utf-8-unix) arguments)
    (kargu-bridge-edit--call
     artifact :append arguments
     (kargu-bridge-edit--guard
      transfer (lambda (value)
                 (unless (and (hash-table-p value) (equal (gethash "offset" value) end))
                   (error "Invalid upload offset"))
                 (setf (kargu-bridge-edit-transfer-offset transfer) end)
                 (kargu-bridge-edit--pump transfer))))))

(defun kargu-bridge-edit--pump (transfer)
  "Send one bounded frame from TRANSFER; wait for its ACK before continuing."
  (let* ((artifact (kargu-bridge-edit-transfer-artifact transfer))
         (parts (kargu-bridge-edit-transfer-parts transfer))
         (part (car parts))
         (offset (kargu-bridge-edit-transfer-offset transfer)))
    (cond
     ((not (kargu-bridge-edit--live-p transfer))
      (kargu-bridge-edit--fail transfer (kargu-bridge--fault "stale_edit_preparation")))
     ((null parts)
      (if (eq (kargu-bridge-edit-transfer-action transfer) :document)
          (kargu-bridge-edit--deliver transfer)
        (kargu-bridge-edit--call
         artifact (if (eq (kargu-bridge-edit-transfer-action transfer) :inspect) :inspect :prepare)
         (kargu-bridge-edit--arguments artifact)
         (kargu-bridge-edit--guard transfer (lambda (value) (kargu-bridge-edit--prepared transfer value))))))
     ((= offset (length (cdr part)))
      (clear-string (cdr part))
      (setf (kargu-bridge-edit-transfer-parts transfer) (cdr parts)
            (kargu-bridge-edit-transfer-offset transfer) 0)
      (kargu-bridge-edit--pump transfer))
     (t (kargu-bridge-edit--send-part transfer part offset)))))

(defun kargu-bridge-edit--begun (transfer value failure)
  "Adopt TRANSFER's allocated VALUE or FAILURE, releasing late acquisitions."
  (let* ((artifact (kargu-bridge-edit-transfer-artifact transfer))
         (id (and (hash-table-p value) (gethash "preparation_id" value)))
         (bytes (and (hash-table-p value) (gethash "page_bytes" value))))
    (when (stringp id) (setf (kargu-bridge-edit-artifact-id artifact) (copy-sequence id)))
    (cond
     ((not (kargu-bridge-edit--live-p transfer))
      ;; Cleanup may have run before the native allocation arrived.
      (setf (kargu-bridge-edit-artifact-released artifact) nil)
      (kargu-bridge-edit-release artifact)
      (kargu-bridge-edit--fail transfer (kargu-bridge--fault "stale_edit_preparation")))
     (failure (kargu-bridge-edit--fail transfer failure))
     ((not (and (stringp id) (string-prefix-p "edit_prepare_" id)
                (integerp bytes) (<= 4 bytes kargu-bridge-edit--chunk-bytes)))
      (kargu-bridge-edit--fail transfer (kargu-bridge--fault "invalid_edit_preparation")))
     (t
      (setf (kargu-bridge-edit-transfer-page-bytes transfer) bytes
            (kargu-bridge-edit-artifact-page-bytes artifact) bytes)
      (kargu-bridge-edit--pump transfer)))))

(defun kargu-bridge-edit--begin (transfer scope failure)
  "Begin TRANSFER on captured SCOPE, or report FAILURE."
  (if failure (kargu-bridge-edit--fail transfer failure)
    (let ((artifact (kargu-bridge-edit-transfer-artifact transfer)))
      (setf (kargu-bridge-edit-artifact-scope artifact) (kargu-bridge-application--copy-scope scope))
      (if (not (kargu-bridge-edit--live-p transfer))
          (kargu-bridge-edit--fail transfer (kargu-bridge--fault "stale_edit_preparation"))
        ;; Keep allocation callbacks alive after cancellation to release tickets.
        (kargu-bridge-edit--call
         artifact :begin (kargu-bridge-edit-transfer-arguments transfer)
         (lambda (value error-data) (kargu-bridge-edit--begun transfer value error-data)))))))

(defun kargu-bridge-edit--ready (transfer connection failure)
  "Bind TRANSFER to CONNECTION after startup, or report FAILURE."
  (let* ((artifact (kargu-bridge-edit-transfer-artifact transfer))
         (task (kargu-bridge-edit-transfer-task transfer)))
    (cond
     (failure (kargu-bridge-edit--fail transfer failure))
     ((not (kargu-async-pending-p task)) nil)
     ((not (kargu-bridge-edit--task-current-p task))
      (kargu-bridge-edit--fail transfer (kargu-bridge--fault "stale_edit_preparation")))
     ((not (member (if (eq (kargu-bridge-edit-transfer-action transfer) :inspect) "edit_patch_preparation" "edit_preparation")
                   (append (kargu-bridge-connection-capabilities connection) nil)))
      (kargu-bridge-edit--fail transfer (kargu-bridge--fault "unsupported_edit_preparation")))
     (t
      (setf (kargu-bridge-edit-artifact-connection artifact) connection)
      (kargu-async-add-cleanup
       task (kargu-bridge-application-ensure
             connection (kargu-bridge-edit-artifact-application artifact)
             (lambda (scope error-data) (kargu-bridge-edit--begin transfer scope error-data))))))))

(defun kargu-bridge-edit--watch-owner (transfer)
  "Cancel TRANSFER when its captured source is killed or mode is altered."
  (let* ((task (kargu-bridge-edit-transfer-task transfer))
         (owner (kargu-async-task-buffer task))
         (cancel (lambda () (kargu-async-cancel task))))
    (add-hook 'kill-buffer-hook cancel nil t)
    (add-hook 'change-major-mode-hook cancel nil t)
    (kargu-async-add-cleanup
     task (lambda () (when (buffer-live-p owner)
                       (with-current-buffer owner
                         (remove-hook 'kill-buffer-hook cancel t)
                         (remove-hook 'change-major-mode-hook cancel t)))))))

(defun kargu-bridge-edit--detach (transfer parts)
  "Detach and bound PARTS before TRANSFER's first asynchronous boundary."
  (let ((total 0) detached)
    (dolist (part parts)
      (unless (and (member (car part) '("old" "new" "document" "patch")) (stringp (cdr part))
                   (<= (length (cdr part)) kargu-bridge-edit--text-bytes)
                   (not (assoc (car part) detached)))
        (error "Invalid upload part"))
      (let ((bytes (copy-sequence (encode-coding-string (substring-no-properties (cdr part)) 'utf-8-unix t))))
        (setq total (+ total (length bytes)))
        (push (cons (copy-sequence (car part)) bytes) detached)
        (setf (kargu-bridge-edit-transfer-parts transfer) detached)
        (when (or (> (length bytes) kargu-bridge-edit--text-bytes) (> total kargu-bridge-edit--upload-bytes)) (error "Upload limit"))))
    (setf (kargu-bridge-edit-transfer-parts transfer) (nreverse detached))))

(cl-defun kargu-bridge-edit--transfer (artifact callback &key arguments parent valid-p (action :prepare))
  "Own one ARTIFACT transfer of ARGUMENTS under CALLBACK/PARENT/VALID-P/ACTION."
  (let* ((task (kargu-async-start
                (kargu-application-wrap
                 (kargu-bridge-edit-artifact-application artifact)
                 (lambda (value failure)
                   (condition-case err (funcall callback value failure)
                     ((error quit)
                      (when (kargu-bridge-edit-artifact-p value) (kargu-bridge-edit-release value))
                      (signal (car err) (cdr err))))))
                :parent parent :valid-p valid-p :timeout kargu-bridge-edit--timeout))
         (transfer (kargu-bridge-edit-transfer--make
                    :task task :artifact artifact :arguments arguments :action action
                    :page-bytes (kargu-bridge-edit-artifact-page-bytes artifact))))
    (kargu-bridge-edit--watch-owner transfer)
    (kargu-async-add-cleanup
     task (lambda ()
            (dolist (part (kargu-bridge-edit-transfer-parts transfer)) (clear-string (cdr part)))
            (setf (kargu-bridge-edit-transfer-parts transfer) nil)
            (unless (kargu-bridge-edit-transfer-handed transfer) (kargu-bridge-edit-release artifact))))
    transfer))

(defun kargu-bridge-edit--copy (value)
  "Detach bounded metadata VALUE from its caller before asynchronous dispatch."
  (json-parse-string (json-serialize value :null-object :json-null :false-object :json-false)
                     :object-type 'hash-table :null-object :json-null :false-object :json-false))

(cl-defun kargu-bridge-edit--start (application arguments parts &key callback parent valid-p (action :prepare))
  "Begin detached ARGUMENTS/PARTS for APPLICATION.
CALLBACK, PARENT, VALID-P and ACTION control transfer lifetime."
  (let* ((arguments (kargu-bridge-edit--copy arguments))
         (artifact (kargu-bridge-edit-artifact--make
                    :application application :origin (copy-sequence (gethash "origin_id" arguments))))
         (transfer (kargu-bridge-edit--transfer artifact callback :arguments arguments :parent parent :valid-p valid-p :action action))
         (task (kargu-bridge-edit-transfer-task transfer)))
    (condition-case nil
        (progn
          (kargu-bridge-edit--detach transfer parts)
          (when (kargu-async-pending-p task)
            (kargu-async-add-cleanup
             task (kargu-bridge-ensure
                   (lambda (connection failure) (kargu-bridge-edit--ready transfer connection failure))))))
      ((error quit) (kargu-bridge-edit--fail transfer (kargu-bridge--fault "invalid_edit_upload"))))
    task))

(cl-defun kargu-bridge-edit-prepare (application arguments parts callback &key parent valid-p)
  "Prepare detached ARGUMENTS and text PARTS for APPLICATION into CALLBACK.
PARTS is an alist of native part names and full decoded text strings.
CALLBACK receives (ARTIFACT FAILURE).  Release ARTIFACT explicitly after use.
PARENT owns cancellation; VALID-P guards captured source and document identity.
This transport does not read editor files or grant editor effects."
  (kargu-bridge-edit--start application arguments parts :callback callback :parent parent :valid-p valid-p))

(defun kargu-bridge-edit-read (artifact part offset callback)
  "Read one bounded page of ARTIFACT's PART at byte OFFSET into CALLBACK."
  (if (not (kargu-bridge-edit--current-p artifact))
      (funcall callback nil (kargu-bridge--fault "stale_edit_preparation"))
    (let ((arguments (kargu-bridge-edit--arguments artifact)))
      (puthash "part" part arguments) (puthash "offset" offset arguments)
      (kargu-bridge-edit--call
       artifact :read arguments
       (lambda (value failure)
         (funcall callback (and (kargu-bridge-edit--current-p artifact) value)
                  (or failure (unless (kargu-bridge-edit--current-p artifact)
                                (kargu-bridge--fault "stale_edit_preparation")))))))))

(defun kargu-bridge-edit-authorize (artifact presenter callback)
  "Request execution authorization for ARTIFACT with PRESENTER into CALLBACK."
  (let ((arguments (kargu-bridge-edit--arguments artifact)))
    (puthash "presenter" (if (eq presenter 'available) "available" "missing") arguments)
    (kargu-bridge-edit--call artifact :authorize arguments callback)))

(cl-defun kargu-bridge-edit-decision (artifact &key edit-id revision decision callback)
  "Submit DECISION for ARTIFACT's exact EDIT-ID and REVISION into CALLBACK."
  (kargu-bridge-edit--execution-call
   artifact :decision :edit edit-id :revision revision
   :fields (list "decision" (if (symbolp decision) (symbol-name decision) decision)) :callback callback))

(cl-defun kargu-bridge-edit-revise (artifact &key edit-id revision file-index new-text callback)
  "Revise ARTIFACT's EDIT-ID at REVISION into CALLBACK.
FILE-INDEX selects the proposal receiving NEW-TEXT."
  (kargu-bridge-edit--execution-call
   artifact :revise :edit edit-id :revision revision
   :fields (list "file_index" file-index "new_text" new-text) :callback callback))

(cl-defun kargu-bridge-edit-preflight (artifact &key edit-id revision witness callback)
  "Preflight ARTIFACT's EDIT-ID and REVISION with WITNESS into CALLBACK."
  (kargu-bridge-edit--execution-call
   artifact :preflight :edit edit-id :revision revision :fields (list "witness" witness) :callback callback))

(cl-defun kargu-bridge-edit--execution-call (artifact method &key edit revision fields callback)
  "Call METHOD on ARTIFACT's EDIT and REVISION with FIELDS into CALLBACK."
  (if (not (kargu-bridge-edit--current-p artifact))
      (funcall callback nil (kargu-bridge--fault "stale_edit_preparation"))
    (kargu-bridge-edit--call
     artifact method
     (apply #'kargu-bridge--object "origin_id" (kargu-bridge-edit-artifact-origin artifact)
            "edit_id" edit "revision" revision fields)
     (lambda (value failure)
       (funcall callback value
                (or failure (unless (kargu-bridge-edit--current-p artifact)
                              (kargu-bridge--fault "stale_edit_preparation"))))))))

(cl-defun kargu-bridge-edit-rollback (application arguments &key callback parent)
  "Prepare APPLICATION rollback from detached ARGUMENTS into CALLBACK.
PARENT owns only preparation; no write capability is returned."
  (let* ((arguments (kargu-bridge-edit--copy arguments))
         (task (kargu-async-start callback :timeout 30 :parent parent)))
    (kargu-bridge-ensure
     (kargu-async-wrap
      task
      (lambda (connection failure)
        (if failure (kargu-async-finish task nil failure)
          (kargu-bridge-application-ensure
           connection application
           (kargu-async-wrap
            task
            (lambda (scope error-data)
              (if error-data (kargu-async-finish task nil error-data)
                (kargu-bridge-call
                 connection "edit/rollback"
                 (kargu-bridge--object "scope" (kargu-bridge-application--copy-scope scope)
                                       "arguments" arguments)
                 (lambda (value fault)
                   (if fault (kargu-async-finish task nil fault)
                     (let ((artifact (kargu-bridge-edit-artifact--make
                                      :application application :connection connection
                                      :scope (kargu-bridge-application--copy-scope scope)
                                      :origin (gethash "origin_id" arguments)
                                      :id (gethash "preparation_id" value)
                                      :descriptor (gethash "descriptor" value))))
                       (if (and (kargu-bridge-edit--task-current-p task)
                                (kargu-bridge-edit--current-p artifact))
                           (kargu-async-finish task artifact nil)
                         (kargu-bridge-edit-release artifact)
                         (kargu-async-finish task nil (kargu-bridge--fault "stale_edit_preparation")))))))))))))))
    task))

(provide 'kargu/bridge/edit)
;;; edit.el ends here
