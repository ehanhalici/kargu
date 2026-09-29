;;; tests/test-metadata.el --- ERT unit tests for model metadata, truncation & background processes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for model metadata extraction, dynamic context window scaling,
;; dynamic compaction threshold, large output truncation preservation,
;; and bash background process execution.

;;; Code:

;; Ensure the package root is on `load-path' during byte/native compilation.
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
(require 'kargu/contract/constants)
(require 'kargu/core)
(require 'kargu/api)
(require 'kargu/api/catalog)
(require 'kargu/api/tools)
(require 'kargu/history/compact)
(require 'kargu/tools/diff)
(require 'kargu/tools/bash)
(require 'kargu/permission)
(require 'kargu/chat)
(require 'kargu/chat/prompt)

(declare-function kargu--efforts-from-specs "kargu/api/catalog" (data specs))
(declare-function kargu-provider-effort-specs "kargu/providers/registry" (id))
(declare-function kargu-provider-models "kargu/providers/registry" (id))
(declare-function kargu-register-provider "kargu/providers/registry" (&rest plist))

(ert-deftest kargu-metadata-context-window-heuristics-test ()
  "Test that `kargu-model-context-window' dynamically resolves metadata."
  ;; Custom registered metadata
  (kargu-model-set-metadata "anthropic/claude-3.5-sonnet" '(:id "anthropic/claude-3.5-sonnet" :context-window 200000))
  (kargu-model-set-metadata "google/gemini-1.5-pro" '(:id "google/gemini-1.5-pro" :context-window 1000000))
  (kargu-model-set-metadata "my-custom-model" '(:id "my-custom-model" :context-window 32768))
  (should (= (kargu-model-context-window "anthropic/claude-3.5-sonnet") 200000))
  (should (= (kargu-model-context-window "google/gemini-1.5-pro") 1000000))
  (should (= (kargu-model-context-window "my-custom-model") 32768))
  ;; A missing record is not a guessed window.
  (should-not (kargu-model-context-window "unknown-model")))

(ert-deftest kargu-dynamic-compaction-threshold-test ()
  "Test that `kargu-history-compact-threshold' dynamically adapts to active model."
  (cl-letf (((symbol-function 'kargu-model-context-window) (lambda (&optional _) 200000)))
    ;; 200k tokens * 3.5 chars * 0.70 = 490,000 chars
    (should (= (kargu-history-compact-threshold) 490000)))
  (cl-letf (((symbol-function 'kargu-model-context-window) (lambda (&optional _) 128000)))
    ;; 128k tokens * 3.5 chars * 0.70 = 313,600 chars
    (should (= (kargu-history-compact-threshold) 313600)))
  (cl-letf (((symbol-function 'kargu-model-context-window) (lambda (&optional _) 10000)))
    ;; 10k tokens * 3.5 chars * 0.70 = 24,500 chars -> bounded by floor 45,000
    (should (= (kargu-history-compact-threshold) 45000))))

(ert-deftest kargu-output-truncation-and-buffer-read-test ()
  "Test that outputs exceeding 24k chars are preserved and readable via read_file."
  (let* ((kargu-tool-output-limit 100)
         (large-string (concat (make-string 80 ?A) "\n"
                               (make-string 80 ?B) "\n"
                               (make-string 80 ?C) "\n"))
         (truncated (kargu--truncate-for-model large-string)))
    ;; Must contain notification and buffer reference
    (should (string-match-p "Output truncated: omitted" truncated))
    (should (string-match-p "\\*kargu-output-[0-9]+\\*" truncated))
    ;; Extract buffer name
    (string-match "\\(\\*kargu-output-[0-9]+\\*\\)" truncated)
    (let ((buf-name (match-string 1 truncated)))
      (should (get-buffer buf-name))
      ;; `kargu-diff-read-file' can read line ranges from this live buffer!
      (let ((read-back (kargu-diff-read-file buf-name 1 2)))
        (should (string-match-p "1 | AAAAA" read-back))
        (should (string-match-p "2 | BBBBB" read-back))
        (should-not (string-match-p "CCCCC" read-back)))
      ;; Cleanup buffer
      (kill-buffer buf-name))))

(ert-deftest kargu-bash-background-process-test ()
  "Test starting a background process with bash and managing it (list, status, kill)."
  (let* ((kargu-permission--mock-decision :approve)
         (kargu-permission-confirm-bash nil)
         ;; Start background sleep process
         (result (kargu-bash-run "sleep 10" default-directory t)))
    (should (string-match-p "Process started in background: ID=\\[\\(p[0-9]+\\)\\]" result))
    (string-match "\\[\\(p[0-9]+\\)\\]" result)
    (let ((id (match-string 1 result)))
      (should id)
      ;; 1. Test list command
      (let ((list-out (kargu-bash-run "list")))
        (should (string-match-p id list-out)))
      ;; 2. Test status command
      (let ((status-out (kargu-bash-run (concat "status " id))))
        (should (string-match-p "RUNNING" status-out)))
      ;; 3. Test kill command
      (let ((kill-out (kargu-bash-run (concat "kill " id))))
        (should (string-match-p "terminated" kill-out)))
      ;; Process should no longer be listed
      (let ((status-after (kargu-bash-run (concat "status " id))))
        (should (string-match-p "ERROR: no background process" status-after))))))

(ert-deftest kargu-model-supports-tools-default-test ()
  "Tools stay available unless the API explicitly disables them."
  (let ((kargu--model-metadata-table (make-hash-table :test 'equal))
        (kargu--session-model "unknown-model"))
    (should (kargu-model-supports-tools-p "unknown-model"))
    (kargu-model-set-metadata "plain-model" '(("id" . "plain-model")))
    (should (kargu-model-supports-tools-p "plain-model"))
    (kargu-model-set-metadata "flagged-off" '(("supports_tools" . :json-false)))
    (should-not (kargu-model-supports-tools-p "flagged-off"))
    (kargu-model-set-metadata "params-without-tools"
                              '(("supported_parameters" . ["temperature" "max_tokens"])))
    (should-not (kargu-model-supports-tools-p "params-without-tools"))
    (kargu-model-set-metadata "params-with-tools"
                              '(("supported_parameters" . ["temperature" "tools"])))
    (should (kargu-model-supports-tools-p "params-with-tools"))))

(ert-deftest kargu-metadata-extended-fields-and-info-test ()
  "Test recording extended model metadata and formatting via `kargu-model-info'."
  (let ((raw-models
         '((("id" . "test/advanced-reasoner")
            ("context_length" . 1000000)
            ("max_output" . 8192)
            ("description" . "A 1M context model with reasoning")
            ("supports_reasoning" . t)
            ("pricing" . (("prompt" . "0.000001") ("completion" . "0.000002")))))))
    (kargu--record-models-metadata raw-models)
    (let ((meta (kargu-model-get-metadata "advanced-reasoner")))
      (should meta)
      (should (= (kargu-model-context-window "advanced-reasoner") 1000000))
      (should (equal (kargu-model-get-prop "advanced-reasoner" "context_length") 1000000))
      (should (equal (kargu-model-get-prop "advanced-reasoner" "max_output") 8192))
      (should (kargu-model-supports-reasoning-p "advanced-reasoner"))
      (should (equal (kargu-aget (kargu-model-get-prop "advanced-reasoner" "pricing") "prompt") "0.000001"))
      (should (equal (kargu-aget (kargu-model-get-prop "advanced-reasoner" "pricing") "completion") "0.000002"))
      (should (string-match-p "1M context" (kargu-model-get-prop "advanced-reasoner" "description")))
      ;; Setting and overriding properties dynamically
      (kargu-model-set-prop "advanced-reasoner" "custom_param" "custom-val")
      (should (equal (kargu-model-get-prop "advanced-reasoner" "custom_param") "custom-val")))
    ;; Model info output test
    (let ((info-msg (kargu-model-info "advanced-reasoner")))
      (should (string-match-p "1000000 tokens" info-msg))
      (should (string-match-p "Compaction" info-msg)))))

(ert-deftest kargu-company-strict-completion-test ()
  "Test that `kargu--completing-read-with-company' enforces valid selections."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt collection &optional _predicate require-match _initial _hist def &rest _ignored)
               (should (equal collection '("openai" "anthropic" "google")))
               (should (eq require-match t))
               def)))
    (let ((res (kargu--completing-read-with-company
                "Pick: " '("openai" "anthropic" "google") "anthropic")))
      (should (string= res "anthropic")))))

(ert-deftest kargu-api-fuzzy-filter-and-scoring-test ()
  "Test fuzzy filtering, scoring, and highlight chunks for model selection."
  (let ((models '("openai/gpt-4o"
                  "openai/gpt-4o-mini"
                  "google/gemini-2.5-flash"
                  "google/gemini-2.5-pro"
                  "anthropic/claude-3-7-sonnet")))
    ;; Substring match in base model name
    (should (equal (mapcar #'substring-no-properties (kargu-api--fuzzy-filter "flash" models))
                   '("google/gemini-2.5-flash")))
    ;; Prefix match
    (should (equal (mapcar #'substring-no-properties (kargu-api--fuzzy-filter "gpt-4o" models))
                   '("openai/gpt-4o" "openai/gpt-4o-mini")))
    ;; Subsequence / flex match
    (should (equal (mapcar #'substring-no-properties (kargu-api--fuzzy-filter "c37s" models))
                   '("anthropic/claude-3-7-sonnet")))
    ;; Non-matching query returns nil
    (should (null (kargu-api--fuzzy-filter "nonexistent-model" models)))
    ;; Highlight chunks via Company
    (let* ((cand (car (kargu-api--fuzzy-filter "flash" models)))
           (chunks (and (fboundp 'company--match-from-capf-face)
                        (company--match-from-capf-face cand))))
      (should (equal chunks '((18 . 23)))))))

(ert-deftest kargu-company-ephemeral-backend-fuzzy-and-strict-test ()
  "Test that the footer Company backend requires a match and filters fuzzily."
  (let* ((cands '("gemini-2.5-flash" "gpt-4o"))
         (backend (kargu-api-select--backend cands nil (point-marker))))
    (should (eq (funcall backend 'require-match) t))
    (let ((matched (funcall backend 'candidates "flash")))
      (should (equal (mapcar #'substring-no-properties matched)
                     '("gemini-2.5-flash")))
      (when (fboundp 'company--match-from-capf-face)
        (should (equal (funcall backend 'match (car matched)) '((11 . 16))))))
    (should (null (funcall backend 'candidates "unknown")))))

(ert-deftest kargu-api-model-selection-strict-template-rejection-test ()
  "Test that model selection accepts only an exact catalog id."
  ;; A typed string that is not a catalog id is rejected.
  (let ((kargu--session-model "gpt-4o")
        (footer-refreshed nil))
    (cl-letf (((symbol-function 'kargu-chat-refresh-footer)
               (lambda () (setq footer-refreshed t)))
              ((symbol-function 'kargu--completing-read-with-company)
               (lambda (&rest _) "out-of-template-model-xyz")))
      (should-error (kargu-chat-select-model-company '("gpt-4o" "gemini-2.5-flash") nil "mock")
                    :type 'user-error)
      (should (string= kargu--session-model "gpt-4o"))
      (should footer-refreshed)))
  ;; A fuzzy fragment is a filter, not a confirmed choice.
  (let ((kargu--session-model "gpt-4o"))
    (cl-letf (((symbol-function 'kargu--completing-read-with-company)
               (lambda (&rest _) "flash")))
      (should-error (kargu-chat-select-model-company '("gpt-4o" "gemini-2.5-flash") nil "mock")
                    :type 'user-error)
      (should (string= kargu--session-model "gpt-4o"))))
  ;; The confirmed value must be the catalog id itself.
  (let ((kargu--session-model "gpt-4o"))
    (cl-letf (((symbol-function 'kargu--completing-read-with-company)
               (lambda (&rest _) "gemini-2.5-flash")))
      (kargu-chat-select-model-company '("gpt-4o" "gemini-2.5-flash") nil "mock")
      (should (string= kargu--session-model "gemini-2.5-flash")))))

(ert-deftest kargu-chat-footer-rendering-and-buttons-test ()
  "Test that `kargu-chat--footer-string' renders provider, model, effort buttons and refreshes."
  (let* ((kargu--session-provider "opencode")
         (kargu--session-model "gemini-3.7-flash")
         (kargu-reasoning-effort 'low))
    (setq-local kargu-chat--session-provider "opencode")
    (setq-local kargu-chat--session-model "gemini-3.7-flash")
    (kargu-model-set-metadata "gemini-3.7-flash" '(:id "gemini-3.7-flash" :context-window 1000000))
    (let ((footer (kargu-chat--footer-string)))
      ;; Check structure
      (should (string-match-p "provider: " footer))
      (should (string-match-p "\\[opencode\\]" footer))
      (should (string-match-p "model: " footer))
      (should (string-match-p "\\[gemini-3\\.7-flash (1m ctx)\\]" footer))
      (should (string-match-p "effort: " footer))
      (should (string-match-p "\\[low\\]" footer)))
    ;; Verify interactive chat buffer integration
    (with-temp-buffer
      (rename-buffer kargu-chat-buffer-name t)
      (let ((orig-name (buffer-name)))
        (unwind-protect
            (progn
              (kargu-chat-mode)
              (kargu-chat--ensure-idle-prompt)
              ;; Insert user input into prompt
              (goto-char (point-max))
              (insert "hello from user")
              ;; Refresh footer
              (setq kargu-reasoning-effort 'high)
              (kargu-chat-refresh-footer)
              ;; User input must be preserved!
              (should (string-match-p "hello from user" (buffer-string)))
              ;; Footer must reflect new effort!
              (should (string-match-p "\\[high\\]" (buffer-string))))
          (kill-buffer orig-name))))))

(ert-deftest kargu-company-workflow-selection-test ()
  "Test full workflow of selecting provider, model, and effort with company completion."
  (let ((kargu-reasoning-effort nil)
        (kargu-connected-mock '("cerebras" "groq")))
    (cl-letf (((symbol-function 'kargu-connected-providers)
               (lambda () kargu-connected-mock))
              ((symbol-function 'kargu--completing-read-with-company)
               (lambda (prompt _cands &optional _def _ann)
                 (cond
                  ((string-match-p "provider" prompt) "cerebras")
                  ((string-match-p "model" prompt) "llama3.1-70b")
                  ((string-match-p "effort" prompt) "medium"))))
              ((symbol-function 'kargu-api-list-models)
               (lambda (cb &optional _p)
                 (funcall cb '((("id" . "llama3.1-70b")
                                ("context_length" . 128000)
                                ("supports_reasoning" . t)
                                ("reasoning" .
                                 (("supported_efforts" .
                                   ["low" "medium" "high"])))))))))
      (kargu-chat-select-provider-company)
      (should (string= (kargu--provider-name) "cerebras"))
      (should (string= (kargu--model) "llama3.1-70b"))
      (should (eq kargu-reasoning-effort 'medium)))))

(ert-deftest kargu-company-in-buffer-select-at-point-test ()
  "Test in-buffer company field navigation and callback execution."
  (when (get-buffer kargu-chat-buffer-name)
    (kill-buffer kargu-chat-buffer-name))
  (with-temp-buffer
    (rename-buffer kargu-chat-buffer-name)
    (unwind-protect
        (progn
          (kargu-chat-mode)
          (kargu-chat--ensure-idle-prompt)
          ;; Test field navigation in footer
          (should (kargu-chat-goto-footer-field 'provider))
          (should (kargu-chat-goto-footer-field 'model))
          (should (kargu-chat-goto-footer-field 'effort))
          ;; Batch selection returns an exact candidate to APPLY.
          (cl-letf (((symbol-function 'kargu--completing-read-with-company)
                     (lambda (_prompt cands &optional _def _ann)
                       (car cands))))
            (let ((chosen nil))
              (kargu-api-select
               'effort '("off" "low" "medium" "high") nil
               (lambda (sel) (setq chosen sel)))
              (should (string= chosen "off")))))
      (when (get-buffer kargu-chat-buffer-name)
        (kill-buffer kargu-chat-buffer-name)))))

(ert-deftest kargu-company-cancel-and-read-only-invariants-test ()
  "Test that cancel hook accepts argument and read-only invariants are maintained."
  (when (get-buffer kargu-chat-buffer-name)
    (kill-buffer kargu-chat-buffer-name))
  (with-temp-buffer
    (rename-buffer kargu-chat-buffer-name)
    (unwind-protect
        (progn
          (kargu-chat-mode)
          (kargu-chat--ensure-idle-prompt)
          ;; Ensure initial read-only state
          (should (null inhibit-read-only))
          (let ((applied nil))
            (cl-letf (((symbol-function 'kargu--completing-read-with-company)
                       (lambda (&rest _) (signal 'quit nil))))
              (kargu-api-select
               'provider '("opencode" "cerebras") nil
               (lambda (_res) (setq applied t)))
              (should-not applied)
              (should (null inhibit-read-only)))))
      (when (get-buffer kargu-chat-buffer-name)
        (kill-buffer kargu-chat-buffer-name)))))

(ert-deftest kargu-company-field-typing-writable-test ()
  "Ensure typing inside prepared footer field does not raise text-read-only error."
  (when (get-buffer kargu-chat-buffer-name)
    (kill-buffer kargu-chat-buffer-name))
  (with-temp-buffer
    (rename-buffer kargu-chat-buffer-name)
    (unwind-protect
        (progn
          (kargu-chat-mode)
          (kargu-chat--ensure-idle-prompt)
          (let ((m (kargu-api-select--open-field 'effort)))
            (should (markerp m))
            ;; Typing between brackets should not signal text-read-only
            (should (progn (insert "low") t))
            (should (string-match-p "effort: \\[low\\]" (buffer-string)))
            ;; Refreshing footer restores read-only state
            (kargu-chat-refresh-footer)
            (should (string-match-p "effort: \\[" (buffer-string)))))
      (when (get-buffer kargu-chat-buffer-name)
        (kill-buffer kargu-chat-buffer-name)))))

(ert-deftest kargu-company-pseudo-tooltip-post-command-test ()
  "Ensure selecting provider with completing-read preserves read-only invariant in chat buffer."
  (when (get-buffer kargu-chat-buffer-name)
    (kill-buffer kargu-chat-buffer-name))
  (with-temp-buffer
    (rename-buffer kargu-chat-buffer-name)
    (set-window-buffer (selected-window) (current-buffer))
    (unwind-protect
        (progn
          (kargu-chat-mode)
          (kargu-chat--ensure-idle-prompt)
          (cl-letf (((symbol-function 'kargu-connected-providers)
                     (lambda () '("opencode" "cerebras" "groq")))
                    ((symbol-function 'kargu--config-providers)
                     (lambda () '(("opencode") ("cerebras") ("groq"))))
                    ((symbol-function 'kargu--completing-read-with-company)
                     (lambda (_prompt cands &optional _def _ann) (car cands)))
                    ((symbol-function 'kargu-chat-select-model-company)
                     (lambda (&rest _) nil)))
            (kargu-chat-select-provider-company)
            (should (null inhibit-read-only))))
      (when (get-buffer kargu-chat-buffer-name)
        (kill-buffer kargu-chat-buffer-name)))))

(ert-deftest kargu-extract-reasoning-efforts-test ()
  "Declared effort paths yield names.  An undeclared key does not."
  (let ((specs (kargu-provider-effort-specs "openai")))
    (let ((m1 '((("type" . "effort") ("values" . ("low" "medium"))))))
      (should (equal (kargu--efforts-from-specs `(("reasoning_options" . ,m1)) specs)
                     '("low" "medium"))))
    (let ((m2 '((("type" . "effort") ("values" . ["none" "low" "medium" "high" "max"]))
                (("type" . "budget_tokens")))))
      (should (equal (kargu--efforts-from-specs `(("reasoning_options" . ,m2)) specs)
                     '("none" "low" "medium" "high" "max"))))
    (should (equal (kargu--efforts-from-specs '(("reasoning_efforts" . ("low" "high"))) specs)
                   '("low" "high")))
    (should (equal (kargu--efforts-from-specs '(("effort_levels" . ["minimal" "medium" "max"])) specs)
                   '("minimal" "medium" "max")))
    (should (null (kargu--efforts-from-specs
                   '(("reasoning" . (("effort" . ("low" "medium")))))
                   specs)))
    (should (null (kargu--efforts-from-specs
                   '(("variants" . (("low" . 1) ("medium" . 2))))
                   specs)))
    (should (null (kargu--efforts-from-specs
                   '(("reasoning_efforts" . "low, high"))
                   specs)))
    (should (null (kargu--efforts-from-specs
                   '(("reasoning_options" . ((("type" . "toggle")))))
                   specs)))
    (let ((m3 '(("mandatory" . :json-false)
                ("supported_efforts" . ["low" "medium" "high"])
                ("default_effort" . "medium"))))
      (should (equal (kargu--efforts-from-specs `(("reasoning" . ,m3)) specs)
                     '("low" "medium" "high"))))
    (let ((m4 '(:mandatory :json-false
                :supported_efforts ["low" "medium" "high"]
                :default_effort "medium")))
      (should (equal (kargu--efforts-from-specs `(("reasoning" . ,m4)) specs)
                     '("low" "medium" "high"))))))

(ert-deftest kargu-effort-csv-override-test ()
  "A provider :models spec reads a comma-separated effort string."
  (kargu-register-provider
   :id "effort-csv"
   :name "Effort CSV"
   :api "https://example.invalid/v1"
   :format 'openapi
   :models '(:reasoning-efforts (:path ("reasoning_effort") :type csv)))
  (should-not (kargu-provider-models "effort-csv"))
  (should (equal (kargu--efforts-from-specs
                  '(("reasoning_effort" . "low, high"))
                  (kargu-provider-effort-specs "effort-csv"))
                 '("low" "high")))
  (should (null (kargu--efforts-from-specs
                 '(("reasoning_effort" . ("low" "high")))
                 (kargu-provider-effort-specs "effort-csv")))))

(ert-deftest kargu-model-reasoning-efforts-resolution-test ()
  "Test resolving reasoning effort options from API metadata only."
  ;; 1. Explicit model metadata
  (kargu-model-set-metadata "test/two-level-model"
                            '(:id "two-level-model" :reasoning-efforts ("low" "medium")))
  (should (equal (kargu-model-reasoning-efforts "two-level-model")
                 '("low" "medium")))

  ;; 2. Explicitly disabled reasoning
  (kargu-model-set-metadata "test/no-reasoning-model"
                            '(:id "no-reasoning-model" :supports-reasoning :json-false))
  (should (null (kargu-model-reasoning-efforts "no-reasoning-model")))

  ;; 3. A supports-reasoning flag without a level list is not a list
  (kargu-model-set-metadata "my-reasoner" '(:id "my-reasoner" :supports-reasoning t))
  (should (null (kargu-model-reasoning-efforts "my-reasoner"))))

(ert-deftest kargu-company-dynamic-effort-selection-test ()
  "Test Company completion presents dynamic effort choices based on active model."
  (let ((kargu-reasoning-effort nil)
        (captured-cands nil)
        (kargu--session-model "test/two-level-reasoner"))
    ;; Register model with only low and medium
    (kargu-model-set-metadata "test/two-level-reasoner"
                              '(:id "two-level-reasoner" :reasoning-efforts ("low" "medium")))
    (cl-letf (((symbol-function 'kargu--completing-read-with-company)
               (lambda (_prompt cands &optional _def _ann)
                 (setq captured-cands cands)
                 "low")))
      (kargu-chat-select-effort-company)
      ;; Candidates must include "off" and exactly the model's supported levels!
      (should (equal captured-cands '("off" "low" "medium")))
      (should (eq kargu-reasoning-effort 'low)))))

(ert-deftest kargu-company-disabled-reasoning-model-test ()
  "Test effort selection when model explicitly disables reasoning."
  (let ((kargu-reasoning-effort 'high)
        (captured-cands nil)
        (kargu--session-model "test/pure-chat-model"))
    (kargu-model-set-metadata "test/pure-chat-model"
                              '(:id "pure-chat-model" :supports-reasoning :json-false))
    (cl-letf (((symbol-function 'kargu--completing-read-with-company)
               (lambda (_prompt cands &optional _def _ann)
                 (setq captured-cands cands)
                 "off")))
      (kargu-chat-select-effort-company)
      ;; Must only offer "off" and set effort to nil!
      (should (equal captured-cands '("off")))
      (should (null kargu-reasoning-effort)))))

(ert-deftest kargu-tune-cycle-dynamic-effort-test ()
  "Test `kargu-tune-cycle-reasoning-effort' respects dynamic model levels."
  (require 'kargu/chat/tune)
  (let ((kargu-reasoning-effort nil)
        (kargu--session-model "test/dual-model"))
    (kargu-model-set-metadata "test/dual-model"
                              '(:id "dual-model" :reasoning-efforts ("low" "medium")))
    ;; nil -> low -> medium -> nil
    (kargu-tune-cycle-reasoning-effort)
    (should (eq kargu-reasoning-effort 'low))
    (kargu-tune-cycle-reasoning-effort)
    (should (eq kargu-reasoning-effort 'medium))
    (kargu-tune-cycle-reasoning-effort)
    (should (null kargu-reasoning-effort))))

(provide 'tests/test-metadata)

;;; test-metadata.el ends here
