;;; test-transport-contract.el --- Tests for Bounded Transport Contract -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Test suite for Wave 2 Package E: Bounded Transport & Circuit Breakers.
;; Verifies Contract 1 (Application), Contract 4 (Connection Snapshot),
;; Contract 6 (Budget Accounting), and Contract 8 (Result Types).

;;; Code:

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)
(require 'kargu/contract/result)
(require 'kargu/application/coordinator)
(require 'kargu/application/budget)
(require 'kargu/config/connection)
(require 'kargu/api/circuit)
(require 'kargu/api/http)
(require 'kargu/api/retry)
(require 'tests/test-native-circuit)

(ert-deftest kargu-transport-logical-handle-owns-all-resources-test ()
  "A logical handle revokes its captured native delivery exactly once."
  (let* ((app (kargu-application-create :status :idle))
         (req (kargu-logical-request-create :generation 1 :state :in-flight))
         (cancelled 0))
    (kargu-application-set-active-request req app)
    (should (eq (kargu-application-current-request app) req))
    (should (kargu-logical-request-live-p req 1))
    (kargu-logical-request-add-cleanup req (lambda () (cl-incf cancelled)))
    (kargu-logical-request-cancel req)
    (kargu-logical-request-cancel req)
    (should (eq (kargu-logical-request-state req) :cancelled))
    (should (= cancelled 1))
    (should-not (kargu-logical-request-cleanups req))
    (should-not (kargu-logical-request-process req))))

;; Native request/retry/usage policy equivalents: Rust api_budget.rs and
;; api_budget_stdio.rs; real editor consumer: test-run-budget.el.

(ert-deftest kargu-transport-scoped-circuit-breaker-isolation-test ()
  "Display facade isolates native providers without granting admission."
  (kargu-circuit-test--with-peer
    (let ((kargu-application--bound application))
      (kargu-bridge-circuit-observe application connection scope
        (kargu-circuit-test--view :id "circuit_a" :provider "a" :state "open") t)
      (kargu-bridge-circuit-observe application connection scope
        (kargu-circuit-test--view :id "circuit_b" :provider "b" :sequence 2 :state "closed") t)
      (should (equal (gethash "state" (kargu-circuit-get "a")) "open"))
      (should (equal (gethash "state" (kargu-circuit-get "b")) "closed"))
      (should-not (kargu-circuit-get "unknown")))))

(ert-deftest kargu-transport-circuit-scoped-reset-test ()
  "Facade reset changes display only after the native ACK for that provider."
  (kargu-circuit-test--with-peer
    (let ((kargu-application--bound application) reply done)
      (kargu-bridge-circuit-observe application connection scope
        (kargu-circuit-test--view :id "circuit_a" :provider "a" :state "open") t)
      (kargu-bridge-circuit-observe application connection scope
        (kargu-circuit-test--view :id "circuit_b" :provider "b" :sequence 2 :state "open") t)
      (cl-letf (((symbol-function 'kargu-bridge-call)
                 (lambda (peer method params callback &rest _)
                   (should (eq peer connection))
                   (should (equal method "api/circuit/reset"))
                   (should (equal (gethash "provider" params) "a"))
                   (setq reply callback))))
        (kargu-circuit-reset "a" (lambda (_ error-data) (should-not error-data) (setq done t)))
        (should-not done)
        (should (equal (gethash "state" (kargu-circuit-get "a")) "open"))
        (funcall reply
                 (kargu-bridge--object "circuits"
                   (vector (kargu-circuit-test--view :id "circuit_a" :provider "a" :sequence 3 :state "closed" :failures 0))) nil)
        (should done)
        (should (equal (gethash "state" (kargu-circuit-get "a")) "closed"))
        (should (equal (gethash "state" (kargu-circuit-get "b")) "open"))))))

(ert-deftest kargu-transport-typed-results-contract-test ()
  "Transport returns canonical kargu-result-err types with side-effect status."
  (let ((err-429 (kargu-err "Rate limit exceeded" :http-status-429
                            '(:side-effect :none :scope "openai")))
        (err-500 (kargu-err "Server error" :http-status-500
                            '(:side-effect :none :scope "anthropic")))
        (err-timeout (kargu-err "Connection timed out" :timeout
                                '(:side-effect :unknown :scope "ollama"))))
    (should (kargu-err-p err-429))
    (should (eq (kargu-result-err-code err-429) :http-status-429))
    (should (eq (plist-get (kargu-result-err-data err-429) :side-effect) :none))

    (should (kargu-err-p err-500))
    (should (eq (kargu-result-err-code err-500) :http-status-500))
    (should (eq (plist-get (kargu-result-err-data err-500) :side-effect) :none))

    (should (kargu-err-p err-timeout))
    (should (eq (kargu-result-err-code err-timeout) :timeout))
    (should (eq (plist-get (kargu-result-err-data err-timeout) :side-effect) :unknown))))


(ert-deftest kargu-transport-error-classification-canonical-test ()
  "UI translates native semantic labels, never HTTP, curl or message guesses."
  (dolist (case '(("rate-limit-exceeded" . :rate-limit-exceeded)
                  ("server-error" . :server-error) ("timeout" . :timeout)
                  ("bad-request" . :bad-request) ("authentication-failed" . :authentication-failed)
                  ("budget-exhausted" . :budget-exhausted) ("context-overflow" . :context-overflow)))
    (let ((result (kargu-api-failure-result
                   (kargu-bridge--object "category" (car case) "code" "synthetic"
                                         "message" "HTTP 503 curl 28 context_length_exceeded"
                                         "status" 418))))
      (should (kargu-err-p result))
      (should (eq (kargu-result-err-code result) (cdr case)))
      (should (= (plist-get (kargu-result-err-data result) :status) 418))
      (should (eq (not (null (kargu-response-overflow-p result)))
                  (eq (cdr case) :context-overflow)))))
  (let ((result (kargu-api-failure-result
                 (kargu-bridge--object "category" "new-untrusted-kind" "code" "http"
                                       "message" "secret fixture" "status" 503))))
    (should (eq (kargu-result-err-code result) :protocol-error))
    (should-not (string-search "secret fixture" (kargu-result-err-message result)))))

(provide 'tests/test-transport-contract)
;;; test-transport-contract.el ends here
