;;; connection.el --- Immutable connection snapshot and lifecycle -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Immutable connection snapshot binding provider, model, endpoint, capability,
;; config revision, and credential scope (Contract 4, CONFIG-01, DEEP-14).
;;
;; Read-only slots capture one target; consumers must not mutate borrowed
;; nested values.  Ordinary printed records and summaries omit credential
;; contents.  Wiping clears this scope's private string, not all copies that
;; a transport, debugger or garbage collector may retain.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/contract/assert)
(require 'kargu/contract/types)
(require 'kargu/contract/result)
(require 'kargu/async)
(require 'kargu/core/log)
(require 'kargu/config/schema)
(require 'kargu/config/worker)

(defvar kargu-config-credential-adapter)

(defvar kargu-connection--bound nil
  "Dynamically captured connection, never a retained default connection.")

(defun kargu-connection-current ()
  "Return the explicitly bound connection, or nil outside a request boundary."
  kargu-connection--bound)

(defun kargu-connection-call (snapshot function &rest args)
  "Call FUNCTION with ARGS inside the captured connection SNAPSHOT."
  (let ((kargu-connection--bound snapshot)) (apply function args)))

(declare-function kargu--provider-name "kargu/config/key" ())
(declare-function kargu--model "kargu/config/key" ())
(declare-function kargu--api-base "kargu/config/key" (&optional provider-name))
(declare-function kargu-provider-format "kargu/providers/registry" (id))
(declare-function kargu-provider-format-stream-p "kargu/providers/registry" (format))
(declare-function kargu-provider-effort-specs "kargu/providers/registry" (id))
(declare-function kargu-provider-wire "kargu/providers/registry" (id))
(declare-function kargu-provider-keyless-p "kargu/providers/registry" (id))
(declare-function kargu-session-context "kargu/core/session" (&optional buffer))

(defun kargu-random-uuid ()
  "Generate a pseudo-random UUID string."
  (format "%08x-%04x-%04x-%04x-%012x"
          (random #xffffffff)
          (random #xffff)
          (logior #x4000 (logand (random #xffff) #x0fff))
          (logior #x8000 (logand (random #xffff) #x3fff))
          (random #xffffffffffff)))

;;;; Credential Scope --------------------------------------------------------

(cl-defstruct (kargu-credential-scope (:constructor kargu-credential-scope--make))
  "Opaque container holding a resolved secret with zeroing capability."
  (id (format "cred-%s" (kargu-random-uuid)) :read-only t)
  (secret-cell nil :read-only t)
  (wiped-p nil)
  (created-at (float-time) :read-only t))

(cl-defun kargu-credential-scope--create (&key raw-secret)
  "Own a private copy of RAW-SECRET behind an uninterned capability.
Ordinary printed scope/snapshot records never include the secret value."
  (kargu-contract-assert #'stringp raw-secret)
  (let ((cell (make-symbol "kargu-credential")))
    (put cell 'value (copy-sequence raw-secret))
    (kargu-credential-scope--make :secret-cell cell)))

(defun kargu-credential-scope-secret (scope)
  "Return secret held by SCOPE, or nil if wiped or invalid."
  (when (and (kargu-credential-scope-p scope)
             (not (kargu-credential-scope-wiped-p scope)))
    (copy-sequence (get (kargu-credential-scope-secret-cell scope) 'value))))

(defun kargu-credential-scope-wipe (scope)
  "Zero out and invalidate secret held in SCOPE."
  (when (and (kargu-credential-scope-p scope)
             (not (kargu-credential-scope-wiped-p scope)))
    (let* ((cell (kargu-credential-scope-secret-cell scope))
           (sec (get cell 'value)))
      (when (stringp sec)
        (clear-string sec))
      (setplist cell nil))
    (setf (kargu-credential-scope-wiped-p scope) t)
    t))

;;;; Connection Snapshot -----------------------------------------------------

(cl-defstruct (kargu-connection-snapshot (:constructor kargu-connection--make))
  "Immutable verified snapshot of provider connection target and credentials."
  (id (format "conn-%s" (kargu-random-uuid)) :read-only t)
  (provider-value nil :read-only t)
  (model-value nil :read-only t)
  (endpoint-value nil :read-only t)
  (wire-format :openai :read-only t)
  (capability-data nil :read-only t)
  (settings-cell nil :read-only t)
  (config-revision 0 :read-only t)
  (credential-scope nil :read-only t)
  (created-at (float-time) :read-only t))

(cl-defun kargu-connection-snapshot--create
    (&key provider model endpoint (wire-format :openai) capabilities settings
          (config-revision 0) credential-scope)
  "Capture PROVIDER, MODEL, ENDPOINT, WIRE-FORMAT and CAPABILITIES.
SETTINGS and CONFIG-REVISION freeze policy; CREDENTIAL-SCOPE owns the secret."
  (let ((cell (make-symbol "kargu-connection-settings")))
    (put cell 'value (kargu-config-copy settings))
    (kargu-connection--make
     :provider-value (kargu-config-copy provider) :model-value (kargu-config-copy model)
     :endpoint-value (kargu-config-copy endpoint) :wire-format wire-format
     :capability-data (kargu-config-copy capabilities) :settings-cell cell
     :config-revision config-revision :credential-scope credential-scope)))

(defun kargu-connection-snapshot-settings (snapshot)
  "Return detached settings from SNAPSHOT, keeping custom headers opaque."
  (kargu-config-copy (get (kargu-connection-snapshot-settings-cell snapshot) 'value)))

(defun kargu-connection-snapshot-provider (snapshot)
  "Return a detached provider identifier from SNAPSHOT."
  (kargu-config-copy (kargu-connection-snapshot-provider-value snapshot)))

(defun kargu-connection-snapshot-model (snapshot)
  "Return a detached model identifier from SNAPSHOT."
  (kargu-config-copy (kargu-connection-snapshot-model-value snapshot)))

(defun kargu-connection-snapshot-endpoint (snapshot)
  "Return a detached endpoint from SNAPSHOT."
  (kargu-config-copy (kargu-connection-snapshot-endpoint-value snapshot)))

(defun kargu-connection-snapshot-capabilities (snapshot)
  "Return detached model capabilities from SNAPSHOT."
  (kargu-config-copy (kargu-connection-snapshot-capability-data snapshot)))

(defun kargu-connection-setting (name &optional snapshot)
  "Read captured setting NAME from SNAPSHOT or the current connection.
The result is borrowed read-only data for trusted internal consumers."
  (when-let* ((snapshot (or snapshot (kargu-connection-current))))
    (plist-get (get (kargu-connection-snapshot-settings-cell snapshot) 'value) name)))

(defun kargu-connection-matches-p (model provider)
  "Return non-nil when optional MODEL and PROVIDER name the bound connection."
  (when-let* ((snapshot (kargu-connection-current)))
    (and (or (null model) (equal model (kargu-connection-snapshot-model-value snapshot)))
         (or (null provider) (equal provider (kargu-connection-snapshot-provider-value snapshot))))))

(defun kargu-connection-snapshot-secret (snapshot)
  "Extract resolved secret from SNAPSHOT's credential scope, or nil if wiped."
  (when (and (kargu-connection-snapshot-p snapshot)
             (kargu-connection-snapshot-credential-scope snapshot))
    (kargu-credential-scope-secret
     (kargu-connection-snapshot-credential-scope snapshot))))

(defun kargu-connection-snapshot-wipe (snapshot)
  "Wipe the credential scope in SNAPSHOT."
  (when (and (kargu-connection-snapshot-p snapshot)
             (kargu-connection-snapshot-credential-scope snapshot))
    (kargu-credential-scope-wipe
     (kargu-connection-snapshot-credential-scope snapshot))))

(defun kargu-connection-redacted-summary (snapshot)
  "Return safe plist representation of SNAPSHOT for logging without secrets."
  (unless (kargu-connection-snapshot-p snapshot)
    (error "Expected kargu-connection-snapshot, got: %S" snapshot))
  (list :id (kargu-connection-snapshot-id snapshot)
        :provider (kargu-connection-snapshot-provider snapshot)
        :model (kargu-connection-snapshot-model snapshot)
        :endpoint (kargu-connection-snapshot-endpoint snapshot)
        :wire-format (kargu-connection-snapshot-wire-format snapshot)
        :capabilities (kargu-connection-snapshot-capabilities snapshot)
        :config-revision (kargu-connection-snapshot-config-revision snapshot)
        :created-at (kargu-connection-snapshot-created-at snapshot)))

(defun kargu-connection--default-capabilities (provider)
  "Derive default capabilities plist for PROVIDER."
  (let ((wire (and (fboundp 'kargu-provider-wire) (kargu-provider-wire provider)))
        (format (and (fboundp 'kargu-provider-format) (kargu-provider-format provider))))
    (list :tools (not (null wire))
          :stream (if (fboundp 'kargu-provider-format-stream-p)
                      (kargu-provider-format-stream-p format)
                    t)
          :reasoning (not (null (and (fboundp 'kargu-provider-effort-specs)
                                     (kargu-provider-effort-specs provider)))))))

;;;; Asynchronous Snapshot Resolution ----------------------------------------

(defun kargu-connection--with-secret (draft secret)
  "Build a credential-owning copy of DRAFT using private SECRET storage."
  (kargu-connection-snapshot--create
   :provider (kargu-connection-snapshot-provider draft)
   :model (kargu-connection-snapshot-model draft)
   :endpoint (kargu-connection-snapshot-endpoint draft)
   :wire-format (kargu-connection-snapshot-wire-format draft)
   :capabilities (kargu-connection-snapshot-capabilities draft)
   :settings (kargu-connection-snapshot-settings draft)
   :config-revision (kargu-connection-snapshot-config-revision draft)
   :credential-scope (kargu-credential-scope--create :raw-secret secret)))

(defun kargu-connection--accept-secret (task draft result)
  "Validate RESULT once and finish TASK with a credential-owning DRAFT."
  (let ((secret (if (kargu-ok-p result) (kargu-result-value result) result)))
    (cond
     ((kargu-err-p result) (kargu-async-finish task result))
     ((stringp secret)
      (kargu-async-finish task (kargu-ok (kargu-connection--with-secret draft secret))))
     (t (kargu-async-finish
         task (kargu-err "Credential adapter returned an invalid result" :auth-unavailable))))))

(defun kargu-connection--sources-current-p (captured names)
  "Compare raw source CAPTURED against current editor inputs for NAMES.
Explicit session intent is frozen by the request; callers own selection guards."
  (condition-case nil
      (let ((current (kargu-bridge-config-context names)))
        (dolist (field '("selected_provider" "selected_model"))
          (puthash field (gethash field captured) current))
        (kargu-config-json-equal captured current))
    (error nil)))

(defun kargu-connection--start-interop (provider host child timeout)
  "Start CHILD's editor credential interop for PROVIDER/HOST under TIMEOUT."
  (if (functionp kargu-config-credential-adapter)
      (funcall kargu-config-credential-adapter provider host child)
    (kargu-config-worker-resolve provider host child :timeout timeout)))

(cl-defun kargu-connection-resolve-async
    (provider model &key callback timeout origin capabilities parent owner settings public expected-endpoint)
  "Resolve PROVIDER/MODEL natively into CALLBACK under PARENT and OWNER.
ORIGIN captures session ownership; TIMEOUT bounds native policy and interop.
CAPABILITIES/SETTINGS are captured DTOs.  PUBLIC is a verified catalog flag.
EXPECTED-ENDPOINT pins a previously verified catalog base before any lookup."
  (kargu-contract-assert #'functionp callback)
  (let* ((app (kargu-application-context))
         (timeout (if (and (numberp timeout) (> timeout 0))
                      (min timeout kargu-config-worker-default-timeout)
                    kargu-config-worker-default-timeout))
         (origin (or origin (current-buffer)))
         (session (kargu-session-context origin))
         (private (make-symbol "kargu-connection-policy"))
         (inputs (kargu-bridge-config-policy--inputs))
         draft revision names task pending-secret)
    (cl-labels
        ((valid ()
           (and (buffer-live-p origin)
                (with-current-buffer origin (eq session (kargu-session-context)))
                (or (null revision)
                    (and (= revision (kargu-config-revision))
                         (kargu-connection--sources-current-p (get private 'value) names)))))
         (finish (value error-data)
           (unwind-protect
               (funcall callback
                        (cond
                         ((not (valid)) (kargu-err "Stale connection discarded" :stale-discard))
                         ((or (kargu-ok-p value) (kargu-err-p value)) value)
                         (t (kargu-err (or error-data "Native connection resolution failed") :auth-unavailable))))
             (kargu-bridge-config-policy--release-inputs private)))
         (validated (value failure)
           (if (or failure (not (hash-table-p value))
                   (not (equal (gethash "endpoint" value) (kargu-connection-snapshot-endpoint draft))))
               (kargu-async-finish task (kargu-err "Native configuration changed during credential lookup" :stale-discard))
             (kargu-connection--accept-secret task draft
                                              (kargu-ok (kargu-credential-scope-secret pending-secret)))))
         (accept (result)
           (cond
            ((kargu-err-p result) (kargu-async-finish task result))
            ((not (and (kargu-ok-p result) (stringp (kargu-result-value result))))
             (kargu-async-finish task (kargu-err "Invalid credential interop result" :auth-unavailable)))
            (t
             (setq pending-secret (kargu-credential-scope--create :raw-secret (kargu-result-value result)))
             (kargu-async-add-cleanup task (lambda () (kargu-credential-scope-wipe pending-secret)))
             ;; Recheck the native head after the external credential yield.
             (kargu-bridge-config-resolve
              (kargu-connection-snapshot-provider draft) (kargu-connection-snapshot-model draft)
              (kargu-async-wrap task #'validated)
              :parent task :application app :revision revision :context (get private 'value)))))
         (resolved (value failure)
           (if (or failure (not (hash-table-p value))
                   (and expected-endpoint (not (equal expected-endpoint (gethash "endpoint" value)))))
               (kargu-async-finish task (kargu-err "Native connection policy unavailable"
                                                   (if (and failure (equal (gethash "code" failure) -32602))
                                                       :invalid-arguments :config-unavailable)))
             (let* ((name (gethash "provider" value))
                    (chosen (gethash "model" value))
                    (format (or (kargu-provider-format name) 'openai))
                    (credential (gethash "credential" value)))
               (unless (and (stringp name) (stringp (gethash "endpoint" value))
                            (equal revision (gethash "revision" value)) (hash-table-p credential)
                            (or (stringp chosen) (eq chosen :json-null)))
                 (error "Invalid native connection projection"))
               (setq draft (kargu-connection-snapshot--create
                            :provider name :model (if (stringp chosen) chosen "")
                            :endpoint (gethash "endpoint" value)
                            :wire-format (if (keywordp format) format (intern (concat ":" (symbol-name format))))
                            :capabilities (or capabilities (kargu-connection--default-capabilities name))
                            :settings settings :config-revision revision))
               (cond
                (public (kargu-connection--accept-secret task draft (kargu-ok "")))
                ((equal (gethash "kind" credential) "direct")
                 (kargu-connection--accept-secret task draft (kargu-ok (gethash "secret" credential))))
                ((equal (gethash "kind" credential) "keyless")
                 (kargu-connection--accept-secret task draft (kargu-ok "")))
                ((equal (gethash "kind" credential) "interop")
                 (let ((child (kargu-async-start
                               (kargu-application-wrap app
						       (lambda (result error-data)
							 (funcall (kargu-async-wrap task #'accept)
								  (or result (kargu-err error-data :auth-unavailable)))))
                               :parent task :owner nil)))
                   (kargu-connection--start-interop name (gethash "host" value) child
                                                    (or timeout kargu-config-worker-default-timeout))))
                (t (kargu-async-finish task (kargu-err "Invalid native credential policy" :auth-unavailable)))))))
         (configured (result)
           (if (kargu-err-p result) (kargu-async-finish task result)
             (setq names (gethash "environment_names" (kargu-config-native-view)))
             (put private 'value (kargu-bridge-config-policy--captured-context inputs names))
             (kargu-bridge-config-policy--release-inputs inputs)
             (setq revision (kargu-config-revision))
             (kargu-bridge-config-resolve provider model (kargu-async-wrap task #'resolved)
                                          :parent task :application app :revision revision :context (get private 'value)))))
      (setq task (kargu-async-start (kargu-application-wrap app #'finish)
                                    :owner owner :parent parent :buffer origin :valid-p (kargu-application-wrap app #'valid)
                                    :timeout (or timeout kargu-config-worker-default-timeout)))
      (kargu-async-add-cleanup task (lambda () (kargu-bridge-config-policy--release-inputs inputs)))
      (kargu-async-add-cleanup task (lambda ()
                                      (when (eq (kargu-async-task-state task) :cancelled)
					(kargu-bridge-config-policy--release-inputs private))))
      (cond
       ((not (kargu-async-pending-p task)) (kargu-async-cancel task))
       ((<= (kargu-async-task-deadline task) (float-time))
        (kargu-async-finish task (kargu-err "Connection deadline elapsed" :deadline)))
       (t (kargu-config-ensure-native-async (kargu-async-wrap task #'configured) :parent task))))
    task))

(provide 'kargu/config/connection)
;;; connection.el ends here
