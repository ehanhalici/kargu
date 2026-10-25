;;; test-run-budget.el --- Native budget projection and lease contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Policy/accounting tests moved to Rust api_budget and api_budget_stdio.
;; These tests exercise editor intent, detached projections and lease delivery.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'tests/test-stream)
(require 'kargu/bridge/budget)

(defun kargu-budget-test--snapshot (&optional requests tokens unknown refusal sealed)
  "Create a detached native fixture from REQUESTS, TOKENS and UNKNOWN.
REFUSAL and SEALED describe native terminal policy."
  (kargu-bridge--object "budget_id" "budget_fixture" "requests_spent" (or requests 0)
                        "tokens_spent" (or tokens 0) "compactions_spent" 0 "outstanding" 0
                        "tokens_unknown" (if unknown t :json-false)
                        "refusal" (or refusal :json-null) "sealed" (if sealed t :json-false)))

(defmacro kargu-budget-test--with-peer (&rest body)
  "Run BODY with an isolated native budget control fixture."
  (declare (indent 0) (debug t))
  `(let ((connection (kargu-bridge--connection-create
                      :state 'ready :capabilities ["api_budget"]))
         (scope (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_fixture"))
         calls)
     (cl-letf (((symbol-function 'kargu-bridge-call)
                (lambda (_connection method params callback &rest options)
                  (push (list method params callback options) calls) "budget-call")))
       ,@body)))

(defun kargu-budget-test--reply (pending method result &optional failure)
  "Deliver RESULT/FAILURE for METHOD recorded in PENDING."
  (let ((call (cl-find method pending :key #'car :test #'equal)))
    (should call) (funcall (nth 2 call) result failure)))

(ert-deftest kargu-budget-creation-defaults-test ()
  "Fresh intent has bounded defaults and no invented native accounting."
  (let ((budget (kargu-budget-create :run-id "run-101")))
    (should (equal (kargu-run-budget-run-id budget) "run-101"))
    (should (= (kargu-run-budget-max-requests budget) 30))
    (should (= (kargu-run-budget-max-compactions budget) 1))
    (should-not (kargu-run-budget-native budget))
    (should (kargu-budget-live-p budget))
    (should (= (kargu-budget-remaining-requests budget) 30))))

(ert-deftest kargu-budget-projection-does-not-recompute-or-reopen-test ()
  "Native counters project verbatim; a late observation cannot undo seal."
  (let ((budget (kargu-budget-create)))
    (kargu-budget-project budget (kargu-budget-test--snapshot 2 350 t))
    (should (= (kargu-run-budget-requests-spent budget) 2))
    (should (= (kargu-run-budget-tokens-spent budget) 350))
    (should (kargu-run-budget-tokens-unknown-p budget))
    (kargu-budget-seal budget)
    (kargu-budget-project budget (kargu-budget-test--snapshot 3 400 t))
    (should-error (kargu-budget-project budget (kargu-budget-test--snapshot 2 399 t)))
    (should (= (kargu-run-budget-tokens-spent budget) 400))
    (should (eq (kargu-run-budget-status budget) :sealed))
    (should-not (kargu-budget-live-p budget))))

(ert-deftest kargu-budget-native-refusal-and-invalid-projection-test ()
  "Known-zero, unknown and native exhaustion remain distinct display values."
  (let ((budget (kargu-budget-create)))
    (kargu-budget-project budget (kargu-budget-test--snapshot 1 0 nil "requests"))
    (should (eq (kargu-run-budget-status budget) :exhausted-requests))
    (should-not (kargu-run-budget-tokens-unknown-p budget))
    (kargu-budget-seal budget)
    (should (eq (kargu-run-budget-status budget) :exhausted-requests))
    (let ((invalid (kargu-budget-test--snapshot)))
      (puthash "tokens_spent" -1 invalid)
      (should-error (kargu-budget-project budget invalid)))
    (should (= (kargu-run-budget-tokens-spent budget) 0))))

(ert-deftest kargu-budget-coordinator-integration-test ()
  "Reset revokes only its application's captured display lease."
  (kargu-test-with-dual-applications (app-a app-b)
				     (let ((first (kargu-budget-create)) (second (kargu-budget-create)))
				       (kargu-application-set-budget first app-a)
				       (kargu-application-set-budget second app-b)
				       (kargu-budget-project first (kargu-budget-test--snapshot 1))
				       (kargu-application-reset app-a)
				       (should-not (kargu-application-budget-get app-a))
				       (should (eq (kargu-run-budget-status first) :sealed))
				       (should (eq (kargu-application-budget-get app-b) second))
				       (should (kargu-budget-live-p second)))))

(ert-deftest kargu-budget-native-ensure-coalesces-and-detaches-test ()
  "One allocation serves waiters without sharing mutable authority strings."
  (kargu-budget-test--with-peer
   (let ((budget (kargu-budget-create)) first second (cancelled 0))
     (kargu-bridge-budget-ensure budget connection scope (lambda (id _) (setq first id)))
     (funcall (kargu-bridge-budget-ensure budget connection scope (lambda (&rest _) (cl-incf cancelled))))
     (kargu-bridge-budget-ensure budget connection scope (lambda (id _) (setq second id)))
     (should (= (length calls) 1))
     (kargu-budget-test--reply calls "api/budget/open" (kargu-budget-test--snapshot))
     (should (equal first second))
     (should-not (eq first second))
     (aset first 0 ?X)
     (should (equal second "budget_fixture"))
     (should (zerop cancelled))
     (kargu-budget-seal budget)
     (should (equal (caar calls) "api/budget/close"))
     (kargu-budget-test--reply calls "api/budget/close"
                               (kargu-bridge--object "status" "closed" "budget" (kargu-budget-test--snapshot 0 0 nil nil t)))
     (should (eq (kargu-bridge-budget-state (kargu-run-budget-native budget)) :closed)))))

(ert-deftest kargu-budget-closed-before-ensure-does-not-create-a-phantom-lease-test ()
  "Sealed or expired intent never installs an unallocated starting lease."
  (kargu-budget-test--with-peer
    (dolist (budget (list (kargu-budget-seal (kargu-budget-create))
                         (kargu-budget-create :deadline 0)))
      (let ((failed 0))
        (funcall (kargu-bridge-budget-ensure
                  budget connection scope
                  (lambda (id failure)
                    (should-not id) (should failure) (cl-incf failed))))
        (should (= failed 1))
        (should-not calls)
        (should-not (kargu-run-budget-native budget))
        (kargu-budget-seal budget)
        (should-not (kargu-run-budget-native budget))))))

(ert-deftest kargu-budget-close-before-allocation-closes-late-id-test ()
  "Canceled startup cannot publish or leak a late native ledger."
  (kargu-budget-test--with-peer
   (let ((budget (kargu-budget-create)) (failed 0))
     (kargu-bridge-budget-ensure budget connection scope
                                 (lambda (id failure) (should-not id) (should failure) (cl-incf failed)))
     (kargu-budget-seal budget)
     (should (= failed 1))
     (kargu-budget-test--reply calls "api/budget/open" (kargu-budget-test--snapshot))
     (should (= (length calls) 2))
     (should (equal (caar calls) "api/budget/close"))
     (should (= failed 1)))))

(ert-deftest kargu-budget-lost-epoch-cannot-reset-native-counters-test ()
  "A replacement connection cannot silently create a zero-valued ledger."
  (kargu-budget-test--with-peer
   (let ((budget (kargu-budget-create)) (replacement (kargu-bridge--connection-create :state 'ready)) failed)
     (kargu-bridge-budget-ensure budget connection scope #'ignore)
     (kargu-budget-test--reply calls "api/budget/open" (kargu-budget-test--snapshot 2 100))
     (kargu-bridge-budget-ensure budget replacement scope
                                 (lambda (id failure) (should-not id) (setq failed failure)))
     (should failed)
     (should (= (length (cl-remove-if-not (lambda (call) (equal (car call) "api/budget/open")) calls)) 1))
     (should (equal (caar calls) "api/budget/close"))
     (should (= (kargu-run-budget-tokens-spent budget) 100))
     (should (eq (kargu-run-budget-status budget) :accounting-lost)))))

(ert-deftest kargu-budget-reentrant-close-revokes-later-waiters-test ()
  "A waiter sealing the budget prevents sibling waiters receiving its ID."
  (kargu-budget-test--with-peer
   (let ((budget (kargu-budget-create)) (ready 0) (failed 0))
     (kargu-bridge-budget-ensure budget connection scope
                                 (lambda (_ _) (cl-incf ready) (kargu-budget-seal budget)))
     (kargu-bridge-budget-ensure budget connection scope
                                 (lambda (id failure) (should-not id) (should failure) (cl-incf failed)))
     (kargu-budget-test--reply calls "api/budget/open" (kargu-budget-test--snapshot))
     (should (= ready 1))
     (should (= failed 1)))))

(ert-deftest kargu-budget-native-transport-counts-once-and-refuses-next-test ()
  "Real editor -> Rust -> HTTP charges once; local usage projection cannot double it."
  (kargu-bridge-test--with-core
   (let* ((application (kargu-application-create))
          (budget (kargu-budget-create :max-requests 1))
          (server (kargu-stream-test--server "{\"choices\":[{\"message\":{\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}" nil))
          (url (format "http://127.0.0.1:%d/chat" (process-contact server :service)))
          finished failure)
     (unwind-protect
         (progn
           (dotimes (attempt 2)
             (setq finished nil failure nil)
             (kargu-transport-request 'post url :application application :budget budget :body "{}"
                                      :debit-kind (if (zerop attempt) :normal-request :retry-attempt)
                                      :timeout 3 :then (lambda (_) (setq finished t))
                                      :else (lambda (error-data) (setq failure error-data finished t)))
             (kargu-bridge-test--wait (lambda () finished))
             (if (zerop attempt) (should-not failure) (should failure))
             (should (= (kargu-run-budget-requests-spent budget) 1))
             (should (= (kargu-run-budget-tokens-spent budget) 5)))
           (should-not (kargu-budget-live-p budget))
           (kargu-budget-seal budget)
           (kargu-bridge-test--wait
            (lambda () (eq (kargu-bridge-budget-state (kargu-run-budget-native budget)) :closed))))
        (delete-process server)))))

(ert-deftest kargu-budget-compaction-retry-captures-kind-and-shared-owner-test ()
  "Logical compaction and its retry carry distinct kinds on the same budget."
  (let* ((budget (kargu-budget-create))
         (kargu-application--context (kargu-application-create :budget budget))
         (run (list :state 'request :iterations 0))
         (kargu--loop-run run) kinds owners)
    (cl-letf (((symbol-function 'kargu-api-send)
               (lambda (_prompt _callback &optional _delta kind)
                 (push kind kinds) (push (kargu-application-budget-get) owners))))
      (kargu--loop-begin-compaction run)
      (kargu--loop-begin-compaction run)
      (should (equal (nreverse kinds) '(:compaction-turn :retry-attempt)))
      (should (cl-every (lambda (owner) (eq owner budget)) owners)))))

(ert-deftest kargu-budget-old-core-is-rejected-without-local-fallback-test ()
  "A core without budget capability cannot silently use an Elisp ledger."
  (kargu-budget-test--with-peer
    (let ((budget (kargu-budget-create)) failure)
      (setf (kargu-bridge-connection-capabilities connection) [])
      (kargu-bridge-budget-ensure budget connection scope
                                  (lambda (id error-data) (should-not id) (setq failure error-data)))
      (should failure)
      (should-not calls)
      (should-not (kargu-budget-live-p budget)))))

(ert-deftest kargu-budget-root-run-uses-native-meter-and-seals-at-finish-test ()
  "Real loop admission captures a budget before preparation and drains it at finish."
  (kargu-bridge-test--with-core
   (let* ((server (kargu-stream-test--server
                   "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}" nil))
          (base (format "http://127.0.0.1:%d/v1" (process-contact server :service)))
          (prepare (symbol-function 'kargu-execution-prepare))
          (kargu-stream nil) budget report)
     (unwind-protect
         (cl-letf (((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
                   ((symbol-function 'kargu--provider-name) (lambda () "openai"))
                   ((symbol-function 'kargu--model) (lambda () "fixture"))
                   ((symbol-function 'kargu--api-base) (lambda () base))
                   ((symbol-function 'kargu-prompt-wrap-user) #'identity)
                   ((symbol-function 'kargu--get-system-prompt) (lambda (&rest _) "Be brief."))
                   ((symbol-function 'kargu-execution-prepare)
                    (lambda (context)
                      (funcall prepare context)
                      (setq budget (kargu-execution-budget context))
                      (should (eq budget (kargu-application-budget-get (kargu-execution-app context))))
                      (should (eq budget (plist-get (kargu-execution-run context) :budget)))
                      (let ((kargu--loop-run (kargu-execution-run context)))
                        (cl-letf (((symbol-function 'kargu-tool-gate-execute-sync)
                                   (lambda (_registry tool-context _name _arguments)
                                     (should (eq budget (kargu-tool-execution-context-budget-scope tool-context)))
                                     "captured")))
                          (should (equal (kargu-execute-tool "budget-fixture" "{}") "captured")))))))
           (kargu-loop-send "hello" nil (lambda (value) (setq report value)))
           (kargu-bridge-test--wait (lambda () report))
           (should (eq (plist-get report :status) :done))
           (should (= (kargu-run-budget-requests-spent budget) 1))
           (should (= (kargu-run-budget-tokens-spent budget) 5))
           (should (eq (kargu-run-budget-status budget) :sealed))
           (should-not (kargu-application-budget-get))
           (kargu-bridge-test--wait
            (lambda () (eq (kargu-bridge-budget-state (kargu-run-budget-native budget)) :closed))))
       (delete-process server)))))

(ert-deftest kargu-budget-run-deadline-does-not-trip-provider-circuit-test ()
  "A real owner-budget timeout is not charged as an upstream failure."
  (kargu-bridge-test--with-core
    (let* ((budget (kargu-budget-create :timeout 0.2))
           (kargu-application--context (kargu-application-create :budget budget))
           (provider (kargu--provider-name))
           (server (kargu-stream-test--server "" nil t))
           (url (format "http://127.0.0.1:%d/chat" (process-contact server :service)))
           (kargu-stream nil) result)
      (unwind-protect
          (progn
            (kargu-circuit-reset provider)
            (kargu--api-post url nil '(("messages" . [(("role" . "user") ("content" . "hi"))]))
                             (kargu-application-current-generation) (lambda (value) (setq result value)))
            (kargu-bridge-test--wait (lambda () result))
            (should (kargu-response-error-message result))
            (should (eq (kargu-run-budget-status budget) :exhausted-deadline))
            (should (= (kargu-run-budget-requests-spent budget) 1))
            (should (= (kargu-circuit-breaker-failure-count (kargu-circuit-get provider)) 0))
            (kargu-budget-seal budget)
            (kargu-bridge-test--wait
             (lambda () (eq (kargu-bridge-budget-state (kargu-run-budget-native budget)) :closed))))
        (delete-process server)))))

(provide 'tests/test-run-budget)
;;; test-run-budget.el ends here
