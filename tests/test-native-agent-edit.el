;;; test-native-agent-edit.el --- Native parent edit ownership contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Final-gate sources: exact conversation scope, detached arguments, foreign
;; cancellation and source retirement.  No provider credentials are used.

;;; Code:

(require 'ert)
(require 'tests/test-bridge)
(require 'cl-lib)
(require 'tests/test-native-session)
(require 'kargu/bridge/native-edit)
(declare-function kargu-stream-test--server "tests/test-stream"
                  (body stream &optional hold capture capture-headers status headers script))

(defun kargu-native-agent-edit-test--params (root)
  "Build a synthetic native edit request in ROOT."
  (kargu-bridge--object
   "request_id" "forward" "connection_epoch" "fixture-epoch"
   "scope" (kargu-native-session-test--scope) "call_id" "native-edit-call"
   "origin_id" "editor_source_12345678-1234-4234-8234-123456789abc"
   "root" (directory-file-name root) "tool" "write_file"
   "arguments" (kargu-bridge--object "file_path" "file.txt" "contents" "new 🦀\n")
   "edit_policy" (kargu-bridge--object "review_mode" "blocking" "save_policy" "buffer_only")))

(ert-deftest kargu-native-agent-edit-captures-the-conversation-and-rejects-foreign-cancel-test ()
  (let* ((root (make-temp-file "kargu-native-edit-" t))
         (owner (generate-new-buffer " *native-edit-owner*"))
         (connection (kargu-bridge--connection-create :state 'ready :epoch "fixture-epoch"))
         (params (kargu-native-agent-edit-test--params root))
         (table (kargu-bridge-connection-native-edits connection))
         spec task)
    (unwind-protect
        (with-current-buffer owner
          (kargu-native-session-test--entry connection root owner)
          ;; Scheduling is detached from capture; caller mutation cannot replace
          ;; either the committed arguments or the reverse cancellation identity.
          (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil))
                    ((symbol-function 'kargu-bridge-edit-batch-execute)
                     (lambda (captured _callback)
                       (setq spec captured task (kargu-async-start #'ignore :timeout 300)))))
            (kargu-bridge-native-edit-start connection "reverse-edit" params)
            (let ((edit (gethash "native-edit-call" table)))
              (should edit)
              (puthash "contents" "foreign text" (gethash "arguments" params))
              (kargu-bridge-native-edit--run connection edit)
              (should (equal (plist-get spec :content) "new 🦀\n"))
              (should (eq (plist-get spec :connection) connection))
              (should (equal (gethash "session_id" (plist-get spec :scope))
                             (gethash "session_id" (gethash "scope" params))))
              (should (eq (plist-get spec :review-mode) 'blocking))
              (should (eq (plist-get spec :save-policy) 'buffer_only))
              (should (funcall (plist-get spec :scope-valid-p)))
              (let ((foreign (kargu-bridge-sensor--copy params)))
                (puthash "generation" 2 (gethash "scope" foreign))
                (kargu-bridge-native-edit-cancel connection foreign)
                (should (eq edit (gethash "native-edit-call" table)))
                (should (kargu-async-pending-p task)))
              (kargu-bridge-native-edit-cancel connection params)
              (should-not (gethash "native-edit-call" table))
              (should-not (funcall (plist-get spec :scope-valid-p)))
              (should-not (kargu-async-pending-p task))
              (should (= (hash-table-count (kargu-bridge-connection-reverse-cleanups connection)) 0)))))
      (when (kargu-async-task-p task) (kargu-async-cancel task))
      (when (buffer-live-p owner) (kill-buffer owner))
      (delete-directory root t))))

(ert-deftest kargu-native-agent-edit-artifact-uses-captured-conversation-validity-test ()
  (let* ((connection (kargu-bridge--connection-create :state 'ready :epoch "fixture-epoch"))
         (live t)
         (kargu--loop-run (list :foreign-run t))
         (artifact (kargu-bridge-edit-artifact--make
                    :connection connection :epoch "fixture-epoch" :scope (kargu-native-session-test--scope)
                    :scope-valid-p (lambda () live))))
    (cl-letf (((symbol-function 'kargu-bridge-application-current-scope)
               (lambda (&rest _) (ert-fail "Conversation edit acquired a service scope"))))
      (should (kargu-bridge-edit--current-p artifact))
      (should-not (kargu-bridge-edit--async-owner artifact))
      (setq live nil)
      (should-not (kargu-bridge-edit--current-p artifact))
      (setq live t)
      (setf (kargu-bridge-edit-artifact-released artifact) t)
      (should-not (kargu-bridge-edit--current-p artifact)))))

(ert-deftest kargu-native-agent-edit-source-retirement-prevents-delayed-start-test ()
  (let* ((root (make-temp-file "kargu-native-edit-late-" t))
         (owner (generate-new-buffer " *native-edit-retiring-owner*"))
         (connection (kargu-bridge--connection-create :state 'ready :epoch "fixture-epoch"))
         (params (kargu-native-agent-edit-test--params root)))
    (unwind-protect
        (with-current-buffer owner
          (kargu-native-session-test--entry connection root owner)
          (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil))
                    ((symbol-function 'kargu-bridge-edit-batch-execute)
                     (lambda (&rest _) (ert-fail "Retired source started an edit"))))
            (kargu-bridge-native-edit-start connection "reverse-edit" params)
            (let ((edit (gethash "native-edit-call" (kargu-bridge-connection-native-edits connection))))
              (kargu-bridge--dismiss-reverse connection "forward")
              (kargu-bridge-native-edit--run connection edit)
              (should (= (hash-table-count (kargu-bridge-connection-native-edits connection)) 0)))))
      (when (buffer-live-p owner) (kill-buffer owner))
      (delete-directory root t))))

(defun kargu-native-symbol-edit-test--roundtrip (tamper)
  "Run a real symbol edit, optionally TAMPER with its provider before mutation."
  (require 'tests/test-stream)
  (require 'kargu/loop/native-owner)
  (kargu-bridge-test--with-core
   (let* ((root (make-temp-file "kargu-symbol-edit-" t))
          (path (expand-file-name "source.el" root))
          (journal (make-temp-file "kargu-symbol-journal-" t))
          (kargu-bridge-edit-batch-journal-directory journal)
          (application (kargu-application-create))
          (before "(defun first () 1)\n(defun second () 2)\n")
          (after "(defun first () 1)\n(defun second () 9)")
          (tool-args (kargu-bridge--object "file_path" "source.el" "symbol" "second"
                                         "kind" "Function" "new_content" "(defun second () 9)"))
          (tool (kargu-bridge--object
                 "id" "model-edit" "type" "function"
                 "function" (kargu-bridge--object "name" "edit_by_lsp"
                                                "arguments" (json-serialize tool-args))))
          (message (kargu-bridge--object "role" "assistant" "content" :json-null
                                        "tool_calls" (vector tool)))
          (choice (kargu-bridge--object "message" message "finish_reason" "tool_calls"))
          (first (json-serialize (kargu-bridge--object "choices" (vector choice))
                                 :null-object :json-null))
          (last "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"done\"},\"finish_reason\":\"stop\"}]}")
          requests done result failure owner server
          (activity-advice
           (lambda (function artifact &rest options)
             (let ((handler (plist-get options :handler)))
               (plist-put options :handler
                          (lambda (live-p)
                            (with-current-buffer owner
                              (setq-local imenu-create-index-function (lambda () nil)))
                            (funcall handler live-p))))
             (apply function artifact options))))
     (unwind-protect
         (progn
           (when tamper (advice-add 'kargu-bridge-edit-activity-start :around activity-advice))
           (with-temp-file path (insert before))
           (setq owner (find-file-noselect path))
           (with-current-buffer owner
             (emacs-lisp-mode)
             (setq-local kargu-application-owner application))
           (setq server (kargu-stream-test--server
                         first nil nil (lambda (body) (push (kargu--json-decode-safe body) requests))
                         nil nil nil (list (list :body first) (list :body last))))
           (with-current-buffer owner
             (kargu-test-native-owned-start
              application
              (kargu-bridge--object
               "root" (directory-file-name root) "mode" "agent"
               "prompt" (kargu-bridge--object "role" "user" "content" "fixture")
               "tools_enabled" t "editor_available" ["edit_by_lsp"]
               "tool_limit" 1 "turn_limit" 3 "timeout_ms" 10000
               "config_revision" 1 "policy_revision" 1
               "edit_policy" (kargu-bridge--object "review_mode" "auto" "save_policy" "buffer_only")
               "connection" (kargu-bridge--object
                             "url" (format "http://127.0.0.1:%d/v1" (process-contact server :service))
                             "model" "fixture" "headers" (kargu-bridge--object)
                             "stream" :json-false "timeouts" (kargu-bridge--object "connect_ms" 500 "first_byte_ms" 1000 "deadline_ms" 10000)))
              (lambda (value fault) (setq result value failure fault done t)) :owner owner))
           (kargu-bridge-test--wait (lambda () done))
           (should-not failure)
           (ert-info ((format "Native symbol edit: %S" result))
             (should (equal (gethash "status" result) "completed")))
           (with-current-buffer owner
             (ert-info ((format "Symbol result: %S" result))
               (should (equal (buffer-string) (if tamper before after))))
             (should (eq (not (null (buffer-modified-p))) (not tamper))))
           (should (= (length requests) 2))
           (let* ((messages (kargu-aget (car requests) "messages"))
                  (tools (seq-filter (lambda (message) (equal (kargu-aget message "role") "tool")) messages)))
             (should (= (length tools) 1))
             (should (equal (kargu-aget (car tools) "tool_call_id") "model-edit"))
             (if tamper
                 (should-not (string-search "applied_full" (kargu-aget (car tools) "content")))
               (should (string-search "applied_full" (kargu-aget (car tools) "content"))))))
       (when tamper (advice-remove 'kargu-bridge-edit-activity-start activity-advice))
       (when (processp server) (delete-process server))
       (when (buffer-live-p owner)
         (with-current-buffer owner (set-buffer-modified-p nil)) (kill-buffer owner))
       (delete-directory journal t)
       (delete-directory root t)))))

(ert-deftest kargu-native-symbol-edit-real-provider-selects-and-applies-one-range-test ()
  (kargu-native-symbol-edit-test--roundtrip nil))

(ert-deftest kargu-native-symbol-edit-provider-change-after-issue-does-not-write-test ()
  (kargu-native-symbol-edit-test--roundtrip t))

(provide 'tests/test-native-agent-edit)
;;; test-native-agent-edit.el ends here
