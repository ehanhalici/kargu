;;; native.el --- Native Rust agent loop integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Provides optional native Rust agent execution for `kargu-loop':
;; When `kargu-loop-native-agent-enabled' is non-nil and native bridge is
;; available, prompt requests are dispatched directly to the Rust core
;; via `session/prompt', with full tool dispatching, streaming and history
;; managed by the Rust core machine.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/bridge)
(require 'kargu/bridge/session)
(require 'kargu/loop/native-owner)
(require 'kargu/api/request)
(require 'kargu/api/retry)
(require 'kargu/api/transport)
(require 'kargu/application/execution)
(require 'kargu/application/budget)
(require 'kargu/core/session)
(require 'kargu/core/custom)
(require 'kargu/core/log)

(defcustom kargu-loop-native-agent-enabled nil
  "Use the native Rust agent loop when non-nil.
Startup errors are reported without switching to the Elisp backend."
  :type 'boolean
  :group 'kargu)

(defun kargu-loop-native-enabled-p ()
  "Return the explicit native backend choice, including when core is missing."
  kargu-loop-native-agent-enabled)

(declare-function kargu--loop-finish "kargu/loop" (run status &optional text))
(declare-function kargu-loop--live-p "kargu/loop" (run))
(declare-function kargu-loop--set-state "kargu/loop" (run state))
(declare-function kargu-state-mode "kargu/state/selectors" ())
(declare-function kargu-model-supports-tools-p "kargu/api/catalog" (&optional model-id provider))
(declare-function kargu--provider-name "kargu/config/key" ())
(declare-function kargu--model "kargu/config/key" ())
(declare-function kargu--api-base "kargu/config/key" (&optional provider))

(defun kargu-loop-native--editor-tools ()
  "List of editor tools allowlisted for native agent reverse dispatch.
Exactly the tools `kargu-bridge-sensor-call-tool' and the native edit
port serve; debugger tools have no reverse handler and stay unlisted."
  (vector "read_file_symbols"
          "read_symbol"
          "lsp_diagnostics"
          "lsp_find_symbol"
          "lsp_project_skeleton"
          "edit_file"
          "write_file"
          "apply_patch"
          "edit_by_lsp"))

(defun kargu-loop-native--refusal-text (failure)
  "Describe native admission FAILURE from its payload-free status."
  (let* ((data (and (hash-table-p failure) (gethash "data" failure)))
         (status (and (hash-table-p data) (gethash "status" data))))
    (pcase status
      ("stale_configuration" "Configuration changed since the run was prepared; send again")
      ("configuration_unavailable"
       "Native run target or credential source is unavailable for this configuration")
      ("busy" "Another native run is still active or draining")
      (_ "Native agent request failed"))))

(defun kargu-loop-native--finish (run result failure)
  "Project native RESULT or FAILURE into the still-owned RUN's terminal state."
  (when (kargu-loop--live-p run)
    (plist-put run :native-backend t)
    (let* ((status (and (hash-table-p result) (gethash "status" result)))
           (accounting (and (hash-table-p result) (gethash "accounting" result)))
           (budget (and (hash-table-p accounting) (gethash "budget" accounting)))
           (changes (and (hash-table-p accounting) (gethash "changes" accounting)))
           (spent (and (hash-table-p budget) (gethash "requests_spent" budget)))
           (compactions (and (hash-table-p budget) (gethash "compactions_spent" budget)))
           (healing (and (hash-table-p accounting) (gethash "healing_rounds" accounting)))
           (verifications (and (hash-table-p changes) (gethash "verified_files" changes))))
      (plist-put run :native-change-evidence changes)
      (when (and (integerp spent) (>= spent 0))
        (plist-put run :iterations spent))
      (when (and (integerp compactions) (>= compactions 0))
        (plist-put run :compactions compactions))
      (when (and (integerp healing) (>= healing 0))
        (plist-put run :healing healing))
      (when (and (integerp verifications) (>= verifications 0))
        (plist-put run :verifications verifications))
      (when (and (hash-table-p budget) (plist-get run :session))
        (kargu-session-project-budget budget (plist-get run :session)))
      (when (and (hash-table-p budget) (kargu-run-budget-p (plist-get run :budget)))
        (kargu-budget-project (plist-get run :budget) budget))
      (cond
       (failure (kargu--loop-finish run :error (kargu-loop-native--refusal-text failure)))
       ((and (equal status "completed") (stringp (gethash "answer_text" result)))
        (kargu--loop-finish run :done (gethash "answer_text" result)))
       ((equal status "cancelled") (kargu--loop-finish run :stopped "Native agent cancelled"))
       ((equal status "timeout") (kargu--loop-finish run :error "Native agent timed out"))
       ((equal status "rejected") (kargu--loop-finish run :error "Native agent rejected the request"))
       ((equal status "stale_configuration")
        (kargu--loop-finish run :error "Configuration changed while the native run was preparing; send again"))
       ((equal status "credential_unavailable")
        (kargu--loop-finish run :error "No credential was available for the native run (auth-source or callable returned no key)"))
       (t (kargu--loop-finish run :error "Native agent did not complete successfully"))))))

(defun kargu-loop-native--arguments (run snapshot)
  "Detach RUN's request policy from its prepared connection SNAPSHOT."
  (unless (kargu-connection-snapshot-p snapshot)
    (error "Native agent requires a prepared connection"))
  (kargu-connection-call
   snapshot
   (lambda ()
     (let* ((provider (kargu-connection-snapshot-provider snapshot))
            (capabilities (kargu-connection-snapshot-capabilities snapshot))
            (settings (kargu-connection-snapshot-settings snapshot))
            (wire (kargu-providers-wire-object (plist-get settings :wire)))
            (tuning (if (plist-get settings :tuning)
                        (kargu-providers-wire-object (plist-get settings :tuning))
                      (kargu-bridge--object)))
            ;; Rust takes direct keys from committed policy and interop keys
            ;; from its own receipt; the editor never sends one.
            (auth (kargu-api-auth-intent nil provider))
            (budget-obj (plist-get run :budget))
            (req-limit (if (kargu-run-budget-p budget-obj)
                           (kargu-run-budget-max-requests budget-obj)
                         (or (plist-get run :request-budget) kargu-budget-default-max-requests)))
            (compactions-limit (if (kargu-run-budget-p budget-obj)
                                   (kargu-run-budget-max-compactions budget-obj)
                                 kargu-budget-default-max-compactions))
            (timeout-secs (or (plist-get run :timeout)
                              (and (kargu-run-budget-p budget-obj)
                                   (kargu-run-budget-deadline budget-obj)
                                   (max 1 (round (- (kargu-run-budget-deadline budget-obj) (float-time)))))
                              (if kargu-stream kargu-api-stream-ceiling kargu-api-timeout)
                              90))
            (timeout-ms (kargu-transport-milliseconds timeout-secs))
            (turn-limit (or (plist-get run :max-iterations) kargu-max-iterations 12))
            (observer (or (plist-get run :retry-observer) "none")))
       (setcdr (assoc "session" auth) (plist-get run :session-id))
       ;; These metadata assertions are owned by the native publication.
       (remhash "supported_parameters" tuning)
       (remhash "provider_policy" tuning)
       (kargu-bridge--object
        "root" (copy-sequence (plist-get run :project-root))
        "mode" (symbol-name (plist-get run :mode))
        "prompt" :json-null
        "tools_enabled" (if (plist-get capabilities :tools) t :json-false)
        "editor_available" (kargu-loop-native--editor-tools)
        "turn_limit" turn-limit
        "timeout_ms" timeout-ms
        "model_revision" (or (plist-get settings :metadata-revision) 0)
        "config_revision" (kargu-connection-snapshot-config-revision snapshot)
        "policy_revision" (kargu-tool-registry-revision kargu--tool-registry)
        "budget" (kargu-bridge--object "requests" req-limit
                                      "compactions" compactions-limit)
        "connection"
        (kargu-bridge--object
         "url" (kargu-connection-snapshot-endpoint snapshot)
         "model" (kargu-connection-snapshot-model snapshot)
         "provider" provider "headers" (kargu-bridge--object)
         "wire" (kargu-bridge--object "default-headers"
                                      (if (hash-table-p wire)
                                          (or (gethash "default-headers" wire) (kargu-bridge--object))
                                        (kargu-bridge--object)))
         "tuning" tuning
         "auth" (kargu-providers-wire-object auth)
         "stream" (if kargu-stream t :json-false)
         "timeouts" (kargu-bridge--object
                     "connect_ms" (kargu-transport-milliseconds kargu-api-connect-timeout)
                     "first_byte_ms" (kargu-transport-milliseconds kargu-api-first-byte-timeout)
                     "idle_ms" (kargu-transport-milliseconds kargu-api-stall-timeout)
                     "deadline_ms" timeout-ms))
        "retry" (kargu-bridge--object
                 "observer" observer
                 "policy" (kargu-providers-wire-object (kargu-api-retry-preferences))))))))

(defun kargu-loop-native--run-arguments (run snapshot)
  "Return RUN's native arguments; a stated tool limit is RUN's user choice.
Without one the core's default tool-call limit applies."
  (let ((arguments (kargu-loop-native--arguments run snapshot)))
    (when-let* ((limit (plist-get run :tool-limit)))
      (puthash "tool_limit" limit arguments))
    arguments))

(defun kargu-loop-native-start (run prompt)
  "Execute RUN for PROMPT through its captured native application lease."
  (plist-put run :native-backend t)
  (let* ((context (plist-get run :context))
         (snapshot (plist-get run :connection-snapshot)))
    (unless (and (kargu-execution-p context) (kargu-loop--live-p run))
      (error "Native agent requires a live execution context"))
    (let ((arguments (kargu-loop-native--run-arguments run snapshot))
          (on-delta (plist-get run :on-delta)))
      (puthash "prompt" (kargu-bridge--object "role" "user" "content" prompt) arguments)
      (let ((task
             (kargu-loop-native-owned-start
              (kargu-execution-app context) arguments
              (kargu-execution-wrap
               context (lambda (result failure)
                         (kargu-loop-native--finish run result failure)))
              :parent (kargu-execution-task context)
              :owner (plist-get run :chat-buffer)
              :session (plist-get run :session)
              :valid-p (lambda () (kargu-loop--live-p run))
              :on-delta (kargu-execution-wrap
                         context (lambda (chunk)
                                   (when (and on-delta (stringp chunk))
                                     (kargu-execution-deliver-delta on-delta chunk))))
              :on-event (kargu-execution-wrap context (lambda (method event)
                          (when (and (equal method "session/state")
                                     (hash-table-p event)
                                     (equal (gethash "phase" event) "summary"))
                            (kargu-loop--set-state run 'compact))
                          (when (equal method "session/accounting")
                            (let* ((budget (and (hash-table-p event) (gethash "budget" event)))
                                   (spent (and (hash-table-p budget) (gethash "requests_spent" budget)))
                                   (compactions (and (hash-table-p budget) (gethash "compactions_spent" budget))))
                              (when (and (integerp spent) (>= spent 0))
                                (plist-put run :iterations spent))
                              (when (and (integerp compactions) (>= compactions 0))
                                (plist-put run :compactions compactions))
                              (when (and (hash-table-p budget) (plist-get run :session))
                                (kargu-session-project-budget budget (plist-get run :session)))
                              (when (and (hash-table-p budget) (kargu-run-budget-p (plist-get run :budget)))
                                (kargu-budget-project (plist-get run :budget) budget)))))))))
        (plist-put run :abort-fn (lambda () (kargu-async-cancel task)))
        task))))

(provide 'kargu/loop/native)
;;; native.el ends here
