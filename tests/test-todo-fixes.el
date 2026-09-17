;;; tests/test-todo-fixes.el --- Tests for todo.md bug fixes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'kargu/core)
(require 'kargu/api/http)
(require 'kargu/api)
(require 'kargu/chat)
(require 'kargu/chat/prompt)
(require 'kargu/chat/header)
(require 'kargu/loop)
(require 'kargu/loop/machine)
(require 'kargu/providers/catalog)

(require 'kargu/tools/lsp)
(require 'kargu/chat/complete)

(ert-deftest kargu-todo-1-context-usage-display-test ()
  "Test that context usage is accurately calculated and rendered."
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

(ert-deftest kargu-todo-2-multi-session-buffers-test ()
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

(ert-deftest kargu-todo-3-loop-continue-prompt-test ()
  "Test loop limit prompt structure and continuation mechanism."
  (let* ((run (list :iterations 12 :max-iterations 12 :state 'request))
         (kargu--loop-run run)
         (chat-buf (get-buffer-create "*kargu-chat-test-limit*"))
         (kargu-loop--mock-continue-decision :continue))
    (plist-put run :chat-buffer chat-buf)
    (unwind-protect
        (progn
          (with-current-buffer chat-buf
            (kargu-chat-mode)
            ;; Mock kargu-api-send so we don't start a real un-mocked request in batch test
            (cl-letf (((symbol-function 'kargu-api-send)
                       (lambda (_prompt _cb &optional _delta) nil)))
              ;; Prompt continue function
              (kargu-loop--prompt-continue run "test prompt")
              (should (string-match-p "Turn limit reached" (buffer-string)))
              (should (string-match-p "Continue" (buffer-string)))
              (should (string-match-p "Stop" (buffer-string))))))
      (setq kargu--busy nil)
      (when (fboundp 'kargu-state-reset) (kargu-state-reset))
      (kill-buffer chat-buf))))

(ert-deftest kargu-todo-4-sound-notifications-test ()
  "Test audio alert notification dispatch."
  (let ((ding-count 0))
    (cl-letf (((symbol-function 'ding)
               (lambda (&optional _do-not-terminate)
                 (setq ding-count (1+ ding-count)))))
      ;; Enabled: triggers ding
      (let ((kargu-sound-notifications t))
        (kargu-notify 'permission)
        (kargu-notify 'finish)
        (kargu-notify 'limit)
        (should (= ding-count 3)))
      ;; Disabled: stays quiet
      (let ((kargu-sound-notifications nil))
        (kargu-notify 'permission)
        (should (= ding-count 3))))))

(ert-deftest kargu-todo-5-mode-selector-footer-test ()
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
          (should (eq kargu-active-mode 'plan))
          (should (string-match-p "mode: \\[PLAN\\]" (buffer-string)))
          (should (string-match-p "kargu · \\[PLAN\\]" (kargu-chat--header-string)))
          ;; Check that top obsolete mode buttons are absent
          (should-not (string-match-p "Mode: \\[ask\\]" (buffer-string)))
          ;; Test company selector fallback in batch mode
          (cl-letf (((symbol-function 'kargu--completing-read-with-company)
                     (lambda (_p _c _d _a) "agent")))
            (kargu-chat-select-mode-company)
            (should (eq kargu-active-mode 'agent))
            (should (string-match-p "mode: \\[AGENT\\]" (buffer-string)))
            (should (string-match-p "kargu · \\[AGENT\\]" (kargu-chat--header-string)))))
      (kill-buffer chat-buf))))

(ert-deftest kargu-todo-6-selection-conflict-guard-test ()
  "Test model and provider completion guard while loop is running."
  (cl-letf (((symbol-function 'kargu-loop-running-p) (lambda () t)))
    (should-error (kargu-chat-select-model-company) :type 'user-error)
    (should-error (kargu-chat-select-provider-company) :type 'user-error)))

(ert-deftest kargu-todo-7-opencode-session-header-test ()
  "Test that x-opencode-session header is generated and passed for OpenCode."
  (let ((kargu--session-provider "opencode")
        (kargu--session-id nil))
    (let ((headers (kargu--api-headers "test-key")))
      (should (assoc "x-opencode-session" headers))
      (should (stringp (cdr (assoc "x-opencode-session" headers))))
      (should (> (length (cdr (assoc "x-opencode-session" headers))) 10)))))

(ert-deftest kargu-todo-8-catalog-model-sanitization-test ()
  "Test that provider endpoints are dynamic and no hallucinated models are statically registered."
  (let ((opencode-models (kargu-provider-models "opencode")))
    ;; Static models should not exist
    (should-not opencode-models)
    (should (equal (kargu-provider-models-api "opencode") "https://opencode.ai/zen/v1/models"))
    (should (equal (kargu-provider-usage-api "opencode") "https://opencode.ai/zen/v1/user"))))

(ert-deftest kargu-todo-9-company-at-mention-prompt-test ()
  "Test that `@' mention completion works at prompt and restores cleanly."
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
      (kill-buffer chat-buf))))

(ert-deftest kargu-company-at-symbol-typing-cycle-test ()
  "Test that continuous typing after `@' preserves company-backend and handles kind/require-match."
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
      (kill-buffer chat-buf))))

(ert-deftest kargu-todo-10-tool-continuation-history-test ()
  "Test that tool continuation after assistant tool call preserves user message."
  (let ((kargu--message-history nil)
        (kargu--busy nil))
    (unwind-protect
        (progn
          ;; 1. User turn added
          (kargu--history-add "user" "@description.md a bakarak bu projedeki hatalarin raporunu cikartir misin")
          ;; 2. Assistant turn with tool_calls added (as when model executes lsp_project_skeleton)
          (let ((msg '((("role" . "assistant")
                        ("content" . "Let me explore the codebase...")
                        ("tool_calls" . [((("id" . "call_123")
                                           ("type" . "function")
                                           ("function" . ((("name" . "lsp_project_skeleton")
                                                           ("arguments" . "{}"))))))])))))
            (setq kargu--message-history (append kargu--message-history msg)))
          ;; 3. Tool result added
          (kargu--history-add-tool-result "call_123" "lsp_project_skeleton" "# Project skeleton (702 chars)")
          ;; 4. Verify history invariants: has user, has assistant tool call, has tool response
          (should (cl-some (lambda (m) (equal (kargu--aget m "role") "user")) kargu--message-history))
          (should (cl-some (lambda (m) (equal (kargu--aget m "role") "tool")) kargu--message-history))
          ;; 5. Next continuation turn (prompt nil) must pass history validation without error
          (cl-letf (((symbol-function 'kargu--resolve-api-key) (lambda () "mock-key"))
                    ((symbol-function 'kargu--api-post) (lambda (&rest _) nil)))
            ;; kargu-api-send with nil prompt should succeed without "history has no user message" error
            (let ((err-msg nil))
              (kargu-api-send nil (lambda (resp)
                                    (when (kargu-response-error-message resp)
                                      (setq err-msg (kargu-response-error-message resp)))))
              (should-not err-msg))))
      (setq kargu--busy nil))))

(ert-deftest kargu-todo-11-unsupported-tools-fallback-test ()
  "Test detection and handling of provider endpoints that do not support tools."
  (let ((err-text "HTTP 404: (404) No endpoints found that support tool use. Try disabling \"lsp_project_skeleton\". To learn more about provider routing, visit: https://openrouter.ai/docs/guides/routing/provider-selection"))
    ;; 1. Error string pattern detection
    (should (kargu--error-no-tools-support-p err-text))
    (should (kargu--error-no-tools-support-p "Model does not support tools"))

    ;; 2. In ask mode: falls back to :no-tools t and retries
    (let* ((kargu-active-mode 'ask)
           (kargu--model-metadata-table (make-hash-table :test 'equal))
           (kargu--session-model "openrouter/free-model")
           (kargu--session-provider "openrouter")
           (retry-called nil)
           (finish-called nil)
           (run (list :state 'wait :no-tools nil)))
      (cl-letf (((symbol-function 'kargu--loop-request)
                 (lambda (_run _prompt)
                   (setq retry-called t)))
                ((symbol-function 'kargu--loop-finish)
                 (lambda (&rest _) (setq finish-called t))))
        (kargu-loop--handle-tools-unsupported run err-text)
        (should retry-called)
        (should-not finish-called)
        (should (plist-get run :no-tools))
        (should-not (kargu-model-supports-tools-p "openrouter/free-model"))
        (should (string-match-p "🚫 no-tools" (kargu-model-annotation-string "openrouter/free-model" "openrouter")))))

    ;; 3. In agent mode: finishes with descriptive error
    (let* ((kargu-active-mode 'agent)
           (kargu--model-metadata-table (make-hash-table :test 'equal))
           (kargu--session-model "openrouter/free-model")
           (kargu--session-provider "openrouter")
           (finish-err nil)
           (run (list :state 'wait :no-tools nil)))
      (cl-letf (((symbol-function 'kargu--loop-finish)
                 (lambda (_run status text)
                   (setq finish-err (cons status text))))
                ((symbol-function 'kargu--loop-request)
                 (lambda (&rest _) nil)))
        (kargu-loop--handle-tools-unsupported run err-text)
        (should (equal (car finish-err) :error))
        (should (string-match-p "does not support tool use" (cdr finish-err)))))))

(provide 'tests/test-todo-fixes)
;;; test-todo-fixes.el ends here
