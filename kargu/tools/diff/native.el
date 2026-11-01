;;; native.el --- Native edit consumer and passive undo references -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Explicitly select the native port for a whole operation.  A failed selected
;; operation never falls through to another writer.  UI rows hold references,
;; while Rust alone owns rollback bodies and their current evidence.

;;; Code:

(require 'kargu/tools/diff/context)
(require 'kargu/bridge/edit/batch)

(declare-function kargu-diff--capture-baseline-diagnostics "kargu/tools/diff/track" (path))

(defvar kargu-diff-review-mode)
(defvar kargu-diff-auto-save)

(defcustom kargu-diff-native-edit-enabled nil
  "Use the asynchronous native edit port for tool and LSP edits.
Enable explicitly while the remaining migration acceptance work is open."
  :type 'boolean :group 'kargu)

(defun kargu-diff-native-enabled-p ()
  "Whether the native edit port is explicitly selected."
  kargu-diff-native-edit-enabled)

(defun kargu-diff-native-describe (result)
  "Describe verified RESULT without inventing an unmeasured hunk count."
  (if (plist-get result :message)
      (format "ERROR: %s" (plist-get result :message))
    (let ((applied (plist-get result :hunks-applied)) (total (plist-get result :hunks-total)))
    (format "%s to %d file(s) (%s%s)"
            (if (eq (plist-get result :status) :applied-full)
                "Patch successfully applied" "Patch NOT fully applied")
            (or (plist-get result :files-total) 0)
            (if (and (integerp applied) (integerp total))
                (format "%d/%d hunks applied" applied total) "hunk count unmeasured")
            (if (plist-get result :saved) "; files saved" "")))))

(defconst kargu-diff-native--base-bytes (* 48 1024 1024)
  "Conservative UTF-8 byte bound for cached display baselines on one service.")

(defun kargu-diff-native--prune-references (service)
  "Discard SERVICE's native display rows outside its retained edit IDs."
  (let ((snapshots (kargu-edit-service-snapshots service)) remove)
    (maphash
     (lambda (path rows)
       (let ((retained (cl-remove-if
                        (lambda (row)
                          (and (plist-get row :native)
                               (not (member (plist-get row :edit-id)
                                            (kargu-edit-service-native-edits service))))) rows)))
         (if retained (puthash path retained snapshots) (push path remove)))) snapshots)
    (dolist (path remove) (remhash path snapshots))))

(defun kargu-diff-native--reference-bytes (service)
  "Count retained native display baseline bytes on SERVICE."
  (let ((total 0))
    (maphash (lambda (_path rows)
               (dolist (row rows)
                 (when (plist-get row :native)
                   (setq total (+ total (or (plist-get row :content-bytes) 0))))))
             (kargu-edit-service-snapshots service))
    total))

(defun kargu-diff-native--retain-references (service result)
  "Bound SERVICE's display references after archiving verified RESULT.
These IDs are presentation history; only Rust decides whether undo is available."
  (when (plist-get result :rollback-available)
    (setf (kargu-edit-service-native-edits service)
          (seq-take (cons (plist-get result :edit-id)
                          (delete (plist-get result :edit-id) (kargu-edit-service-native-edits service))) 16)))
  (kargu-diff-native--prune-references service)
  (while (and (kargu-edit-service-native-edits service)
              (> (kargu-diff-native--reference-bytes service) kargu-diff-native--base-bytes))
    (setf (kargu-edit-service-native-edits service) (butlast (kargu-edit-service-native-edits service)))
    (kargu-diff-native--prune-references service)))

(defun kargu-diff-native--failure-result (failure)
  "Translate native RPC FAILURE into a structured consumer result."
  (let* ((data (and (hash-table-p failure) (gethash "data" failure)))
         (raw-status (or (and (hash-table-p failure) (gethash "status" failure))
                         (and (hash-table-p data) (gethash "status" data))))
         (message (or (and (hash-table-p failure) (gethash "message" failure))
                      (and (stringp failure) failure)
                      (format "%s" failure)))
         (status (pcase raw-status
                   ("rejected" :rejected)
                   ("cancelled" :interrupted)
                   ("timeout" :timeout)
                   ("outcome_unknown" :outcome-unknown)
                   ((or "conflict" "workspace_changed" "missing_match"
                        "ambiguous_match" "missing_target" "patch_failed")
                    :conflict)
                   (_ :error))))
    (list :status status :saved nil :message message :native-failure failure)))

(defun kargu-diff-native--project (service spec result)
  "Update SERVICE's passive references from SPEC and verified RESULT."
  (dolist (file (plist-get result :files))
    (when (memq (plist-get file :status) '(:applied :partial))
      (let* ((path (plist-get file :path))
             (snapshots (kargu-edit-service-snapshots service))
             (changes (kargu-edit-service-changes service))
             (stack (gethash path snapshots))
             (baseline (plist-get file :baseline)))
        (if (and (eq (plist-get spec :intent) :rollback)
                 (eq (plist-get file :status) :applied))
            (progn
              (setq stack (cl-remove (plist-get spec :target-edit-id) stack
                                     :key (lambda (row) (plist-get row :edit-id)) :test #'equal))
              (if stack
                  (puthash path stack snapshots)
                (remhash path snapshots)
                (remhash path changes)
                (setf (kargu-edit-service-run-modified-files service)
                      (delete path (kargu-edit-service-run-modified-files service)))))
          (when (and (eq (plist-get file :status) :applied)
                     (plist-get result :rollback-available))
            (puthash path
                     (seq-take
                      (cons (list :native t :edit-id (plist-get result :edit-id)
                                  :root (plist-get result :root)
                                  :application (plist-get spec :application)
                                  :content (plist-get file :base)
                                  :content-bytes (if (stringp (plist-get file :base))
                                                     (string-bytes (encode-coding-string (plist-get file :base) 'utf-8-unix)) 0)
                                  :created-new (not (plist-get file :existed))
                                  :baseline-diagnostics (plist-get baseline :diagnostics)
                                  :baseline-available (plist-get baseline :available))
                            stack)
                      16)
                     snapshots))
          (puthash path
                   (list :native t :edit-id (plist-get result :edit-id)
                         :service-id (plist-get spec :service-id)
                         :application (plist-get spec :application)
                         :root (plist-get result :root)
                         :relative (plist-get file :relative)
                         :file-index (or (plist-get file :file-index) 0)
                         :final-hash (plist-get file :final-hash)
                         :status (plist-get file :status)
                         :saved (plist-get file :saved)
                         :baseline baseline
                         :baseline-diagnostics (plist-get baseline :diagnostics)
                         :baseline-available (plist-get baseline :available))
                   changes)
          (cl-pushnew path (kargu-edit-service-run-modified-files service) :test #'equal)))))
  (kargu-diff-native--retain-references service result))

(defun kargu-diff-native-execute (spec callback &optional service)
  "Execute SPEC into CALLBACK on captured SERVICE; never choose another writer."
  (if (null callback) "ERROR: Native edits require an asynchronous callback"
    (let* ((service (or service (kargu-diff--current-service)))
           (spec (copy-tree spec))
           (policy (kargu-edit-service-policy-revision service))
           (review (if (eq service kargu-diff--default-service) kargu-diff-review-mode
                     (kargu-edit-service-review-mode service)))
           (save (if (eq service kargu-diff--default-service) kargu-diff-auto-save
                   (kargu-edit-service-auto-save service))) task)
      (let ((application (or (plist-get spec :application)
                             (kargu-edit-service-native-application service)
                             (kargu-application-context))))
        (when (and (kargu-edit-service-native-application service)
                   (not (eq application (kargu-edit-service-native-application service))))
          (error "Native edit service belongs to another application"))
        (setf (kargu-edit-service-native-application service) application
              (plist-get spec :application) application))
      (setf (plist-get spec :root) (or (plist-get spec :root) (kargu-edit-service-root service)
                                       (kargu-permission-project-root))
            (plist-get spec :service-id)
            (or (kargu-edit-service-native-id service)
                (setf (kargu-edit-service-native-id service) (concat "edit_service_" (kargu-random-uuid))))
            (plist-get spec :application) (or (plist-get spec :application) (kargu-application-context))
            (plist-get spec :review-mode) (or (plist-get spec :review-mode) review)
            (plist-get spec :save-policy) (or (plist-get spec :save-policy) (if save 'save 'buffer_only))
            (plist-get spec :capture-baseline) #'kargu-diff--capture-baseline-diagnostics
            (plist-get spec :policy-revision) policy
            (plist-get spec :valid-p)
            (lambda ()
              (and (not (kargu-edit-service-closed service))
                   (= policy (kargu-edit-service-policy-revision service))
                   (eq review (if (eq service kargu-diff--default-service) kargu-diff-review-mode
                                (kargu-edit-service-review-mode service)))
                   (eq save (if (eq service kargu-diff--default-service) kargu-diff-auto-save
                              (kargu-edit-service-auto-save service))))))
      (setq task
            (kargu-bridge-edit-batch-execute
             spec (lambda (result failure)
                    (unless (kargu-edit-service-closed service)
                      (if failure
                          (funcall callback (kargu-diff-native--failure-result failure))
                        (kargu-diff-native--project service spec result)
                        (funcall callback result))))))
      (push task (kargu-edit-service-native-tasks service))
      (kargu-async-add-cleanup
       task (lambda () (setf (kargu-edit-service-native-tasks service)
                             (delq task (kargu-edit-service-native-tasks service)))))
      'deferred)))

(cl-defun kargu-diff-native-rollback (path &key single-step service callback)
  "Rollback PATH on SERVICE asynchronously into CALLBACK.
SINGLE-STEP consumes one native snapshot; otherwise continue to the oldest."
  (let* ((service (or service (kargu-diff--current-service)))
         (row (car (gethash path (kargu-edit-service-snapshots service)))))
    (unless (plist-get row :native) (error "No native snapshot for %s" path))
    (when (and (not single-step)
               (cl-some (lambda (entry) (not (plist-get entry :native)))
                        (gethash path (kargu-edit-service-snapshots service))))
      (error "Use single-step rollback to cross native and legacy history"))
    (kargu-diff-native-execute
     (list :intent :rollback :path path :root (plist-get row :root)
           :application (plist-get row :application) :target-edit-id (plist-get row :edit-id))
     (lambda (result)
       (if (and (eq (plist-get result :status) :applied-full) (not single-step)
                (plist-get (car (gethash path (kargu-edit-service-snapshots service))) :native))
           (kargu-diff-native-rollback path :service service :callback callback)
         (when callback (funcall callback result)))) service)))

(provide 'kargu/tools/diff/native)
;;; native.el ends here
