;;; batch.el --- Asynchronous native edit batch coordinator -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Freeze every proposal and document before preflight.  Issued handlers perform
;; only editor primitives; Rust retains approval, outcome and rollback ownership.

;;; Code:

(require 'cl-lib)
(require 'kargu/async)
(require 'kargu/bridge/edit)
(require 'kargu/bridge/edit/batch/read)
(require 'kargu/bridge/edit/batch/review)
(require 'kargu/bridge/edit/activity)
(require 'kargu/permission)
(require 'kargu/state)

(defvar kargu-diff-review-mode)
(defvar kargu-diff-auto-save)
(declare-function kargu-permission-project-root "kargu/permission/guards" ())

(defcustom kargu-bridge-edit-batch-journal-directory
  (locate-user-emacs-file "kargu/edit-journals/")
  "Private persistent directory retaining native edit journals."
  :type 'directory :group 'kargu)

(defun kargu-bridge-edit-batch--journal-directory ()
  "Return the persistent private journal directory, creating it if absent."
  (let ((directory (expand-file-name kargu-bridge-edit-batch-journal-directory)))
    (unless (file-exists-p directory)
      (make-directory directory t)
      (set-file-modes directory #o700))
    directory))

(defun kargu-bridge-edit-batch--random-origin ()
  "Return a fresh native editor source identity."
  (concat "editor_source_" (kargu-random-uuid)))

(defun kargu-bridge-edit-batch--arguments (spec root)
  "Build frozen preparation arguments from SPEC and trusted ROOT."
  (let* ((intent (plist-get spec :intent))
         (mode (or (plist-get spec :mode) (kargu-state-mode)))
         (review (or (plist-get spec :review-mode) kargu-diff-review-mode))
         (save (or (plist-get spec :save-policy) (if kargu-diff-auto-save 'save 'buffer_only)))
         (path (plist-get spec :path))
         (relative (and path (file-relative-name (expand-file-name path root) root)))
         (arguments
          (kargu-bridge--object
           "origin_id" (kargu-bridge-edit-batch--random-origin)
           "root" root "mode" (symbol-name mode) "live" :json-null
           "config_revision" (or (plist-get spec :config-revision) 0)
           "policy_revision" (or (plist-get spec :policy-revision) 0)
           "review_mode" (symbol-name review) "save_policy" (symbol-name save))))
    (unless (eq mode 'agent) (error "Native edits require agent mode"))
    (puthash "intent"
             (pcase intent
               (:replace (kargu-bridge--object "kind" "replace" "path" relative
                                               "old_bytes" (string-bytes (encode-coding-string (plist-get spec :old) 'utf-8-unix))
                                               "new_bytes" (string-bytes (encode-coding-string (plist-get spec :new) 'utf-8-unix))))
               (:write (kargu-bridge--object "kind" "write" "path" relative
                                             "new_bytes" (string-bytes (encode-coding-string (plist-get spec :content) 'utf-8-unix))))
               (:patch (kargu-bridge--object "kind" "patch"
                                             "patch_bytes" (string-bytes (encode-coding-string (plist-get spec :patch) 'utf-8-unix))))
               (:rollback :json-null)
               (_ (error "Unknown native edit intent"))) arguments)
    arguments))

(defun kargu-bridge-edit-batch--owned-dirty-p (view)
  "Whether native VIEW requires the exact owned dirty document."
  (let ((document (gethash "document" view)))
    (and (hash-table-p document) (eq (gethash "dirty" document) t))))

(defun kargu-bridge-edit-batch--apply (files live-p)
  "Apply frozen FILES only while LIVE-P owns the issuance."
  ;; One stale document prevents entry into every file in this batch.
  (dolist (file files)
    (kargu-bridge-edit-document-check (plist-get file :document)
                                      (kargu-bridge-edit-batch--owned-dirty-p (plist-get file :view))))
  (mapcar
   (lambda (file)
     (let* ((view (plist-get file :view))
            (document (plist-get file :document))
            (owned-dirty (kargu-bridge-edit-batch--owned-dirty-p view)))
       (if (equal (gethash "operation" view) "delete")
           (kargu-bridge-edit-document-delete document :check-issued live-p :owned-dirty owned-dirty)
         (kargu-bridge-edit-document-replace
          document (plist-get file :proposed) :check-issued live-p :owned-dirty owned-dirty
          :save (equal (gethash "save_policy" view) "save")
          :restore-coding (let ((coding (gethash "restore_coding" view)))
                            (and (stringp coding) (intern coding)))
          :restore-clean (eq (gethash "restore_dirty" view) :json-false)))))
   files))

(defun kargu-bridge-edit-batch--result (native root)
  "Project verified NATIVE facts under ROOT into a consumer result."
  (let* ((receipt (gethash "receipt" native))
         (files (mapcar
                 (lambda (file)
                   (list :path (expand-file-name (gethash "path" file) root)
                         :status (intern (concat ":" (replace-regexp-in-string "_" "-" (gethash "outcome" file))))
                         :saved (eq (gethash "saved" file) t)
                         :hunks (gethash "hunks" file)
                         :hook-transformed (eq (gethash "hook_modified" file) t)))
                 (append (gethash "files" receipt) nil))))
    (list :status (intern (concat ":" (replace-regexp-in-string "_" "-" (gethash "outcome" receipt))))
          :file (and (= (length files) 1) (plist-get (car files) :path))
          :files files :root root :edit-id (gethash "edit_id" native)
          :rollback-available (eq (gethash "rollback_available" native) t)
          :files-total (gethash "files_total" receipt) :files-applied (gethash "files_applied" receipt)
          :hunks-total (gethash "hunks_total" receipt) :hunks-applied (gethash "hunks_applied" receipt)
          :hook-transformed (cl-some (lambda (file) (plist-get file :hook-transformed)) files)
          :saved (and files (cl-every (lambda (file) (plist-get file :saved)) files)) :native native)))

(defun kargu-bridge-edit-batch--freeze (spec)
  "Detach SPEC's mutable strings before the first asynchronous boundary."
  (let ((copy (copy-sequence spec)))
    (dolist (key '(:path :root :old :new :content :patch :target-edit-id :journal-directory))
      (when (stringp (plist-get copy key))
        (setf (plist-get copy key) (copy-sequence (plist-get copy key)))))
    copy))

(defun kargu-bridge-edit-batch-execute (spec &optional callback)
  "Start SPEC asynchronously, returning its task and delivering CALLBACK once.
SPEC requires a trusted :root or configured project root.  :intent is :replace,
:write, :patch or :rollback.  Review and save policies are frozen at entry."
  (let* ((spec (kargu-bridge-edit-batch--freeze spec))
         (source (current-buffer))
         (session (kargu-session-context))
         (mode-revision (kargu-session-mode-revision session))
         (directory default-directory)
         (valid-p (lambda ()
                    (and (eq session (kargu-session-context))
                         (= mode-revision (kargu-session-mode-revision session))
                         (eq (kargu-state-mode) 'agent)
                         (equal directory default-directory)
                         (or (null (plist-get spec :valid-p))
                             (funcall (plist-get spec :valid-p))))))
         (task (kargu-async-start (or callback #'ignore) :timeout 300 :valid-p valid-p))
         artifact activity)
    (cl-labels
        ((finish (value failure) (kargu-async-finish task value failure))
         (guard (function)
           (kargu-async-wrap task (lambda (value failure)
                                    (if failure (finish nil failure) (funcall function value)))))
         (ready (value)
           (setq artifact value)
           (kargu-async-add-cleanup task (lambda () (kargu-bridge-edit-release artifact)))
           (kargu-bridge-edit-batch-read-proposals
            artifact (guard (lambda (files) (authorize files)))))
         (authorize (files)
           (dolist (file files)
             (setf (plist-get file :document)
                   (kargu-bridge-edit-batch-read-document (gethash "path" (plist-get file :view)))))
           (kargu-bridge-edit-authorize
            artifact (or (plist-get spec :presenter) 'available)
            (guard
             (lambda (value)
               (let ((edit (gethash "edit_id" value)) (revision (gethash "revision" value)))
                 (pcase (gethash "state" value)
                   ("authorized" (preflight files edit revision))
                   ("review"
                    (kargu-bridge-edit-batch-review
                     artifact files :edit edit :revision revision :task task
                     :callback (guard (lambda (decision)
                                        (preflight files edit (gethash "revision" decision))))))
                   (_ (error "Unexpected native authorization state"))))))))
         (preflight (files edit revision)
           (cl-labels ((next (remaining index last-value)
                         (if (null remaining) (issue files edit revision last-value)
                           (kargu-bridge-edit-preflight
                            artifact :edit-id edit :revision revision
                            :witness (kargu-bridge-edit-document-witness (plist-get (car remaining) :document) index)
                            :callback (guard (lambda (value) (next (cdr remaining) (1+ index) value)))))))
             (next files 0 nil)))
         (issue (files edit revision preflight)
           (setq activity
                 (kargu-bridge-edit-activity-start
                  artifact :edit-id edit :revision revision
                  :preflight-digest (gethash "preflight_digest" (gethash "preflight" preflight))
                  :journal-directory (or (plist-get spec :journal-directory)
                                         (kargu-bridge-edit-batch--journal-directory))
                  :valid-p (lambda () (and (kargu-async-pending-p task) (funcall valid-p)))
                  :handler (lambda (live-p) (kargu-bridge-edit-batch--apply files live-p))
                  :callback (guard (lambda (value)
                                     (finish (kargu-bridge-edit-batch--result
                                              (plist-get value :native) (plist-get spec :root)) nil)))))
           (kargu-async-add-cleanup task (lambda () (kargu-bridge-edit-activity-cancel activity))))
         (prepare-patch (application arguments)
           (kargu-bridge-edit-patch-inspect
            application arguments (plist-get spec :patch) :parent task
            :callback
            (guard (lambda (inspected)
                     (setq artifact inspected)
                     (kargu-async-add-cleanup task (lambda () (kargu-bridge-edit-release inspected)))
                     (attach-documents inspected 0 nil)))))
         (attach-documents (inspected offset remaining)
           (if remaining
               (let* ((view (car remaining))
                      (path (gethash "path" view))
                      (document (kargu-bridge-edit-batch-read-document
                                 (expand-file-name path (plist-get spec :root)))))
                 (kargu-bridge-edit-patch-document
                  inspected path (kargu-bridge-edit-document-facts document)
                  :text (kargu-bridge-edit-document-text document) :parent task
                  :callback (guard (lambda (_) (attach-documents inspected offset (cdr remaining))))))
             (if (eq offset :complete)
                 (kargu-bridge-edit-patch-prepare inspected (guard #'ready) :parent task)
               (kargu-bridge-edit-patch-targets
                inspected offset
                (guard (lambda (page)
                         (let ((next (gethash "next_offset" page)))
                           (unless (or (eq (gethash "complete" page) t) (> next offset))
                             (error "Invalid native target cursor"))
                           (attach-documents inspected
                                             (if (eq (gethash "complete" page) t) :complete next)
                                             (append (gethash "files" page) nil)))))))))
         (start ()
           (unless (funcall valid-p) (error "Native edit source is no longer current"))
           (let* ((root (or (plist-get spec :root) (kargu-permission-project-root)))
                  (application (or (plist-get spec :application) (kargu-application-context))))
             (unless (and root (file-name-absolute-p root) (not (file-remote-p root)))
               (error "Native edits require a trusted local project root"))
             (setf (plist-get spec :root) (expand-file-name root))
             (let ((arguments (kargu-bridge-edit-batch--arguments spec root)))
               (pcase (plist-get spec :intent)
                 (:rollback
                  (remhash "intent" arguments) (remhash "live" arguments)
                  (when (plist-get spec :target-edit-id)
                    (puthash "target_edit_id" (plist-get spec :target-edit-id) arguments))
                  (when (plist-get spec :path)
                    (puthash "target_file" (file-relative-name (plist-get spec :path) root) arguments))
                  (kargu-bridge-edit-rollback application arguments :parent task :callback (guard #'ready)))
                 (:patch (prepare-patch application arguments))
                 (_
                  (let* ((document (kargu-bridge-edit-batch-read-document
                                    (expand-file-name (plist-get spec :path) root)))
                         (parts (if (eq (plist-get spec :intent) :replace)
                                    (list (cons "old" (plist-get spec :old)) (cons "new" (plist-get spec :new)))
                                  (list (cons "new" (plist-get spec :content))))))
                    (puthash "live" (kargu-bridge-edit-document-facts document) arguments)
                    (kargu-bridge-edit-prepare
                     application arguments (cons (cons "document" (kargu-bridge-edit-document-text document)) parts)
                     (guard #'ready) :parent task))))))))
      (let ((cancel (lambda () (kargu-async-cancel task))))
        (add-hook 'kill-buffer-hook cancel nil t)
        (add-hook 'change-major-mode-hook cancel nil t)
        (kargu-async-add-cleanup
         task (lambda () (when (buffer-live-p source)
                           (with-current-buffer source
                             (remove-hook 'kill-buffer-hook cancel t)
                             (remove-hook 'change-major-mode-hook cancel t))))))
      (condition-case failure (start)
        ((error quit) (finish nil (error-message-string failure)))))
    task))

(provide 'kargu/bridge/edit/batch)
;;; batch.el ends here
