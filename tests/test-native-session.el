;;; test-native-session.el --- Native session owner and callback contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Acceptance sources for the final 3/4/5 gate.  No live provider or credential.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'kargu/chat)
(require 'kargu/chat/session)
(require 'kargu/bridge/session)
(require 'kargu/bridge/sensor)
(require 'kargu/tools/lsp/snapshot)
(require 'kargu/tools/lsp/symbols)

(defun kargu-native-session-test--scope ()
  "Build an exact synthetic native run scope."
  (kargu-bridge--object "purpose" "agent_turn" "application_id" "app_12345678-1234-4234-8234-000000000001"
                       "session_id" "sess_12345678-1234-4234-8234-000000000002" "run_id" "run_12345678-1234-4234-8234-000000000003"
                       "claim_id" "claim_12345678-1234-4234-8234-000000000004" "generation" 1
                       "config_revision" 1 "policy_revision" 1))

(defun kargu-native-session-test--entry (connection root owner &optional consumer)
  "Bind a synthetic native waiter to CONNECTION, ROOT, OWNER and CONSUMER."
  (let ((entry (kargu-bridge--pending-create
                :owner owner :callback #'ignore :on-event consumer
                :session-intent (kargu-bridge--object
                                 "scope" (kargu-bridge--object "application_id" "app_12345678-1234-4234-8234-000000000001"
                                                               "session_id" "sess_12345678-1234-4234-8234-000000000002")
                                 "root" root "config_revision" 1 "policy_revision" 1
                                 "editor_available" ["read_file_symbols"]))))
    (puthash "forward" entry (kargu-bridge-connection-pending connection))
    entry))

(ert-deftest kargu-native-session-events-reject-foreign-epoch-owner-and-duplicate-sequence-test ()
  (let* ((connection (kargu-bridge--connection-create :state 'ready :epoch "fixture-epoch"))
         (params (kargu-bridge--object "request_id" "forward" "connection_epoch" "fixture-epoch"
                                       "scope" (kargu-native-session-test--scope)
                                       "sequence" 1 "event" (kargu-bridge--object "phase" "ready")))
         events)
    (kargu-native-session-test--entry connection "/fixture" nil
                                     (lambda (method event) (push (list method event) events)))
    (kargu-bridge-session-notify connection "session/state" params)
    (should (= (length events) 1))
    (puthash "connection_epoch" "foreign-epoch" params)
    (puthash "sequence" 2 params)
    (kargu-bridge-session-notify connection "session/state" params)
    (should (= (length events) 1))
    (puthash "connection_epoch" "fixture-epoch" params)
    (puthash "generation" 2 (gethash "scope" params))
    (kargu-bridge-session-notify connection "session/state" params)
    (should (= (length events) 1))
    (puthash "generation" 1 (gethash "scope" params))
    (puthash "sequence" 1 params)
    (kargu-bridge-session-notify connection "session/state" params)
    (should (= (length events) 1))
    (puthash "sequence" 2 params)
    (kargu-bridge-session-notify connection "session/terminal" params)
    (should (= (length events) 2))
    (should (equal (caar events) "session/terminal"))))

(ert-deftest kargu-native-session-gap-recovers-only-the-still-owned-waiter-test ()
  (let* ((connection (kargu-bridge--connection-create :state 'ready :epoch "fixture-epoch"))
         (params (kargu-bridge--object "request_id" "forward" "connection_epoch" "fixture-epoch"
                                       "scope" (kargu-native-session-test--scope)
                                       "sequence" 1 "event" (kargu-bridge--object)))
         events snapshot-callback)
    (kargu-native-session-test--entry connection "/fixture" nil
                                     (lambda (method _event) (push method events)))
    (cl-letf (((symbol-function 'kargu-bridge-session-snapshot)
               (lambda (_connection _scope callback &optional _owner)
                 (setq snapshot-callback callback))))
      (kargu-bridge-session-notify connection "session/state" params)
      (puthash "sequence" 3 params)
      (kargu-bridge-session-notify connection "session/state" params)
      (should (member "session/gap" events))
      (should snapshot-callback)
      (remhash "forward" (kargu-bridge-connection-pending connection))
      (funcall snapshot-callback (kargu-bridge--object "state" "idle") nil)
      (should-not (member "session/snapshot" events)))))

(ert-deftest kargu-native-session-repeat-rejection-sends-explicit-false-test ()
  (let (captured)
    (cl-letf (((symbol-function 'kargu-bridge-call)
               (lambda (_connection _method params _callback &rest _options)
                 (setq captured params))))
      (kargu-bridge-session-continue nil (kargu-native-session-test--scope) #'ignore
                                     :call-id "call_12345678-1234-4234-8234-000000000005" :approved nil)
      (should (eq (gethash "approved" captured :missing) :json-false)))))

(ert-deftest kargu-native-session-persistence-bridge-methods-test ()
  (let (captured-method captured-params)
    (cl-letf (((symbol-function 'kargu-bridge-call)
               (lambda (_connection method params _callback &rest _options)
                 (setq captured-method method captured-params params))))
      (let ((params (kargu-bridge--object "session_id" "sess-01" "project_root" "/test")))
        (kargu-bridge-session-save nil params #'ignore)
        (should (equal captured-method "session/save"))
        (should (equal (gethash "session_id" captured-params) "sess-01"))

        (kargu-bridge-session-load nil params #'ignore)
        (should (equal captured-method "session/load"))

        (kargu-bridge-session-list nil params #'ignore)
        (should (equal captured-method "session/list"))

        (kargu-bridge-session-delete nil params #'ignore)
        (should (equal captured-method "session/delete"))

        (kargu-bridge-session-import nil params #'ignore)
        (should (equal captured-method "session/import"))))))

(ert-deftest kargu-native-editor-cancel-retains-the-issued-read-until-its-callback-test ()
  (let* ((root (make-temp-file "kargu-native-symbols-" t))
         (path (expand-file-name "source.el" root))
         (buffer (generate-new-buffer " *native-symbols-source*"))
         (connection (kargu-bridge--connection-create :state 'ready :epoch "fixture-epoch"))
         (params (kargu-bridge--object "request_id" "forward" "connection_epoch" "fixture-epoch"
                                       "scope" (kargu-native-session-test--scope)
                                       "root" (directory-file-name (file-truename root))
                                       "call_id" "call_12345678-1234-4234-8234-000000000005" "tool" "read_file_symbols"
                                       "timeout_ms" 1000
                                       "arguments" (kargu-bridge--object "file_path" "source.el")))
         replies callback)
    (unwind-protect
        (with-current-buffer buffer
          (emacs-lisp-mode)
          (setq buffer-file-name path)
          (insert "(defun alpha () nil)\n")
          (kargu-native-session-test--entry connection (gethash "root" params) buffer)
          (cl-letf (((symbol-function 'kargu-bridge-sensor--reply)
                     (lambda (_connection id result) (push (cons id result) replies)))
                    ((symbol-function 'kargu-lsp-snapshot-capture)
                     (lambda (_buffer _source deliver _timeout) (setq callback deliver))))
            (kargu-bridge-sensor-prepare-tool connection "capture" params)
            (should (equal (caar replies) "capture"))
            (puthash "resource" (gethash "resource" (cdar replies)) params)
            (kargu-bridge-sensor-call-tool connection "issued" params)
            (should callback)
            (should (= (hash-table-count (kargu-bridge-connection-sensor-calls connection)) 1))
            (kargu-bridge-sensor-cancel-tool
             connection (kargu-bridge--object "connection_epoch" "fixture-epoch"
                                               "request_id" "issued" "call_id" "call_12345678-1234-4234-8234-000000000005"
                                               "scope" (gethash "scope" params)))
            (should (= (hash-table-count (kargu-bridge-connection-sensor-calls connection)) 1))
            (insert "; changed while awaiting LSP\n")
            (funcall callback nil nil)
            (should (equal (gethash "outcome" (cdar replies)) "cancelled"))
            (should (eq (gethash "quiescent" (cdar replies)) t))
            (should (= (hash-table-count (kargu-bridge-connection-sensor-calls connection)) 0))
            (should (= (hash-table-count (kargu-bridge-connection-reverse-cleanups connection)) 0))))
      (when (buffer-live-p buffer) (with-current-buffer buffer (set-buffer-modified-p nil)) (kill-buffer buffer))
      (delete-directory root t))))

(provide 'tests/test-native-session)
;;; test-native-session.el ends here
