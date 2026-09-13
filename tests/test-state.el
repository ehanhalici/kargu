;;; tests/test-state.el --- ERT unit tests for state management -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for Kargu centralized state management (`kargu/state`).

;;; Code:

(require 'ert)
(require 'kargu/state)

(ert-deftest kargu-state-init-and-selectors-test ()
  "Test that state initializes properly with default values."
  (kargu-state-reset)
  (should (eq (kargu-state-mode) 'ask))
  (should (eq (kargu-state-status) :idle))
  (should-not (kargu-state-busy-p))
  (should (stringp (kargu-state-model)))
  (should (symbolp (kargu-state-provider)))
  (should (null (kargu-state-reasoning-effort)))
  (let ((tokens (kargu-state-tokens)))
    (should (= (plist-get tokens :total) 0))))

(ert-deftest kargu-state-mode-transitions-test ()
  "Test mode transition validation and state update."
  (kargu-state-reset)
  (should (eq (kargu-state-set-mode 'agent) 'agent))
  (should (eq (kargu-state-mode) 'agent))
  (should (eq (kargu-state-set-mode 'plan) 'plan))
  (should (eq (kargu-state-mode) 'plan))
  (should-error (kargu-state-set-mode 'invalid-mode))
  (kargu-state-reset))

(ert-deftest kargu-state-status-lifecycle-test ()
  "Test lifecycle status transitions and busy flag synchronization."
  (kargu-state-reset)
  (should-not (kargu-state-busy-p))
  ;; Transition to requesting -> should become busy
  (kargu-state-transition-status :requesting)
  (should (eq (kargu-state-status) :requesting))
  (should (kargu-state-busy-p))
  ;; Transition to executing tools -> still busy
  (kargu-state-transition-status :executing-tools)
  (should (eq (kargu-state-status) :executing-tools))
  (should (kargu-state-busy-p))
  ;; Transition to idle -> no longer busy
  (kargu-state-transition-status :idle)
  (should (eq (kargu-state-status) :idle))
  (should-not (kargu-state-busy-p))
  ;; Invalid status should signal an error
  (should-error (kargu-state-transition-status :bogus-status))
  (kargu-state-reset))

(ert-deftest kargu-state-token-accumulation-test ()
  "Test cumulative token usage updates."
  (kargu-state-reset)
  (let ((u1 (kargu-state-record-tokens 100 50)))
    (should (= (plist-get u1 :prompt) 100))
    (should (= (plist-get u1 :completion) 50))
    (should (= (plist-get u1 :total) 150)))
  (let ((u2 (kargu-state-record-tokens 200 100)))
    (should (= (plist-get u2 :prompt) 300))
    (should (= (plist-get u2 :completion) 150))
    (should (= (plist-get u2 :total) 450)))
  (kargu-state-reset))

(ert-deftest kargu-state-hooks-notification-test ()
  "Test state hook notifications on changes."
  (kargu-state-reset)
  (let ((notified-mode nil)
        (notified-provider nil))
    (let ((mode-fn (lambda (m) (setq notified-mode m)))
          (prov-fn (lambda (p) (setq notified-provider p))))
      (kargu-state-subscribe :mode mode-fn)
      (kargu-state-subscribe :provider prov-fn)
      (unwind-protect
          (progn
            (kargu-state-set-mode 'debug)
            (should (eq notified-mode 'debug))
            (kargu-state-set-provider 'cerebras)
            (should (eq notified-provider 'cerebras)))
        (kargu-state-unsubscribe :mode mode-fn)
        (kargu-state-unsubscribe :provider prov-fn))))
  (kargu-state-reset))

(provide 'test-state)

;;; test-state.el ends here
