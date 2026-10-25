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

(ert-deftest kargu-native-default-plain-and-stream-retry-one-owned-exchange-test ()
  "Default chat replays in Rust, observes before IO and charges every socket."
  (kargu-bridge-test--with-core
    (dolist (stream '(nil t))
      (let* ((budget (kargu-budget-create))
             (kargu-application--bound (kargu-application-create :budget budget))
             (kargu-stream stream) (kargu-api-retry-max 1)
             (posts 0) (observations 0) (deliveries 0) result
             (consumer #'ignore)
             (server (kargu-stream-test--server
                      "" stream nil (lambda (_) (cl-incf posts)) nil nil nil
                      (list (list :status 503 :body "" :headers "Retry-After: 0\r\n")
                            (list :status 200 :body
                                  (if stream
                                      "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}\n\ndata: [DONE]\n\n"
                                    "{\"choices\":[{\"message\":{\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}")))))
             (kargu-api-retry-hook
              (list (lambda (generation delta)
                      (cl-incf observations)
                      (should (= generation (kargu-application-current-generation)))
                      (should (eq delta consumer))
                      (should (= posts 1))
                      (should (= (kargu-run-budget-requests-spent budget) 1))))))
        (unwind-protect
            (progn
              (kargu--api-post
               (format "http://127.0.0.1:%d/chat" (process-contact server :service))
               nil '(("messages" . [(("role" . "user") ("content" . "hi"))]))
               (kargu-application-current-generation)
               (lambda (value) (setq result value) (cl-incf deliveries)) consumer)
              (kargu-bridge-test--wait (lambda () result))
              (should-not (kargu-err-p result))
              (should (equal (kargu-response-text result) "ok"))
              (should (= posts 2)) (should (= observations 1)) (should (= deliveries 1))
              (should (= (kargu-run-budget-requests-spent budget) 2))
              (should (= (kargu-run-budget-tokens-spent budget) 5))
              (should-not (kargu-application-current-request)))
          (kargu-http-cancel) (kargu-budget-seal budget) (delete-process server))))))

(ert-deftest kargu-native-default-terminal-errors-never-reclassify-or-replay-test ()
  "Native HTTP/protocol/overflow outcomes retain their kind without prose replay."
  (kargu-bridge-test--with-core
    (dolist (case '((401 "" :authentication-failed 0)
                    (503 "" :server-error 1)
                    (200 "{\"error\":{\"message\":\"HTTP 503 temporarily unavailable\"}}" :protocol-error 0)
                    (400 "{\"error\":{\"code\":\"context_length_exceeded\"}}" :context-overflow 0)))
      (let* ((budget (kargu-budget-create))
             (kargu-application--bound (kargu-application-create :budget budget))
             (kargu-api-retry-max 0) (kargu-stream nil) (posts 0) (deliveries 0) result
             (kargu-api-retry-hook (list (lambda (&rest _) (ert-fail "No terminal replay"))))
             (server (kargu-stream-test--server (nth 1 case) nil nil
                                               (lambda (_) (cl-incf posts)) nil (car case))))
        (unwind-protect
            (progn
              (kargu--api-post
               (format "http://127.0.0.1:%d/chat" (process-contact server :service))
               nil '(("messages" . [(("role" . "user") ("content" . "hi"))]))
               (kargu-application-current-generation)
               (lambda (value) (setq result value) (cl-incf deliveries)))
              (kargu-bridge-test--wait (lambda () result))
              (should (eq (kargu-result-err-code result) (nth 2 case)))
              (should (= posts 1)) (should (= deliveries 1))
              (should (= (kargu-run-budget-requests-spent budget) 1))
              (should (= (gethash "failures" (kargu-circuit-get)) (nth 3 case))))
          (kargu-http-cancel) (kargu-budget-seal budget) (delete-process server))))))

(ert-deftest kargu-native-default-retry-observer-cancel-drains-before-next-socket-test ()
  "Default chat cancellation inside its UI observer refuses native replay ACK."
  (kargu-bridge-test--with-core
    (let* ((budget (kargu-budget-create))
           (kargu-application--bound (kargu-application-create :budget budget))
           (kargu-api-retry-max 1) (kargu-stream nil)
           (posts 0) (observations 0) (deliveries 0)
           (server (kargu-stream-test--server "" nil nil (lambda (_) (cl-incf posts)) nil 503
                                             "Retry-After: 0\r\n"))
           (kargu-api-retry-hook
            (list (lambda (&rest _)
                    (cl-incf observations) (kargu-http-cancel)))))
      (unwind-protect
          (progn
            (kargu--api-post
             (format "http://127.0.0.1:%d/chat" (process-contact server :service))
             nil '(("messages" . [(("role" . "user") ("content" . "hi"))]))
             (kargu-application-current-generation) (lambda (_) (cl-incf deliveries)))
            (kargu-bridge-test--wait (lambda () (> observations 0)))
            (kargu-budget-seal budget)
            (kargu-bridge-test--wait
             (lambda () (eq (kargu-bridge-budget-state (kargu-run-budget-native budget)) :closed)))
            (should (= posts 1)) (should (= observations 1)) (should (= deliveries 0))
            (should (= (kargu-run-budget-requests-spent budget) 1))
            (should-not (kargu-application-current-request)))
        (kargu-http-cancel) (kargu-budget-seal budget) (delete-process server)))))

(ert-deftest kargu-native-default-circuit-refuses-before-debit-and-reset-acks-test ()
  "Default native admission owns circuit refusal and explicit facade reset."
  (kargu-bridge-test--with-core
    (let* ((budget (kargu-budget-create))
           (kargu-application--bound (kargu-application-create :budget budget))
           (kargu-api-retry-max 0) (kargu-circuit-failure-threshold 1)
           (kargu-circuit-cooldown-seconds 30) (kargu-stream nil)
           (posts 0) result reset-ack
           (server (kargu-stream-test--server
                    "" nil nil (lambda (_) (cl-incf posts)) nil nil nil
                    (list (list :status 503 :body "")
                          (list :status 200 :body "{\"choices\":[{\"message\":{\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}")))))
      (unwind-protect
          (progn
            (dotimes (attempt 3)
              (setq result nil)
              (when (= attempt 2)
                (kargu-circuit-reset nil (lambda (_ failure) (should-not failure) (setq reset-ack t)))
                (kargu-bridge-test--wait (lambda () reset-ack)))
              (kargu--api-post
               (format "http://127.0.0.1:%d/chat" (process-contact server :service))
               nil '(("messages" . [(("role" . "user") ("content" . "hi"))]))
               (kargu-application-current-generation) (lambda (value) (setq result value)))
              (kargu-bridge-test--wait (lambda () result))
              (pcase attempt
                (0 (should (eq (kargu-result-err-code result) :server-error)))
                (1 (should (eq (kargu-result-err-code result) :circuit-open)))
                (2 (should (equal (kargu-response-text result) "ok"))))
              (should (= posts (if (< attempt 2) 1 2)))
              (should (= (kargu-run-budget-requests-spent budget) (if (< attempt 2) 1 2))))
            (should (equal (gethash "state" (kargu-circuit-get)) "closed"))
            (should (= (gethash "failures" (kargu-circuit-get)) 0)))
        (kargu-http-cancel) (kargu-budget-seal budget) (delete-process server)))))

(ert-deftest kargu-native-default-requires-every-native-capability-before-post-test ()
  "An old core cannot receive a chat POST before all required gates are present."
  (dolist (missing '("api_failure" "api_retry" "api_circuit"))
    (let ((kargu--generation 42) result (calls 0))
      (cl-letf (((symbol-function 'kargu-bridge-ensure)
                 (lambda (callback)
                   (funcall callback
                            (kargu-bridge--connection-create
                             :state 'ready :capabilities
                             (vconcat (remove missing '("api_request" "api_failure" "api_retry" "api_circuit"
                                                        "api_budget" "api_wire" "api_request_policy" "api_auth")))) nil)
                   #'ignore))
                ((symbol-function 'kargu-bridge-call)
                 (lambda (&rest _) (cl-incf calls) (ert-fail "No startup/admission/POST on old core"))))
        (kargu--api-post "https://fixture.invalid" nil nil 42 (lambda (value) (setq result value)))
        (should (eq (kargu-result-err-code result) :service-unavailable))
        (should (zerop calls))
        (should-not (kargu-application-current-request))))))

(ert-deftest kargu-native-default-invalid-preferences-fail-before-first-debit-test ()
  "Rust validates captured retry/circuit settings before admitting any socket."
  (kargu-bridge-test--with-core
    (dolist (setting '((kargu-api-retry-max . -1) (kargu-api-retry-max . 11)
                       (kargu-http-retry-statuses . (418))
                       (kargu-api-retry-after-max . -1)
                       (kargu-circuit-failure-threshold . 0)
                       (kargu-circuit-cooldown-seconds . 0)))
      (let* ((budget (kargu-budget-create))
             (kargu-application--bound (kargu-application-create :budget budget))
             (kargu-stream nil) (posts 0) result
             (server (kargu-stream-test--server "{}" nil nil (lambda (_) (cl-incf posts)))))
        (unwind-protect
            (cl-progv (list (car setting)) (list (cdr setting))
              (kargu--api-post
               (format "http://127.0.0.1:%d/chat" (process-contact server :service))
               nil nil (kargu-application-current-generation) (lambda (value) (setq result value)))
              (kargu-bridge-test--wait (lambda () result))
              (should (eq (kargu-result-err-code result) :invalid-request))
              (should (= posts 0))
              (should (= (kargu-run-budget-requests-spent budget) 0)))
          (kargu-http-cancel) (kargu-budget-seal budget) (delete-process server))))))

(ert-deftest kargu-native-default-preferences-are-frozen-before-startup-test ()
  "Async startup cannot reread changed retry/circuit preferences, including zero."
  (let ((kargu-api-retry-max 2) (kargu-http-retry-statuses '(429 503))
        (kargu-api-retry-after-max 0) (kargu-circuit-failure-threshold 3)
        (kargu-circuit-cooldown-seconds 1.25) ready captured)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (setq ready callback) #'ignore))
              ((symbol-function 'kargu-bridge-application-ensure)
               (lambda (_connection _app callback)
                 (funcall callback (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_fixture") nil)
                 #'ignore))
              ((symbol-function 'kargu-bridge-budget-ensure)
               (lambda (_budget _connection _scope callback) (funcall callback "budget_fixture" nil) #'ignore))
              ((symbol-function 'kargu-bridge-call)
               (lambda (_connection method params _callback &rest _)
                 (should (equal method "api/request")) (setq captured params) "owned-forward")))
      (unwind-protect
          (progn
            (kargu--api-post "https://fixture.invalid" nil nil
                             (kargu-application-current-generation) #'ignore)
            (setq kargu-api-retry-max 9 kargu-http-retry-statuses '(500)
                  kargu-api-retry-after-max 60 kargu-circuit-failure-threshold 10
                  kargu-circuit-cooldown-seconds 30)
            (funcall ready
                     (kargu-bridge--connection-create
                      :state 'ready :capabilities ["api_request" "api_failure" "api_retry" "api_circuit"
                                                  "api_budget" "api_wire" "api_request_policy" "api_auth"]) nil)
            (let* ((retry (gethash "retry" captured)) (policy (gethash "policy" retry))
                   (circuit (gethash "circuit" retry)))
              (should (= (gethash "retry_max" policy) 2))
              (should (equal (gethash "statuses" policy) [429 503]))
              (should (= (gethash "retry_after_max_ms" policy) 0))
              (should (= (gethash "failure_threshold" circuit) 3))
              (should (= (gethash "cooldown_ms" circuit) 1250))))
        (kargu-http-cancel)))))

(provide 'tests/test-native-retry)
;;; test-native-retry.el ends here
