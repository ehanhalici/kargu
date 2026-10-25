;;; execution.el --- Captured native execution boundary -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A run captures authority once.  Continuations re-enter that boundary,
;; never whichever buffer or default application happens to be current.
;; Algorithmic loop data remains in the existing run record.

;;; Code:

(require 'kargu/application/coordinator)
(require 'kargu/core/session)
(require 'kargu/async)
(require 'kargu/config/connection)

(defvar kargu--state-store)
(defvar kargu-execution--current nil
  "Dynamically bound execution context, never a retained runtime singleton.")

(cl-defstruct (kargu-execution (:constructor kargu-execution--create))
  "Captured APP, CLAIM, SESSION, ORIGIN, ROOT and RUN with their TASK lifetime."
  (app nil :read-only t) claim (session nil :read-only t)
  (origin nil :read-only t) (root nil :read-only t)
  (run nil :read-only t) task enter connection budget
  (metadata-legacy (or kargu-metadata--legacy
                       (null (or kargu-application--bound kargu-application-owner))))
  (state :starting))

(cl-defun kargu-execution-create (&key app session origin root run)
  "Capture validated APP, SESSION, ORIGIN, ROOT and RUN for native execution."
  (kargu-contract-assert #'kargu-application-p app)
  (kargu-contract-assert #'kargu-session-p session)
  (kargu-contract-assert #'buffer-live-p origin)
  (kargu-contract-assert #'stringp root)
  (kargu-contract-assert #'consp run)
  (unless (eq session (kargu-session-context origin))
    (user-error "Kargu: execution session was replaced before admission"))
  (kargu-execution--create :app app :session session :origin origin :root root :run run))

(defun kargu-execution-prepare (context)
  "Capture CONTEXT's one API budget before any asynchronous run preparation."
  (let ((budget (kargu-budget-create :run-id (plist-get (kargu-execution-run context) :id))))
    (setf (kargu-execution-budget context) budget)
    (kargu-application-set-budget budget (kargu-execution-app context))))

(defun kargu-execution-request-started ()
  "Publish first-request admission in the current execution, exactly once."
  (when kargu-execution--current
    (let ((run (kargu-execution-run kargu-execution--current)))
      (plist-put run :request-started t)
      (when-let* ((callback (plist-get run :on-ready)))
        (plist-put run :on-ready nil)
        (funcall callback t nil)))))

(defun kargu-execution-live-p (context)
  "Return non-nil while CONTEXT owns its exact application claim."
  (and (kargu-execution-p context)
       (memq (kargu-execution-state context) '(:starting :running))
       (eq (kargu-execution-claim context)
           (kargu-application-active-claim-token (kargu-execution-app context)))
       (eq (kargu-execution-run context)
           (kargu-application-current-run (kargu-execution-app context)))))

(defun kargu-execution-call (context function &rest args)
  "Call FUNCTION with ARGS inside captured CONTEXT, including during cleanup."
  (unwind-protect
      (kargu-execution--call-owned context function args)
    (when (and (eq (kargu-execution-state context) :closed)
               (eq kargu--loop-run (kargu-execution-run context)))
      (setq kargu--loop-run nil))))

(defun kargu-execution--call-owned (context function args)
  "Apply FUNCTION to ARGS with CONTEXT's captured compatibility bindings."
  (let ((kargu-execution--current context)
        (kargu-application--bound (kargu-execution-app context))
        (kargu-application--context (kargu-execution-app context))
        (kargu--loop-run (kargu-execution-run context))
        (kargu--busy nil) (kargu--current-process nil)
        (kargu--generation (kargu-application-current-generation (kargu-execution-app context)))
        (kargu-async--current-task (kargu-execution-task context))
        (kargu--state-store nil)
        (kargu-connection--bound (kargu-execution-connection context))
        (kargu-metadata--legacy (kargu-execution-metadata-legacy context)))
    (save-match-data
      (with-current-buffer (if (buffer-live-p (kargu-execution-origin context))
                               (kargu-execution-origin context) (current-buffer))
        (let ((kargu-application-owner (kargu-execution-app context)))
          (if-let* ((enter (kargu-execution-enter context)))
              (funcall enter function args)
            (apply function args)))))))

(defun kargu-execution-wrap (context function)
  "Capture CONTEXT for FUNCTION and ignore obsolete continuations."
  (lambda (&rest args)
    (when (and (kargu-execution-live-p context)
               (buffer-live-p (kargu-execution-origin context))
               (eq (kargu-execution-session context)
                   (kargu-session-context (kargu-execution-origin context))))
      (apply #'kargu-execution-call context function args))))

(provide 'kargu/application/execution)
;;; execution.el ends here
