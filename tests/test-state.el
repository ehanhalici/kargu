;;; tests/test-state.el --- ERT unit tests for state management -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for Kargu centralized state management (`kargu/state`).

;;; Code:

;; Ensure the package root is on `load-path` during byte/native compilation.
(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'ert)
(require 'kargu/state)

(ert-deftest kargu-state-init-and-selectors-test ()
  "Test that state initializes properly with default values."
  (kargu-state-reset)
  (should (eq (kargu-state-mode) 'ask))
  (should (eq (kargu-state-status) :idle))
  (should-not (kargu-state-busy-p))
  (should-not (kargu-state-model))
  (should-not (kargu-state-provider))
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
            (kargu-state-set-mode 'plan)
            (should (eq notified-mode 'plan))
            (kargu-state-set-provider 'cerebras)
            (should (eq notified-provider 'cerebras)))
        (kargu-state-unsubscribe :mode mode-fn)
        (kargu-state-unsubscribe :provider prov-fn))))
  (kargu-state-reset))

(ert-deftest kargu-state-token-notifications-see-complete-totals-test ()
  "Token listeners see all counters updated before the first notification."
  (let ((kargu--state-store (kargu-state-initial))
        (kargu-state-change-hook nil)
        keys)
    (add-hook 'kargu-state-change-hook
              (lambda (key value)
                (push (cons key value) keys)
                (should (equal (kargu-state-tokens)
                               '(:prompt 10 :completion 5 :total 15)))))
    (kargu-state-record-tokens 10 5)
    (should (equal (nreverse keys)
                   '((:prompt-tokens . 10) (:completion-tokens . 5)
                     (:total-tokens . 15))))))

(ert-deftest kargu-state-mode-synchronization-test ()
  "Test that kargu-state-set-mode writes the store."
  (kargu-state-reset)
  (kargu-state-set-mode 'agent)
  (should (eq (kargu-state-mode) 'agent))
  (kargu-state-set-mode 'ask)
  (should (eq (kargu-state-mode) 'ask))
  (kargu-state-reset))

(ert-deftest kargu-state-snapshots-remain-stable-after-transitions-test ()
  "Holding an earlier store reference never observes later writes."
  (let* ((kargu--state-store (kargu-state-initial))
         (before kargu--state-store)
         (expected (copy-sequence before)))
    (kargu-state-set-model "next-model")
    (kargu-state-set-provider 'next-provider)
    (kargu-state-record-tokens 10 5)
    (kargu-state-transition-status :requesting)
    (should (equal before expected))
    (should-not (eq before kargu--state-store))
    (should (eq (kargu-state-status) :requesting))
    (should (kargu-state-busy-p))))

(ert-deftest kargu-state-listener-failures-do-not-interrupt-notification-test ()
  "A failing listener cannot skip later hooks or leave state half updated."
  (let ((kargu--state-store (kargu-state-initial))
        (kargu-state-change-hook nil)
        (kargu-state-status-hook nil)
        events logs)
    (setq kargu-state-change-hook
          (list (lambda (&rest _) (string-match "bad" "bad") (error "broken listener"))
                (lambda (key value) (push (list key value) events) :non-nil)))
    (setq kargu-state-status-hook
          (list (lambda (status detail) (push (list status detail) events))))
    (cl-letf (((symbol-function 'kargu-log)
               (lambda (_level format &rest args) (push (apply #'format format args) logs))))
      (string-match "saved" "saved")
      (let ((saved (match-data)))
        (kargu-state-transition-status :requesting "start")
        (should (equal (match-data) saved))))
    (should (equal (nreverse events) '((:status :requesting) (:requesting "start"))))
    (should (cl-some (lambda (line) (string-search "broken listener" line)) logs))
    (should (kargu-state-busy-p))
    (should (eq (kargu-state-status) :requesting))))

(provide 'tests/test-state)

;;; test-state.el ends here
