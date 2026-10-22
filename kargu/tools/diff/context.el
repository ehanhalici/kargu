;;; context.el --- Edit service context and transaction contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Edit service context managing snapshots, change tracking, review sessions,
;; active transaction plans, and owned temporary resources.
;; Guarantees single-owner edit transactions, frozen approval identity,
;; safe resource isolation and lifecycle cleanup.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/contract/assert)
(require 'kargu/contract/result)
(require 'kargu/files)

(declare-function kargu-diff-apply-replace "kargu/tools/diff/stage"
                  (file-path old-string new-string &optional callback))
(declare-function kargu-diff-apply-proposal "kargu/tools/diff/stage"
                  (file-path new-content &optional callback))
(declare-function kargu-diff-apply-patch "kargu/tools/diff"
                  (patch-text &optional callback))
(declare-function kargu-diff--describe "kargu/tools/diff/stage" (outcome))
(declare-function kargu-permission-resolve "kargu/permission" (path &optional kind root))
(declare-function kargu-session-context "kargu/core/session" ())
(declare-function kargu-session-id "kargu/core/session" (session))
(declare-function kargu-session-id-value "kargu/core/session" (session))
(declare-function kargu-process-cancel "kargu/tools/process" (proc))
(declare-function ediff-really-quit "ediff-util" (&optional flag))

(defvar kargu-diff-review-mode)
(defvar kargu-diff-auto-save)
(defvar kargu-diff--snapshots)
(defvar kargu-diff--changed)
(defvar kargu-diff--sessions)
(defvar kargu-diff--run-modified-files)
(defvar ediff-quit-hook)

;;;; UUID and identity helpers --------------------------------------------

(defun kargu-edit--random-uuid ()
  "Generate a pseudo-random identifier string."
  (format "%s-%06x"
          (format-time-string "%Y%m%d%H%M%S")
          (random #xffffff)))

;;;; Core Structs ---------------------------------------------------------

(cl-defstruct (kargu-edit-service (:constructor kargu-edit-service--create))
  "Explicit edit-service context managing snapshot, review and change tables."
  (service-id (format "edit-%s" (kargu-edit--random-uuid)) :read-only t)
  (root nil :read-only t)
  (snapshots (make-hash-table :test #'equal))
  (changes (make-hash-table :test #'equal))
  (reviews (make-hash-table :test #'equal))
  (active-plans (make-hash-table :test #'equal))
  (policy-revision 0)
  (run-modified-files nil)
  (temp-dirs nil)
  (processes nil)
  (timers nil)
  (buffers nil)
  (review-mode 'auto)
  (auto-save t)
  (closed nil))

(cl-defstruct (kargu-edit-plan (:constructor kargu-edit-plan--create))
  "Immutable captured transaction plan for proposed file modifications."
  (plan-id (format "plan-%s" (kargu-edit--random-uuid)) :read-only t)
  (path nil :read-only t)
  (kind nil :read-only t) ; :block, :symbol, :unified-diff, :write
  (proposed-content nil :read-only t)
  (expected-revision nil :read-only t) ; kargu-file-revision
  (policy-revision 0 :read-only t)
  (session-id nil :read-only t)
  (run-id nil :read-only t)
  (app-id nil :read-only t)
  (review-mode nil :read-only t)
  (auto-save nil :read-only t)
  (metadata nil :read-only t)
  (created-at (float-time) :read-only t))

(cl-defstruct (kargu-edit-outcome (:constructor kargu-edit-outcome--create))
  "Unified transaction outcome for file editing operations."
  (plan-id nil :read-only t)
  (path nil :read-only t)
  (status nil :read-only t) ; :applied, :staged, :conflict, :partial, :unavailable, :rejected, :interrupted, :unchanged, :rolled-back, :error
  (post-revision nil :read-only t) ; kargu-file-revision after save-hooks
  (hunks-applied 0 :read-only t)
  (hunks-total 0 :read-only t)
  (message nil :read-only t)
  (saved nil :read-only t)
  (hook-transformed nil :read-only t)
  (decided-content nil :read-only t)
  (snapshot nil :read-only t)
  (rollback-status nil :read-only t)
  (write-effects nil :read-only t))

;;;; Constructors & Public Helpers ----------------------------------------

(cl-defun kargu-edit-service-create (&key root review-mode (auto-save t) policy-revision service-id)
  "Create and return an explicit `kargu-edit-service' context.
ROOT is the optional root directory.
REVIEW-MODE defaults to `auto'.
AUTO-SAVE defaults to t.
POLICY-REVISION defaults to 0.
SERVICE-ID is an optional string identifier."
  (kargu-edit-service--create
   :service-id (or service-id (format "edit-%s" (kargu-edit--random-uuid)))
   :root (and root (file-truename root))
   :snapshots (make-hash-table :test #'equal)
   :changes (make-hash-table :test #'equal)
   :reviews (make-hash-table :test #'equal)
   :active-plans (make-hash-table :test #'equal)
   :policy-revision (or policy-revision 0)
   :review-mode (or review-mode 'auto)
   :auto-save (if (null auto-save) nil t)))

(defun kargu-edit-service-closed-p (service)
  "Return non-nil if edit SERVICE has been closed."
  (and (kargu-edit-service-p service)
       (kargu-edit-service-closed service)))

(defun kargu-edit-service--close-review (review)
  "Release only the control and private buffers recorded in REVIEW."
  (let ((control (plist-get review :ediff-control)))
    (when (buffer-live-p control)
      (with-current-buffer control
        (remove-hook 'ediff-quit-hook #'kargu-diff--ediff-quit t)
        (condition-case nil
            (if (fboundp 'ediff-really-quit) (ediff-really-quit nil)
              (kill-buffer control))
          (error (when (buffer-live-p control) (kill-buffer control)))))))
  (dolist (buffer (list (plist-get review :base-buffer)
                        (plist-get review :shadow-buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

(defun kargu-edit-service-close (service)
  "Revoke edit SERVICE before closing only its own resources."
  (when (and (kargu-edit-service-p service) (not (kargu-edit-service-closed service)))
    (setf (kargu-edit-service-closed service) t)
    (maphash (lambda (_path review) (kargu-edit-service--close-review review))
             (kargu-edit-service-reviews service))
    (dolist (process (kargu-edit-service-processes service))
      (when (processp process) (kargu-process-cancel process)))
    (dolist (timer (kargu-edit-service-timers service))
      (when (timerp timer) (cancel-timer timer)))
    (dolist (buffer (kargu-edit-service-buffers service))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))
    (dolist (directory (kargu-edit-service-temp-dirs service))
      (when (file-directory-p directory) (delete-directory directory t)))
    (mapc #'clrhash (list (kargu-edit-service-snapshots service)
                          (kargu-edit-service-changes service)
                          (kargu-edit-service-reviews service)
                          (kargu-edit-service-active-plans service)))
    (setf (kargu-edit-service-processes service) nil
          (kargu-edit-service-timers service) nil
          (kargu-edit-service-buffers service) nil
          (kargu-edit-service-temp-dirs service) nil
          (kargu-edit-service-run-modified-files service) nil)
    t))

;;;; Resource Registration Helpers ----------------------------------------

(defun kargu-edit-service-register-temp-dir (service dir)
  "Register temporary directory DIR with edit SERVICE."
  (when (and service (kargu-edit-service-p service) dir)
    (cl-pushnew dir (kargu-edit-service-temp-dirs service) :test #'equal)))

(defun kargu-edit-service-unregister-temp-dir (service dir)
  "Unregister temporary directory DIR from edit SERVICE."
  (when (and service (kargu-edit-service-p service) dir)
    (setf (kargu-edit-service-temp-dirs service)
          (delete dir (kargu-edit-service-temp-dirs service)))))

(defun kargu-edit-service-register-process (service proc)
  "Register process PROC with edit SERVICE."
  (when (and service (kargu-edit-service-p service) proc)
    (cl-pushnew proc (kargu-edit-service-processes service))))

(defun kargu-edit-service-unregister-process (service proc)
  "Unregister process PROC from edit SERVICE."
  (when (and service (kargu-edit-service-p service) proc)
    (setf (kargu-edit-service-processes service)
          (delq proc (kargu-edit-service-processes service)))))

(defun kargu-edit-service-register-timer (service timer)
  "Register TIMER with edit SERVICE."
  (when (and service (kargu-edit-service-p service) timer)
    (cl-pushnew timer (kargu-edit-service-timers service))))

(defun kargu-edit-service-unregister-timer (service timer)
  "Unregister TIMER from edit SERVICE."
  (when (and service (kargu-edit-service-p service) timer)
    (setf (kargu-edit-service-timers service)
          (delq timer (kargu-edit-service-timers service)))))

(defun kargu-edit-service-register-buffer (service buf)
  "Register buffer BUF with edit SERVICE."
  (when (and service (kargu-edit-service-p service) (buffer-live-p buf))
    (cl-pushnew buf (kargu-edit-service-buffers service))))

(defun kargu-edit-service-unregister-buffer (service buf)
  "Unregister buffer BUF from edit SERVICE."
  (when (and service (kargu-edit-service-p service) buf)
    (setf (kargu-edit-service-buffers service)
          (delq buf (kargu-edit-service-buffers service)))))

;;;; Plan & Outcome Constructors ------------------------------------------

(cl-defun kargu-edit-plan-create (&key path kind proposed-content expected-revision
                                       policy-revision session-id run-id app-id
                                       review-mode auto-save metadata plan-id)
  "Create an immutable `kargu-edit-plan' capturing proposal and environment.
PATH is the target file path.
KIND is one of :block, :symbol, :unified-diff, :write.
PROPOSED-CONTENT is the proposed modification content.
EXPECTED-REVISION is the expected `kargu-file-revision'.
POLICY-REVISION is the integer policy generation.
SESSION-ID, RUN-ID, and APP-ID capture execution identity.
REVIEW-MODE and AUTO-SAVE capture policy flags.
METADATA contains optional auxiliary properties.
PLAN-ID is an optional string identifier."
  (unless (and (stringp path) (not (string-empty-p (string-trim path))))
    (error "PATH must be a non-empty string"))
  (unless (memq kind '(:block :symbol :unified-diff :write))
    (error "KIND must be one of :block, :symbol, :unified-diff, :write"))
  (let ((resolved (file-truename (kargu-permission-resolve path "file"))))
    (kargu-edit-plan--create
     :plan-id (or plan-id (format "plan-%s" (kargu-edit--random-uuid)))
     :path resolved
     :kind kind
     :proposed-content proposed-content
     :expected-revision (or expected-revision (kargu-file-current-revision resolved))
     :policy-revision (or policy-revision 0)
     :session-id session-id
     :run-id run-id
     :app-id app-id
     :review-mode review-mode
     :auto-save auto-save
     :metadata metadata)))

(cl-defun kargu-edit-outcome-create (&key plan-id path status post-revision
                                          hunks-applied hunks-total message saved
                                          hook-transformed decided-content snapshot
                                          rollback-status write-effects)
  "Create a unified `kargu-edit-outcome' struct.
PLAN-ID is the plan identifier.
PATH is the modified file path.
STATUS is a symbol indicating the transaction result.
POST-REVISION is the post-write `kargu-file-revision'.
HUNKS-APPLIED is the count of applied hunks.
HUNKS-TOTAL is the total count of proposed hunks.
MESSAGE is a model/human-facing description.
SAVED is non-nil if disk write succeeded.
HOOK-TRANSFORMED is non-nil if save hooks altered file content.
DECIDED-CONTENT is the accepted text.
SNAPSHOT is the recorded rollback snapshot.
ROLLBACK-STATUS is the rollback state if attempted.
WRITE-EFFECTS contains write effect properties."
  (kargu-edit-outcome--create
   :plan-id plan-id
   :path path
   :status status
   :post-revision post-revision
   :hunks-applied (or hunks-applied 0)
   :hunks-total (or hunks-total 0)
   :message message
   :saved saved
   :hook-transformed hook-transformed
   :decided-content decided-content
   :snapshot snapshot
   :rollback-status rollback-status
   :write-effects write-effects))

;;;; Service Resolution & Dynamic Context ---------------------------------

(defvar kargu-diff--active-service nil
  "Dynamically bound active `kargu-edit-service', or nil for default.")

(defvar-local kargu-diff--execution-service nil
  "Session and edit service attached by native composition, or nil.")

(defvar kargu-diff--default-service
  (kargu-edit-service--create
   :service-id "edit-default"
   :root nil
   :snapshots (make-hash-table :test #'equal)
   :changes (make-hash-table :test #'equal)
   :reviews (make-hash-table :test #'equal)
   :active-plans (make-hash-table :test #'equal)
   :policy-revision 0)
  "Default edit service singleton.")

(defun kargu-diff--get-default-service ()
  "Return `kargu-diff--default-service', keeping its tables synchronized."
  (when (or (null kargu-diff--default-service)
            (kargu-edit-service-closed kargu-diff--default-service))
    (setq kargu-diff--default-service
          (kargu-edit-service--create
           :service-id "edit-default"
           :root nil
           :snapshots (if (boundp 'kargu-diff--snapshots) kargu-diff--snapshots (make-hash-table :test #'equal))
           :changes (if (boundp 'kargu-diff--changed) kargu-diff--changed (make-hash-table :test #'equal))
           :reviews (if (boundp 'kargu-diff--sessions) kargu-diff--sessions (make-hash-table :test #'equal))
           :active-plans (make-hash-table :test #'equal)
           :policy-revision 0)))
  (when (boundp 'kargu-diff--snapshots)
    (setf (kargu-edit-service-snapshots kargu-diff--default-service) kargu-diff--snapshots))
  (when (boundp 'kargu-diff--changed)
    (setf (kargu-edit-service-changes kargu-diff--default-service) kargu-diff--changed))
  (when (boundp 'kargu-diff--sessions)
    (setf (kargu-edit-service-reviews kargu-diff--default-service) kargu-diff--sessions))
  kargu-diff--default-service)

(defun kargu-diff--current-service ()
  "Return the explicitly active edit service or the compatibility default.
An explicitly closed service never silently acquires another owner's state."
  (let ((service (or kargu-diff--active-service
                     (and (eq (car kargu-diff--execution-service) (kargu-session-context))
                          (cdr kargu-diff--execution-service))
                     (kargu-diff--get-default-service))))
    (when (kargu-edit-service-closed-p service) (error "Edit service is closed"))
    service))

(defmacro kargu-diff-with-service (service &rest body)
  "Execute BODY with SERVICE bound as the active `kargu-edit-service'."
  (declare (indent 1))
  `(let* ((kargu-diff--active-service ,service)
          (kargu-permission--override-root
           (or (kargu-edit-service-root kargu-diff--active-service)
               kargu-permission--override-root))
          (kargu-diff-review-mode
           (if (eq kargu-diff--active-service kargu-diff--default-service)
               kargu-diff-review-mode
             (kargu-edit-service-review-mode kargu-diff--active-service)))
          (kargu-diff-auto-save
           (if (eq kargu-diff--active-service kargu-diff--default-service)
               kargu-diff-auto-save
             (kargu-edit-service-auto-save kargu-diff--active-service))))
     (kargu-diff--current-service)
     ,@body))

(defun kargu-diff--service-snapshots (&optional service)
  "Return SERVICE's snapshot table, defaulting to the active owner."
  (kargu-edit-service-snapshots (or service (kargu-diff--current-service))))

(defun kargu-diff--service-changes (&optional service)
  "Return SERVICE's change table, defaulting to the active owner."
  (kargu-edit-service-changes (or service (kargu-diff--current-service))))

(defun kargu-diff--service-reviews (&optional service)
  "Return SERVICE's review table, defaulting to the active owner."
  (kargu-edit-service-reviews (or service (kargu-diff--current-service))))

;;;; Transaction Plan Execution & Submission ------------------------------

(defun kargu-edit--build-outcome (plan resolved raw)
  "Construct a `kargu-edit-outcome' from PLAN, RESOLVED path, and RAW outcome."
  (let* ((plan-id (kargu-edit-plan-plan-id plan))
         (post-rev (kargu-file-current-revision resolved))
         (is-plist (listp raw))
         (raw-status (and is-plist (plist-get raw :status)))
         (status (cond
                  ((memq raw-status '(:applied :applied-full)) :applied)
                  ((eq raw-status :applied-partial) :partial)
                  ((eq raw-status :staged) :staged)
                  ((eq raw-status :conflict) :conflict)
                  ((eq raw-status :rejected) :rejected)
                  ((eq raw-status :interrupted) :interrupted)
                  ((eq raw-status :unchanged) :unchanged)
                  ((eq raw-status :rolled-back) :rolled-back)
                  ((eq raw-status :error) :error)
                  (t :unknown)))
         (saved (and is-plist (plist-get raw :saved)))
         (hook-transformed (if is-plist (plist-get raw :hook-transformed) nil))
         (decided (if is-plist (plist-get raw :decided-content) nil))
         (snap (if is-plist (plist-get raw :snapshot) nil))
         (rollback-status (if is-plist (plist-get raw :rollback-status) nil))
         (msg (cond
               ((and is-plist (plist-get raw :message)) (plist-get raw :message))
               ((stringp raw) raw)
               ((and is-plist (fboundp 'kargu-diff--describe))
                (kargu-diff--describe raw))
               (t (format "Edit of %s finished with status %s" resolved status)))))
    (kargu-edit-outcome-create
     :plan-id plan-id
     :path resolved
     :status status
     :post-revision post-rev
     :hunks-applied (if (memq status '(:applied :partial)) 1 0)
     :hunks-total 1
     :message msg
     :saved saved
     :hook-transformed hook-transformed
     :decided-content decided
     :snapshot snap
     :rollback-status rollback-status
     :write-effects (list :post-revision post-rev
                          :saved saved
                          :hook-transformed hook-transformed))))

(defun kargu-edit--execute-plan (service plan resolved callback)
  "Execute PLAN for RESOLVED path in SERVICE with CALLBACK."
  (let* ((kind (kargu-edit-plan-kind plan))
         (content (kargu-edit-plan-proposed-content plan))
         (plan-id (kargu-edit-plan-plan-id plan))
         (metadata (kargu-edit-plan-metadata plan))
         (handle-outcome
          (lambda (raw)
            (remhash plan-id (kargu-edit-service-active-plans service))
            (let ((outcome (kargu-edit--build-outcome plan resolved raw)))
              (cond
               ((eq (kargu-edit-outcome-status outcome) :conflict)
                (kargu-err (kargu-edit-outcome-message outcome) :conflict outcome))
               ((eq (kargu-edit-outcome-status outcome) :error)
                (kargu-err (kargu-edit-outcome-message outcome) :edit-failed outcome))
               (t
                (kargu-ok outcome)))))))
    (pcase kind
      (:block
       (let ((old-str (or (and (listp content) (plist-get content :old-string))
                          (and (consp content) (car content))
                          (and (listp metadata) (plist-get metadata :old-string))))
             (new-str (or (and (listp content) (plist-get content :new-string))
                          (and (consp content) (cdr content))
                          (and (stringp content) content)
                          (and (listp metadata) (plist-get metadata :new-string)))))
         (unless (and (stringp old-str) (not (string-empty-p old-str)))
           (error "Old_string is required for :block edit"))
         (unless (stringp new-str)
           (error "New_string is required for :block edit"))
         (if callback
             (kargu-diff-apply-replace
              resolved old-str new-str
              (lambda (raw) (funcall callback (funcall handle-outcome raw))))
           (funcall handle-outcome (kargu-diff-apply-replace resolved old-str new-str nil)))))
      ((or :write :symbol)
       (let ((new-text (if (stringp content) content (plist-get metadata :text))))
         (unless (stringp new-text)
           (error "Proposed content must be a string for %s edit" kind))
         (if callback
             (kargu-diff-apply-proposal
              resolved new-text
              (lambda (raw) (funcall callback (funcall handle-outcome raw))))
           (funcall handle-outcome (kargu-diff-apply-proposal resolved new-text nil)))))
      (:unified-diff
       (let ((patch-text (if (stringp content) content (plist-get metadata :patch))))
         (unless (stringp patch-text)
           (error "Proposed content must be a patch string for :unified-diff edit"))
         (if callback
             (kargu-diff-apply-patch
              patch-text
              (lambda (summary)
                (funcall callback
                         (funcall handle-outcome
                                  (list :status :unknown
                                        :file resolved
                                        :message summary)))))
           (let ((summary (kargu-diff-apply-patch patch-text nil)))
             (funcall handle-outcome
                      (list :status :unknown
                            :file resolved
                            :message summary)))))))))

(defun kargu-diff--submit-plan-impl (service plan callback)
  "Submit transaction PLAN to edit SERVICE, delivering result to CALLBACK."
  (unless (and service (kargu-edit-service-p service))
    (error "SERVICE must be a kargu-edit-service: %S" service))
  (if (kargu-edit-service-closed service)
      (let ((err (kargu-err "Edit service is closed" :service-closed)))
        (if callback (funcall callback err) err))
    (unless (and plan (kargu-edit-plan-p plan))
      (error "PLAN must be a kargu-edit-plan: %S" plan))
    (let* ((path (kargu-edit-plan-path plan))
           (plan-id (kargu-edit-plan-plan-id plan))
           (expected-rev (kargu-edit-plan-expected-revision plan))
           (policy-rev (kargu-edit-plan-policy-revision plan))
           (session-id (kargu-edit-plan-session-id plan)))
      ;; 1. Policy revision re-verification (ARCH-03, Task 2)
      (if (/= (kargu-edit-service-policy-revision service) policy-rev)
          (let ((err (kargu-err "Policy revision mismatch; edit plan invalidated" :policy-conflict)))
            (if callback (funcall callback err) err))
        ;; 2. Session re-verification
        (let* ((curr-sess (and (fboundp 'kargu-session-context) (kargu-session-context)))
               (curr-sess-id (cond
                              ((null curr-sess) nil)
                              ((fboundp 'kargu-session-id) (kargu-session-id curr-sess))
                              ((fboundp 'kargu-session-id-value) (kargu-session-id-value curr-sess))
                              (t curr-sess))))
          (if (and session-id (not (equal session-id curr-sess-id)))
              (let ((err (kargu-err "Session mismatch; edit plan invalidated" :session-conflict)))
                (if callback (funcall callback err) err))
            ;; 3. Document revision re-verification (ARCH-03 / ARCH-04 / DEEP-10)
            (let* ((resolved (kargu-permission-resolve path "file" (kargu-edit-service-root service)))
                   (curr-rev (kargu-file-current-revision resolved))
                   (buf (find-buffer-visiting resolved)))
              (cond
               ((and (buffer-live-p buf) (buffer-modified-p buf))
                (let ((err (kargu-err (format "Buffer %s has unsaved modifications" (buffer-name buf)) :conflict)))
                  (if callback (funcall callback err) err)))
               ((and expected-rev (not (equal curr-rev expected-rev)))
                (let ((err (kargu-err (format "Document revision changed for %s before apply" resolved) :conflict)))
                  (if callback (funcall callback err) err)))
               (t
                (puthash plan-id plan (kargu-edit-service-active-plans service))
                (kargu-diff-with-service service
                  (kargu-edit--execute-plan service plan resolved callback)))))))))))

(defun kargu-diff-submit-plan (service plan &rest args)
  "Submit transaction PLAN to edit SERVICE, delivering result to CALLBACK.
Supports both positional (SERVICE PLAN &optional CALLBACK)
and keyword (SERVICE PLAN &key CALLBACK) invocations.
When CALLBACK is nil, returns `(kargu-ok outcome)' or `(kargu-err ...)'.
When CALLBACK is non-nil, delivers the result asynchronously to CALLBACK."
  (let ((callback (cond
                   ((and (consp args) (eq (car args) :callback))
                    (cadr args))
                   ((consp args)
                    (car args))
                   (t nil))))
    (kargu-diff--submit-plan-impl service plan callback)))

(defalias 'kargu-edit-submit-plan #'kargu-diff-submit-plan)

(provide 'kargu/tools/diff/context)
;;; context.el ends here
