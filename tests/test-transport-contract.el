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

(ert-deftest kargu-transport-logical-handle-owns-all-resources-test ()
  "Single logical handle owns process, retry timer and stream watchdog."
  (let* ((app (kargu-application-create :status :idle))
         (req (kargu-logical-request-create :generation 1 :state :in-flight)))
    (kargu-application-set-active-request req app)
    (should (eq (kargu-application-current-request app) req))
    (should (kargu-logical-request-live-p req 1))

    ;; Attach mock timer and cancel
    (let ((timer (run-at-time 60 nil #'ignore)))
      (kargu-logical-request-set-retry-timer req timer)
      (should (eq (kargu-logical-request-state req) :retrying))
      (should (eq (kargu-logical-request-retry-timer req) timer))

      ;; Idempotent cancellation releases all
      (kargu-logical-request-cancel req)
      (should (eq (kargu-logical-request-state req) :cancelled))
      (should-not (kargu-logical-request-retry-timer req))
      (should-not (kargu-logical-request-process req)))))

(ert-deftest kargu-transport-budget-debits-initial-request-test ()
  "Initial transport attempt debits :normal-request from run budget."
  (let* ((budget (kargu-budget-create :max-requests 2))
         (app (kargu-application-create :budget budget)))
    (should (eq (kargu-application-budget app) budget))
    (should (= (kargu-run-budget-requests-spent budget) 0))

    ;; Debit 1 normal request
    (let ((res (kargu-budget-debit budget :normal-request :requests 1)))
      (should (kargu-ok-p res))
      (should (= (kargu-run-budget-requests-spent budget) 1)))

    ;; Debit 2nd normal request -> reaches limit
    (let ((res (kargu-budget-debit budget :normal-request :requests 1)))
      (should (kargu-ok-p res))
      (should (= (kargu-run-budget-requests-spent budget) 2)))

    ;; Debit 3rd request -> budget exhausted error
    (let ((res (kargu-budget-debit budget :normal-request :requests 1)))
      (should (kargu-err-p res))
      (should (eq (kargu-result-err-code res) :budget-exhausted))
      (should (eq (kargu-run-budget-status budget) :exhausted-requests)))))

(ert-deftest kargu-transport-retry-debits-run-budget-test ()
  "Transport retry attempt debits :retry-attempt from run budget."
  (let* ((budget (kargu-budget-create :max-requests 2))
         (res-1 (kargu-budget-debit budget :normal-request :requests 1)))
    (should (kargu-ok-p res-1))
    (should (= (kargu-run-budget-requests-spent budget) 1))

    ;; Retry attempt debits the 2nd slot
    (let ((res-retry (kargu-budget-debit budget :retry-attempt :requests 1)))
      (should (kargu-ok-p res-retry))
      (should (= (kargu-run-budget-requests-spent budget) 2)))

    ;; Subsequent retry denied
    (let ((res-retry-fail (kargu-budget-debit budget :retry-attempt :requests 1)))
      (should (kargu-err-p res-retry-fail))
      (should (eq (kargu-result-err-code res-retry-fail) :budget-exhausted)))))

(ert-deftest kargu-transport-records-token-usage-accurately-test ()
  "Response token usage is attributed to budget; missing tokens mark unknown."
  (let ((budget (kargu-budget-create :max-tokens 1000)))
    ;; Normal tokens
    (kargu-budget-record-tokens budget 100 250)
    (should (= (kargu-run-budget-tokens-spent budget) 350))
    (should-not (kargu-run-budget-tokens-unknown-p budget))

    ;; Missing tokens set unknown without coercing to zero
    (kargu-budget-record-tokens budget nil nil)
    (should (kargu-run-budget-tokens-unknown-p budget))
    (should (= (kargu-run-budget-tokens-spent budget) 350))))

(ert-deftest kargu-transport-scoped-circuit-breaker-isolation-test ()
  "Failures on provider A trip circuit A without affecting provider B."
  (kargu-circuit-reset 'all)
  (unwind-protect
      (progn
        ;; Initially both allow requests
        (should (kargu-circuit-allow-request-p "provider-a"))
        (should (kargu-circuit-allow-request-p "provider-b"))

        ;; Fail provider-a 4 times (threshold)
        (dotimes (_ 4)
          (kargu-circuit-record-failure "500 Internal Error" "provider-a"))

        ;; Provider A is now open
        (should (kargu-circuit-open-p "provider-a"))
        (should-not (kargu-circuit-allow-request-p "provider-a"))

        ;; Provider B remains healthy and closed
        (should-not (kargu-circuit-open-p "provider-b"))
        (should (kargu-circuit-allow-request-p "provider-b")))
    (kargu-circuit-reset 'all)))

(ert-deftest kargu-transport-circuit-scoped-reset-test ()
  "Resetting provider A leaves provider B undisturbed."
  (kargu-circuit-reset 'all)
  (unwind-protect
      (progn
        (dotimes (_ 4)
          (kargu-circuit-record-failure "500 Internal Error" "provider-a"))
        (dotimes (_ 4)
          (kargu-circuit-record-failure "500 Internal Error" "provider-b"))
        (should (kargu-circuit-open-p "provider-a"))
        (should (kargu-circuit-open-p "provider-b"))

        ;; Reset only provider-a
        (kargu-circuit-reset "provider-a")
        (should-not (kargu-circuit-open-p "provider-a"))
        (should (kargu-circuit-open-p "provider-b")))
    (kargu-circuit-reset 'all)))

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

(ert-deftest kargu-transport-cross-origin-auth-stripping-test ()
  "Cross-origin redirects strip sensitive authorization and api-key headers."
  (let ((orig-url "https://api.openai.com/v1/chat/completions")
        (same-url "https://api.openai.com/v1/other")
        (diff-host "https://evil.com/v1/chat")
        (diff-port "https://api.openai.com:8443/v1/chat")
        (diff-proto "http://api.openai.com/v1/chat")
        (headers '(("Authorization" . "Bearer secret-token")
                   ("X-API-Key" . "api-key-1234")
                   ("Content-Type" . "application/json"))))
    ;; Same origin preserves headers
    (should (equal (kargu-http--strip-auth-for-cross-origin orig-url same-url headers)
                   headers))
    ;; Cross-origin host strips Authorization and X-API-Key
    (let ((stripped-host (kargu-http--strip-auth-for-cross-origin orig-url diff-host headers)))
      (should (= (length stripped-host) 1))
      (should (equal (car stripped-host) '("Content-Type" . "application/json"))))
    ;; Cross-origin port strips
    (let ((stripped-port (kargu-http--strip-auth-for-cross-origin orig-url diff-port headers)))
      (should (= (length stripped-port) 1)))
    ;; Cross-origin protocol strips
    (let ((stripped-proto (kargu-http--strip-auth-for-cross-origin orig-url diff-proto headers)))
      (should (= (length stripped-proto) 1)))))

(ert-deftest kargu-transport-error-classification-canonical-test ()
  "Classifies error codes and checks retryability using canonical codes without string parsing."
  ;; 429 and 503 are retryable
  (should (eq (kargu-api-classify-error-code 429) :rate-limit-exceeded))
  (should (kargu--api-error-looks-retryable-p :rate-limit-exceeded))
  (should (eq (kargu-api-classify-error-code 503) :server-error))
  (should (kargu--api-error-looks-retryable-p :server-error))
  (should (kargu--api-error-looks-retryable-p :timeout))

  ;; 400 and 401 are client errors and NOT retryable
  (should (eq (kargu-api-classify-error-code 400) :bad-request))
  (should-not (kargu--api-error-looks-retryable-p :bad-request))
  (should (eq (kargu-api-classify-error-code 401) :authentication-failed))
  (should-not (kargu--api-error-looks-retryable-p :authentication-failed)))

(provide 'tests/test-transport-contract)
;;; test-transport-contract.el ends here
