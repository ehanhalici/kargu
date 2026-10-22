;;; test-run-budget.el --- Tests for run budget accounting and debit gate -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for unified run budget accounting (ARCH-01, DEEP-09, Contract 6):
;; 1. Unified debit gate across normal requests, retries, healing, and compaction.
;; 2. Strict request bound enforcement and terminal exhaustion state.
;; 3. Deadline expiry rejection.
;; 4. Single-compaction invariant per run.
;; 5. Unknown token usage preservation without zero coercion.
;; 6. Budget sealing and subtask immunity.
;; 7. Coordinator application budget binding and reset isolation.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'kargu/application/budget)
(require 'kargu/application/coordinator)
(require 'kargu/contract/result)
(require 'tests/test-helpers)

(ert-deftest kargu-budget-creation-defaults-test ()
  "Test that `kargu-budget-create' initializes with canonical defaults."
  (let ((budget (kargu-budget-create :run-id "run-101")))
    (should (kargu-run-budget-p budget))
    (should (equal (kargu-run-budget-run-id budget) "run-101"))
    (should (= (kargu-run-budget-max-requests budget) 30))
    (should (= (kargu-run-budget-requests-spent budget) 0))
    (should-not (kargu-run-budget-deadline budget))
    (should-not (kargu-run-budget-max-tokens budget))
    (should (= (kargu-run-budget-tokens-spent budget) 0))
    (should-not (kargu-run-budget-tokens-unknown-p budget))
    (should (= (kargu-run-budget-max-compactions budget) 1))
    (should (= (kargu-run-budget-compactions-spent budget) 0))
    (should (eq (kargu-run-budget-status budget) :ok))
    (should (kargu-budget-live-p budget))
    (should-not (kargu-budget-exhausted-p budget))
    (should (= (kargu-budget-remaining-requests budget) 30))))

(ert-deftest kargu-budget-normal-debit-accounting-test ()
  "Test standard request debits and remaining counter updates."
  (let ((budget (kargu-budget-create :run-id "run-102" :max-requests 5)))
    ;; First debit
    (let ((res1 (kargu-budget-debit budget :normal-request)))
      (should (kargu-ok-p res1))
      (should (eq (kargu-result-value res1) budget))
      (should (= (kargu-run-budget-requests-spent budget) 1))
      (should (= (kargu-budget-remaining-requests budget) 4))
      (should (eq (kargu-run-budget-status budget) :ok)))

    ;; Multi-count debit
    (let ((res2 (kargu-budget-debit budget :normal-request :requests 2)))
      (should (kargu-ok-p res2))
      (should (= (kargu-run-budget-requests-spent budget) 3))
      (should (= (kargu-budget-remaining-requests budget) 2)))

    ;; Debit reaching the limit
    (let ((res3 (kargu-budget-debit budget :normal-request :requests 2)))
      (should (kargu-ok-p res3))
      (should (= (kargu-run-budget-requests-spent budget) 5))
      (should (= (kargu-budget-remaining-requests budget) 0))
      (should (kargu-budget-live-p budget)))

    ;; Exceeding the limit must be rejected
    (let ((res4 (kargu-budget-debit budget :normal-request :requests 1)))
      (should (kargu-err-p res4))
      (should (eq (kargu-result-err-code res4) :budget-exhausted))
      (should (eq (plist-get (kargu-result-err-data res4) :reason) :exhausted-requests))
      (should (eq (kargu-run-budget-status budget) :exhausted-requests))
      (should (kargu-budget-exhausted-p budget))
      (should-not (kargu-budget-live-p budget)))

    ;; Subsequent debits remain blocked
    (let ((res5 (kargu-budget-debit budget :normal-request)))
      (should (kargu-err-p res5))
      (should (eq (kargu-result-err-code res5) :budget-exhausted)))))

(ert-deftest kargu-budget-multi-turn-types-unified-gate-test ()
  "Normal, retry, healing, and continuation turns all debit the same counter (DEEP-09)."
  (let ((budget (kargu-budget-create :run-id "run-103" :max-requests 4)))
    ;; Turn 1: normal request
    (should (kargu-ok-p (kargu-budget-debit budget :normal-request)))
    (should (= (kargu-run-budget-requests-spent budget) 1))

    ;; Turn 2: transport retry attempt
    (should (kargu-ok-p (kargu-budget-debit budget :retry-attempt)))
    (should (= (kargu-run-budget-requests-spent budget) 2))

    ;; Turn 3: diagnostic healing attempt
    (should (kargu-ok-p (kargu-budget-debit budget :healing-turn)))
    (should (= (kargu-run-budget-requests-spent budget) 3))

    ;; Turn 4: user continuation turn
    (should (kargu-ok-p (kargu-budget-debit budget :continuation)))
    (should (= (kargu-run-budget-requests-spent budget) 4))

    ;; Turn 5: next turn fails because unified budget is spent
    (let ((res (kargu-budget-debit budget :retry-attempt)))
      (should (kargu-err-p res))
      (should (eq (kargu-result-err-code res) :budget-exhausted)))))

(ert-deftest kargu-budget-deadline-enforcement-test ()
  "Debits past the configured deadline are rejected with :exhausted-deadline."
  (let ((budget (kargu-budget-create :run-id "run-104"
                                     :deadline (- (float-time) 10.0))))
    (should-not (kargu-budget-live-p budget))
    (should (kargu-budget-exhausted-p budget))
    (let ((res (kargu-budget-debit budget :normal-request)))
      (should (kargu-err-p res))
      (should (eq (kargu-result-err-code res) :budget-exhausted))
      (should (eq (plist-get (kargu-result-err-data res) :reason) :exhausted-deadline))
      (should (eq (kargu-run-budget-status budget) :exhausted-deadline)))))

(ert-deftest kargu-budget-single-compaction-invariant-test ()
  "By default at most one context compaction turn is permitted per run."
  (let ((budget (kargu-budget-create :run-id "run-105" :max-requests 10)))
    ;; First compaction turn is granted
    (let ((res1 (kargu-budget-debit budget :compaction-turn)))
      (should (kargu-ok-p res1))
      (should (= (kargu-run-budget-compactions-spent budget) 1))
      (should (= (kargu-run-budget-requests-spent budget) 1))
      (should (eq (kargu-run-budget-status budget) :ok)))

    ;; Second compaction turn must be rejected
    (let ((res2 (kargu-budget-debit budget :compaction-turn)))
      (should (kargu-err-p res2))
      (should (eq (kargu-result-err-code res2) :budget-exhausted))
      (should (eq (plist-get (kargu-result-err-data res2) :reason) :exhausted-compactions))
      (should (eq (kargu-run-budget-status budget) :exhausted-compactions)))

    ;; Multi-stage policy allows configured number
    (let ((multi (kargu-budget-create :run-id "run-105-multi" :max-requests 10 :max-compactions 2)))
      (should (kargu-ok-p (kargu-budget-debit multi :compaction-turn)))
      (should (kargu-ok-p (kargu-budget-debit multi :compaction-turn)))
      (should (kargu-err-p (kargu-budget-debit multi :compaction-turn))))))

(ert-deftest kargu-budget-token-accounting-and-unknown-integrity-test ()
  "Token usage accumulates monotonically and missing usage is marked unknown without zero coercion."
  (let ((budget (kargu-budget-create :run-id "run-106" :max-tokens 500)))
    ;; Record known tokens
    (kargu-budget-record-tokens budget 100 50)
    (should (= (kargu-run-budget-tokens-spent budget) 150))
    (should-not (kargu-run-budget-tokens-unknown-p budget))

    ;; Record wire response with missing/nil tokens
    (kargu-budget-record-tokens budget nil nil)
    (should (= (kargu-run-budget-tokens-spent budget) 150))
    (should (kargu-run-budget-tokens-unknown-p budget))

    ;; Additional known tokens add up
    (kargu-budget-record-tokens budget 200 100)
    (should (= (kargu-run-budget-tokens-spent budget) 450))

    ;; Exceeding max tokens transitions status to exhausted
    (kargu-budget-record-tokens budget 50 50)
    (should (= (kargu-run-budget-tokens-spent budget) 550))
    (should (eq (kargu-run-budget-status budget) :exhausted-tokens))
    (should (kargu-budget-exhausted-p budget))

    ;; Further debits are denied
    (let ((res (kargu-budget-debit budget :normal-request)))
      (should (kargu-err-p res))
      (should (eq (kargu-result-err-code res) :budget-exhausted)))))

(ert-deftest kargu-budget-sealing-test ()
  "Sealing a budget prevents any subsequent debits."
  (let ((budget (kargu-budget-create :run-id "run-107" :max-requests 10)))
    (should (kargu-ok-p (kargu-budget-debit budget :normal-request)))
    (should (eq (kargu-run-budget-status budget) :ok))

    ;; Seal budget
    (kargu-budget-seal budget)
    (should (eq (kargu-run-budget-status budget) :sealed))
    (should (kargu-budget-exhausted-p budget))

    ;; Debits on sealed budget fail
    (let ((res (kargu-budget-debit budget :normal-request)))
      (should (kargu-err-p res))
      (should (eq (kargu-result-err-code res) :budget-exhausted))
      (should (eq (plist-get (kargu-result-err-data res) :reason) :sealed)))))

(ert-deftest kargu-budget-coordinator-integration-test ()
  "Application coordinator binds and clears run budget across claims and resets."
  (kargu-test-with-dual-applications (app-a app-b)
    (let ((budget-a (kargu-budget-create :run-id "run-a" :max-requests 15))
          (budget-b (kargu-budget-create :run-id "run-b" :max-requests 20)))
      (kargu-application-set-budget budget-a app-a)
      (kargu-application-set-budget budget-b app-b)

      (should (eq (kargu-application-budget-get app-a) budget-a))
      (should (eq (kargu-application-budget-get app-b) budget-b))

      ;; Debit through bound budget
      (should (kargu-ok-p (kargu-budget-debit (kargu-application-budget-get app-a) :normal-request)))
      (should (= (kargu-run-budget-requests-spent budget-a) 1))
      (should (= (kargu-run-budget-requests-spent budget-b) 0))

      ;; Reset app-a clears budget-a while leaving budget-b intact
      (kargu-application-reset app-a)
      (should-not (kargu-application-budget-get app-a))
      (should (eq (kargu-application-budget-get app-b) budget-b)))))

(provide 'tests/test-run-budget)
;;; test-run-budget.el ends here
