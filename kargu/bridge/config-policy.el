;;; config-policy.el --- Owned native configuration publication port -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Capture editor inputs and requested environment values without choosing their
;; precedence.  Only the native application actor stages and commits config.

;;; Code:

(require 'kargu/async)
(require 'kargu/bridge/application)
(require 'kargu/providers/registry)
(require 'kargu/providers/projection)

(declare-function kargu-config-copy "kargu/config/service" (value))
(declare-function kargu-selection-provider "kargu/selection" (&optional session))
(declare-function kargu-selection-model "kargu/selection" (&optional session))
(declare-function kargu-config-revision "kargu/config/schema" ())
(declare-function kargu-config-native-view "kargu/config/service" ())

(defun kargu-bridge-config-policy--inputs ()
  "Freeze bounded editor inputs behind a non-printing, private capability.
Environment names are interpreted only by Rust; unrelated values stay local."
  (let ((cell (make-symbol "kargu-config-inputs")) (bytes 0) (count 0) environment)
    (dolist (entry process-environment)
      (unless (stringp entry) (error "Invalid editor environment capture"))
      (setq count (1+ count))
      (setq bytes (+ bytes (string-bytes entry)))
      (when (or (> count 16384) (> bytes (* 2 1024 1024)))
        (error "Editor environment exceeds capture limit"))
      (push (copy-sequence entry) environment))
    (put cell 'environment (nreverse environment))
    (put cell 'registry (kargu-bridge-config-policy--registry t))
    (put cell 'options (kargu-bridge-config-policy--options t))
    cell))

(defun kargu-bridge-config-policy--wipe (value)
  "Clear private, exclusively owned VALUE strings and nested containers."
  (cond ((stringp value) (clear-string value))
        ((consp value) (kargu-bridge-config-policy--wipe (car value)) (kargu-bridge-config-policy--wipe (cdr value)))
        ((vectorp value) (mapc #'kargu-bridge-config-policy--wipe value))
        ((hash-table-p value) (maphash (lambda (_key item) (kargu-bridge-config-policy--wipe item)) value))))

(defun kargu-bridge-config-policy--release-inputs (cell)
  "Release and clear CELL's private captures, idempotently."
  (kargu-bridge-config-policy--wipe (symbol-plist cell))
  (setplist cell nil))

(defun kargu-bridge-config-policy--captured-context (cell names &optional publication)
  "Project native-requested NAMES from immutable editor input CELL.
PUBLICATION includes header metadata; transient credential source DTOs do not."
  (let ((process-environment (get cell 'environment))
        (registry (kargu-config-copy (get cell 'registry)))
        (options (kargu-config-copy (get cell 'options))))
    (unless publication
      (remhash "app_url" options)
      (mapc (lambda (entry) (remhash "headers" entry) (remhash "wire_headers" entry)) registry))
    (kargu-bridge-config-policy--context registry names options)))

(defun kargu-bridge-config-policy--options (&optional publication)
  "Capture raw editor options and selection, without choosing any fallback.
PUBLICATION includes the application URL metadata for native header bindings."
  (let ((options (kargu-bridge--object
                  "api_base" (or (kargu-config-copy kargu-api-base) :json-null)
                  "api_key" (or (kargu-config-copy kargu-api-key) :json-null)
                  "selected_provider" (or (kargu-config-copy (kargu-selection-provider)) :json-null)
                  "selected_model" (or (kargu-config-copy (kargu-selection-model)) :json-null))))
    (when publication (puthash "app_url" (kargu-config-copy kargu-app-url) options))
    options))

(defun kargu-bridge-config-context (&optional names options)
  "Capture native-requested environment NAMES and raw editor OPTIONS.
When omitted, use the last committed native view and current editor options."
  (kargu-bridge-config-policy--context
   (kargu-bridge-config-policy--registry)
   (or names (gethash "environment_names" (kargu-config-native-view)))
   (or options (kargu-bridge-config-policy--options))))

(defun kargu-bridge-config-policy--registry (&optional metadata)
  "Capture the registry's literal config inputs, without resolving policy.
METADATA includes detached header DTOs for native publication."
  (let (entries)
    (maphash (lambda (id info)
               (let ((entry (kargu-bridge--object
                             "id" (copy-sequence id)
                             "api" (or (kargu-config-copy (plist-get info :api)) :json-null)
                             "env" (vconcat (kargu-config-copy (plist-get info :env)))
                             "models" (vconcat (kargu-config-copy (kargu-provider-models id)))
                             "local" (if (plist-get info :local) t :json-false)
                             "keyless" (if (plist-get info :keyless) t :json-false))))
                 (when metadata
                   (puthash "headers" (kargu-providers-wire-object
                                       (or (kargu-provider-extra-headers id) :json-empty-object)) entry)
                   (puthash "wire_headers" (kargu-providers-wire-object
                                            (or (kargu-provider-format-headers (kargu-provider-format id))
                                                :json-empty-object)) entry))
                 (push entry entries)))
             kargu-providers--table)
    (vconcat (sort entries (lambda (left right) (string< (gethash "id" left) (gethash "id" right)))))))

(defun kargu-bridge-config-policy--context (registry names options)
  "Capture only requested environment NAMES for REGISTRY and captured OPTIONS."
  (let ((values (make-hash-table :test #'equal)))
    (unless (and (vectorp names) (<= (length names) 2048) (cl-every #'stringp names))
      (error "Invalid native environment projection"))
    (mapc (lambda (name) (puthash name (or (kargu-config-copy (getenv name)) :json-null) values)) names)
    (let ((context (kargu-config-copy options)))
      (puthash "environment" values context)
      (puthash "registry" registry context)
      context)))

(defun kargu-bridge-config-policy--call (task connection scope method arguments callback)
  "Send METHOD/ARGUMENTS for TASK on captured CONNECTION/SCOPE to CALLBACK."
  (kargu-bridge-call
   connection method
   (kargu-bridge--object "scope" (kargu-bridge-application--copy-scope scope) "arguments" arguments)
   callback :timeout (max 0.001 (- (kargu-async-task-deadline task) (float-time)))))

(cl-defun kargu-bridge-config-stage (method arguments callback &key parent application valid-p)
  "Stage config natively with METHOD/ARGUMENTS, then commit what Rust requests.
Rust orders the refresh, reads and parses the file and names the environment
variables it needs; this port only answers that request from frozen editor
inputs.  CALLBACK receives (VIEW FAILURE); an invalid source arrives as a
VIEW whose status is \"invalid\".  VALID-P guards the captured editor intent
under PARENT and APPLICATION.  This port never updates an editor cache."
  (let* ((inputs (kargu-bridge-config-policy--inputs))
         (task (kargu-async-start (kargu-application-wrap application callback) :parent parent :owner nil :timeout 5))
         connection scope ticket commit-sent)
    (put inputs 'arguments (kargu-config-copy arguments))
    (setq arguments nil)
    (cl-labels
        ((abort ()
           (when (and ticket (not commit-sent) connection scope (eq (kargu-bridge-status connection) 'ready))
             (let ((id ticket))
               (setq ticket nil)
               (kargu-bridge-call connection "configuration/abort"
                                  (kargu-bridge--object "scope" scope "arguments" (kargu-bridge--object "capture_id" id)) #'ignore))))
         (live ()
           (and (kargu-async-pending-p task) (> (kargu-async-task-deadline task) (float-time))
                (or (null valid-p) (funcall valid-p))
                (kargu-bridge-application-current-p application connection)
                (or (null scope)
                    (kargu-bridge-application-scope-equal-p
                     scope (kargu-bridge-application-current-scope application connection)))))
         (finish (value failure)
           (when (kargu-async-pending-p task)
             (if (live) (kargu-async-finish task value failure)
               (kargu-async-finish task nil (kargu-bridge--fault "stale_configuration")))))
         (staged (value failure)
           (let ((status (and (hash-table-p value) (gethash "status" value))))
             (setq ticket (and (hash-table-p value) (gethash "capture_id" value)))
             (cond
              (failure (finish nil failure))
              ((equal status "invalid") (finish value nil))
              ((equal status "observed")
               (kargu-bridge-config-policy--call
                task connection scope "configuration/snapshot" (kargu-bridge--object) #'finish))
              ((not (stringp ticket))
               (finish nil (kargu-bridge--fault "invalid_configuration_ticket")))
              ((not (live)) (abort) (finish nil (kargu-bridge--fault "stale_configuration")))
              (t
               (condition-case nil
                   (let ((context (kargu-bridge-config-policy--captured-context
                                   inputs (gethash "environment_names" value) t)))
                     (setq commit-sent t)
                     (kargu-bridge-config-policy--call
                      task connection scope "configuration/commit"
                      (kargu-bridge--object "capture_id" ticket "context" context) #'finish))
                 (error (finish nil (kargu-bridge--fault "invalid_configuration_context"))))))))
         (scoped (value failure)
           (if failure (finish nil failure)
             (setq scope value)
             (when (live)
               (let ((request (kargu-config-copy (get inputs 'arguments))))
                 (puthash "registry" (get inputs 'registry) request)
                 (puthash "timeout_ms" (max 1 (min 5000 (floor (* 1000 (- (kargu-async-task-deadline task) (float-time))))))
                          request)
                 (kargu-bridge-config-policy--call task connection scope method request #'staged)))))
         (ready (value failure)
           (setq connection value)
           (cond
            (failure (kargu-async-finish task nil failure))
            ((not (live)) (finish nil (kargu-bridge--fault "stale_configuration")))
            ((not (member "configuration_policy" (append (kargu-bridge-connection-capabilities connection) nil)))
             (finish nil (kargu-bridge--fault "unsupported_configuration_policy")))
            (t (kargu-async-add-cleanup task (kargu-bridge-application-ensure connection application #'scoped))))))
      (kargu-async-add-cleanup task #'abort)
      (kargu-async-add-cleanup task (lambda () (kargu-bridge-config-policy--release-inputs inputs)))
      (when (kargu-async-pending-p task)
        (if-let* ((binding (gethash :native-core (kargu-application-services application))))
            (ready (kargu-bridge-application-connection binding) nil)
          (kargu-async-add-cleanup task (kargu-bridge-ensure #'ready)))))
    task))

(defun kargu-bridge-config-locations ()
  "Capture raw editor location observations; Rust decides their precedence."
  (kargu-bridge--object
   "home" (or (kargu-config-copy (getenv "HOME")) :json-null)
   "xdg_config_home" (or (kargu-config-copy (getenv "XDG_CONFIG_HOME")) :json-null)
   "user_emacs_directory" (expand-file-name user-emacs-directory)))

(cl-defun kargu-bridge-config-refresh (callback &key paths defaults-only parent application valid-p)
  "Ask Rust to discover, read, parse and stage config, then commit it.
PATHS are explicit local editor file grants replacing native discovery;
remote (TRAMP) or relative grants are refused before any native call.
DEFAULTS-ONLY bootstraps built-ins and never supersedes a publication or a
pending refresh.  CALLBACK, PARENT, APPLICATION and VALID-P are as for
`kargu-bridge-config-stage'."
  (if (and paths (not (and (<= 1 (length paths) 8)
                            (cl-every (lambda (path) (and (stringp path) (file-name-absolute-p path)
                                                         (not (file-remote-p path))))
                                      paths))))
      (let ((task (kargu-async-start (kargu-application-wrap application callback)
                                     :parent parent :owner nil :timeout 5)))
        (when (kargu-async-pending-p task)
          (kargu-async-finish task nil (kargu-bridge--fault "invalid_configuration_paths")))
        task)
    (kargu-bridge-config-stage
     "configuration/refresh"
     (if paths
       (kargu-bridge--object "paths" (vconcat (mapcar #'expand-file-name paths))
                             "defaults_only" (if defaults-only t :json-false))
     (kargu-bridge--object "locations" (kargu-bridge-config-locations)
                           "defaults_only" (if defaults-only t :json-false)))
     callback :parent parent :application application :valid-p valid-p)))

(cl-defun kargu-bridge-config-query (method arguments callback &key parent application)
  "Query native config METHOD/ARGUMENTS into CALLBACK under PARENT/APPLICATION."
  (let* ((task (kargu-async-start (kargu-application-wrap application callback) :parent parent :owner nil :timeout 5))
         (binding (gethash :native-core (kargu-application-services application)))
         (connection (and binding (kargu-bridge-application-connection binding)))
         (scope (and connection (kargu-bridge-application-current-scope application connection)))
         (revision (let ((kargu-application--bound application)) (kargu-config-revision))))
    (when (kargu-async-pending-p task)
      (cond
       ((<= (kargu-async-task-deadline task) (float-time))
        (kargu-async-finish task nil (kargu-bridge--fault "configuration_deadline")))
       ((not scope) (kargu-async-finish task nil (kargu-bridge--fault "configuration_unavailable")))
       (t
        (let ((id (kargu-bridge-config-policy--call
                   task connection scope method arguments
                   (kargu-application-wrap application
					   (kargu-async-wrap
					    task (lambda (value failure)
						   (if (and (> (kargu-async-task-deadline task) (float-time))
							    (= revision (kargu-config-revision))
							    (kargu-bridge-application-scope-equal-p scope (kargu-bridge-application-current-scope application connection)))
						       (kargu-async-finish task value failure)
						     (kargu-async-finish task nil (kargu-bridge--fault "stale_configuration")))))))))
          (kargu-async-add-cleanup task (lambda () (kargu-bridge-cancel connection id)))))))
    task))

(cl-defun kargu-bridge-config-resolve (provider model callback
                                               &key parent application context revision target-only)
  "Resolve PROVIDER/MODEL into CALLBACK under PARENT/APPLICATION.
CONTEXT and REVISION pin captured editor inputs and native config publication.
TARGET-ONLY asks for the secret-free projection a native run needs; the
default private projection serves standalone API and catalog consumers."
  (kargu-bridge-config-query
   "configuration/resolve"
   (kargu-bridge--object
    "revision" (or revision (let ((kargu-application--bound application)) (kargu-config-revision)))
    "context" (or context (let ((kargu-application--bound application)) (kargu-bridge-config-context)))
    "target" (kargu-bridge--object "provider" (or provider :json-null) "model" (or model :json-null))
    "projection" (if target-only "target" "private"))
   callback :parent parent :application application))

(provide 'kargu/bridge/config-policy)
;;; config-policy.el ends here
