;;; test-plan-async.el --- Asynchronous approved-plan startup -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Claim spans preparation, with one actual dispatch and scoped cancellation.

;;; Code:

(require 'ert)
(require 'tests/test-plan)
(require 'kargu/chat)

(ert-deftest kargu-plan-waits-for-real-mode-completion-test ()
  "Held preparation neither dispatches nor publishes approval prematurely."
  (kargu-test-with-plan-chats
    (let* (ready sent
           (kargu-mode-prepare-functions
            `((agent . ,(lambda (success _failure) (setq ready success)))))
           (record (kargu-test-plan-record chat-a "approved revision")))
      (with-current-buffer chat-a (kargu-state-set-mode 'plan))
      (cl-letf (((symbol-function 'kargu-chat-prompt)
                 (lambda (prompt &rest options)
                   (push (list (current-buffer) prompt) sent)
                   (funcall (plist-get options :on-ready) t nil))))
        (with-current-buffer chat-b (kargu-plan-approve record) (kargu-plan-approve record))
        (should-not sent)
        (should (eq (kargu-plan-record-state record) :dispatching))
        (with-current-buffer chat-a (should (eq (kargu-state-mode) 'plan)))
        (with-current-buffer chat-b
          (funcall ready)
          (funcall ready)
          (should (eq (kargu-state-mode) 'ask)))
        (should (= (length sent) 1))
        (should (eq (caar sent) chat-a))
        (should (eq (kargu-plan-record-state record) :approved))))))

(ert-deftest kargu-plan-stale-preparation-keeps-draft-and-decision-test ()
  "Editing a draft or plan, changing selection, or Stop prevents old dispatch."
  (dolist (case '(draft plan selection stop replace close-view))
    (kargu-test-with-plan-chats
      (let* (ready sent
             (kargu-mode-prepare-functions
              `((agent . ,(lambda (success _failure) (setq ready success)))))
             (record (kargu-test-plan-record chat-a "approved revision")))
        (with-current-buffer chat-a
          (kargu-chat--ensure-idle-prompt)
          (goto-char (point-max))
          (insert "keep this draft")
          (kargu-state-set-mode 'plan))
        (cl-letf (((symbol-function 'kargu-chat-prompt)
                   (lambda (&rest _) (setq sent t))))
          (kargu-plan-approve record)
          (with-current-buffer chat-a
            (pcase case
              ('draft (goto-char (point-max)) (insert " newly edited"))
              ('plan (with-current-buffer (kargu-plan-record-buffer record)
                       (goto-char (point-max)) (insert " changed")))
              ('selection (kargu-selection-update :model "newer-model"))
              ('stop (kargu-chat-stop))
              ('replace (kargu-session-clear))
              ('close-view (kill-buffer (kargu-plan-record-buffer record)))))
          (with-current-buffer chat-b (funcall ready) (funcall ready))
          (should-not sent)
          (should-not (eq (kargu-plan-record-state record) :approved))
          (should-not (kargu-plan-record-dispatch-task record))
          (with-current-buffer chat-a
            (should (string-prefix-p "keep this draft" (kargu-chat--input-text)))
            (unless (eq case 'replace) (should (eq (kargu-state-mode) 'plan)))))))))

(ert-deftest kargu-plan-delayed-startup-refusal-can-be-retried-test ()
  "Late startup failure restores the previous mode and keeps approval pending."
  (kargu-test-with-plan-chats
    (let* (ready failed
           (attempts 0)
           (kargu-mode-prepare-functions
            `((agent . ,(lambda (success failure) (setq ready success failed failure)))))
           (record (kargu-test-plan-record chat-a "retry this revision")))
      (with-current-buffer chat-a (kargu-state-set-mode 'plan))
      (cl-letf (((symbol-function 'kargu-chat-prompt)
                 (lambda (_prompt &rest options)
                   (cl-incf attempts)
                   (when (= attempts 1) (error "Refused"))
                   (funcall (plist-get options :on-ready) t nil))))
        (kargu-plan-approve record)
        (funcall ready)
        (should (kargu-plan-pending-p record))
        (with-current-buffer chat-a (should (eq (kargu-state-mode) 'plan)))
        (kargu-plan-approve record)
        (funcall failed "Preparation failed")
        (funcall ready)
        (should (= attempts 1))
        (should (kargu-plan-pending-p record))
        (kargu-plan-approve record)
        (funcall ready)
        (should (= attempts 2))
        (should (eq (kargu-plan-record-state record) :approved))))))

(ert-deftest kargu-plan-mode-observer-replacement-cannot-dispatch-test ()
  "A reentrant mode observer replacing the owner prevents actual startup."
  (kargu-test-with-plan-chats
    (let* (sent
           (record (kargu-test-plan-record chat-a "do not dispatch stale owner"))
           (kargu-state-mode-hook (list (lambda (_mode) (kargu-session-clear)))))
      (cl-letf (((symbol-function 'kargu-chat-prompt) (lambda (&rest _) (setq sent t))))
        (should-error (kargu-plan-approve record))
        (should-not sent)
        (should-not (eq (kargu-plan-record-state record) :approved))))))

(provide 'tests/test-plan-async)
;;; test-plan-async.el ends here
