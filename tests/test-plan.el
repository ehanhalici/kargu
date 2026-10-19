;;; tests/test-plan.el --- ERT unit tests for Plan mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the in-memory plan buffer, user options (approve, reject, view),
;; and transition to agent mode execution.

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

(require 'tests/test-helpers)
(require 'ert)
(require 'kargu/contract/constants)
(require 'kargu/core)
(require 'kargu/plan)

(defmacro kargu-test-with-plan-chats (&rest body)
  "Run BODY with independent `chat-a' and `chat-b' in temporary projects."
  (declare (indent 0))
  `(kargu-test-with-git-repo nil
     (let ((chat-a (generate-new-buffer " *kargu-plan-chat-a*"))
           (chat-b (generate-new-buffer " *kargu-plan-chat-b*")))
       (unwind-protect
           (progn
             (dolist (chat (list chat-a chat-b))
               (with-current-buffer chat
                 (kargu-chat-mode)
                 (setq default-directory (expand-file-name (buffer-name chat) repo))
                 (make-directory default-directory t)
                 (setq-local kargu-chat--project-root
                             (file-name-as-directory (file-truename default-directory)))
                 (setq-local kargu-chat--session-id (buffer-name chat))))
             ,@body)
         (dolist (chat (list chat-a chat-b))
           (when-let* ((record (kargu-plan-current chat))
                       (view (kargu-plan-record-buffer record)))
             (when (buffer-live-p view) (kill-buffer view)))
           (when (buffer-live-p chat) (kill-buffer chat)))))))

(defun kargu-test-plan-record (origin text)
  "Create a plan containing TEXT for ORIGIN and return its record."
  (with-current-buffer origin
    (kargu-plan-setup-buffer text)
    (kargu-plan-current)))

(ert-deftest kargu-plan-setup-buffer-unsaved-test ()
  "Test that `kargu-plan-setup-buffer' populates memory without disk association."
  (let* ((text "### Plan: Step 1, Step 2")
         (buf (kargu-plan-setup-buffer text)))
    (unwind-protect
        (progn
          (should (bufferp buf))
          (should (buffer-live-p buf))
          (should (string-prefix-p kargu-plan-buffer-name (buffer-name buf)))
          ;; Must NEVER have a file backing
          (should (null (buffer-file-name buf)))
          ;; Must not offer or prompt to save
          (should (null (buffer-local-value 'buffer-offer-save buf)))
          ;; Buffer content must match
          (with-current-buffer buf
            (should (equal (buffer-substring-no-properties (point-min) (point-max)) text)))
          ;; Decision pending must be t
          (should (kargu-plan-pending-p (kargu-plan-current))))
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
          (kargu-test-mode 'plan)
          ;; User edits buffer without saving to disk
          (with-current-buffer buf
            (erase-buffer)
            (insert edited))
          ;; User clicks approve
          (kargu-plan-approve)
          ;; Mode must be switched to agent
          (should (eq (kargu-state-mode) 'agent))
          ;; Decision pending reset
          (should-not (kargu-plan-pending-p (kargu-plan-current)))
          ;; Dispatched prompt must contain the edited text
          (should (stringp dispatched-prompt))
          (should (string-match-p "Edited Plan - Step 1 & 2" dispatched-prompt))
          (should (string-match-p "approved plan" dispatched-prompt)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest kargu-plan-failed-dispatch-can-be-approved-again-test ()
  "A failed startup preserves plan approval and restores the previous mode."
  (let ((buffer (kargu-plan-setup-buffer "retryable plan")) (attempts 0))
    (unwind-protect
        (progn
          (kargu-test-mode 'plan)
          (cl-letf (((symbol-function 'kargu-chat-prompt)
                     (lambda (_prompt)
                       (cl-incf attempts)
                       (kargu-plan-approve)
                       (when (= attempts 1) (error "Startup refused")))))
            (should-error (kargu-plan-approve))
            (should (kargu-plan-pending-p (kargu-plan-current)))
            (should (eq (kargu-state-mode) 'plan))
            (kargu-plan-approve)
            (should (= attempts 2))
            (should-not (kargu-plan-pending-p (kargu-plan-current))))
          (kargu-plan-setup-buffer "new retryable plan")
          (cl-letf (((symbol-function 'kargu-chat-prompt) nil))
            (should-error (kargu-plan-approve))
            (should (kargu-plan-pending-p (kargu-plan-current)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest kargu-plan-reject-test ()
  "Test that `kargu-plan-reject' cancels the pending plan."
  (let* ((text "Plan to reject")
         (buf (kargu-plan-setup-buffer text)))
    (unwind-protect
        (progn
          (should (kargu-plan-pending-p (kargu-plan-current)))
          (kargu-plan-reject)
          (should-not (kargu-plan-pending-p (kargu-plan-current))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest kargu-plan-handle-response-test ()
  "Test that `kargu-plan-handle-response' populates buffer and pending state."
  (let* ((report (list :status :done :text "1. Investigate\n2. Fix issue"))
         (chat-buf (get-buffer-create "*kargu-chat*")))
    (unwind-protect
        (progn
          (kargu-plan-handle-response report)
          (should (kargu-plan-pending-p (kargu-plan-current)))
          (let ((plan-buf (kargu-plan-record-buffer (kargu-plan-current))))
            (should (bufferp plan-buf))
            (with-current-buffer plan-buf
              (should (string-match-p "1. Investigate" (buffer-string))))))
      (when-let ((plan-buf (and (kargu-plan-current)
                               (kargu-plan-record-buffer (kargu-plan-current)))))
        (kill-buffer plan-buf))
      (when (buffer-live-p chat-buf)
        (kill-buffer chat-buf)))))

(provide 'tests/test-plan)

;;; test-plan.el ends here

(ert-deftest kargu-plan-decision-is-taken-once-test ()
  "A button that stays in the transcript cannot approve or reject a plan twice."
  (let ((buf (kargu-plan-setup-buffer "Plan"))
        (dispatched 0))
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-chat-prompt) (lambda (_p) (cl-incf dispatched))))
          (kargu-plan-approve)
          (kargu-plan-approve)
          (kargu-plan-reject)
          (should (= dispatched 1)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest kargu-plan-independent-owners-dispatch-to-original-chat-test ()
  "Approving A while B is current cannot dispatch B or consume B's decision."
  (kargu-test-with-plan-chats
    (let* ((a (kargu-test-plan-record chat-a "A's plan"))
           (b (kargu-test-plan-record chat-b "B's plan"))
           dispatched-origin dispatched-text)
      (should-not (eq (kargu-plan-record-buffer a) (kargu-plan-record-buffer b)))
      (cl-letf (((symbol-function 'kargu-chat-prompt)
                 (lambda (text) (setq dispatched-origin (current-buffer) dispatched-text text))))
        (with-current-buffer chat-b (kargu-plan-approve a)))
      (should (eq dispatched-origin chat-a))
      (should (string-search "A's plan" dispatched-text))
      (should (kargu-plan-pending-p b))
      (should (eq (kargu-plan-record-state a) :approved))
      (with-current-buffer chat-a (should (string-search "Plan Approved" (buffer-string))))
      (with-current-buffer chat-b (should-not (string-search "Plan Approved" (buffer-string)))))))

(ert-deftest kargu-plan-stale-transcript-button-cannot-approve-new-plan-test ()
  "A historical button retains the old record, never a lookup of the new one."
  (kargu-test-with-plan-chats
    (with-current-buffer chat-a
      (kargu-plan-handle-response '(:text "first plan"))
      (goto-char (point-min))
      (search-forward "Approve & Apply")
      (let ((old-button (button-at (1- (point))))
            (old (kargu-plan-current)))
        (kargu-plan-handle-response '(:text "replacement plan"))
        (let ((new (kargu-plan-current)) (calls 0))
          (cl-letf (((symbol-function 'kargu-chat-prompt) (lambda (_) (cl-incf calls))))
            (should-error (button-activate old-button) :type 'user-error))
          (should (= calls 0))
          (should (eq (kargu-plan-record-state old) :superseded))
          (should (kargu-plan-pending-p new)))))))

(ert-deftest kargu-plan-reject-routes-notice-despite-other-run-test ()
  "Rejecting A never routes its status notice into B's active run transcript."
  (kargu-test-with-plan-chats
    (let ((a (kargu-test-plan-record chat-a "A's plan"))
          (b (kargu-test-plan-record chat-b "B's plan"))
          (kargu--loop-run (list :chat-buffer chat-b)))
      (with-current-buffer chat-b (kargu-plan-reject a))
      (should (eq (kargu-plan-record-state a) :rejected))
      (should (kargu-plan-pending-p b))
      (with-current-buffer chat-a (should (string-search "Plan Rejected" (buffer-string))))
      (with-current-buffer chat-b (should-not (string-search "Plan Rejected" (buffer-string)))))))

(ert-deftest kargu-plan-reassigned-owner-or-closed-view-cannot-dispatch-test ()
  "Session/root changes and closing either captured resource invalidate a plan."
  (kargu-test-with-plan-chats
    (let ((a (kargu-test-plan-record chat-a "A's plan")) (calls 0))
      (cl-letf (((symbol-function 'kargu-chat-prompt) (lambda (_) (cl-incf calls))))
        (with-current-buffer chat-a
          (let ((kargu-chat--session-id "replacement-session"))
            (should-error (kargu-plan-approve a) :type 'user-error))
          (let ((kargu-chat--project-root (buffer-local-value 'kargu-chat--project-root chat-b)))
            (should-error (kargu-plan-approve a) :type 'user-error)))
        (kill-buffer (kargu-plan-record-buffer a))
        (should-not (kargu-plan-current chat-a))
        (should-error (kargu-plan-approve a) :type 'user-error)
        (setq a (kargu-test-plan-record chat-a "another plan"))
        (let ((view (kargu-plan-record-buffer a)))
          (kill-buffer chat-a)
          (should-error (kargu-plan-approve a) :type 'user-error)
          (kill-buffer view)))
      (should (= calls 0)))))

(ert-deftest kargu-plan-failed-old-dispatch-cannot-restore-new-decision-test ()
  "A replaced plan's failed startup cannot overwrite its replacement's state."
  (kargu-test-with-plan-chats
    (let ((a (kargu-test-plan-record chat-a "old plan")) replacement)
      (kargu-test-mode 'plan)
      (cl-letf (((symbol-function 'kargu-chat-prompt)
                 (lambda (_)
                   (setq replacement (kargu-test-plan-record chat-a "replacement"))
                   (error "Startup failed"))))
        (should-error (kargu-plan-approve a)))
      (should (eq (kargu-plan-record-state a) :superseded))
      (should (kargu-plan-pending-p replacement))
      (should (eq (kargu-plan-current chat-a) replacement)))))

(ert-deftest kargu-plan-approval-reads-full-narrowed-review-test ()
  "Narrowing the review changes neither the approved text nor its restriction."
  (kargu-test-with-plan-chats
    (let* ((a (kargu-test-plan-record chat-a "first\nsecond\nthird")) text)
      (with-current-buffer (kargu-plan-record-buffer a)
        (narrow-to-region 7 13)
        (cl-letf (((symbol-function 'kargu-chat-prompt) (lambda (prompt) (setq text prompt))))
          (kargu-plan-approve))
        (should (= (point-min) 7))
        (should (= (point-max) 13)))
      (should (string-search "first\nsecond\nthird" text)))))

(ert-deftest kargu-plan-active-run-refusal-preserves-decision-test ()
  "A global active-run refusal happens before claiming a pending plan."
  (kargu-test-with-plan-chats
    (let ((a (kargu-test-plan-record chat-a "pending plan")) (mode (kargu-state-mode)))
      (cl-letf (((symbol-function 'kargu-loop-running-p) (lambda () t)))
        (should-error (kargu-plan-approve a) :type 'user-error))
      (should (kargu-plan-pending-p a))
      (should (eq (kargu-state-mode) mode)))))

(ert-deftest kargu-plan-empty-report-does-not-read-other-history-test ()
  "An empty owned report cannot synthesize a plan from global chat history."
  (let ((kargu--message-history '((("role" . "assistant") ("content" . "other project")))))
    (should-not (kargu-plan-extract-text '(:text "")))
    (should-not (kargu-plan-extract-text '(:status :done)))))

(ert-deftest kargu-plan-explicit-notice-preserves-narrowed-chat-test ()
  "An owned status notice writes outside narrowing without changing the view."
  (kargu-test-with-plan-chats
    (let ((a (kargu-test-plan-record chat-a "plan")))
      (with-current-buffer chat-a
        (let ((inhibit-read-only t)) (insert "prefix middle suffix"))
        (narrow-to-region 8 14)
        (kargu-plan-reject a)
        (should (= (point-min) 8))
        (should (= (point-max) 14))
        (save-restriction
          (widen)
          (should (string-prefix-p "prefix middle suffix" (buffer-string)))
          (should (string-search "Plan Rejected" (buffer-string))))))))
