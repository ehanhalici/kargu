;;; jobs.el --- Owned Rust job transport handles -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; No OS child, PID signals or output archive is owned by Emacs here.
;; The client installs source-owner cleanup before claiming a startup receipt.

;;; Code:

(require 'kargu/bridge/approval)

(cl-defstruct (kargu-bridge-job (:constructor kargu-bridge-job--create))
  "One native job identity and its captured client-side cleanup resources."
  connection id pid root scope owner session owner-cleanup
  (state :claiming) timer cleanup-deadline on-close)

(defun kargu-bridge-job--params (job &optional extras)
  "Build JOB's immutable wire owner and append EXTRAS."
  (let ((params (kargu-bridge--object
                 "owner" (kargu-bridge--object "scope" (kargu-bridge-job-scope job) "root" (kargu-bridge-job-root job))
                 "job_id" (kargu-bridge-job-id job))))
    (dolist (pair extras) (puthash (car pair) (cdr pair) params))
    params))

(defun kargu-bridge-job--call (job method callback &optional extras cleanup)
  "Call METHOD for JOB with CALLBACK and EXTRAS; CLEANUP may outlive its source."
  (let ((connection (kargu-bridge-job-connection job)))
    (if (not (and (eq (kargu-bridge-status connection) 'ready)
                  (not (memq (kargu-bridge-job-state job) '(:forgotten :disconnected)))
                  (or cleanup
                      (and (buffer-live-p (kargu-bridge-job-owner job))
                           (eq (kargu-bridge-job-session job) (kargu-session-context (kargu-bridge-job-owner job)))))))
        (progn (kargu-bridge--callback callback nil (kargu-bridge--fault "stale_owner")) nil)
      (kargu-bridge-call connection method (kargu-bridge-job--params job extras)
                         callback :owner (unless cleanup (kargu-bridge-job-owner job)) :timeout 15))))

(defun kargu-bridge-job--detach (job)
  "Release JOB's source hooks and cleanup timer without touching another job."
  (when (timerp (kargu-bridge-job-timer job)) (cancel-timer (kargu-bridge-job-timer job)))
  (setf (kargu-bridge-job-timer job) nil)
  (when (buffer-live-p (kargu-bridge-job-owner job))
    (with-current-buffer (kargu-bridge-job-owner job)
      (remove-hook 'kill-buffer-hook (kargu-bridge-job-owner-cleanup job) t)
      (remove-hook 'change-major-mode-hook (kargu-bridge-job-owner-cleanup job) t))))

(defun kargu-bridge-job--disconnect (job status)
  "End JOB's client resources with STATUS; native cleanup is not invented."
  (unless (memq (kargu-bridge-job-state job) '(:forgotten :disconnected))
    (kargu-bridge-job--detach job)
    (setf (kargu-bridge-job-state job) (if status :disconnected :forgotten))
    (remhash (kargu-bridge-job-id job) (kargu-bridge-connection-jobs (kargu-bridge-job-connection job)))
    (let ((callback (kargu-bridge-job-on-close job)))
      (setf (kargu-bridge-job-on-close job) nil)
      (kargu-bridge--callback callback nil (and status (kargu-bridge--fault status))))))

(defun kargu-bridge-job-dispose (job)
  "Cancel and drain JOB after source closure, then forget only its native archive."
  (unless (memq (kargu-bridge-job-state job) '(:disposing :forgotten :disconnected))
    (kargu-bridge-job--detach job)
    (setf (kargu-bridge-job-state job) :disposing
          (kargu-bridge-job-cleanup-deadline job) (+ (float-time) 15))
    (kargu-bridge-job--call job "job/cancel"
                           (lambda (_result _error) (kargu-bridge-job--drain job)) nil t)))

(defun kargu-bridge-job--drain (job)
  "Poll cleanup of JOB without source ownership or blocking the editor."
  (when (eq (kargu-bridge-job-state job) :disposing)
    (if (>= (float-time) (kargu-bridge-job-cleanup-deadline job))
        (kargu-bridge-job--disconnect job "cleanup_unconfirmed")
      (kargu-bridge-job--call
       job "job/status"
       (lambda (result error-data)
         (cond
          (error-data (kargu-bridge-job--disconnect job "cleanup_unconfirmed"))
          ((and (hash-table-p result) (equal (gethash "state" result) "exited"))
           (kargu-bridge-job--call job "job/forget"
                                  (lambda (_value failure) (kargu-bridge-job--disconnect job (and failure "cleanup_unconfirmed"))) nil t))
          (t (setf (kargu-bridge-job-timer job) (run-at-time 0.05 nil #'kargu-bridge-job--drain job))))) nil t))))

(defun kargu-bridge-job--adopt (connection receipt root owner callback)
  "Bind RECEIPT to CONNECTION, ROOT and OWNER before invoking CALLBACK."
  (if (not (buffer-live-p owner))
      (kargu-bridge--callback callback nil (kargu-bridge--fault "stale_owner"))
  (let* ((id (and (hash-table-p receipt) (gethash "job_id" receipt)))
         (job (and (stringp id) (string-prefix-p "job_" id)
                   (kargu-bridge-job--create
                    :connection connection :id id :pid (gethash "process_id" receipt)
                    :root root :scope (kargu-bridge-approval--copy (kargu-bridge-connection-read-scope connection))
                    :owner owner :session (kargu-session-context owner)))))
    (if (not job) (kargu-bridge--callback callback nil (kargu-bridge--fault "protocol_error"))
      (setf (kargu-bridge-job-owner-cleanup job) (lambda () (kargu-bridge-job-dispose job)))
      (puthash id job (kargu-bridge-connection-jobs connection))
      (with-current-buffer owner
        (add-hook 'kill-buffer-hook (kargu-bridge-job-owner-cleanup job) nil t)
        (add-hook 'change-major-mode-hook (kargu-bridge-job-owner-cleanup job) nil t))
      (kargu-bridge-job--call
       job "job/claim"
       (lambda (result error-data)
         (if (or error-data (not (hash-table-p result)) (not (eq (gethash "claimed" result) t))
                 (not (eq (kargu-bridge-job-state job) :claiming)))
             (progn (kargu-bridge-job-dispose job)
                    (kargu-bridge--callback callback nil (or error-data (kargu-bridge--fault "stale_owner"))))
           (setf (kargu-bridge-job-state job) :running)
           (kargu-bridge--callback callback job nil))))))))

(cl-defun kargu-bridge-job-start (connection arguments callback &key owner valid-p)
  "Start explicit ARGUMENTS on CONNECTION; CALLBACK receives (JOB ERROR).
Install OWNER cleanup before claiming startup; OWNER defaults to current buffer."
  (let* ((owner (or owner (current-buffer)))
         (snapshot (kargu-bridge-approval--copy arguments))
         (root (directory-file-name (file-truename (gethash "root" snapshot)))))
    (kargu-bridge-approval-execute
     connection snapshot
     (lambda (result error-data)
       (if error-data (kargu-bridge--callback callback nil error-data)
         (kargu-bridge-job--adopt connection result root owner callback)))
     :owner owner :method "job/start" :capability "process_jobs" :purpose "process_job" :valid-p valid-p)))

(defun kargu-bridge-job-status (job callback)
  "Asynchronously deliver JOB's native snapshot to CALLBACK."
  (kargu-bridge-job--call job "job/status" callback))
(defun kargu-bridge-job-read (job stream cursor callback)
  "Read a lossless byte page of JOB's STREAM at CURSOR through CALLBACK."
  (kargu-bridge-job--call job "job/read" callback `(("stream" . ,stream) ("cursor" . ,cursor))))
(defun kargu-bridge-job-write (job text callback)
  "Send bounded TEXT to JOB, acknowledging through CALLBACK without retry."
  (kargu-bridge-job--call job "job/write" callback `(("text" . ,text))))
(defun kargu-bridge-job-eof (job callback)
  "Close JOB's stdin; deliver actual native acceptance to CALLBACK."
  (kargu-bridge-job--call job "job/eof" callback))
(defun kargu-bridge-job-cancel (job callback)
  "Request JOB's owned process-group cancellation through CALLBACK."
  (if (memq (kargu-bridge-job-state job) '(:forgotten :disconnected :disposing))
      (kargu-bridge--callback callback nil (kargu-bridge--fault "stale_owner"))
    (setf (kargu-bridge-job-state job) :closing)
    (kargu-bridge-job--call job "job/cancel" callback)))
(defun kargu-bridge-job-forget (job callback)
  "Forget only JOB's completed native archive and deliver CALLBACK."
  (kargu-bridge-job--call
   job "job/forget" (lambda (result error-data)
                      (unless error-data (kargu-bridge-job--disconnect job nil))
                      (kargu-bridge--callback callback result error-data))))

(provide 'kargu/bridge/jobs)
;;; jobs.el ends here
