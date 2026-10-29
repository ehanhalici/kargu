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

(defun kargu-diff-native--retain-references (service result)
  "Bound SERVICE's display references after archiving verified RESULT.
These IDs are presentation history; only Rust decides whether undo is available."
  (when (plist-get result :rollback-available)
    (setf (kargu-edit-service-native-edits service)
          (seq-take (cons (plist-get result :edit-id)
                          (delete (plist-get result :edit-id) (kargu-edit-service-native-edits service))) 16))
    (let ((snapshots (kargu-edit-service-snapshots service)) remove)
      (maphash
       (lambda (path rows)
         (let ((retained (cl-remove-if
                          (lambda (row)
                            (and (plist-get row :native)
                                 (not (member (plist-get row :edit-id)
                                              (kargu-edit-service-native-edits service))))) rows)))
           (if retained (puthash path retained snapshots) (push path remove)))) snapshots)
      (dolist (path remove) (remhash path snapshots)))))

(defun kargu-diff-native--project (service spec result)
  "Update SERVICE's passive references from SPEC and verified RESULT."
  (kargu-diff-native--retain-references service result)
  (dolist (file (plist-get result :files))
    (when (memq (plist-get file :status) '(:applied :partial))
      (let* ((path (plist-get file :path))
             (snapshots (kargu-edit-service-snapshots service))
             (stack (gethash path snapshots)))
        (when (eq (plist-get file :status) :applied)
          (if (eq (plist-get spec :intent) :rollback)
              (progn
		(setq stack (cl-remove (plist-get spec :target-edit-id) stack
                                       :key (lambda (row) (plist-get row :edit-id)) :test #'equal))
		(if stack (puthash path stack snapshots) (remhash path snapshots)))
            (when (plist-get result :rollback-available)
              (puthash path
                       (seq-take (cons (list :native t :edit-id (plist-get result :edit-id)
                                             :root (plist-get result :root)
                                             :application (plist-get spec :application)) stack) 16)
                       snapshots))))
        (puthash path (list :native t :edit-id (plist-get result :edit-id))
                 (kargu-edit-service-changes service))
        (cl-pushnew path (kargu-edit-service-run-modified-files service) :test #'equal)))))

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
      (setf (plist-get spec :root) (or (plist-get spec :root) (kargu-edit-service-root service)
                                       (kargu-permission-project-root))
            (plist-get spec :application) (or (plist-get spec :application) (kargu-application-context))
            (plist-get spec :review-mode) review
            (plist-get spec :save-policy) (if save 'save 'buffer_only)
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
                          (funcall callback (list :status :error :message (format "%s" failure)))
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
