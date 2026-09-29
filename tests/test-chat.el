;;; tests/test-chat.el --- Tests for the chat buffer, footer and @ completion -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'kargu/core)
(require 'kargu/api)
(require 'kargu/chat)
(require 'kargu/chat/prompt)
(require 'kargu/chat/header)
(require 'kargu/chat/complete)
(require 'kargu/loop)
(require 'kargu/providers/catalog)
(require 'kargu/tools/lsp)

(ert-deftest kargu-chat-context-usage-footer-test ()
  "Test that context usage is accurately calculated and rendered."
  (kargu-model-set-metadata "gemini-2.5-flash" '(("context_length" . 1000000)))
  (let ((kargu--session-model "gemini-2.5-flash")
        (kargu--session (list :tokens 0 :turns 0 :last-prompt-tokens 32000)))
    (let ((info (kargu-session-context-info)))
      (should (= (plist-get info :used) 32000))
      (should (> (plist-get info :capacity) 0))
      (should (string-match-p "32.0k" (plist-get info :formatted)))
      (should (string-match-p "%" (plist-get info :formatted))))
    ;; Verify footer contains context info
    (let ((footer (kargu-chat--footer-string)))
      (should (string-match-p "ctx:" footer)))))

(ert-deftest kargu-chat-multiple-buffers-test ()
  "Test creating and switching multiple independent chat buffers."
  (let ((buf1 (get-buffer-create "*kargu-chat-test-1*"))
        (buf2 (get-buffer-create "*kargu-chat-test-2*")))
    (unwind-protect
        (progn
          (with-current-buffer buf1
            (kargu-chat-mode))
          (with-current-buffer buf2
            (kargu-chat-mode))
          (let ((live (kargu-chat-list-buffers)))
            (should (member buf1 live))
            (should (member buf2 live)))
          ;; Switching respects current mode
          (with-current-buffer buf1
            (should (derived-mode-p 'kargu-chat-mode))))
      (kill-buffer buf1)
      (kill-buffer buf2))))

(ert-deftest kargu-chat-mode-selector-footer-test ()
  "Test mode selector in footer, company integration, header line, and buffer cleanup."
  (let ((chat-buf (get-buffer-create "*kargu-chat-mode-test*")))
    (unwind-protect
        (with-current-buffer chat-buf
          (kargu-chat-mode)
          (kargu-chat--ensure-idle-prompt)
          ;; Initially ASK
          (kargu-set-mode 'ask)
          (should (string-match-p "mode: \\[ASK\\]" (buffer-string)))
          (should (string-match-p "kargu · \\[ASK\\]" (kargu-chat--header-string)))
          ;; Change to PLAN: footer and header must update!
          (kargu-set-mode 'plan)
          (should (eq (kargu-state-mode) 'plan))
          (should (string-match-p "mode: \\[PLAN\\]" (buffer-string)))
          (should (string-match-p "kargu · \\[PLAN\\]" (kargu-chat--header-string)))
          ;; Check that top obsolete mode buttons are absent
          (should-not (string-match-p "Mode: \\[ask\\]" (buffer-string)))
          ;; Test company selector fallback in batch mode
          (cl-letf (((symbol-function 'kargu--completing-read-with-company)
                     (lambda (_p _c _d _a) "agent")))
            (kargu-chat-select-mode-company)
            (should (eq (kargu-state-mode) 'agent))
            (should (string-match-p "mode: \\[AGENT\\]" (buffer-string)))
            (should (string-match-p "kargu · \\[AGENT\\]" (kargu-chat--header-string)))))
      (kill-buffer chat-buf))))

(ert-deftest kargu-chat-selection-guard-while-running-test ()
  "Test model and provider completion guard while loop is running."
  (cl-letf (((symbol-function 'kargu-loop-running-p) (lambda () t)))
    (should-error (kargu-chat-select-model-company) :type 'user-error)
    (should-error (kargu-chat-select-provider-company) :type 'user-error)))

(ert-deftest kargu-chat-company-at-mention-test ()
  "Test that `@' mention completion works at prompt and restores cleanly."
  (kargu-test-with-git-repo '(("tests/test-git.el" . "x") ("tests/test-fs.el" . "y") ("main.el" . "z"))
  (let ((chat-buf (get-buffer-create "*kargu-chat-complete-test*")))
    (unwind-protect
        (with-current-buffer chat-buf
          (kargu-chat-mode)
          (kargu-chat--ensure-idle-prompt)
          (goto-char (point-max))
          ;; Initial prompt state must have kargu-chat-company
          (should (equal company-backends '(kargu-chat-company)))
          (should (= company-minimum-prefix-length 1))
          ;; Type `@'
          (insert "@")
          (should (equal (kargu-chat--at-prefix) "@"))
          (let ((cands (kargu-chat-company 'candidates "@")))
            (should (listp cands))
            (should (> (length cands) 0)))
          ;; Rogue company-backend clearing
          (let ((rogue (lambda (&rest _) nil)))
            (setq company-backend rogue)
            (kargu-chat--maybe-company)
            (should-not (eq company-backend rogue))
            (should (equal company-backends '(kargu-chat-company))))
          (setq company-backend nil)
          ;; Typing `@' calls maybe-company which triggers company-manual-begin
          (let ((triggered nil))
            (cl-letf (((symbol-function 'company-manual-begin) (lambda () (setq triggered t))))
              (kargu-chat--maybe-company)
              (should triggered)))
          ;; Test symbol completion candidates with LSP symbols
          (cl-letf (((symbol-function 'kargu-lsp-all-symbols)
                     (lambda (&optional _q _r)
                       '(("/path/to/main.go" 42 "CalcTotal" "Function")
                         ("/path/to/user.go" 10 "UserStruct" "Struct")))))
            ;; Query without ::
            (let ((sym-cands (kargu-chat--symbol-candidates "Calc")))
              (should (listp sym-cands))
              (should (> (length sym-cands) 0))
              (should (cl-some (lambda (c) (string-match-p "CalcTotal" c)) sym-cands)))
            ;; Query with :: delimiter
            (let ((cands (kargu-chat-company 'candidates "@main.go::Calc")))
              (should (listp cands))
              (should (> (length cands) 0))
              (should (cl-some (lambda (c) (string-match-p "CalcTotal" c)) cands))))
          ;; Ensure company-backends invariant holds
          (should (equal company-backends '(kargu-chat-company)))
          (should-not company-backend)
          (should (= company-minimum-prefix-length 1)))
      (kill-buffer chat-buf)))))
(ert-deftest kargu-company-at-symbol-typing-cycle-test ()
  "Test that continuous typing after `@' preserves company-backend and handles kind/require-match."
  (kargu-test-with-git-repo '(("tests/test-git.el" . "x") ("tests/test-fs.el" . "y") ("main.el" . "z"))
  (let ((chat-buf (get-buffer-create "*kargu-chat-typing-test*")))
    (unwind-protect
        (with-current-buffer chat-buf
          (kargu-chat-mode)
          (kargu-chat--ensure-idle-prompt)
          (goto-char (point-max))
          ;; 1. Verify kargu-chat-company protocol commands
          (let ((file-cands (kargu-chat-company 'candidates "@tests/test-git.el")))
            (should (consp file-cands))
            (let ((cand (car file-cands)))
              (should (equal (get-text-property 0 'company-backend cand) 'kargu-chat-company))
              (should (equal (kargu-chat-company 'kind cand) 'file))
              (should (stringp (kargu-chat-company 'meta cand)))))
          (should (eq (kargu-chat-company 'require-match) 'never))

          ;; 2. Simulate typing `@' followed by incremental characters
          (insert "@")
          (kargu-chat--maybe-company)
          (should (equal company-backend 'kargu-chat-company))
          (should (consp company-candidates))

          ;; 3. Insert character while completion is active
          (insert "s")
          (kargu-chat--maybe-company)
          ;; company-backend must NOT be reset to nil
          (should (equal company-backend 'kargu-chat-company))

          ;; 4. Verify kind call on candidate works cleanly (no void: nil error)
          (let ((kind (company-call-backend 'kind (car company-candidates))))
            (should (memq kind '(file function variable struct method))))

          ;; 5. Even if company-backend were forced to nil, candidate property prevents crash
          (setq company-backend nil)
          (let ((cand (car (kargu-chat-company 'candidates "@tests"))))
            (should (equal (company-call-backend 'kind cand) 'file))))
      (kill-buffer chat-buf)))))
(ert-deftest kargu-chat-request-uses-the-buffer-model-test ()
  "A request from a chat carries that chat's model, and the other chat keeps its own."
  (let ((buf1 (get-buffer-create "*kargu-chat-sel-1*"))
        (buf2 (get-buffer-create "*kargu-chat-sel-2*"))
        (kargu--session-provider "openrouter")
        (kargu--session-model "model-shared"))
    (unwind-protect
        (progn
          (with-current-buffer buf1
            (kargu-chat-mode)
            (kargu-chat-note-selection))
          (with-current-buffer buf2
            (kargu-chat-mode)
            (kargu-chat-note-selection))
          (with-current-buffer buf1
            (kargu-set-model "model-one"))
          (with-current-buffer buf1
            (should (equal (kargu--model) "model-one"))
            (should (equal (kargu-aget (kargu--build-payload) "model") "model-one"))
            (should (equal kargu-chat--session-model "model-one")))
          (with-current-buffer buf2
            (should (equal (kargu--model) "model-shared"))
            (should (equal kargu-chat--session-model "model-shared"))
            (should (equal (kargu-aget (kargu--build-payload) "model") "model-shared"))))
      (when (buffer-live-p buf1) (kill-buffer buf1))
      (when (buffer-live-p buf2) (kill-buffer buf2)))))

(provide 'tests/test-chat)
;;; test-chat.el ends here
