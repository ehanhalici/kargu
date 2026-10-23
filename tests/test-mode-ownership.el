;;; test-mode-ownership.el --- Owned mode intent tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Cross-buffer and reentrant completions must never publish a stale mode.

;;; Code:

(require 'ert)
(require 'kargu/core)

(ert-deftest kargu-mode-new-session-is-independent-test ()
  "A fresh owner starts in ask; changing another owner leaves it alone."
  (with-temp-buffer
    (kargu-state-set-mode 'agent)
    (with-temp-buffer
      (should (eq (kargu-state-mode) 'ask))
      (kargu-state-set-mode 'plan))
    (should (eq (kargu-state-mode) 'agent))))

(ert-deftest kargu-mode-delayed-result-retains-origin-test ()
  "A held preparer completes once in its captured origin, not the caller."
  (let (ready events)
    (with-temp-buffer
      (let ((origin (current-buffer))
            (kargu-mode-prepare-functions
             `((debug . ,(lambda (success _failure) (setq ready success)))))
            (kargu-state-before-mode-change-hook nil))
        (kargu-set-mode 'debug (lambda (mode error) (push (list mode error) events)))
        (should (eq (kargu-state-mode) 'ask))
        (with-temp-buffer
          (funcall ready)
          (funcall ready)
          (should (eq (kargu-state-mode) 'ask)))
        (should (eq (kargu-state-mode) 'debug))
        (should (eq (current-buffer) origin))
        (should (equal events '((debug nil))))))))

(ert-deftest kargu-mode-cancel-or-replacement-rejects-late-ready-test ()
  "Supersession, reset, directory change and close invalidate a held intent."
  (dolist (case '(cancel replace directory close))
    (let ((origin (generate-new-buffer " *kargu-mode-owner*")) ready events)
      (unwind-protect
          (let ((kargu-mode-prepare-functions
                 `((debug . ,(lambda (success _failure) (setq ready success)))))
                (kargu-state-before-mode-change-hook nil))
            (with-current-buffer origin
              (kargu-set-mode 'debug
                              (lambda (mode error) (push (list mode error) events)))
              (pcase case
                ('cancel (kargu-mode-cancel))
                ('replace (kargu-session-clear))
                ('directory (setq default-directory "/tmp/"))
                ('close (kill-buffer origin))))
            (funcall ready)
            (funcall ready)
            (should (= (length events) 1))
            (should-not (caar events))
            (should (stringp (cadar events)))
            (when (buffer-live-p origin)
              (with-current-buffer origin (should (eq (kargu-state-mode) 'ask)))))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(ert-deftest kargu-mode-new-intent-cancels-old-child-test ()
  "A newer mode intent cancels owned resources before it publishes."
  (with-temp-buffer
    (let (old-ready child events
          (kargu-state-before-mode-change-hook nil))
      (let ((kargu-mode-prepare-functions
             `((debug . ,(lambda (success _failure)
                           (setq old-ready success
                                 child (kargu-async-start #'ignore)))))))
        (kargu-set-mode 'debug (lambda (mode error) (push (list mode error) events)))
        (kargu-set-mode 'plan)
        (funcall old-ready)
        (should (eq (kargu-async-task-state child) :cancelled))
        (should (eq (kargu-state-mode) 'plan))
        (should (= (length events) 1))))))

(ert-deftest kargu-mode-reentrant-admission-is-rechecked-test ()
  "A before-mode hook cannot start a run and then mutate its frozen mode."
  (with-temp-buffer
    (let ((kargu--loop-run nil)
          (kargu-state-before-mode-change-hook
           (list (lambda (_mode) (setq kargu--loop-run (list :state 'tools))))))
      (should-error (kargu-state-set-mode 'agent) :type 'user-error)
      (should (eq (kargu-state-mode) 'ask)))))

(provide 'tests/test-mode-ownership)
;;; test-mode-ownership.el ends here
