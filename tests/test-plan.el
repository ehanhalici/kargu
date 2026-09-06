;;; tests/test-plan.el --- ERT unit tests for Plan mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the in-memory plan buffer, user options (approve, reject, view),
;; and transition to agent mode execution.

;;; Code:

(require 'ert)
(require 'kargu/constants)
(require 'kargu/core)
(require 'kargu/plan)

(ert-deftest kargu-plan-setup-buffer-unsaved-test ()
  "Test that `kargu-plan-setup-buffer' populates memory without disk association."
  (let* ((text "### Plan: Step 1, Step 2")
         (buf (kargu-plan-setup-buffer text)))
    (unwind-protect
        (progn
          (should (bufferp buf))
          (should (buffer-live-p buf))
          (should (equal (buffer-name buf) kargu-plan-buffer-name))
          ;; Must NEVER have a file backing
          (should (null (buffer-file-name buf)))
          ;; Must not offer or prompt to save
          (should (null (buffer-local-value 'buffer-offer-save buf)))
          ;; Buffer content must match
          (with-current-buffer buf
            (should (equal (buffer-substring-no-properties (point-min) (point-max)) text)))
          ;; Decision pending must be t
          (should (eq kargu-plan--decision-pending t)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest kargu-plan-view-test ()
  "Test that `kargu-plan-view' opens the plan buffer in a live window."
  (let* ((text "Plan steps to view")
         (buf (kargu-plan-setup-buffer text)))
    (unwind-protect
        (progn
          (kargu-plan-view)
          (should (get-buffer-window buf)))
      (when-let ((win (get-buffer-window buf)))
        (quit-window nil win))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest kargu-plan-approve-dispatches-agent-test ()
  "Test that `kargu-plan-approve' reads edited memory, sets agent mode, and dispatches."
  (let* ((initial "Initial Plan")
         (edited "Edited Plan - Step 1 & 2")
         (buf (kargu-plan-setup-buffer initial))
         (dispatched-prompt nil))
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-chat-prompt)
                   (lambda (prompt) (setq dispatched-prompt prompt))))
          (setq kargu-active-mode 'plan)
          ;; User edits buffer without saving to disk
          (with-current-buffer buf
            (erase-buffer)
            (insert edited))
          ;; User clicks approve
          (kargu-plan-approve)
          ;; Mode must be switched to agent
          (should (eq kargu-active-mode 'agent))
          ;; Decision pending reset
          (should-not kargu-plan--decision-pending)
          ;; Dispatched prompt must contain the edited text
          (should (stringp dispatched-prompt))
          (should (string-match-p "Edited Plan - Step 1 & 2" dispatched-prompt))
          (should (string-match-p "approved plan" dispatched-prompt)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest kargu-plan-reject-test ()
  "Test that `kargu-plan-reject' cancels the pending plan."
  (let* ((text "Plan to reject")
         (buf (kargu-plan-setup-buffer text)))
    (unwind-protect
        (progn
          (should (eq kargu-plan--decision-pending t))
          (kargu-plan-reject)
          (should-not kargu-plan--decision-pending))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest kargu-plan-handle-response-test ()
  "Test that `kargu-plan-handle-response' populates buffer and pending state."
  (let* ((report (list :status :done :text "1. Investigate\n2. Fix issue"))
         (chat-buf (get-buffer-create "*kargu-chat*")))
    (unwind-protect
        (progn
          (kargu-plan-handle-response report)
          (should (eq kargu-plan--decision-pending t))
          (let ((plan-buf (get-buffer kargu-plan-buffer-name)))
            (should (bufferp plan-buf))
            (with-current-buffer plan-buf
              (should (string-match-p "1. Investigate" (buffer-string))))))
      (when-let ((plan-buf (get-buffer kargu-plan-buffer-name)))
        (kill-buffer plan-buf))
      (when (buffer-live-p chat-buf)
        (kill-buffer chat-buf)))))

(provide 'tests/test-plan)

;;; test-plan.el ends here
