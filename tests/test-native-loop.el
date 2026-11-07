;;; test-native-loop.el --- Native terminal projection contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Native terminal results project into the editor loop exactly once.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'kargu/loop)
(require 'kargu/loop/native)
(require 'tests/test-helpers)
(require 'tests/test-bridge)
(require 'tests/test-native-conversation)
(require 'tests/test-native-history)

(declare-function kargu-stream-test--server "tests/test-stream"
                  (body stream &optional hold capture capture-headers status headers script))

(ert-deftest kargu-native-loop-terminal-failure-never-projects-success-test ()
  (dolist (case '(("completed" . :done) ("failed" . :error)
                  ("rejected" . :error) ("timeout" . :error)
                  ("cancelled" . :stopped) ("unknown" . :error) (nil . :error)))
    (let ((run (list :iterations 0)) delivered)
      (cl-letf (((symbol-function 'kargu-loop--live-p) (lambda (_run) t))
                ((symbol-function 'kargu--loop-finish)
                 (lambda (_run status &optional _text) (push status delivered))))
               (kargu-loop-native--finish run (kargu-bridge--object "status" (car case) "answer_text" "fixture answer") nil)
               (should (equal delivered (list (cdr case))))))))

(ert-deftest kargu-native-loop-terminal-error-and-retired-owner-test ()
  (let ((run (list :iterations 0)) live delivered)
    (cl-letf (((symbol-function 'kargu-loop--live-p) (lambda (_run) live))
              ((symbol-function 'kargu--loop-finish)
               (lambda (_run status &optional _text) (push status delivered))))
	     (kargu-loop-native--finish run (kargu-bridge--object "status" "completed") nil)
	     (should-not delivered)
	     (setq live t)
	     (kargu-loop-native--finish run (kargu-bridge--object "status" "completed") 'rpc-failed)
	     (should (equal delivered '(:error))))))

(ert-deftest kargu-native-loop-cancel-before-startup-rejects-late-dispatch-test ()
  (let (ready acquired dispatched cleanup task)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (setq ready callback)
                 (lambda () (setq cleanup t))))
              ((symbol-function 'kargu-bridge-application-ensure)
               (lambda (&rest _) (setq acquired t)))
              ((symbol-function 'kargu-bridge-session-start)
               (lambda (&rest _) (setq dispatched t))))
	     (setq task (kargu-loop-native-owned-start
			 nil (kargu-bridge--object) #'ignore))
	     (kargu-async-cancel task)
	     (funcall ready (kargu-bridge--connection-create :state 'ready :epoch "fixture-epoch") nil)
	     (should cleanup)
	     (should-not acquired)
	     (should-not dispatched))))

(ert-deftest kargu-native-loop-detaches-input-and-cancels-exact-prompt-test ()
  (let* ((scope (kargu-bridge--object "application_id" "app-fixture"
                                      "session_id" "sess-fixture"))
         (arguments (kargu-bridge--object "text" "original"))
         ready task sent cancel-id finish)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (setq ready callback) #'ignore))
              ((symbol-function 'kargu-bridge-application-ensure)
               (lambda (_connection _application callback)
                 (funcall callback scope nil) #'ignore))
              ((symbol-function 'kargu-bridge-conversation-ensure)
               (lambda (_connection _application _session scope callback)
                 (funcall callback scope nil) #'ignore))
              ((symbol-function 'kargu-bridge-conversation-current-scope)
               (lambda (application _session connection)
                 (kargu-bridge-application-current-scope application connection)))
              ((symbol-function 'kargu-bridge-application-current-scope)
               (lambda (&rest _) scope))
              ((symbol-function 'kargu-bridge-session-start)
               (lambda (_connection actual-scope input callback &rest _)
                 (should (equal actual-scope scope))
                 (setq sent input finish callback) "exact-prompt-id"))
              ((symbol-function 'kargu-bridge-cancel)
               (lambda (_connection id) (setq cancel-id id))))
	     (setq task (kargu-loop-native-owned-start nil arguments
						       (lambda (&rest _) (ert-fail "late callback"))))
	     (puthash "text" "mutated" arguments)
	     (funcall ready (kargu-bridge--connection-create :state 'ready :epoch "fixture-epoch") nil)
	     (should (equal (gethash "text" sent) "original"))
	     (kargu-async-cancel task)
	     (should (equal cancel-id "exact-prompt-id"))
	     (funcall finish (kargu-bridge--object "status" "completed") nil))))

(ert-deftest kargu-native-loop-replaced-lease-never-dispatches-test ()
  (let (task delivered sent)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (funcall callback (kargu-bridge--connection-create :state 'ready :epoch "fixture-epoch") nil) #'ignore))
              ((symbol-function 'kargu-bridge-application-ensure)
               (lambda (_connection _application callback)
                 (funcall callback (kargu-bridge--object "application_id" "old" "session_id" "old") nil)
                 #'ignore))
              ((symbol-function 'kargu-bridge-conversation-ensure)
               (lambda (_connection _application _session scope callback)
                 (funcall callback scope nil) #'ignore))
              ((symbol-function 'kargu-bridge-conversation-current-scope)
               (lambda (application _session connection)
                 (kargu-bridge-application-current-scope application connection)))
              ((symbol-function 'kargu-bridge-application-current-scope)
               (lambda (&rest _) (kargu-bridge--object "application_id" "new" "session_id" "new")))
              ((symbol-function 'kargu-bridge-session-start)
               (lambda (&rest _) (setq sent t))))
	     (setq task (kargu-loop-native-owned-start
			 nil (kargu-bridge--object)
			 (lambda (_result error-data) (setq delivered error-data))))
	     (should delivered)
	     (should-not sent)
	     (should-not (kargu-async-pending-p task)))))

(ert-deftest kargu-native-loop-real-pipe-acquires-actual-application-scope-test ()
  (kargu-bridge-test--with-core
   (let* ((application (kargu-application-create))
          (arguments (kargu-bridge--object
                      "root" default-directory "mode" "ask"
                      "prompt" (kargu-bridge--object "role" "user" "content" "fixture")
                      "tools_enabled" :json-false "tool_limit" 1 "turn_limit" 1
                      "timeout_ms" 1000 "config_revision" 1 "policy_revision" 1
                      "connection" (kargu-bridge--object
                                    "url" "http://127.0.0.1:1" "model" "fixture"
                                    "headers" (kargu-bridge--object) "stream" :json-false
                                    "timeouts" (kargu-bridge--object "connect_ms" 50
                                                                     "deadline_ms" 100))))
          done result failure)
     (kargu-test-native-owned-start
      application arguments
      (lambda (value fault) (setq result value failure fault done t)))
     (kargu-bridge-test--wait (lambda () done))
     (should-not failure)
     (should (equal (gethash "status" result) "failed"))
     (let ((scope (gethash "scope" result)))
       (should (string-prefix-p "app_" (gethash "application_id" scope)))
       (should (string-prefix-p "run_" (gethash "run_id" scope)))))))

(ert-deftest kargu-native-loop-retired-owner-never-starts-core-test ()
  (let (started failure)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (&rest _) (setq started t))))
	     (kargu-loop-native-owned-start
	      nil (kargu-bridge--object)
	      (lambda (_value fault) (setq failure fault)) :valid-p (lambda () nil))
	     (should failure)
	     (should-not started))))

(ert-deftest kargu-native-loop-full-wire-policy-reaches-native-provider-test ()
  (require 'tests/test-stream)
  (kargu-bridge-test--with-core
   (let* ((application (kargu-application-create))
          headers payload result failure done
          (server (kargu-stream-test--server
                   "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"fixture answer\"},\"finish_reason\":\"stop\"}]}"
                   nil nil (lambda (body) (setq payload body))
                   (lambda (value) (setq headers value))))
          (snapshot (kargu-connection-snapshot--create
                     :provider "openai" :model "frozen-model"
                     :endpoint (format "http://127.0.0.1:%d/v1" (process-contact server :service))
                     :config-revision 2 :capabilities '(:tools nil :stream nil)
                     :settings (list :wire (kargu-provider-format-record :openai))
                     :credential-scope (kargu-credential-scope--create :raw-secret "synthetic-owned-key")))
          (run (kargu-loop--new-run "fixture"))
          (arguments (kargu-loop-native--arguments run snapshot)))
     (unwind-protect
         (progn
           (puthash "prompt" (kargu-bridge--object "role" "user" "content" "fixture") arguments)
           (should (eq (gethash "key" (gethash "auth" (gethash "connection" arguments))) :json-null))
           ;; Only the fixture's committed config carries the key Rust sends.
           (puthash "key" "synthetic-owned-key" (gethash "auth" (gethash "connection" arguments)))
           (kargu-test-native-owned-start
            application arguments
            (lambda (value fault) (setq result value failure fault done t)))
           (kargu-bridge-test--wait (lambda () done))
           (should-not failure)
           (ert-info ((format "Native terminal: %S; body: %S" result payload))
             (should (equal (gethash "status" result) "completed")))
           (should (string-search "POST /v1/chat/completions " headers))
           (should (string-search "authorization: Bearer synthetic-owned-key" headers))
           (should (equal (kargu-aget (kargu--json-decode-safe payload) "model") "frozen-model")))
       (delete-process server)
       (kargu-connection-snapshot-wipe snapshot)))))

(ert-deftest kargu-native-loop-late-acquired-request-is-cancelled-test ()
  (let* ((scope (kargu-bridge--object "application_id" "app-fixture" "session_id" "sess-fixture"))
         (parent (kargu-async-start #'ignore :owner nil :parent nil))
         task issued cancelled)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (funcall callback (kargu-bridge--connection-create :state 'ready :epoch "fixture-epoch") nil) #'ignore))
              ((symbol-function 'kargu-bridge-application-ensure)
               (lambda (_conn _app callback) (funcall callback scope nil) #'ignore))
              ((symbol-function 'kargu-bridge-conversation-ensure)
               (lambda (_connection _application _session scope callback)
                 (funcall callback scope nil) #'ignore))
              ((symbol-function 'kargu-bridge-conversation-current-scope)
               (lambda (application _session connection)
                 (kargu-bridge-application-current-scope application connection)))
              ((symbol-function 'kargu-bridge-application-current-scope)
               (lambda (&rest _) scope))
              ((symbol-function 'kargu-bridge-session-start)
               (lambda (_conn _scope _arguments _callback &rest options)
                 (funcall (plist-get options :on-delta) "first")
                 (setq issued t)
                 "late-id"))
              ((symbol-function 'kargu-bridge-cancel)
               (lambda (_conn id) (setq cancelled id))))
      (setq task (kargu-loop-native-owned-start
                  nil (kargu-bridge--object) #'ignore
                  :parent parent
                  :on-delta (lambda (_text)
                              (kargu-async-cancel (car (kargu-async-task-children parent))))))
      (should issued)
      (should (equal cancelled "late-id"))
      (should-not (kargu-async-pending-p task))
      (kargu-async-cancel parent))))

(ert-deftest kargu-native-loop-explicit-choice-never-falls-back-test ()
  (let ((kargu-loop-native-agent-enabled t))
    (cl-letf (((symbol-function 'kargu-bridge-available-p) (lambda () nil))
              ((symbol-function 'kargu-api-send) (lambda (&rest _) 'custom-send)))
      (should (kargu-loop-native-enabled-p))))
  (let ((kargu-loop-native-agent-enabled nil))
    (should-not (kargu-loop-native-enabled-p))))

(ert-deftest kargu-native-loop-terminal-report-never-borrows-legacy-change-evidence-test ()
  (dolist (status '(:done :stopped :error))
    (let ((run (list :id "native-run" :native-backend t)))
      (cl-letf (((symbol-function 'kargu-edit-changes)
                 (lambda (&rest _) (ert-fail "Native report borrowed legacy edit tables"))))
        (let ((report (kargu-loop--finish-report run status "fixture")))
          (should (eq (plist-get report :change-evidence) :unavailable))
          (should-not (plist-member report :modified-files))
          (should-not (plist-member report :pending-files)))))))

(ert-deftest kargu-native-loop-backend-selection-is-captured-before-startup-test ()
  (with-temp-buffer
    (setq-local kargu-session--context
                (kargu-test-session-with-history :provider "openai" :model "fixture"))
    (let* ((kargu-loop-native-agent-enabled t)
           (run (kargu-loop--new-run "fixture")))
      (setq kargu-loop-native-agent-enabled nil)
      (should (plist-get run :native-backend))
      (should-not (plist-get (kargu-loop--new-run "another") :native-backend))
      (cl-letf (((symbol-function 'kargu-edit-changes)
                 (lambda (&rest _) (ert-fail "Startup failure borrowed legacy edit tables"))))
        (should (eq (plist-get (kargu-loop--finish-report run :error "startup") :change-evidence)
                    :unavailable))))))

(ert-deftest kargu-native-loop-cleanup-never-aborts-or-repairs-legacy-domain-state-test ()
  (dolist (status '(:done :error :stopped))
    (let ((run (list :native-backend t)) calls)
      (cl-letf (((symbol-function 'kargu-history-context)
                 (lambda (&rest _) (ert-fail "Native cleanup acquired legacy history")))
                ((symbol-function 'kargu-loop--cleanup-step)
                 (lambda (function &rest _) (push function calls)))
                ((symbol-function 'kargu-application-set-active-run) #'ignore))
        (kargu-loop--cleanup-run run status)
        (should (memq #'kargu-async-cancel-owner calls))
        (should-not (memq #'kargu-edit-changes calls))
        (should-not (memq #'kargu--validate-history calls))))))

(ert-deftest kargu-native-loop-report-projects-only-the-native-change-dto-test ()
  (let* ((evidence (kargu-bridge--object "revision" 7
                                        "pending_files" 2 "retained_files" 3))
         (run (list :native-backend t :native-change-evidence evidence)))
    (cl-letf (((symbol-function 'kargu-edit-changes)
               (lambda (&rest _) (ert-fail "Native evidence borrowed a legacy table"))))
      (let* ((report (kargu-loop--finish-report run :done "fixture"))
             (projection (plist-get report :change-evidence)))
        (should (= (gethash "revision" projection) 7))
        (should (= (gethash "pending_files" projection) 2))
        (should-not (eq evidence projection))
        (puthash "pending_files" 0 projection)
        (should (= (gethash "pending_files" evidence) 2))))))

(ert-deftest kargu-native-loop-change-counter-ui-never-invents-a-clean-verdict-test ()
  (dolist (pending '(0 2))
    (let (text)
      (cl-letf (((symbol-function 'kargu-chat-insert)
                 (lambda (value &rest _) (setq text (concat text value)))))
        (kargu-chat--render-change-evidence
         (kargu-bridge--object "pending_files" pending "retained_files" 3))
        (should (string-match-p (format "%d pending verification" pending) text))
        (should-not (string-match-p "clean\\|passed\\|verified" text)))))
  (let (text)
    (cl-letf (((symbol-function 'kargu-chat-insert)
               (lambda (value &rest _) (setq text value))))
      (kargu-chat--render-change-evidence :unavailable)
      (should (string-match-p "unconfirmed" text)))))

(provide 'tests/test-native-loop)
;;; test-native-loop.el ends here
