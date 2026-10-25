;;; circuit.el --- Native circuit projections and explicit reset delivery -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Read-only native observations, scoped to the current application lease.
;; Never infer admission, increment failures, grant probes or run retry timers.

;;; Code:

(require 'cl-lib)
(require 'kargu/bridge/application)

(cl-defstruct (kargu-bridge-circuits (:constructor kargu-bridge-circuits--make))
  "Detached circuit views, not a second breaker registry or admission gate."
  connection scope (sequence 0) order
  (views (make-hash-table :test #'equal)) (latest (make-hash-table :test #'equal)))

(defun kargu-bridge-circuit-current-p (application connection scope)
  "Check APPLICATION still owns exact CONNECTION and native SCOPE."
  (when-let* (((kargu-application-p application))
              (current (kargu-bridge-application-current-scope application connection)))
    (kargu-bridge-application-scope-equal-p current scope)))

(defun kargu-bridge-circuit--view (snapshot)
  "Detach validated native SNAPSHOT; preserve unknown/false/null distinctions."
  (let ((id (and (hash-table-p snapshot) (gethash "circuit_id" snapshot)))
        (provider (and (hash-table-p snapshot) (gethash "provider" snapshot))))
    (unless (and (stringp id) (string-prefix-p "circuit_" id) (<= (length id) 80)
                 (or (eq provider :json-null) (and (stringp provider) (<= 1 (string-bytes provider) 256)))
                 (member (gethash "state" snapshot) '("closed" "open" "half_open"))
                 (cl-every (lambda (key) (natnump (gethash key snapshot)))
                           '("failures" "cooldown_remaining_ms" "sequence"))
                 (memq (gethash "probe_inflight" snapshot) '(t :json-false)))
      (error "Invalid native circuit projection"))
    (kargu-bridge--object "circuit_id" (copy-sequence id)
                          "provider" (if (stringp provider) (copy-sequence provider) :json-null)
                          "state" (copy-sequence (gethash "state" snapshot))
                          "failures" (gethash "failures" snapshot) "sequence" (gethash "sequence" snapshot)
                          "cooldown_remaining_ms" (gethash "cooldown_remaining_ms" snapshot)
                          "probe_inflight" (gethash "probe_inflight" snapshot))))

(defun kargu-bridge-circuit--evict-view (service)
  "Bound SERVICE's display cache; never evict native circuit state or authority."
  (when (>= (hash-table-count (kargu-bridge-circuits-views service)) 256)
    (let ((oldest (car (last (kargu-bridge-circuits-order service)))) providers)
      (setf (kargu-bridge-circuits-order service) (butlast (kargu-bridge-circuits-order service)))
      (remhash oldest (kargu-bridge-circuits-views service))
      (maphash (lambda (provider id) (when (equal id oldest) (push provider providers)))
               (kargu-bridge-circuits-latest service))
      (dolist (provider providers) (remhash provider (kargu-bridge-circuits-latest service))))))

(defun kargu-bridge-circuit-observe (application connection scope snapshot &optional current)
  "Project SNAPSHOT under APPLICATION's exact CONNECTION and SCOPE.
CURRENT marks its last used provider circuit, not an admission decision."
  (unless (kargu-bridge-circuit-current-p application connection scope)
    (error "Obsolete native circuit owner"))
  (let* ((view (kargu-bridge-circuit--view snapshot))
         (id (gethash "circuit_id" view))
         (service (kargu-application-service :native-circuits #'kargu-bridge-circuits--make application)))
    (unless (and (eq connection (kargu-bridge-circuits-connection service))
                 (kargu-bridge-application-scope-equal-p scope (kargu-bridge-circuits-scope service)))
      (setf (kargu-bridge-circuits-connection service) connection
            (kargu-bridge-circuits-scope service) (kargu-bridge-application--copy-scope scope)
            (kargu-bridge-circuits-sequence service) 0
            (kargu-bridge-circuits-order service) nil)
      (clrhash (kargu-bridge-circuits-views service))
      (clrhash (kargu-bridge-circuits-latest service)))
    (when (> (gethash "sequence" view) (kargu-bridge-circuits-sequence service))
      (unless (gethash id (kargu-bridge-circuits-views service))
        (kargu-bridge-circuit--evict-view service)
        (push (copy-sequence id) (kargu-bridge-circuits-order service)))
      (setf (kargu-bridge-circuits-sequence service) (gethash "sequence" view))
      (puthash (copy-sequence id) view (kargu-bridge-circuits-views service))
      (when current
        (puthash (gethash "provider" view) (copy-sequence id) (kargu-bridge-circuits-latest service)))))
  nil)

(defun kargu-bridge-circuit-view (application provider)
  "Read APPLICATION's last native PROVIDER circuit; nil means unavailable.
Return detached fields, never mutable storage or execution authority."
  (when-let* ((service (gethash :native-circuits (kargu-application-services application)))
              ((kargu-bridge-circuit-current-p application (kargu-bridge-circuits-connection service)
                                                (kargu-bridge-circuits-scope service)))
              (id (gethash provider (kargu-bridge-circuits-latest service)))
              (view (gethash id (kargu-bridge-circuits-views service))))
    (kargu-bridge-circuit--view view)))

(defun kargu-bridge-circuit-reset (application provider callback)
  "Reset APPLICATION's captured native PROVIDER, or all when nil.
CALLBACK receives native result/error.  Never start or reconnect a core."
  (let* ((service (gethash :native-circuits (kargu-application-services application)))
         (connection (and service (kargu-bridge-circuits-connection service)))
         (scope (and service (kargu-bridge-circuits-scope service))))
    (if (not (and service (kargu-bridge-circuit-current-p application connection scope)))
        (kargu-bridge--callback callback nil (kargu-bridge--fault "unavailable"))
      (let ((params (kargu-bridge--object "scope" (kargu-bridge-application--copy-scope scope))))
        (when provider (puthash "provider" (copy-sequence provider) params))
        (kargu-bridge-call
         connection "api/circuit/reset" params
         (lambda (result failure)
           (unless failure
             (condition-case nil
                 (let ((views (and (hash-table-p result) (gethash "circuits" result))))
                   (unless (and (vectorp views) (<= (length views) 256)) (error "Invalid circuit reset"))
                   (mapc (lambda (view) (kargu-bridge-circuit-observe application connection scope view)) views))
               (error (setq failure (kargu-bridge--fault "invalid_circuit_projection")))))
           (kargu-bridge--callback callback (unless failure result) failure)))))))

(provide 'kargu/bridge/circuit)
;;; circuit.el ends here
