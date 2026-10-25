;;; budget.el --- Native API budget delivery leases -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Bind captured budget intent once to an application and connection epoch.
;; Never replace a lost native ledger with a new zero-valued one.  Allocation
;; callbacks outlive individual attempt waiters so late allocation can be closed.

;;; Code:

(require 'cl-lib)
(require 'kargu/bridge)
(require 'kargu/bridge/application)
(require 'kargu/application/budget)

(cl-defstruct (kargu-bridge-budget (:constructor kargu-bridge-budget--make))
  "One connection-bound native ledger delivery lease, not a local debit gate."
  connection scope budget id waiters (state :starting))

(defun kargu-bridge-budget--notify (binding failure)
  "Deliver BINDING's detached IDs or FAILURE to its owned waiters once."
  (let ((waiters (kargu-bridge-budget-waiters binding)))
    (setf (kargu-bridge-budget-waiters binding) nil)
    (dolist (ticket (nreverse waiters))
      (let ((callback (car ticket)))
        (setcar ticket nil)
        (let ((error-data
               (or failure
                   (unless (and (eq (kargu-bridge-budget-state binding) :ready)
                                (kargu-budget-live-p (kargu-bridge-budget-budget binding))
                                (eq (kargu-bridge-status (kargu-bridge-budget-connection binding)) 'ready))
                     (kargu-bridge--fault "budget_closed")))))
          (kargu-bridge--callback callback
                                  (unless error-data (copy-sequence (kargu-bridge-budget-id binding)))
                                  error-data))))))

(defun kargu-bridge-budget-observe (budget snapshot)
  "Project SNAPSHOT only onto BUDGET's exact native ledger identity."
  (let ((binding (kargu-run-budget-native budget)))
    (unless (and (kargu-bridge-budget-p binding) (hash-table-p snapshot)
                 (equal (gethash "budget_id" snapshot) (kargu-bridge-budget-id binding)))
      (error "Foreign native budget projection"))
    (kargu-budget-project budget snapshot)))

(defun kargu-bridge-budget--close-native (binding)
  "Close BINDING's known ID; do not start or reconnect the sidecar."
  (when (and (kargu-bridge-budget-id binding)
             (eq (kargu-bridge-budget-state binding) :closing))
    (setf (kargu-bridge-budget-state binding) :draining)
    (if (not (eq (kargu-bridge-status (kargu-bridge-budget-connection binding)) 'ready))
        (setf (kargu-bridge-budget-state binding) :failed)
      (kargu-bridge-call
       (kargu-bridge-budget-connection binding) "api/budget/close"
       (kargu-bridge--object "scope" (kargu-bridge-budget-scope binding)
                             "budget_id" (kargu-bridge-budget-id binding))
       (lambda (result failure)
         (unless failure
           (condition-case nil
               (progn
                 (unless (and (hash-table-p result) (equal (gethash "status" result) "closed"))
                   (error "Invalid native budget close"))
                 (kargu-bridge-budget-observe (kargu-bridge-budget-budget binding) (gethash "budget" result)))
             (error (setq failure (kargu-bridge--fault "protocol_error")))))
         (setf (kargu-bridge-budget-state binding) (if failure :failed :closed)))
       :timeout :unlimited))))

(defun kargu-bridge-budget-close (budget)
  "Revoke BUDGET's editor waiters before closing and draining its native lease."
  (when-let* ((binding (kargu-run-budget-native budget)))
    (when (memq (kargu-bridge-budget-state binding) '(:starting :ready))
      (setf (kargu-bridge-budget-state binding) :closing)
      (kargu-bridge-budget--notify binding (kargu-bridge--fault "budget_closed"))
      (kargu-bridge-budget--close-native binding))))

(defun kargu-bridge-budget--opened (binding snapshot failure)
  "Finish BINDING's allocation from SNAPSHOT or FAILURE, closing late acquisitions."
  (let ((id (and (hash-table-p snapshot) (gethash "budget_id" snapshot)))
        (closing (eq (kargu-bridge-budget-state binding) :closing)))
    (unless (or failure (and (stringp id) (string-prefix-p "budget_" id)))
      (setq failure (kargu-bridge--fault "protocol_error")))
    (when (and (not failure) id)
      (setf (kargu-bridge-budget-id binding) (copy-sequence id))
      (condition-case nil
          (kargu-bridge-budget-observe (kargu-bridge-budget-budget binding) snapshot)
        (error (setq failure (kargu-bridge--fault "protocol_error")))))
    (cond
     (failure
      (setf (kargu-bridge-budget-state binding) (if (kargu-bridge-budget-id binding) :closing :failed))
      (unless (eq (kargu-run-budget-status (kargu-bridge-budget-budget binding)) :sealed)
        (setf (kargu-run-budget-status (kargu-bridge-budget-budget binding)) :accounting-failed))
      (kargu-bridge-budget--notify binding failure)
      (kargu-bridge-budget--close-native binding))
     (closing (kargu-bridge-budget--close-native binding))
     (t
      (setf (kargu-bridge-budget-state binding) :ready)
      (kargu-bridge-budget--notify binding nil)))))

(defun kargu-bridge-budget-ensure (budget connection scope callback)
  "Bind BUDGET once on CONNECTION and SCOPE; asynchronously deliver CALLBACK.
Return a detachable waiter cleanup, never admission or billing authority."
  (let* ((binding (kargu-run-budget-native budget))
         (ticket (list callback))
         (start (null binding)))
    (when start
      (setq binding (kargu-bridge-budget--make
                     :connection connection :budget budget
                     :scope (kargu-bridge-application--copy-scope scope)))
      (setf (kargu-run-budget-native budget) binding))
    (cond
     ((or (not (eq connection (kargu-bridge-budget-connection binding)))
          (not (cl-every (lambda (key)
                           (equal (gethash key scope)
                                  (gethash key (kargu-bridge-budget-scope binding))))
                         '("application_id" "session_id"))))
      (setf (kargu-run-budget-status budget) :accounting-lost)
      (kargu-bridge-budget-close budget)
      (kargu-bridge--callback callback nil (kargu-bridge--fault "budget_epoch_lost")))
     ((or (not (kargu-budget-live-p budget))
          (not (memq (kargu-bridge-budget-state binding) '(:starting :ready))))
      (kargu-bridge--callback callback nil (kargu-bridge--fault "budget_closed")))
     ((not (member "api_budget" (append (kargu-bridge-connection-capabilities connection) nil)))
      (setf (kargu-bridge-budget-state binding) :failed
            (kargu-run-budget-status budget) :accounting-failed)
      (kargu-bridge--callback callback nil (kargu-bridge--fault "unsupported_budget")))
     (t
      (push ticket (kargu-bridge-budget-waiters binding))
      (cond
       ((eq (kargu-bridge-budget-state binding) :ready) (kargu-bridge-budget--notify binding nil))
       (start
        (kargu-bridge-call
         connection "api/budget/open"
         (kargu-bridge--object
          "scope" (kargu-bridge-budget-scope binding)
          "limits" (kargu-bridge--object
                    "requests" (kargu-run-budget-max-requests budget)
                    "compactions" (kargu-run-budget-max-compactions budget)
                    "tokens" (or (kargu-run-budget-max-tokens budget) :json-null))
          "deadline_epoch_ms" (if-let* ((deadline (kargu-run-budget-deadline budget)))
                                  (max 0 (floor (* deadline 1000))) :json-null))
         (lambda (snapshot failure) (kargu-bridge-budget--opened binding snapshot failure))
         :timeout :unlimited)))))
    (lambda () (setcar ticket nil))))

(provide 'kargu/bridge/budget)
;;; budget.el ends here
