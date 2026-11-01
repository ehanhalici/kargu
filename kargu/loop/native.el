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
(require 'kargu/core/log)

(defcustom kargu-loop-native-agent-enabled nil
  "Use the native Rust agent loop when non-nil.
Startup errors are reported without switching to the Elisp backend."
  :type 'boolean
  :group 'kargu)

(defun kargu-loop-native-enabled-p ()
  "Return the explicit native backend choice, including when core is missing."
  kargu-loop-native-agent-enabled)

(defun kargu-loop--deliver-delta (callback text &optional thought)
  "Deliver TEXT to CALLBACK once, optionally identifying a THOUGHT."
  (condition-case err
      (save-match-data
        (if (and thought (not (equal (cdr (func-arity callback)) 1)))
            (funcall callback text 'thought)
          (funcall callback text)))
    (error (kargu-log 'warn "Stream listener failed: %s"
                       (error-message-string err)))))

(declare-function kargu--loop-finish "kargu/loop" (run status &optional text))
(declare-function kargu-loop--live-p "kargu/loop" (run))
(declare-function kargu-loop--set-state "kargu/loop" (run state))
(declare-function kargu-state-mode "kargu/state/mode" ())
(declare-function kargu-model-supports-tools-p "kargu/api/catalog" ())
(declare-function kargu--provider-name "kargu/config/key" ())
(declare-function kargu--model "kargu/config/key" ())
(declare-function kargu--api-base "kargu/config/key" ())
(declare-function kargu--api-key "kargu/config/key" ())
(defun kargu-loop-native--editor-tools ()
  "List of editor tools allowlisted for native agent reverse dispatch."
  (vector "read_file_symbols"
          "read_symbol"
          "edit_file"
          "write_file"
          "apply_patch"
          "edit_by_lsp"))

(defun kargu-loop-native--finish (run result failure)
  "Project native RESULT or FAILURE into the still-owned RUN's terminal state."
  (when (kargu-loop--live-p run)
    (let* ((status (and (hash-table-p result) (gethash "status" result)))
           (accounting (and (hash-table-p result) (gethash "accounting" result)))
           (budget (and (hash-table-p accounting) (gethash "budget" accounting)))
           (spent (and (hash-table-p budget) (gethash "requests_spent" budget))))
      (when (and (integerp spent) (>= spent 0))
        (plist-put run :iterations spent))
      (cond
       (failure (kargu--loop-finish run :error "Native agent request failed"))
       ((and (equal status "completed") (stringp (gethash "answer_text" result)))
        (kargu--loop-finish run :done (gethash "answer_text" result)))
       ((equal status "cancelled") (kargu--loop-finish run :stopped "Native agent cancelled"))
       ((equal status "timeout") (kargu--loop-finish run :error "Native agent timed out"))
       ((equal status "rejected") (kargu--loop-finish run :error "Native agent rejected the request"))
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
            (auth (kargu-api-auth-intent
                   (kargu-connection-snapshot-secret snapshot) provider)))
       (setcdr (assoc "session" auth) (plist-get run :session-id))
       (kargu-bridge--object
        "root" (copy-sequence (plist-get run :project-root))
        "mode" (symbol-name (plist-get run :mode))
        "prompt" :json-null
        "tools_enabled" (if (plist-get capabilities :tools) t :json-false)
        "editor_available" (kargu-loop-native--editor-tools)
        "tool_limit" 16 "turn_limit" (plist-get run :max-iterations)
        "timeout_ms" 120000
        "config_revision" (kargu-connection-snapshot-config-revision snapshot)
        "policy_revision" (kargu-tool-registry-revision kargu--tool-registry)
        "budget" (kargu-bridge--object "requests" 16)
        "connection"
        (kargu-bridge--object
         "url" (kargu-connection-snapshot-endpoint snapshot)
         "model" (kargu-connection-snapshot-model snapshot)
         "provider" provider "headers" (kargu-bridge--object)
         "wire" (kargu-providers-wire-object (plist-get settings :wire))
         "tuning" (if-let* ((tuning (plist-get settings :tuning)))
                      (kargu-providers-wire-object tuning)
                    (kargu-bridge--object))
         "auth" (kargu-providers-wire-object auth)
         "cache_markers" (if (plist-get settings :cache-marker) t :json-false)
         "stream" (if (and kargu-stream (plist-get capabilities :stream)) t :json-false)
         "timeouts" (kargu-bridge--object
                     "connect_ms" (kargu-transport--milliseconds kargu-api-connect-timeout)
                     "first_byte_ms" (kargu-transport--milliseconds kargu-api-first-byte-timeout)
                     "idle_ms" (kargu-transport--milliseconds kargu-api-stall-timeout)
                     "deadline_ms" 120000))
        "retry" (kargu-bridge--object
                 "observer" "none"
                 "policy" (kargu-providers-wire-object (kargu-api-retry-preferences))))))))

(defun kargu-loop-native-start (run prompt)
  "Execute RUN for PROMPT through its captured native application lease."
  (let* ((context (plist-get run :context))
         (snapshot (plist-get run :connection-snapshot)))
    (unless (and (kargu-execution-p context) (kargu-loop--live-p run))
      (error "Native agent requires a live execution context"))
    (let ((arguments (kargu-loop-native--arguments run snapshot))
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
                                     (kargu-loop--deliver-delta on-delta chunk))))
              :on-event (kargu-execution-wrap context (lambda (method event)
                          (when (equal method "session/accounting")
                            (let* ((budget (and (hash-table-p event) (gethash "budget" event)))
                                   (spent (and (hash-table-p budget) (gethash "requests_spent" budget))))
                              (when (and (integerp spent) (>= spent 0))
                                (plist-put run :iterations spent)))))))))
        (plist-put run :abort-fn (lambda () (kargu-async-cancel task)))
        task))))

(provide 'kargu/loop/native)
;;; native.el ends here
