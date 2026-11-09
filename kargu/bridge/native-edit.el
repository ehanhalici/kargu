;;; native-edit.el --- Editor adapter for one native agent edit -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Reuse the native preparation/review/transaction adapter on the conversation's
;; captured scope.  Rust binds the source to model arguments and owns the result.

;;; Code:

(require 'cl-lib)
(require 'kargu/bridge/sensor)
(require 'kargu/bridge/edit/batch)

(cl-defstruct (kargu-bridge-native-edit (:constructor kargu-bridge-native-edit--make))
  "One owned orchestration; actual issuance retains its separate activity fence."
  params entry owner session id timer task)

(defun kargu-bridge-native-edit--key (call-id)
  "Return the reverse cleanup key for CALL-ID."
  (concat "edit:" call-id))

(defun kargu-bridge-native-edit--current-p (connection edit)
  "Check EDIT's exact forward waiter and editor session on CONNECTION."
  (let* ((params (kargu-bridge-native-edit-params edit))
         (call-id (gethash "call_id" params))
         (owner (kargu-bridge-native-edit-owner edit)))
    (and (eq edit (gethash call-id (kargu-bridge-connection-native-edits connection)))
         (buffer-live-p owner)
         (eq (kargu-session-context owner) (kargu-bridge-native-edit-session edit))
         (eq (kargu-bridge-session-owned-entry connection params)
             (kargu-bridge-native-edit-entry edit)))))

(defun kargu-bridge-native-edit--release (connection edit)
  "Revoke EDIT's orchestration on CONNECTION, retaining issued activity."
  (let ((call-id (gethash "call_id" (kargu-bridge-native-edit-params edit))))
    (when (eq edit (gethash call-id (kargu-bridge-connection-native-edits connection)))
      ;; Revoke validity before task cleanup can reenter a delayed callback.
      (remhash call-id (kargu-bridge-connection-native-edits connection))
      (remhash (kargu-bridge-native-edit--key call-id)
               (kargu-bridge-connection-reverse-cleanups connection))
      (when (timerp (kargu-bridge-native-edit-timer edit))
        (cancel-timer (kargu-bridge-native-edit-timer edit)))
      (when (kargu-async-task-p (kargu-bridge-native-edit-task edit))
        (kargu-async-cancel (kargu-bridge-native-edit-task edit))))))

(defun kargu-bridge-native-edit--finish (connection edit failure)
  "Report only orchestration completion for EDIT on CONNECTION.
FAILURE cannot establish effects."
  (when (kargu-bridge-native-edit--current-p connection edit)
    (let* ((params (kargu-bridge-native-edit-params edit))
           (data (and (hash-table-p failure) (gethash "data" failure)))
           (status (and (hash-table-p data) (gethash "status" data))))
      (kargu-bridge-sensor--reply
       connection (kargu-bridge-native-edit-id edit)
       (kargu-bridge--object "scope" (gethash "scope" params)
                             "call_id" (gethash "call_id" params)
                             "origin_id" (gethash "origin_id" params)
                             "finished" t
                             "failure" (if failure
                                           (if (member status '("rejected" "cancelled" "timeout")) status "failed")
                                         :json-null)))))
  (kargu-bridge-native-edit--release connection edit))

(defun kargu-bridge-native-edit--symbol-current-p (params)
  "Revalidate the exact symbol document/provider in captured PARAMS before issue."
  (condition-case nil
      (let* ((selection (gethash "symbol_selection" params))
             (root (gethash "root" params))
             (document (gethash "document" selection))
             (buffer (find-buffer-visiting (expand-file-name (gethash "path" document) root)))
             (resource (and (buffer-live-p buffer)
                            (kargu-bridge-sensor--language-document buffer root))))
        (and resource
             (kargu-json-equal document (gethash "document" resource))
             (kargu-json-equal (gethash "source" selection) (gethash "source" resource))))
    (error nil)))

(defun kargu-bridge-native-edit--spec (connection edit)
  "Build EDIT's closed, detached batch specification on CONNECTION."
  (let* ((params (kargu-bridge-native-edit-params edit))
         (args (gethash "arguments" params))
         (scope (gethash "scope" params))
         (policy (gethash "edit_policy" params))
         (review (gethash "review_mode" policy))
         (save (gethash "save_policy" policy))
         (valid-p (lambda () (kargu-bridge-native-edit--current-p connection edit)))
         (spec (list :root (gethash "root" params) :mode 'agent
                     :application (kargu-application-context)
                     :connection connection :scope scope :scope-valid-p valid-p :valid-p valid-p
                     :origin-id (gethash "origin_id" params)
                     :config-revision (gethash "config_revision" scope)
                     :policy-revision (gethash "policy_revision" scope))))
    (unless (and (hash-table-p args) (member review '("auto" "async" "blocking"))
                 (member save '("save" "buffer_only")))
      (error "Invalid native edit specification"))
    (setq spec (append spec (list :review-mode (intern review) :save-policy (intern save))))
    (append spec
            (pcase (gethash "tool" params)
              ("edit_file" (list :intent :replace :path (gethash "file_path" args)
                                  :old (gethash "old_string" args) :new (gethash "new_string" args)))
              ("write_file" (list :intent :write :path (gethash "file_path" args) :content (gethash "contents" args)))
              ("apply_patch" (list :intent :patch :patch (gethash "patch" args)))
              ("edit_by_lsp"
               (unless (kargu-bridge-native-edit--symbol-current-p params)
                 (error "Symbol source changed before edit capture"))
               (list :intent :symbol :path (gethash "file_path" args)
                     :content (gethash "new_content" args)
                     :language-source (gethash "source" (gethash "symbol_selection" params))
                     :validate-source (lambda ()
                                        (unless (kargu-bridge-native-edit--symbol-current-p params)
                                          (error "Symbol source changed before edit issue")))))
              (_ (error "Unavailable native edit adapter"))))))

(defun kargu-bridge-native-edit--run (connection edit)
  "Run EDIT's editor capture outside the process filter on CONNECTION."
  (when (kargu-bridge-native-edit--current-p connection edit)
    (condition-case nil
        (with-current-buffer (kargu-bridge-native-edit-owner edit)
          (setf (kargu-bridge-native-edit-task edit)
                (kargu-bridge-edit-batch-execute
                 (kargu-bridge-native-edit--spec connection edit)
                 (lambda (_result failure) (kargu-bridge-native-edit--finish connection edit failure)))))
      ((error quit)
       (kargu-bridge-native-edit--finish connection edit (kargu-bridge--fault "failed"))))))

(defun kargu-bridge-native-edit-start (connection id params)
  "Schedule the owned native ID/PARAMS edit on its exact CONNECTION."
  (let (registered)
    (condition-case nil
        (let* ((entry (kargu-bridge-session-owned-entry connection params))
               (owner (and entry (kargu-bridge--pending-owner entry)))
               (intent (and entry (kargu-bridge--pending-session-intent entry)))
               (call-id (gethash "call_id" params))
               (origin (gethash "origin_id" params))
               (root (gethash "root" params))
               (table (kargu-bridge-connection-native-edits connection)))
          (unless (and entry (buffer-live-p owner) (stringp call-id) (not (string-empty-p call-id))
                       (stringp origin) (string-match-p "\\`editor_source_[0-9a-f-]+\\'" origin)
                       (stringp root) (file-name-absolute-p root) (not (file-remote-p root))
                       (equal (directory-file-name (file-truename root))
                              (directory-file-name (file-truename (gethash "root" intent))))
                       (not (gethash call-id table)) (< (hash-table-count table) kargu-bridge--max-pending))
            (error "Unowned native edit"))
          (let ((edit (kargu-bridge-native-edit--make
                       :params (kargu-bridge-sensor--copy params) :entry entry :owner owner :id id
                       :session (kargu-session-context owner))))
            (puthash call-id edit table)
            (setq registered edit)
            (puthash (kargu-bridge-native-edit--key call-id)
                     (cons (gethash "request_id" params) (lambda () (kargu-bridge-native-edit--release connection edit)))
                     (kargu-bridge-connection-reverse-cleanups connection))
            (setf (kargu-bridge-native-edit-timer edit)
                  (run-at-time 0 nil #'kargu-bridge-native-edit--run connection edit))))
      ((error quit)
       (when registered (kargu-bridge-native-edit--release connection registered))
       (kargu-bridge-sensor--error connection id)))))

(defun kargu-bridge-native-edit-cancel (connection params)
  "Cancel only the exact native orchestration in PARAMS on CONNECTION."
  (let* ((call-id (and (hash-table-p params) (gethash "call_id" params)))
         (edit (gethash call-id (kargu-bridge-connection-native-edits connection))))
    (when (and edit (kargu-bridge-native-edit--current-p connection edit)
               (cl-every (lambda (key) (kargu-json-equal
                                        (gethash key params)
                                        (gethash key (kargu-bridge-native-edit-params edit))))
                         '("request_id" "connection_epoch" "scope" "call_id" "origin_id")))
      (kargu-bridge-native-edit--release connection edit))))

(provide 'kargu/bridge/native-edit)
;;; native-edit.el ends here
