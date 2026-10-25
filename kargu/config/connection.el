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
(declare-function kargu--url-host "kargu/config/key" (url))
(declare-function kargu--resolve-direct-api-key "kargu/config/key" (&optional provider-name))
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

(defun kargu-connection--resolve-secret (task draft timeout)
  "Resolve DRAFT's credential under TASK and TIMEOUT, preserving its endpoint."
  (let* ((provider (kargu-connection-snapshot-provider draft))
         (direct (kargu--resolve-direct-api-key provider))
         (host (kargu--url-host (kargu-connection-snapshot-endpoint draft)))
         (accept (kargu-async-wrap
                  task (lambda (result) (kargu-connection--accept-secret task draft result)))))
    (cond
     ((or direct (kargu-provider-keyless-p provider)) (funcall accept (or direct "")))
     (t
      (let ((child (kargu-async-start
                    (lambda (value error)
                      (funcall accept (or value (kargu-err error :auth-unavailable))))
                    :owner nil :parent task :timeout timeout)))
        (if (functionp kargu-config-credential-adapter)
            (funcall kargu-config-credential-adapter provider host child)
          (kargu-config-worker-resolve provider host child :timeout timeout)))))))

(defun kargu-connection--current-p (draft origin session)
  "Check DRAFT's captured configuration and SESSION in ORIGIN."
  (and (buffer-live-p origin)
       (with-current-buffer origin
         (and (eq session (kargu-session-context))
              (= (kargu-connection-snapshot-config-revision draft) (kargu-config-revision))
              (equal (kargu-connection-snapshot-endpoint draft)
                     (kargu--api-base (kargu-connection-snapshot-provider draft)))))))

(cl-defun kargu-connection-resolve-async
    (provider model &key callback timeout origin capabilities parent owner settings public)
  "Resolve PROVIDER and MODEL into CALLBACK as a captured connection result.
ORIGIN retains session ownership; TIMEOUT bounds credential resolution.
CAPABILITIES and SETTINGS are detached; PARENT and OWNER own preparation.
PUBLIC skips authentication only for an independently verified public endpoint."
  (kargu-contract-assert #'functionp callback)
  (let* ((app (kargu-application-context))
         (origin (or origin (current-buffer)))
         (session (kargu-session-context origin))
         (provider (downcase (string-trim (format "%s" (or provider (kargu--provider-name))))))
         (format (or (kargu-provider-format provider) 'openai))
         (draft (kargu-connection-snapshot--create
                 :provider provider :model (copy-sequence (or model (kargu--model) ""))
                 :endpoint (copy-sequence (kargu--api-base provider))
                 :wire-format (if (keywordp format) format (intern (concat ":" (symbol-name format))))
                 :capabilities (or capabilities (kargu-connection--default-capabilities provider))
                 :settings settings
                 :config-revision (kargu-config-revision)))
         (valid (kargu-application-wrap
                 app (lambda ()
                       (let ((kargu-connection--bound nil))
                         (kargu-connection--current-p draft origin session)))))
         (task (kargu-async-start
                (kargu-application-wrap
                 app (lambda (value error)
                       (funcall callback
                                (cond
                                 ((not (funcall valid)) (kargu-err "Stale connection discarded" :stale-discard))
                                 ((or (kargu-ok-p value) (kargu-err-p value)) value)
                                 (t (kargu-err (or error "Connection resolution failed") :auth-unavailable))))))
                :owner owner :parent parent :buffer origin
                :timeout (or timeout kargu-config-worker-default-timeout) :valid-p valid)))
    (if (kargu-contract-url-p (kargu-connection-snapshot-endpoint draft))
        (funcall (kargu-async-wrap task
                                  (lambda ()
                                    (if public
                                        (kargu-connection--accept-secret task draft (kargu-ok ""))
                                      (kargu-connection--resolve-secret
                                       task draft (or timeout kargu-config-worker-default-timeout))))))
      (kargu-async-finish task (kargu-err "Invalid endpoint URL" :invalid-arguments)))
    task))

(provide 'kargu/config/connection)

;;; connection.el ends here
