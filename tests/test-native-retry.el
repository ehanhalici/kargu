;;; test-native-retry.el --- Owned native retry observer contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Only delivery/ownership policy belongs here.  Native stdio tests exercise
;; jitter, attempt limits, timers, accounting and drain at their Rust owner.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tests/test-stream)
(require 'kargu/bridge/api)

(defmacro kargu-retry-test--with-peer (&rest body)
  "Run BODY with a single isolated captured forward observer."
  (declare (indent 0) (debug t))
  `(let* ((connection (kargu-bridge--connection-create :state 'ready :epoch "epoch"))
          (scope (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_fixture"))
          (observations 0) sent
          (entry (kargu-bridge--pending-create
                  :callback #'ignore :api-scope scope
                  :on-retry (lambda (_) (cl-incf observations))))
          (params (kargu-bridge--object "request_id" "forward" "scope" (copy-hash-table scope)
                                        "connection_epoch" "epoch" "attempt" 1)))
     (puthash "forward" entry (kargu-bridge-connection-pending connection))
     (cl-letf (((symbol-function 'kargu-bridge--send)
                (lambda (_connection message) (push message sent))))
       ,@body)))

(ert-deftest kargu-native-retry-observer-correlates-and-delivers-once-test ()
  "Duplicate/reentrant delivery cannot invoke the same captured observer twice."
  (kargu-retry-test--with-peer
    (kargu-bridge-api-retry connection "reverse" params)
    (should (= observations 1))
    (should (eq (gethash "accepted" (gethash "result" (car sent))) t))
    (kargu-bridge-api-retry connection "reverse" params)
    (should (= observations 1))
    (should (eq (gethash "accepted" (gethash "result" (car sent))) :json-false))
    (puthash "attempt" 2 params)
    (kargu-bridge-api-retry connection "next-reverse" params)
    (should (= observations 2))
    (should (eq (gethash "accepted" (gethash "result" (car sent))) t))))

(ert-deftest kargu-native-retry-foreign-or-stale-observer-never-runs-test ()
  "A different forward ID, scope, epoch or invalid attempt cannot reach the UI."
  (dolist (field '(forward scope epoch attempt))
    (kargu-retry-test--with-peer
      (pcase field
        ('forward (puthash "request_id" "foreign" params))
        ('scope (puthash "scope" (kargu-bridge--object "application_id" "app_foreign" "session_id" "sess_fixture") params))
        ('epoch (puthash "connection_epoch" "old-epoch" params))
        ('attempt (puthash "attempt" 0 params)))
      (kargu-bridge-api-retry connection "reverse" params)
      (should (zerop observations))
      (should (eq (gethash "accepted" (gethash "result" (car sent))) :json-false)))))

(ert-deftest kargu-native-retry-reentrant-cancel-or-consumer-error-refuses-ack-test ()
  "Cancellation or observer failure before ACK cannot authorize another socket."
  (dolist (action '(cancel failure replace))
    (kargu-retry-test--with-peer
      (setf (kargu-bridge--pending-on-retry entry)
            (lambda (_)
              (cl-incf observations)
              (pcase action
                ('cancel (kargu-bridge-cancel connection "forward"))
                ('failure (error "synthetic observer failure"))
                ('replace (puthash "forward" (kargu-bridge--pending-create) (kargu-bridge-connection-pending connection))))))
      (kargu-bridge-api-retry connection "reverse" params)
      (should (= observations 1))
      (should (eq (gethash "accepted" (gethash "result" (car sent))) :json-false)))))

(ert-deftest kargu-native-retry-scope-is-detached-before-bridge-delivery-test ()
  "Mutation of the original scope cannot retarget an observer waiter."
  (let* ((mutable (copy-sequence "app_original"))
         (request (kargu-bridge--object "scope" (kargu-bridge--object "application_id" mutable "session_id" "sess_original")))
         (captured (kargu-bridge--capture-api-scope request)))
    (aset mutable 0 ?X)
    (should (equal (gethash "application_id" captured) "app_original"))))

(ert-deftest kargu-native-retry-real-transport-observer-before-replay-test ()
  "Editor -> core -> two real sockets preserves one ledger and hook boundary."
  (kargu-bridge-test--with-core
    (let* ((posts 0) (observations 0) finished failure result
           (budget (kargu-budget-create))
           (application (kargu-application-create))
           (server (kargu-stream-test--server
                    "" nil nil (lambda (_) (cl-incf posts)) nil nil nil
                    (list (list :status 503 :body "" :headers "Retry-After: 0\r\n")
                          (list :status 200 :body "{\"choices\":[{\"message\":{\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}")))))
      (unwind-protect
          (progn
            (kargu-transport-request
             'post (format "http://127.0.0.1:%d/chat" (process-contact server :service))
             :application application :budget budget :body "{}" :timeout 3
             :retry '(("retry_max" . 2) ("backoff_base_ms" . 1) ("backoff_cap_ms" . 1))
             :on-retry (lambda (observation)
                         (cl-incf observations)
                         (should (= posts 1))
                         (should (= (gethash "attempt" observation) 1))
                         (should (= (kargu-run-budget-requests-spent budget) 1)))
             :then (lambda (value) (setq result value finished t))
             :else (lambda (error-data) (setq failure error-data finished t)))
            (kargu-bridge-test--wait (lambda () finished))
            (should-not failure)
            (should (equal (kargu-response-text (kargu--json-decode result)) "ok"))
            (should (= posts 2)) (should (= observations 1))
            (should (= (kargu-run-budget-requests-spent budget) 2))
            (should (= (kargu-run-budget-tokens-spent budget) 5)))
        (kargu-budget-seal budget)
        (delete-process server)))))

(ert-deftest kargu-native-retry-real-observer-cancel-never-replays-test ()
  "Cancel inside a real editor observer is acknowledged before another POST."
  (kargu-bridge-test--with-core
    (let* ((posts 0) (observations 0) (deliveries 0) handle
           (budget (kargu-budget-create))
           (application (kargu-application-create))
           (server (kargu-stream-test--server "" nil nil (lambda (_) (cl-incf posts)) nil 503)))
      (unwind-protect
          (progn
            (setq handle
                  (kargu-transport-request
                   'post (format "http://127.0.0.1:%d/chat" (process-contact server :service))
                   :application application :budget budget :body "{}" :timeout 3
                   :retry '(("retry_max" . 2) ("backoff_base_ms" . 1) ("backoff_cap_ms" . 1))
                   :on-retry (lambda (_)
                               (cl-incf observations)
                               (should (= posts 1))
                               (kargu-transport-cancel handle))
                   :then (lambda (_) (cl-incf deliveries)) :else (lambda (_) (cl-incf deliveries))))
            (kargu-bridge-test--wait (lambda () (> observations 0)))
            (kargu-budget-seal budget)
            (kargu-bridge-test--wait
             (lambda () (eq (kargu-bridge-budget-state (kargu-run-budget-native budget)) :closed)))
            (should (= posts 1)) (should (= observations 1)) (should (zerop deliveries))
            (should (= (kargu-run-budget-requests-spent budget) 1)))
        (kargu-budget-seal budget)
        (delete-process server)))))

(provide 'tests/test-native-retry)
;;; test-native-retry.el ends here
