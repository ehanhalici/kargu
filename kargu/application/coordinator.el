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

(defvar kargu--loop-run nil)
(defvar kargu--busy nil)
(defvar kargu--generation 0)
(defvar kargu--current-process nil)

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
  (state :pending)
  (process nil)
  (retry-timer nil)
  (stream-timer nil))

(cl-defun kargu-logical-request-create (&key id (generation 0) session origin
                                             (state :pending) process
                                             retry-timer stream-timer)
  "Create a validated `kargu-logical-request' record.
ID, GENERATION, SESSION, ORIGIN, STATE, PROCESS, RETRY-TIMER and
STREAM-TIMER initialize the owned fields."
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
  (when (kargu-logical-request-p request)
    (kargu-logical-request-cancel-retry-timer request)
    (setf (kargu-logical-request-retry-timer request) timer
          (kargu-logical-request-state request) :retrying)
    timer))

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
    (kargu-logical-request-cancel-retry-timer request)
    (kargu-logical-request-cancel-stream-timer request)
    (let ((process (kargu-logical-request-process request)))
      (setf (kargu-logical-request-process request) nil)
      (when (and (processp process) (process-live-p process))
        (ignore-errors (delete-process process))))))

(defun kargu-logical-request-finish (request)
  "Mark REQUEST finished and release any remaining timers."
  (when (kargu-logical-request-p request)
    (unless (eq (kargu-logical-request-state request) :cancelled)
      (setf (kargu-logical-request-state request) :finished))
    (kargu-logical-request-cancel-retry-timer request)
    (kargu-logical-request-cancel-stream-timer request)
    (setf (kargu-logical-request-process request) nil)))

;;;; Application coordinator -----------------------------------------------

(cl-defstruct (kargu-application
               (:constructor kargu-application--create))
  "Owned application coordinator for single-run and lifecycle state."
  (status :idle)
  (active-run nil)
  (active-request nil)
  (generation 0))

(cl-defun kargu-application-create (&key (status :idle) active-run
                                         active-request (generation 0))
  "Create a validated `kargu-application' coordinator record.
STATUS, ACTIVE-RUN, ACTIVE-REQUEST and GENERATION initialize the fields."
  (kargu-contract-assert #'keywordp status "STATUS must be a keyword: %S" status)
  (kargu-contract-assert #'integerp generation
                         "GENERATION must be an integer: %S" generation)
  (kargu-application--create
   :status status
   :active-run active-run
   :active-request active-request
   :generation generation))

(defvar kargu-application--context nil
  "Owned default application coordinator instance, initialized on demand.")

(defun kargu-application-context (&optional app)
  "Return explicit APP, or the lazily initialized application coordinator."
  (if app
      (progn
        (kargu-contract-assert #'kargu-application-p app)
        app)
    (unless (kargu-application-p kargu-application--context)
      (setq kargu-application--context (kargu-application-create)))
    kargu-application--context))

(defun kargu-application-current-status (&optional app)
  "Return the lifecycle status keyword of APP or the active coordinator."
  (kargu-application-status (kargu-application-context app)))

(defun kargu-application-set-status (status &optional app)
  "Set the lifecycle STATUS keyword on APP or the active coordinator."
  (kargu-contract-assert #'keywordp status "STATUS must be a keyword: %S" status)
  (let ((target (kargu-application-context app)))
    (setf (kargu-application-status target) status)
    status))

(defun kargu-application-current-run (&optional app)
  "Return the active run record for APP or the active coordinator."
  (if app
      (kargu-application-active-run (kargu-application-context app))
    (or kargu--loop-run
        (kargu-application-active-run (kargu-application-context)))))

(defun kargu-application-set-active-run (run &optional app)
  "Set RUN as the active run on APP or the active coordinator."
  (let ((target (kargu-application-context app)))
    (setf (kargu-application-active-run target) run)
    (unless app
      (setq kargu--loop-run run))
    run))

(defun kargu-application-current-request (&optional app)
  "Return the active `kargu-logical-request' on APP, or nil."
  (kargu-application-active-request (kargu-application-context app)))

(defun kargu-application-set-active-request (request &optional app)
  "Set REQUEST as the active `kargu-logical-request' on APP."
  (kargu-contract-assert
   (lambda (r) (or (null r) (kargu-logical-request-p r)))
   request "REQUEST must be a kargu-logical-request or nil: %S" request)
  (let ((target (kargu-application-context app)))
    (setf (kargu-application-active-request target) request)
    request))

(defun kargu-application-current-generation (&optional app)
  "Return the current request generation integer for APP."
  (if app
      (kargu-application-generation (kargu-application-context app))
    kargu--generation))

(defun kargu-application-next-generation (&optional app)
  "Advance and return the request generation integer for APP."
  (let ((target (kargu-application-context app)))
    (if app
        (cl-incf (kargu-application-generation target))
      (let ((next (cl-incf kargu--generation)))
        (setf (kargu-application-generation target) next)
        next))))

(defun kargu-application-work-active-p (&optional app)
  "Return non-nil when APP has an active agent run or transport request."
  (if app
      (let ((target (kargu-application-context app)))
        (or (not (null (kargu-application-active-run target)))
            (kargu-logical-request-live-p
             (kargu-application-active-request target)
             (kargu-application-generation target))))
    (or (not (null (kargu-application-current-run)))
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
    (setf (kargu-application-status target) :idle)
    (when (null (and (not app) kargu--loop-run))
      (setf (kargu-application-active-run target) nil))
    (when (null (and (not app) kargu--busy))
      (setf (kargu-application-active-request target) nil))
    target))

(provide 'kargu/application/coordinator)

;;; coordinator.el ends here
