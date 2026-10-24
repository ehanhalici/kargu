;;; approval.el --- Owned Rust command approval presenter -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Present only exact command reviews tied to a live forward request.
;; No adapter means rejection.  Replies never restart a dead connection.

;;; Code:

(require 'kargu/bridge)
(require 'kargu/confirm)
(require 'kargu/core/session)

(defun kargu-bridge-approval--copy (value)
  "Capture JSON VALUE without sharing mutable containers with its caller."
  (json-parse-string (json-serialize value :null-object :json-null :false-object :json-false)
                     :object-type 'hash-table :array-type 'array
                     :null-object :json-null :false-object :json-false))

(cl-defun kargu-bridge-approval-execute
    (connection arguments callback &key owner (method "tool/execute")
                (capability "command_execute") (purpose "agent_turn") valid-p)
  "Capture ARGUMENTS for CONNECTION and OWNER, delivering CALLBACK once."
  (if (not (and (eq (kargu-bridge-status connection) 'ready)
                (member capability (append (kargu-bridge-connection-capabilities connection) nil))
                (hash-table-p (kargu-bridge-connection-read-scope connection))))
      (progn (kargu-bridge--callback callback nil (kargu-bridge--fault "unavailable")) nil)
    (let* ((captured (kargu-bridge-approval--copy arguments))
           (timeout (gethash "timeout_ms" captured))
           (session (kargu-session-context owner))
           (parent kargu-async--current-task)
           (id (kargu-bridge-call
                connection method
                (kargu-bridge--object "scope" (kargu-bridge-connection-read-scope connection) "arguments" captured)
                callback :owner owner :timeout (+ 311 (/ (if (numberp timeout) timeout 0) 1000.0)))))
      (when-let* ((entry (and id (gethash id (kargu-bridge-connection-pending connection)))))
        (setf (kargu-bridge--pending-review entry) (list captured session parent nil purpose valid-p))
        (when parent
          (kargu-async-add-cleanup parent (lambda () (kargu-bridge-cancel connection id)))))
      id)))

(defun kargu-bridge-approval--equal-map (left right)
  "Whether LEFT and RIGHT have exactly the same string keys and values."
  (and (hash-table-p left) (hash-table-p right)
       (= (hash-table-count left) (hash-table-count right))
       (let ((same t))
         (maphash (lambda (key value) (unless (equal value (gethash key right :missing)) (setq same nil))) left)
         same)))

(defun kargu-bridge-approval--valid (connection params entry)
  "Verify PARAMS exactly match ENTRY and CONNECTION's captured live owner."
  (condition-case nil
      (let* ((review (kargu-bridge--pending-review entry))
             (args (car review)) (owner (kargu-bridge--pending-owner entry))
             (scope (gethash "scope" params))
             (bound (kargu-bridge-connection-read-scope connection))
             (cwd (gethash "cwd" args)))
        (and review (buffer-live-p owner) (eq (kargu-bridge-status connection) 'ready)
             (< (float-time) (kargu-bridge--pending-deadline entry))
             (or (null (nth 2 review)) (kargu-async-pending-p (nth 2 review)))
             (eq (nth 1 review) (kargu-session-context owner))
             (or (null (nth 5 review)) (funcall (nth 5 review)))
             (equal (gethash "mode" args) "agent")
             (equal (gethash "purpose" scope) (nth 4 review))
             (equal (gethash "retention" params) (if (equal (nth 4 review) "process_job") "tail" "prefix"))
             (equal (gethash "timeout_ms" params) (gethash "timeout_ms" args))
             (equal (gethash "output_bytes" params) (gethash "output_bytes" args 1048576))
             (equal (gethash "stderr" params) (gethash "stderr" args "separate"))
             (equal (gethash "application_id" scope) (gethash "application_id" bound))
             (equal (gethash "session_id" scope) (gethash "session_id" bound))
             (equal (gethash "config_revision" scope) (gethash "config_revision" args))
             (equal (gethash "policy_revision" scope) (gethash "policy_revision" args))
             (equal (gethash "invocation" params) (gethash "program" args))
             (equal (gethash "program" params) (file-truename (gethash "program" args)))
             (equal (gethash "arguments" params) (gethash "arguments" args))
             (equal (directory-file-name (gethash "cwd" params))
                    (directory-file-name (file-truename
                                          (expand-file-name (if (stringp cwd) cwd ".") (gethash "root" args)))))
             (kargu-bridge-approval--equal-map (gethash "environment" params) (gethash "environment" args))))
    (error nil)))

(defun kargu-bridge-approval--reply (connection id approved)
  "Reply to captured reverse ID on CONNECTION with APPROVED, never reconnect."
  (condition-case nil
      (kargu-bridge--send connection
                          (kargu-bridge--object "jsonrpc" "2.0" "id" id
                                                "result" (kargu-bridge--object "approved" (if approved t :json-false))))
    (error nil)))

(defun kargu-bridge-approval--details (params)
  "Format exact PARAMS for the trusted approval UI, not for logs."
  (let (environment)
    (maphash (lambda (key _value) (push key environment)) (gethash "environment" params))
    (format "Invocation (argv[0]): %S\nExecutable: %S\nArguments: %S\nDirectory: %S\nOutput: %s, %s bytes/stream, stderr=%s\nTimeout: %S ms\nExplicit environment keys (values withheld): %s"
            (gethash "invocation" params) (gethash "program" params) (gethash "arguments" params)
            (gethash "cwd" params) (gethash "retention" params) (gethash "output_bytes" params)
            (gethash "stderr" params) (gethash "timeout_ms" params)
            (string-join (sort environment #'string<) ", "))))

(defun kargu-bridge-approval-request (connection id params)
  "Present exact reverse approval ID and PARAMS for CONNECTION, or reject."
  (let* ((forward (and (hash-table-p params) (gethash "request_id" params)))
         (pending (kargu-bridge-connection-pending connection))
         (entry (gethash forward pending))
         (table (kargu-bridge-connection-reverse-cleanups connection)))
    (cond
     ((gethash id table) nil)
     ((not (and entry (not (nth 3 (kargu-bridge--pending-review entry)))
                (kargu-bridge-approval--valid connection params entry)))
      (kargu-bridge-approval--reply connection id nil))
     (t (setf (nth 3 (kargu-bridge--pending-review entry)) id)
        (kargu-bridge-approval--present connection id params entry forward)))))

(defun kargu-bridge-approval--present (connection id params entry forward)
  "Own presentation of PARAMS for reverse ID, ENTRY and FORWARD on CONNECTION."
  (let ((active t) handle timer
        (table (kargu-bridge-connection-reverse-cleanups connection)))
    (cl-labels
        ((cleanup ()
           (when active
             (setq active nil)
             (remhash id table)
             (when timer (cancel-timer timer))
             (when handle
               (condition-case nil (kargu-cancel-confirmation handle) ((error quit) nil)))))
         (decide (decision)
           (when active
             (let ((approved (and (eq decision :approve) (eq entry (gethash forward (kargu-bridge-connection-pending connection)))
                                  (kargu-bridge-approval--valid connection params entry))))
               (cleanup)
               (kargu-bridge-approval--reply connection id approved)))))
      (puthash id (cons forward #'cleanup) table)
      (setq timer (run-at-time 300 nil #'decide :reject))
      (condition-case nil
          (with-current-buffer (kargu-bridge--pending-owner entry)
            (setq handle (kargu-confirm
                          :title "Rust command approval" :details (kargu-bridge-approval--details params)
                          :chat-buffer (kargu-bridge--pending-owner entry) :notify 'permission
                          :actions '((:key :approve :label "Approve") (:key :reject :label "Reject"))
                          :default-action :reject :on-decision #'decide)))
        ((error quit) (decide :reject)))
      (unless active
        (when handle
          (condition-case nil (kargu-cancel-confirmation handle) ((error quit) nil)))))))

(provide 'kargu/bridge/approval)
;;; approval.el ends here
