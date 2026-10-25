;;; coordinator.el --- Owned application and logical request coordination -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Single-run application coordinator and logical request resource owner.
;; Replaces scattered global runtime flags with explicit owned structs
;; (`kargu-application' and `kargu-logical-request') while keeping
;; single-active-run and request cancellation invariants.

;;; Code:

(require 'cl-lib)
(require 'kargu/contract/assert)
(require 'kargu/application/budget)

(defvar kargu--loop-run nil)
(defvar kargu--busy nil)
(defvar kargu--generation 0)
(defvar kargu--current-process nil)
(defvar kargu-metadata--legacy nil
  "Non-nil inside a detached compatibility continuation.")

(declare-function kargu-loop-running-p "kargu/loop" ())
(declare-function kargu-busy-p "kargu/api/http" ())

;;;; Logical request record ------------------------------------------------

(cl-defstruct (kargu-logical-request
               (:constructor kargu-logical-request--create))
  "One logical API request owning its attempt process, retry timer and watch."
  (id nil :read-only t)
  (generation 0)
  (session nil)
  (origin nil)
  (circuit-scope nil :read-only t)
  (budget nil :read-only t)
  (debit-kind :normal-request :read-only t)
  (app nil :read-only t)
  (claim nil :read-only t)
  (state :pending)
  (process nil)
  (retry-timer nil)
  (stream-timer nil)
  connection preparation cleanups owner-cleanup)

(defun kargu-logical-request-add-cleanup (request cleanup)
  "Attach CLEANUP to REQUEST, releasing late acquisitions immediately."
  (if (kargu-logical-request-live-p request)
      (push cleanup (kargu-logical-request-cleanups request))
    (funcall cleanup)))

(defun kargu-logical-request-clean-resources (request)
  "Drain REQUEST's acquired resources exactly once."
  (let ((cleanups (kargu-logical-request-cleanups request)))
    (setf (kargu-logical-request-cleanups request) nil)
    (dolist (cleanup cleanups)
      (condition-case err (funcall cleanup)
        (error (message "Kargu request cleanup failed: %s" (error-message-string err)))))))

(defun kargu-logical-request-detach-owner (request)
  "Remove only REQUEST's captured origin lifecycle hooks."
  (when-let* ((cleanup (kargu-logical-request-owner-cleanup request)))
    (setf (kargu-logical-request-owner-cleanup request) nil)
    (when (buffer-live-p (kargu-logical-request-origin request))
      (with-current-buffer (kargu-logical-request-origin request)
        (remove-hook 'kill-buffer-hook cleanup t)
        (remove-hook 'change-major-mode-hook cleanup t)))))

(cl-defun kargu-logical-request-create (&key id (generation 0) session origin
                                             (state :pending) process
                                             retry-timer stream-timer circuit-scope budget app claim
                                             (debit-kind :normal-request))
  "Create a validated `kargu-logical-request' record.
ID, GENERATION, SESSION, ORIGIN, STATE, PROCESS, RETRY-TIMER and
STREAM-TIMER initialize the owned fields.
CIRCUIT-SCOPE and BUDGET retain accounting owners; APP and CLAIM own delivery.
DEBIT-KIND identifies the captured logical turn category."
  (kargu-contract-assert #'integerp generation
                         "GENERATION must be an integer: %S" generation)
  (kargu-contract-assert (lambda (s)
                           (memq s '(:pending :in-flight :retrying :finished :cancelled)))
                         state "Invalid logical request state: %S" state)
  (kargu-logical-request--create
   :id (or id (format "req-%d" generation))
   :generation generation
   :session session
   :origin origin
   :circuit-scope circuit-scope :budget budget :app app :claim claim :debit-kind debit-kind
   :state state
   :process process
   :retry-timer retry-timer
   :stream-timer stream-timer))

(defun kargu-logical-request-live-p (request &optional current-generation)
  "Return non-nil when REQUEST is active in CURRENT-GENERATION."
  (and (kargu-logical-request-p request)
       (memq (kargu-logical-request-state request) '(:pending :in-flight :retrying))
       (or (null current-generation)
           (= (kargu-logical-request-generation request) current-generation))))

(defun kargu-logical-request-cancel-retry-timer (request)
  "Cancel and clear REQUEST's retry backoff timer, if any."
  (when (kargu-logical-request-p request)
    (let ((timer (kargu-logical-request-retry-timer request)))
      (setf (kargu-logical-request-retry-timer request) nil)
      (when (timerp timer)
        (cancel-timer timer)))))

(defun kargu-logical-request-set-retry-timer (request timer)
  "Attach retry TIMER to REQUEST after cancelling any previous retry timer."
  (if (kargu-logical-request-live-p request)
      (progn
        (kargu-logical-request-cancel-retry-timer request)
        (setf (kargu-logical-request-retry-timer request) timer
              (kargu-logical-request-state request) :retrying)
        timer)
    (when (timerp timer) (cancel-timer timer))
    nil))

(defun kargu-logical-request-cancel-stream-timer (request)
  "Cancel and clear REQUEST's stream watchdog timer, if any."
  (when (kargu-logical-request-p request)
    (let ((timer (kargu-logical-request-stream-timer request))
          (process (kargu-logical-request-process request)))
      (setf (kargu-logical-request-stream-timer request) nil)
      (when (timerp timer)
        (cancel-timer timer))
      (when (processp process)
        (when-let* ((ptimer (process-get process :kargu-stream-timer)))
          (when (timerp ptimer)
            (cancel-timer ptimer))
          (process-put process :kargu-stream-timer nil))))))

(defun kargu-logical-request-cancel (request)
  "Idempotently cancel REQUEST and release its timers and transport process."
  (when (kargu-logical-request-p request)
    (setf (kargu-logical-request-state request) :cancelled)
    (kargu-logical-request-clean-resources request)
    (kargu-logical-request-detach-owner request)
    (kargu-logical-request-cancel-retry-timer request)
    (kargu-logical-request-cancel-stream-timer request)
    (let ((process (kargu-logical-request-process request)))
      (setf (kargu-logical-request-process request) nil)
      (when (and (processp process) (process-live-p process))
        (ignore-errors (delete-process process))))))

(defun kargu-logical-request-finish (request)
  "Mark REQUEST finished and release any remaining timers."
  (when (kargu-logical-request-p request)
    (kargu-logical-request-detach-owner request)
    (unless (eq (kargu-logical-request-state request) :cancelled)
      (setf (kargu-logical-request-state request) :finished))
    (kargu-logical-request-clean-resources request)
    (kargu-logical-request-cancel-retry-timer request)
    (kargu-logical-request-cancel-stream-timer request)
    (setf (kargu-logical-request-process request) nil)))

;;;; Application coordinator -----------------------------------------------

(cl-defstruct (kargu-application
               (:constructor kargu-application--create))
  "Owned application coordinator for single-run and lifecycle state."
  (id (format "app-%s-%06x"
              (format-time-string "%Y%m%d%H%M%S")
              (random #xffffff)) :read-only t)
  (status :idle)
  (active-run nil)
  (active-claim-token nil)
  (active-request nil)
  (generation 0)
  (session-id nil)
  (run-id nil)
  (budget nil)
  (services (make-hash-table :test #'eq) :read-only t))

(defun kargu-application-service (name factory &optional app)
  "Return NAME's service on APP, creating it once through FACTORY."
  (let ((services (kargu-application-services (kargu-application-context app))))
    (or (gethash name services)
        (puthash name (funcall factory) services))))

(defvar-local kargu-application-owner nil
  "Application explicitly attached to this boundary buffer, or nil for default.")

(defvar kargu-application--bound nil
  "Dynamically captured application during a continuation, never retained.")

(defconst kargu-application--transition-table
  '((:idle
     :idle :starting :running :requesting :waiting-model :busy
     :executing-tools :verifying :compacting :stopped :pause)
    (:starting
     :starting :running :requesting :waiting-model :executing-tool :executing-tools :idle :stopped :error)
    (:running
     :running :requesting :streaming :waiting-model :executing-tool :executing-tools
     :waiting-approval :compacting :verifying :done :stopped :error :limit :pause :idle :busy)
    (:requesting
     :requesting :streaming :waiting-model :executing-tool :executing-tools
     :waiting-approval :compacting :verifying :done :stopped :error :limit :pause :running :idle :busy)
    (:streaming
     :streaming :executing-tool :executing-tools :waiting-approval :compacting :verifying
     :done :stopped :error :limit :pause :running :idle)
    (:waiting-model
     :waiting-model :streaming :requesting :executing-tool :executing-tools :done :stopped :error :idle :running :busy :pause)
    (:executing-tool
     :executing-tool :executing-tools :requesting :waiting-model :waiting-approval :verifying
     :done :stopped :error :limit :pause :running :idle)
    (:executing-tools
     :executing-tools :executing-tool :requesting :waiting-model :waiting-approval :verifying
     :done :stopped :error :limit :pause :running :idle)
    (:waiting-approval
     :waiting-approval :executing-tool :executing-tools :requesting :done :stopped :error :idle :running)
    (:compacting
     :compacting :requesting :waiting-model :executing-tools :executing-tool :done :stopped :error :idle :running)
    (:verifying
     :verifying :requesting :executing-tools :executing-tool :done :stopped :error :idle :running)
    (:done
     :done :idle :starting :running)
    (:stopped
     :stopped :idle :starting :running :error :requesting)
    (:error
     :error :idle :starting :running :requesting :waiting-model)
    (:limit
     :limit :idle :starting :running)
    (:pause
     :pause :idle :running :requesting :starting :waiting-model :stopped :error)
    (:closing :closing :resetting :idle :done :stopped :error :limit)
    (:resetting :resetting :closing :idle)
    (:busy
     :busy :idle :running :requesting :waiting-model :stopped :error :done))
  "Alist mapping each lifecycle status to its permitted next statuses.")

(defun kargu-application-valid-transition-p (from-status to-status)
  "Return non-nil when transitioning from FROM-STATUS to TO-STATUS is permitted."
  (let ((allowed (alist-get from-status kargu-application--transition-table)))
    (or (and allowed (memq to-status '(:closing :resetting)))
        (memq to-status allowed))))

(defun kargu-application-transition (app new-status &optional _reason)
  "Transition APP's status to NEW-STATUS using the transition table.
Signals an error if the transition from current status is disallowed.
Returns NEW-STATUS."
  (let* ((target (kargu-application-context app))
         (current (kargu-application-status target)))
    (unless (or (kargu-application-valid-transition-p current new-status)
                ;; Accommodate unmigrated legacy modules when no owned claim is active on default coordinator
                (and (null app)
                     (null (kargu-application-active-claim-token target))
                     (assq new-status kargu-application--transition-table)))
      (error "Kargu: invalid application status transition from %S to %S"
             current new-status))
    (setf (kargu-application-status target) new-status)
    new-status))

(cl-defun kargu-application-create (&key id (status :idle) active-run
                                         active-claim-token active-request
                                         (generation 0) session-id run-id budget)
  "Create a validated `kargu-application' coordinator record.
ID, STATUS, ACTIVE-RUN, ACTIVE-CLAIM-TOKEN, ACTIVE-REQUEST, GENERATION,
SESSION-ID, RUN-ID and BUDGET initialize the fields."
  (kargu-contract-assert #'keywordp status "STATUS must be a keyword: %S" status)
  (kargu-contract-assert #'integerp generation
                         "GENERATION must be an integer: %S" generation)
  (kargu-application--create
   :id (or id (format "app-%s-%06x"
                      (format-time-string "%Y%m%d%H%M%S")
                      (random #xffffff)))
   :status status
   :active-run active-run
   :active-claim-token active-claim-token
   :active-request active-request
   :generation generation
   :session-id session-id
   :run-id run-id
   :budget budget))

(defvar kargu-application--context nil
  "Owned default application coordinator instance, initialized on demand.")

(defun kargu-application-context (&optional app)
  "Return explicit APP, or the lazily initialized application coordinator."
  (if (or app kargu-application--bound kargu-application-owner)
      (progn
        (kargu-contract-assert #'kargu-application-p
                               (or app kargu-application--bound kargu-application-owner))
        (or app kargu-application--bound kargu-application-owner))
    (unless (kargu-application-p kargu-application--context)
      (setq kargu-application--context (kargu-application-create)))
    kargu-application--context))

(defun kargu-application-current-status (&optional app)
  "Return the lifecycle status keyword of APP or the active coordinator."
  (kargu-application-status (kargu-application-context app)))

(defun kargu-application-set-status (status &optional app)
  "Set the lifecycle STATUS keyword on APP or the active coordinator."
  (kargu-contract-assert #'keywordp status "STATUS must be a keyword: %S" status)
  (kargu-application-transition app status))

(defun kargu-application-current-run (&optional app)
  "Return the active run record for APP or the active coordinator."
  (if (or app kargu-application--bound kargu-application-owner)
      (kargu-application-active-run (kargu-application-context app))
    (or (kargu-application-active-run (kargu-application-context))
        kargu--loop-run)))

(defun kargu-application-set-active-run (run &optional app)
  "Set RUN as the active run on APP or the active coordinator.
Signals an error if APP already has an active run and RUN is non-nil."
  (let ((target (kargu-application-context app)))
    (when (and run (kargu-application-active-run target)
               (not (equal (kargu-application-active-run target) run)))
      (error "Kargu: application already has an active run (ARCH-01): %S"
             (kargu-application-active-run target)))
    (setf (kargu-application-active-run target) run)
    (unless (or app kargu-application--bound kargu-application-owner)
      (setq kargu--loop-run run))
    run))

(cl-defstruct (kargu-application-claim
               (:constructor kargu-application-claim--create))
  "Active claim token for single-run execution on an application instance."
  (id nil :read-only t)
  (token nil :read-only t)
  (app nil :read-only t)
  (app-id nil :read-only t)
  (run-id nil :read-only t)
  (session-id nil :read-only t)
  (mode nil :read-only t)
  (created-at (float-time) :read-only t))

(defun kargu-application-claim (app &rest plist)
  "Claim execution on APP for arguments in PLIST.
PLIST accepts `:run-id', `:run', `:session-id', `:mode' and `:no-error'.
Signals an error if APP already has an active run or active claim (ARCH-01).
Returns a `kargu-application-claim' token on success."
  (let* ((target (kargu-application-context app))
         (session-id (plist-get plist :session-id))
         (mode (plist-get plist :mode))
         (no-error (plist-get plist :no-error)))
    (if (or (memq (kargu-application-status target) '(:closing :resetting))
            (kargu-application-active-run target)
            (kargu-application-active-claim-token target)
            (kargu-application-work-active-p target))
        (if no-error
            nil
          (error "Kargu: application already has an active run (ARCH-01): %S"
                 (or (kargu-application-active-run target) "busy")))
      (let* ((generation (cl-incf (kargu-application-generation target)))
             (run-id (or (plist-get plist :run-id) (format "run-%d" generation)))
             (claim-id (format "claim-%d" generation))
             (claim (kargu-application-claim--create
                     :id claim-id
                     :token claim-id
                     :app target
                     :app-id (kargu-application-id target)
                     :run-id run-id
                     :session-id session-id
                     :mode mode
                     :created-at (float-time))))
        (setf (kargu-application-active-run target) (or (plist-get plist :run) run-id))
        (setf (kargu-application-active-claim-token target) claim)
        (setf (kargu-application-status target) :running)
        claim))))

(defun kargu-application-release (app claim)
  "Release APP only when CLAIM is its exact active capability, not a run label."
  (let* ((target (kargu-application-context app))
         (current (kargu-application-active-claim-token target)))
    (when (and current (eq current claim))
      ;; Keep admission closed until resource cleanup has finished.
      (let ((status (kargu-application-status target)))
        (setf (kargu-application-status target) :closing)
        (when-let* ((request (kargu-application-active-request target)))
          (setf (kargu-application-active-request target) nil)
          (kargu-logical-request-cancel request))
        (setf (kargu-application-active-run target) nil
              (kargu-application-active-claim-token target) nil
              (kargu-application-status target) (if (eq status :resetting) :resetting :idle)))
      t)))

(defun kargu-application-current-request (&optional app)
  "Return the active `kargu-logical-request' on APP, or nil."
  (kargu-application-active-request (kargu-application-context app)))

(defun kargu-logical-request-current-p (request &optional finished)
  "Check REQUEST's exact authority; FINISHED permits its detached delivery."
  (when (kargu-logical-request-p request)
    (let* ((app (kargu-logical-request-app request))
           (current (kargu-application-current-request app)))
      (and (= (kargu-logical-request-generation request)
              (kargu-application-current-generation app))
           (eq (kargu-logical-request-claim request)
               (kargu-application-active-claim-token (kargu-application-context app)))
           (or (and (eq request current) (kargu-logical-request-live-p request))
               (and finished (null current)
                    (eq (kargu-logical-request-state request) :finished)))))))

(defun kargu-application-wrap (app function)
  "Capture APP for asynchronous FUNCTION without consulting the current owner."
  (let ((legacy (null (or kargu-application--bound kargu-application-owner)))
        (metadata-legacy (or kargu-metadata--legacy
                             (null (or kargu-application--bound kargu-application-owner))))
        (origin (current-buffer)))
    (lambda (&rest args)
      (with-current-buffer (if (buffer-live-p origin) origin (current-buffer))
        (if legacy
            (let ((kargu-application--bound app) (kargu-application--context app)
                  (kargu-metadata--legacy metadata-legacy))
              (save-match-data (apply function args)))
          (let ((kargu-application--bound app)
                (kargu-metadata--legacy metadata-legacy)
                (kargu-application--context app)
                (kargu--busy nil) (kargu--current-process nil))
            (save-match-data (apply function args))))))))

(defun kargu-application-set-active-request (request &optional app)
  "Set REQUEST as the active `kargu-logical-request' on APP."
  (kargu-contract-assert
   (lambda (r) (or (null r) (kargu-logical-request-p r)))
   request "REQUEST must be a kargu-logical-request or nil: %S" request)
  (let ((target (kargu-application-context app)))
    (setf (kargu-application-active-request target) request)
    (when (and request (kargu-logical-request-p request))
      (setf (kargu-application-generation target)
            (max (kargu-application-generation target)
                 (kargu-logical-request-generation request))))
    request))

(defun kargu-application-current-generation (&optional app)
  "Return the current request generation integer for APP."
  (if (or app kargu-application--bound kargu-application-owner)
      (kargu-application-generation (kargu-application-context app))
    (max kargu--generation (kargu-application-generation (kargu-application-context)))))

(defun kargu-application-next-generation (&optional app)
  "Advance and return the request generation integer for APP."
  (let ((target (kargu-application-context app)))
    (if (or app kargu-application--bound kargu-application-owner)
        (let ((next (cl-incf (kargu-application-generation target))))
          (when kargu-application--bound (setq kargu--generation next))
          next)
      (let ((next (1+ (max kargu--generation (kargu-application-generation target)))))
        (setq kargu--generation next)
        (setf (kargu-application-generation target) next)
        next))))

(defun kargu-application-work-active-p (&optional app)
  "Return non-nil when APP has an active agent run or transport request."
  (if (or app kargu-application--bound kargu-application-owner)
      (let ((target (kargu-application-context app)))
        (or (memq (kargu-application-status target) '(:closing :resetting))
            (not (null (kargu-application-active-run target)))
            (kargu-logical-request-live-p
             (kargu-application-active-request target)
             (kargu-application-generation target))))
    (or (not (null (kargu-application-current-run)))
        (memq (kargu-application-current-status) '(:closing :resetting))
        (and (boundp 'kargu--busy) kargu--busy)
        (kargu-logical-request-live-p
         (kargu-application-current-request) kargu--generation)
        (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
        (and (fboundp 'kargu-busy-p) (kargu-busy-p)))))

(defun kargu-application-busy-p (&optional app)
  "Derive whether APP is busy from its active work and lifecycle status."
  (or (kargu-application-work-active-p app)
      (not (memq (kargu-application-current-status app)
                 '(:idle :stopped :error :done :limit :pause)))))

(defun kargu-application-reset (&optional app)
  "Reset APP's lifecycle status to `:idle' and clear stale references."
  (let ((target (kargu-application-context app)))
    (unless (memq (kargu-application-status target) '(:resetting :closing))
      (setf (kargu-application-status target) :idle))
    (setf (kargu-application-active-claim-token target) nil)
    (when (null (and (not app) kargu--loop-run))
      (setf (kargu-application-active-run target) nil))
    (when (null (and (not app) kargu--busy))
      (setf (kargu-application-active-request target) nil))
    (when-let* ((budget (kargu-application-budget target))) (kargu-budget-seal budget))
    (setf (kargu-application-budget target) nil)
    target))

(defun kargu-application-budget-get (&optional app)
  "Return the active run budget record of APP, or nil."
  (kargu-application-budget (kargu-application-context app)))

(defun kargu-application-set-budget (budget &optional app)
  "Set BUDGET as the active run budget on APP."
  (let ((target (kargu-application-context app)))
    (setf (kargu-application-budget target) budget)
    budget))

(provide 'kargu/application/coordinator)

;;; coordinator.el ends here
