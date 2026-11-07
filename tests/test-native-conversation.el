;;; test-native-conversation.el --- Per-chat native ownership -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Each chat owns its own native conversation; fixtures use a real core.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'kargu/bridge/conversation)
(require 'kargu/loop/native-owner)
(require 'tests/test-bridge)
(require 'tests/test-stream)

(defmacro kargu-conversation-test--fixture (&rest body)
  "Evaluate BODY with a controlled native session allocation port."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (let* ((application (kargu-application-create))
            (session (kargu-session-context))
            (connection (kargu-bridge--connection-create :state 'ready :epoch "conversation-epoch"))
            (service (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_service"))
            (chat (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_chat"))
            (binding (kargu-bridge-application--make :connection connection :scope service :state :ready))
            (creates 0) pending closes)
       (puthash :native-core binding (kargu-application-services application))
       (cl-letf (((symbol-function 'kargu-bridge-call)
                  (lambda (_connection method params callback &rest _options)
                    (pcase method
                      ("session/create" (cl-incf creates) (setq pending callback))
                      ("session/close" (push params closes)
                       (funcall callback (kargu-bridge--object "status" "closed") nil))
                      (_ (ert-fail (format "Unexpected RPC %s" method))))
                    "fixture-rpc")))
         (unwind-protect (progn ,@body)
           (kargu-bridge-conversation-retire session))))))

(ert-deftest kargu-native-conversation-waiters-detach-and-cancel-independently-test ()
  (kargu-conversation-test--fixture
    (let (first second failure)
      (let ((cancel (kargu-bridge-conversation-ensure
                     connection application session service
                     (lambda (&rest _) (setq first t)))))
        (kargu-bridge-conversation-ensure
         connection application session service
         (lambda (scope error-data) (setq second scope failure error-data)))
        (funcall cancel))
      (should (= creates 1))
      (funcall pending chat nil)
      (kargu-bridge-test--wait (lambda () second))
      (should-not failure)
      (should-not first)
      (should-not (equal (gethash "session_id" second) (gethash "session_id" service)))
      (aset (gethash "session_id" second) 0 ?X)
      (should (equal (gethash "session_id" (kargu-bridge-conversation-current-scope
                                            application session connection)) "sess_chat")))))

(ert-deftest kargu-native-conversation-late-create-is-revoked-after-retirement-test ()
  (kargu-conversation-test--fixture
    (let ((deliveries 0) failure)
      (kargu-bridge-conversation-ensure
       connection application session service
       (lambda (scope error-data)
         (should-not scope) (setq failure error-data) (cl-incf deliveries)))
      (kargu-bridge-conversation-retire session)
      (kargu-bridge-test--wait (lambda () failure))
      (funcall pending chat nil)
      (should (= (length closes) 1))
      (should (kargu-bridge-application-scope-equal-p (car closes) chat))
      (should (= deliveries 1))
      (should-not (kargu-bridge-conversation-current-scope application session connection))
      (let (rejected)
        (kargu-bridge-conversation-ensure connection application session service
                                        (lambda (_scope error-data) (setq rejected error-data)))
        (kargu-bridge-test--wait (lambda () rejected)))
      (should (= creates 1)))))

(ert-deftest kargu-native-conversation-replaced-application-revokes-old-create-test ()
  (kargu-conversation-test--fixture
    (let (failure)
      (kargu-bridge-conversation-ensure connection application session service
                                      (lambda (_scope error-data) (setq failure error-data)))
      (setf (kargu-bridge-application-scope binding)
            (kargu-bridge--object "application_id" "app_replaced" "session_id" "sess_replaced"))
      (funcall pending chat nil)
      (kargu-bridge-test--wait (lambda () failure))
      (should (= (length closes) 1))
      (should (kargu-bridge-application-scope-equal-p (car closes) chat))
      (should-not (kargu-bridge-conversation-current-scope application session connection)))))

(ert-deftest kargu-native-conversation-epoch-loss-never-revokes-on-new-epoch-test ()
  (kargu-conversation-test--fixture
    (let (ready)
      (kargu-bridge-conversation-ensure connection application session service
                                      (lambda (scope _failure) (setq ready scope)))
      (funcall pending chat nil)
      (kargu-bridge-test--wait (lambda () ready))
      (setf (kargu-bridge-connection-epoch connection) "replacement-epoch")
      (should-not (kargu-bridge-conversation-current-scope application session connection))
      (kargu-bridge-conversation-retire session)
      (should-not closes))))

(ert-deftest kargu-native-conversation-major-mode-change-retires-exact-chat-test ()
  (kargu-conversation-test--fixture
    (let (ready)
      (kargu-bridge-conversation-ensure connection application session service
                                      (lambda (scope _failure) (setq ready scope)))
      (funcall pending chat nil)
      (kargu-bridge-test--wait (lambda () ready))
      (text-mode)
      (should (kargu-session-native-retired session))
      (should (= (length closes) 1))
      (should (kargu-bridge-application-scope-equal-p (car closes) chat))
      (should-not (kargu-bridge-conversation-current-scope application session connection)))))

(defun kargu-conversation-test--prompt (application owner root url prompt)
  "Send PROMPT for APPLICATION and OWNER to the local provider at URL under ROOT."
  (let (done result failure)
    (with-current-buffer owner
      (kargu-test-native-owned-start
       application
       (kargu-bridge--object
        "root" root "mode" "ask" "prompt" (kargu-bridge--object "role" "user" "content" prompt)
        "tools_enabled" :json-false "tool_limit" 1 "turn_limit" 2
        "timeout_ms" 3000 "config_revision" 1 "policy_revision" 1
        "connection" (kargu-bridge--object
                      "url" url "model" "conversation-fixture" "headers" (kargu-bridge--object)
                      "stream" :json-false
                      "timeouts" (kargu-bridge--object "connect_ms" 1000 "first_byte_ms" 1000 "deadline_ms" 2000)))
       (lambda (value error-data) (setq result value failure error-data done t)) :owner owner))
    (kargu-bridge-test--wait (lambda () done))
    (should-not failure)
    (should (equal (gethash "status" result) "completed"))
    (gethash "scope" result)))

(ert-deftest kargu-native-conversation-real-chats-do-not-share-history-or-close-test ()
  (kargu-bridge-test--with-core
   (let* ((application (kargu-application-create))
          (first (generate-new-buffer " *native conversation A*"))
          (second (generate-new-buffer " *native conversation B*"))
          (root (make-temp-file "kargu-conversation-root-" t))
          requests
          (server (kargu-stream-test--server
                   "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"native answer\"},\"finish_reason\":\"stop\"}]}"
                   nil nil (lambda (body) (push (kargu--json-decode-safe body) requests))))
          (url (format "http://127.0.0.1:%d/v1" (process-contact server :service))))
     (unwind-protect
         (let* ((a (kargu-conversation-test--prompt application first root url "A-private-first"))
                (b (kargu-conversation-test--prompt application second root url "B-private-first"))
                (again (kargu-conversation-test--prompt application first root url "A-second"))
                (binding (gethash :native-core (kargu-application-services application)))
                (connection (kargu-bridge-application-connection binding))
                (service (kargu-bridge-application-scope binding))
                (a-scope (kargu-bridge--object "application_id" (gethash "application_id" a)
                                              "session_id" (gethash "session_id" a)))
                (b-scope (kargu-bridge--object "application_id" (gethash "application_id" b)
                                              "session_id" (gethash "session_id" b))))
           (should (equal (gethash "session_id" a) (gethash "session_id" again)))
           (should-not (equal (gethash "session_id" a) (gethash "session_id" b)))
           (should-not (equal (gethash "session_id" a) (gethash "session_id" service)))
           (should (= (length requests) 3))
           (let ((a-messages (append (kargu-aget (car requests) "messages") nil))
                 (b-messages (append (kargu-aget (cadr requests) "messages") nil)))
             (should (equal (mapcar (lambda (m) (kargu-aget m "content")) a-messages)
                            '("A-private-first" "native answer" "A-second")))
             (should (equal (mapcar (lambda (m) (kargu-aget m "content")) b-messages)
                            '("B-private-first"))))
           (kill-buffer first)
           (let ((a-result (kargu-bridge-test--call connection "session/snapshot" a-scope))
                 (b-result (kargu-bridge-test--call connection "session/snapshot" b-scope)))
             (should (cadr a-result))
             (should (car b-result))
             (should-not (cadr b-result))))
       (when (buffer-live-p first) (kill-buffer first))
       (when (buffer-live-p second) (kill-buffer second))
       (delete-process server)
       (delete-directory root t)))))

(provide 'tests/test-native-conversation)
;;; test-native-conversation.el ends here
