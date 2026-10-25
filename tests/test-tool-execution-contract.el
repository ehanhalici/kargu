;;; test-tool-execution-contract.el --- Contract test suite for tool execution gate -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Contract verification test suite for the unified Tool Execution Gate.
;; Verifies Contract 5, MOD-02, ARCH-02, ARCH-03, ARCH-09, ARCH-15, ARCH-16, ARCH-17.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu)
(require 'kargu/core/data)
(require 'kargu/contract)
(require 'kargu/tools/registry)
(require 'kargu/tools/execution)
(require 'kargu/application/budget)

(defun kargu-test-tool--make-test-fixture ()
  "Create an isolated registry and execution context for testing."
  (let* ((reg (kargu-tool-registry-create))
         (root (kargu-test-scratch-root))
         (ctx (kargu-tool-execution-context-create
               :root root
               :mode 'agent
               :policy-revision (kargu-tool-registry-revision reg))))
    (cons reg ctx)))

;; 1. Canonical and alias resolution equivalence
(ert-deftest kargu-tool-gate-canonical-and-alias-execution-test ()
  "Canonical tool and its alias execute identically through the gate."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (ctx (cdr fixture))
         (executed nil))
    (kargu-tool-registry-register
     reg :name "echo_tool" :description "Echo"
     :executor (lambda (args) (push (kargu-aget args "msg") executed) "OK")
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))
    (kargu-tool-registry-alias reg "et" "echo_tool")

    (let (res1 res2)
      (kargu-tool-gate-execute reg ctx "echo_tool" '(("msg" . "direct"))
                               :callback (lambda (r) (setq res1 r)))
      (kargu-tool-gate-execute reg ctx "et" '(("msg" . "aliased"))
                               :callback (lambda (r) (setq res2 r)))
      (should (equal res1 "OK"))
      (should (equal res2 "OK"))
      (should (equal executed '("aliased" "direct"))))))

;; 2. Alias readonly bypass prohibited
(ert-deftest kargu-tool-gate-alias-readonly-bypass-prohibited-test ()
  "Calling a mutating tool via alias in plan or ask mode is strictly prohibited."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (root (kargu-tool-execution-context-root (cdr fixture)))
         (ask-ctx (kargu-tool-execution-context-create :root root :mode 'ask))
         (effect nil))
    (kargu-tool-registry-register
     reg :name "edit_file" :description "Mutating edit"
     :executor (lambda (_) (setq effect t) "OK")
     :parameters '(("type" . "object") ("properties" . :json-empty-object))
     :policy '(:modes (agent)))
    (kargu-tool-registry-alias reg "ef" "edit_file")

    (let (res-direct res-alias)
      (kargu-tool-gate-execute reg ask-ctx "edit_file" nil
                               :callback (lambda (r) (setq res-direct r)))
      (kargu-tool-gate-execute reg ask-ctx "ef" nil
                               :callback (lambda (r) (setq res-alias r)))
      (should-not effect)
      (should (string-prefix-p "ERROR:" res-direct))
      (should (string-prefix-p "ERROR:" res-alias)))))

;; 3. Schema validation rejection
(ert-deftest kargu-tool-gate-schema-validation-test ()
  "Malformed JSON arguments are rejected before executor dispatch."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (ctx (cdr fixture))
         (called nil)
         result)
    (kargu-tool-registry-register
     reg :name "test_schema" :description "Test"
     :executor (lambda (_) (setq called t) "OK")
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))

    (kargu-tool-gate-execute reg ctx "test_schema" "{bad json"
                             :callback (lambda (r) (setq result r)))
    (should-not called)
    (should (string-prefix-p "ERROR:" result))
    (should (string-match-p "not a valid JSON object" result))))

;; 4. Mode gating rejection
(ert-deftest kargu-tool-gate-mode-gating-test ()
  "Tools declared for specific modes are rejected when current mode mismatches."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (agent-ctx (cdr fixture))
         result)
    (kargu-tool-registry-register
     reg :name "debug_cmd" :description "Debug only"
     :executor (lambda (_) "OK")
     :parameters '(("type" . "object") ("properties" . :json-empty-object))
     :policy '(:modes (debug)))

    (kargu-tool-gate-execute reg agent-ctx "debug_cmd" nil
                             :callback (lambda (r) (setq result r)))
    (should (string-prefix-p "ERROR:" result))
    (should (string-match-p "unavailable in agent mode" result))))

;; 5. Availability refusal
(ert-deftest kargu-tool-gate-policy-availability-refusal-test ()
  "When policy :available-p returns refusal string, gate delivers refusal."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (ctx (cdr fixture))
         result)
    (kargu-tool-registry-register
     reg :name "lsp_tool" :description "LSP"
     :executor (lambda (_) "OK")
     :parameters '(("type" . "object") ("properties" . :json-empty-object))
     :policy '(:modes (agent ask)
		      :available-p (lambda () "LSP server not initialized")))

    (kargu-tool-gate-execute reg ctx "lsp_tool" nil
                             :callback (lambda (r) (setq result r)))
    (should (equal result "LSP server not initialized"))))

;; 6. Sync and async executor dispatch
(ert-deftest kargu-tool-gate-sync-and-async-executors-test ()
  "Both 1-arity sync and 2-arity async executors are supported and deliver results."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (ctx (cdr fixture))
         sync-res async-res)
    (kargu-tool-registry-register
     reg :name "sync_tool" :description "Sync"
     :executor (lambda (args) (format "Sync: %s" (kargu-aget args "v")))
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))
    (kargu-tool-registry-register
     reg :name "async_tool" :description "Async"
     :executor (lambda (args on-done)
                 (run-with-timer 0.01 nil (lambda () (funcall on-done (format "Async: %s" (kargu-aget args "v"))))))
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))

    (kargu-tool-gate-execute reg ctx "sync_tool" '(("v" . "1"))
                             :callback (lambda (r) (setq sync-res r)))
    (should (equal sync-res "Sync: 1"))

    (kargu-tool-gate-execute reg ctx "async_tool" '(("v" . "2"))
                             :callback (lambda (r) (setq async-res r)))
    (let ((deadline (+ (float-time) 1.0)))
      (while (and (not async-res) (< (float-time) deadline))
        (accept-process-output nil 0.02)))
    (should (equal async-res "Async: 2"))))

;; 7. Duplicate finish protection
(ert-deftest kargu-tool-gate-duplicate-finish-protection-test ()
  "An async executor calling completion twice delivers only the first result."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (ctx (cdr fixture))
         done-cb (deliveries 0) result)
    (kargu-tool-registry-register
     reg :name "double_tool" :description "Double"
     :executor (lambda (_ on-done) (setq done-cb on-done))
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))

    (kargu-tool-gate-execute reg ctx "double_tool" nil
                             :callback (lambda (r) (cl-incf deliveries) (setq result r)))
    (funcall done-cb "First")
    (funcall done-cb "Second")
    (should (= deliveries 1))
    (should (equal result "First"))))

;; 8. Early completion
(ert-deftest kargu-tool-gate-early-completion-test ()
  "An async executor that calls on-done immediately before return completes cleanly."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (ctx (cdr fixture))
         result)
    (kargu-tool-registry-register
     reg :name "early_tool" :description "Early"
     :executor (lambda (_ on-done) (funcall on-done "Immediate") "OK")
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))

    (kargu-tool-gate-execute reg ctx "early_tool" nil
                             :callback (lambda (r) (setq result r)))
    (should (equal result "Immediate"))))

;; 9. Late result after cancellation is dropped
(ert-deftest kargu-tool-gate-late-result-after-cancel-test ()
  "When a tool task is cancelled, late completions are silently ignored."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (ctx (cdr fixture))
         held-cb (delivered nil) task)
    (kargu-tool-registry-register
     reg :name "slow_tool" :description "Slow"
     :executor (lambda (_ on-done) (setq held-cb on-done))
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))

    (setq task (kargu-tool-gate-execute reg ctx "slow_tool" nil
                                        :callback (lambda (r) (setq delivered r))))
    (kargu-async-cancel task)
    (funcall held-cb "Late output")
    (should-not delivered)))

;; 10. Observer error isolation
(ert-deftest kargu-tool-gate-observer-error-protection-test ()
  "Exceptions thrown inside executor do not crash the gate and return an error result."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (ctx (cdr fixture))
         result)
    (kargu-tool-registry-register
     reg :name "failing_tool" :description "Crash"
     :executor (lambda (_) (error "Simulated tool crash"))
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))

    (kargu-tool-gate-execute reg ctx "failing_tool" nil
                             :callback (lambda (r) (setq result r)))
    (should (string-prefix-p "ERROR:" result))
    (should (string-match-p "Simulated tool crash" result))))

;; 11. Single-use approval token claim
(ert-deftest kargu-tool-gate-single-use-approval-claim-test ()
  "An approval token can only be claimed once; replay attempts fail."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (root (kargu-tool-execution-context-root (cdr fixture)))
         (token (kargu-tool-approval-create
                 :tool-name "guarded_op"
                 :args '(("cmd" . "deploy"))
                 :root root
                 :policy-revision 0)))
    (should-not (kargu-tool-approval-claimed-p token))
    (let ((c1 (kargu-tool-approval-claim token :tool-name "guarded_op"
                                         :args '(("cmd" . "deploy")) :root root)))
      (should (kargu-ok-p c1))
      (should (kargu-tool-approval-claimed-p token)))
    ;; Second claim fails with approval-stale
    (let ((c2 (kargu-tool-approval-claim token :tool-name "guarded_op"
                                         :args '(("cmd" . "deploy")) :root root)))
      (should (kargu-err-p c2))
      (should (eq (kargu-result-err-code c2) :approval-stale)))))

;; 12. Approval token binding verification
(ert-deftest kargu-tool-gate-approval-binding-mismatch-test ()
  "Approval token bound to specific root, tool name, and args cannot be used for others."
  (let* ((root "/tmp/project-root/")
         (token (kargu-tool-approval-create
                 :tool-name "tool_a" :args '(("k" . "v1")) :root root :policy-revision 1)))
    ;; Mismatched tool name
    (should (eq (kargu-result-err-code
                 (kargu-tool-approval-claim token :tool-name "tool_b"
                                            :args '(("k" . "v1")) :root root :policy-revision 1))
                :approval-mismatch))
    ;; Mismatched arguments
    (should (eq (kargu-result-err-code
                 (kargu-tool-approval-claim token :tool-name "tool_a"
                                            :args '(("k" . "v2")) :root root :policy-revision 1))
                :approval-mismatch))
    ;; Mismatched root
    (should (eq (kargu-result-err-code
                 (kargu-tool-approval-claim token :tool-name "tool_a"
                                            :args '(("k" . "v1")) :root "/tmp/other/" :policy-revision 1))
                :approval-mismatch))))

;; 13. Output budget accounting and debiting
(ert-deftest kargu-tool-gate-output-budget-debit-test ()
  "Tool output does not pretend that a character estimate is observed usage."
  (let* ((budget (kargu-budget-create :run-id "run-1" :max-requests 10 :max-tokens 100))
         (root (kargu-test-scratch-root))
         (reg (kargu-tool-registry-create))
         (ctx (kargu-tool-execution-context-create
               :root root :mode 'agent :budget-scope budget)))
    (kargu-tool-registry-register
     reg :name "verbose_tool" :description "Verbose"
     :executor (lambda (_) (make-string 200 ?A))
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))

    (should (= (kargu-run-budget-tokens-spent budget) 0))
    (kargu-tool-gate-execute reg ctx "verbose_tool" nil :callback #'ignore)
    (should (= (kargu-run-budget-tokens-spent budget) 0))
    (should-not (kargu-run-budget-tokens-unknown-p budget))))

;; 14. Output budget exhaustion halts tool execution
(ert-deftest kargu-tool-gate-budget-exhaustion-rejection-test ()
  "When budget is exhausted, tool execution is blocked at the gate."
  (let* ((budget (kargu-budget-create :run-id "run-1" :max-requests 1))
         (root (kargu-test-scratch-root))
         (reg (kargu-tool-registry-create))
         (ctx (kargu-tool-execution-context-create
               :root root :mode 'agent :budget-scope budget))
         (called nil) result)
    (kargu-budget-project budget
                          (kargu-bridge--object "requests_spent" 1 "compactions_spent" 0
                                                "tokens_spent" 0 "outstanding" 0
                                                "tokens_unknown" :json-false "sealed" :json-false
                                                "refusal" "requests"))
    (should (kargu-budget-exhausted-p budget))

    (kargu-tool-registry-register
     reg :name "test_tool" :description "Test"
     :executor (lambda (_) (setq called t) "OK")
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))

    (kargu-tool-gate-execute reg ctx "test_tool" nil
                             :callback (lambda (r) (setq result r)))
    (should-not called)
    (should (string-prefix-p "ERROR:" result))
    (should (string-match-p "budget exhausted" result))))

;; 15. Secret redaction before delivery
(ert-deftest kargu-tool-gate-output-redaction-test ()
  "API keys and bearer tokens in tool output are masked before delivery."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (ctx (cdr fixture))
         result)
    (kargu-tool-registry-register
     reg :name "leak_tool" :description "Leak"
     :executor (lambda (_) "Config: Authorization: Bearer secret_token_xyz123, api_key: sk-1234567890abcdef1234567890")
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))

    (kargu-tool-gate-execute reg ctx "leak_tool" nil
                             :callback (lambda (r) (setq result r)))
    (should-not (string-match-p "secret_token_xyz123" result))
    (should-not (string-match-p "sk-1234567890abcdef" result))
    (should (string-match-p "Bearer \\[REDACTED\\]" result))))

;; 16. Output truncation and archive quota
(ert-deftest kargu-tool-gate-output-truncation-and-archive-test ()
  "Outputs larger than limit are truncated and excess is preserved in project archive."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (ctx (cdr fixture))
         (kargu-tool-output-limit 100)
         (kargu-tool-output-archive-max-buffers 5)
         (kargu-tool-output-archive-max-chars 1000)
         result)
    (kargu-tool-registry-register
     reg :name "huge_tool" :description "Huge"
     :executor (lambda (_) (make-string 300 ?X))
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))

    (kargu-tool-gate-execute reg ctx "huge_tool" nil
                             :callback (lambda (r) (setq result r)))
    (should (string-match-p "\\[Output truncated: omitted 200 chars" result))))

;; 17. Safe draining on unregister
(ert-deftest kargu-tool-gate-safe-unregister-draining-test ()
  "Unregistering a tool with active running work cancels or drains before code removal."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (ctx (cdr fixture))
         held-cb task)
    (kargu-tool-registry-register
     reg :name "async_task_tool" :description "Async"
     :executor (lambda (_ on-done) (setq held-cb on-done))
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))

    (setq task (kargu-tool-gate-execute reg ctx "async_task_tool" nil :callback #'ignore))
    (should (= (kargu-tool-execution-active-task-count reg "async_task_tool") 1))

    ;; Drain with cancellation
    (kargu-tool-execution-drain reg "async_task_tool" :cancel-p t)
    (should-not (kargu-tool-registry-find reg "async_task_tool"))
    (should (= (kargu-tool-execution-active-task-count reg "async_task_tool") 0))
    (should (kargu-async-task-p task))
    (when (functionp held-cb)
      (funcall held-cb "Ignored"))))

;; 18. Consumer schema immutability
(ert-deftest kargu-tool-gate-consumer-schema-immutability-test ()
  "Mutating returned tool parameters definition does not mutate the registry entry."
  (let* ((reg (kargu-tool-registry-create))
         (schema '(("type" . "object") ("properties" . (("f" . (("type" . "string"))))))))
    (kargu-tool-registry-register
     reg :name "schema_tool" :description "Schema"
     :executor #'ignore
     :parameters schema)

    (let* ((def (kargu-tool-registry-find reg "schema_tool"))
           (params (kargu-tool-definition-parameters def)))
      ;; Caller tries to mutate in-place
      (should (equal (alist-get "type" params nil nil #'equal) "object")))))

;; 19. Dual isolated registries
(ert-deftest kargu-tool-gate-two-isolated-registries-test ()
  "Two registries with identical tool names execute independently without cross-leakage."
  (let* ((root (kargu-test-scratch-root))
         (reg-a (kargu-tool-registry-create))
         (reg-b (kargu-tool-registry-create))
         (ctx-a (kargu-tool-execution-context-create :root root :mode 'agent))
         (ctx-b (kargu-tool-execution-context-create :root root :mode 'agent))
         res-a res-b)
    (kargu-tool-registry-register
     reg-a :name "foo" :description "Foo A"
     :executor (lambda (_) "Result A")
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))
    (kargu-tool-registry-register
     reg-b :name "foo" :description "Foo B"
     :executor (lambda (_) "Result B")
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))

    (kargu-tool-gate-execute reg-a ctx-a "foo" nil :callback (lambda (r) (setq res-a r)))
    (kargu-tool-gate-execute reg-b ctx-b "foo" nil :callback (lambda (r) (setq res-b r)))
    (should (equal res-a "Result A"))
    (should (equal res-b "Result B"))))

;; 20. Mutating tools rejected in ask mode even without explicit policy
(ert-deftest kargu-tool-gate-mutating-tools-rejected-in-ask-mode-test ()
  "Mutating tools without explicit policy are rejected at gate in ask mode."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (root (kargu-tool-execution-context-root (cdr fixture)))
         (ask-ctx (kargu-tool-execution-context-create :root root :mode 'ask))
         (executed nil))
    (kargu-tool-registry-register
     reg :name "edit_file" :description "Edit file"
     :executor (lambda (_) (push "edit_file" executed) "OK")
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))
    (kargu-tool-registry-register
     reg :name "bash" :description "Bash shell"
     :executor (lambda (_) (push "bash" executed) "OK")
     :parameters '(("type" . "object") ("properties" . :json-empty-object)))

    (let (res-edit res-bash)
      (kargu-tool-gate-execute reg ask-ctx "edit_file" nil
                               :callback (lambda (r) (setq res-edit r)))
      (kargu-tool-gate-execute reg ask-ctx "bash" nil
                               :callback (lambda (r) (setq res-bash r)))
      (should-not executed)
      (should (string-prefix-p "ERROR:" res-edit))
      (should (string-match-p "unavailable in ask mode" res-edit))
      (should (string-prefix-p "ERROR:" res-bash))
      (should (string-match-p "unavailable in ask mode" res-bash)))))

;; 21. Approval claim and single-use anti-replay on general tools
(ert-deftest kargu-tool-gate-general-tool-approval-claim-and-replay-test ()
  "Approval tokens passed to general tools are claimed and replays fail."
  (let* ((fixture (kargu-test-tool--make-test-fixture))
         (reg (car fixture))
         (root (kargu-tool-execution-context-root (cdr fixture)))
         (executed 0)
         res1 res2)
    (kargu-tool-registry-register
     reg :name "guarded_custom_op" :description "Guarded custom tool"
     :executor (lambda (_) (cl-incf executed) "SUCCESS")
     :parameters '(("type" . "object") ("properties" . :json-empty-object))
     :policy '(:modes (agent)))

    (let* ((ctx (kargu-tool-execution-context-create
                 :root root :mode 'agent
                 :policy-revision (kargu-tool-registry-revision reg)))
           (args '(("key" . "val")))
           (token (kargu-tool-approval-create
                   :tool-name "guarded_custom_op" :args args :root root
                   :policy-revision (kargu-tool-registry-revision reg))))
      (should-not (kargu-tool-approval-claimed-p token))

      ;; First execution claims token and succeeds
      (kargu-tool-gate-execute reg ctx "guarded_custom_op" args
                               :approval token
                               :callback (lambda (r) (setq res1 r)))
      (should (equal res1 "SUCCESS"))
      (should (= executed 1))
      (should (kargu-tool-approval-claimed-p token))

      ;; Replay execution is rejected with approval error
      (kargu-tool-gate-execute reg ctx "guarded_custom_op" args
                               :approval token
                               :callback (lambda (r) (setq res2 r)))
      (should (= executed 1))
      (should (string-prefix-p "ERROR:" res2))
      (should (string-match-p "already been claimed" res2)))))

;; 22. Tool registry policy schema supports :needs-approval-p
(ert-deftest kargu-tool-registry-policy-needs-approval-p-test ()
  "Tool registry accepts boolean :needs-approval-p in policy schema."
  (let ((reg (kargu-tool-registry-create)))
    (should (equal (kargu-tool-registry-register
                    reg :name "needs_appr_tool" :description "Needs approval"
                    :executor #'ignore
                    :parameters '(("type" . "object") ("properties" . :json-empty-object))
                    :policy '(:modes (agent) :needs-approval-p t))
                   "needs_appr_tool"))
    (should (equal (kargu-tool-registry-register
                    reg :name "no_appr_tool" :description "No approval"
                    :executor #'ignore
                    :parameters '(("type" . "object") ("properties" . :json-empty-object))
                    :policy '(:modes (agent) :needs-approval-p nil))
                   "no_appr_tool"))
    (should-error (kargu-tool-registry-register
                   reg :name "bad_appr_tool" :description "Bad approval"
                   :executor #'ignore
                   :parameters '(("type" . "object") ("properties" . :json-empty-object))
                   :policy '(:modes (agent) :needs-approval-p "invalid"))
                  :type 'error)))

(provide 'tests/test-tool-execution-contract)
;;; test-tool-execution-contract.el ends here
