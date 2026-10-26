;;; config-policy.el --- Owned native configuration publication port -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Capture editor inputs and requested environment values without choosing their
;; precedence.  Only the native application actor stages and commits config.

;;; Code:

(require 'kargu/bridge/config)
(require 'kargu/providers/registry)

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
    (put cell 'registry (kargu-bridge-config-policy--registry))
    (put cell 'options (kargu-bridge-config-policy--options))
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

(defun kargu-bridge-config-policy--captured-context (cell names)
  "Project only native-requested NAMES from immutable editor input CELL."
  (let ((process-environment (get cell 'environment)))
    (kargu-bridge-config-policy--context (kargu-config-copy (get cell 'registry)) names (get cell 'options))))

(defun kargu-bridge-config-policy--options ()
  "Capture raw editor options and selection, without choosing any fallback."
  (kargu-bridge--object
   "api_base" (or (kargu-config-copy kargu-api-base) :json-null)
   "api_key" (or (kargu-config-copy kargu-api-key) :json-null)
   "selected_provider" (or (kargu-config-copy (kargu-selection-provider)) :json-null)
   "selected_model" (or (kargu-config-copy (kargu-selection-model)) :json-null)))

(defun kargu-bridge-config-context (&optional names options)
  "Capture native-requested environment NAMES and raw editor OPTIONS.
When omitted, use the last committed native view and current editor options."
  (kargu-bridge-config-policy--context
   (kargu-bridge-config-policy--registry)
   (or names (gethash "environment_names" (kargu-config-native-view)))
   (or options (kargu-bridge-config-policy--options))))

(defun kargu-bridge-config-policy--registry ()
  "Capture the registry's literal config inputs, without resolving policy."
  (let (entries)
    (maphash (lambda (id info)
               (push (kargu-bridge--object
                      "id" (copy-sequence id)
                      "api" (or (kargu-config-copy (plist-get info :api)) :json-null)
                      "env" (vconcat (kargu-config-copy (plist-get info :env)))
                      "models" (vconcat (kargu-config-copy (kargu-provider-models id)))
                      "local" (if (plist-get info :local) t :json-false)
                      "keyless" (if (plist-get info :keyless) t :json-false)) entries))
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

(cl-defun kargu-bridge-config-publish (captured generation callback &key parent application valid-p)
  "Publish CAPTURED/GENERATION natively for APPLICATION under PARENT.
CALLBACK receives (VIEW FAILURE); VALID-P guards the captured editor intent.
This port never updates an editor cache."
  (let* ((inputs (kargu-bridge-config-policy--inputs))
         (task (kargu-async-start (kargu-application-wrap application callback) :parent parent :owner nil :timeout 5))
         connection scope ticket commit-sent)
    (put inputs 'captured (kargu-config-copy captured))
    (setq captured nil)
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
         (prepared (value failure)
           (setq ticket (and (hash-table-p value) (gethash "capture_id" value)))
           (cond
            (failure (finish nil failure))
            ((not (and (stringp ticket) (equal (gethash "generation" value) generation)))
             (finish nil (kargu-bridge--fault "invalid_configuration_ticket")))
            ((not (live)) (abort) (finish nil (kargu-bridge--fault "stale_configuration")))
            (t
             (condition-case nil
                 (let ((context (kargu-bridge-config-policy--captured-context inputs (gethash "environment_names" value))))
                   (setq commit-sent t)
                   (kargu-bridge-config-policy--call
                    task connection scope "configuration/commit"
                    (kargu-bridge--object "capture_id" ticket "context" context) #'finish))
               (error (finish nil (kargu-bridge--fault "invalid_configuration_context")))))))
         (scoped (value failure)
           (if failure (finish nil failure)
             (setq scope value)
             (when (live)
               (kargu-bridge-config-policy--call
                task connection scope "configuration/prepare"
                (kargu-bridge--object
                 "generation" generation "path" (gethash "path" (get inputs 'captured))
                 "timeout_ms" (max 1 (min 5000 (floor (* 1000 (- (kargu-async-task-deadline task) (float-time))))))
                 "digest" (or (gethash "digest" (get inputs 'captured)) :json-null)
                 "document" (or (gethash "config" (get inputs 'captured)) :json-null) "registry" (get inputs 'registry))
                #'prepared))))
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

(cl-defun kargu-bridge-config-resolve (provider model callback &key parent application context revision)
  "Resolve PROVIDER/MODEL into CALLBACK under PARENT/APPLICATION.
CONTEXT and REVISION pin captured editor inputs and native config publication."
  (kargu-bridge-config-query
   "configuration/resolve"
   (kargu-bridge--object
    "revision" (or revision (let ((kargu-application--bound application)) (kargu-config-revision)))
    "context" (or context (let ((kargu-application--bound application)) (kargu-bridge-config-context)))
    "target" (kargu-bridge--object "provider" (or provider :json-null) "model" (or model :json-null)))
   callback :parent parent :application application))

(provide 'kargu/bridge/config-policy)
;;; config-policy.el ends here
