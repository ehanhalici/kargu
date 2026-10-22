;;; jobs.el --- Bounded live output and shell job control -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Foreground and background jobs share one process runner and live log.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/tools/process)
(require 'kargu/permission)
(require 'kargu/async)

(defvar kargu-bash-timeout)
(defcustom kargu-bash-completed-jobs 20
  "Maximum completed, non-displayed shell logs to retain."
  :type 'natnum :group 'kargu-bash)

(cl-defstruct (kargu-job-service (:constructor kargu-job-service--create))
  "Owned job management service per project root."
  (id (format "job-svc-%06x" (random #xffffff)) :read-only t)
  (project-root nil)
  (counter 0)
  (jobs (make-hash-table :test #'equal))
  (active-async-proc nil)
  (completed-limit 20))

(defvar kargu-job--services (make-hash-table :test #'equal)
  "Table of `kargu-job-service' instances keyed by canonical project root.")

(defvar kargu-job--default-service nil
  "Default fallback `kargu-job-service' when no project root is set.")

(defun kargu-job-service-for-project (&optional root)
  "Get or create the `kargu-job-service' for ROOT (default: project root)."
  (let* ((proj-root (or root (and (fboundp 'kargu-permission-project-root)
                                  (kargu-permission-project-root))))
         (canonical (and proj-root (file-name-as-directory (file-truename proj-root)))))
    (if canonical
        (or (gethash canonical kargu-job--services)
            (let ((svc (kargu-job-service--create
                        :project-root canonical
                        :completed-limit kargu-bash-completed-jobs)))
              (puthash canonical svc kargu-job--services)
              svc))
      (or kargu-job--default-service
          (setq kargu-job--default-service
                (kargu-job-service--create
                 :project-root nil
                 :completed-limit kargu-bash-completed-jobs))))))

;; Backwards compatibility bridge variables
(defvar kargu-bash--counter 0 "Compatibility alias for monotonic shell job counter.")
(defvar kargu-bash--processes (make-hash-table :test #'equal)
  "Compatibility table of shell jobs keyed by stable identifiers.")
(defvar kargu-bash--active-async-proc nil
  "Compatibility handle for active foreground process.")
(defvar-local kargu-bash--buffer-job nil "Job displayed in this output buffer.")

(defun kargu-job-services-reset ()
  "Cancel owned jobs before resetting registered services and legacy tables."
  (dolist (service (hash-table-values kargu-job--services))
    (kargu-job-service-close service))
  (when kargu-job--default-service (kargu-job-service-close kargu-job--default-service))
  (clrhash kargu-job--services)
  (setq kargu-job--default-service nil)
  (clrhash kargu-bash--processes)
  (setq kargu-bash--counter 0)
  (setq kargu-bash--active-async-proc nil))

(cl-defstruct (kargu-bash--job (:constructor kargu-bash--make-job))
  "A shell job and its bounded output buffer."
  id command directory root service process pgid buffer started ended-at background result (state :starting))

(defun kargu-job-service-close (service)
  "Cancel and detach only SERVICE's registered jobs."
  (maphash
   (lambda (id job)
     (when (kargu-bash--job-p job)
       (setf (kargu-bash--job-state job) :cancelled)
       (when-let* ((process (kargu-bash--job-process job)))
         (kargu-process-cancel process))
       (when (eq job (gethash id kargu-bash--processes))
         (remhash id kargu-bash--processes))))
   (kargu-job-service-jobs service))
  (clrhash (kargu-job-service-jobs service))
  (setf (kargu-job-service-active-async-proc service) nil)
  (when (eq service (gethash (kargu-job-service-project-root service) kargu-job--services))
    (remhash (kargu-job-service-project-root service) kargu-job--services)))

(defvar-keymap kargu-bash-output-mode-map
  :parent special-mode-map
  "C-c C-k" #'kargu-bash-cancel-process)

(define-derived-mode kargu-bash-output-mode special-mode "Kargu Job"
  "View bounded live shell output and cancel jobs using its command map."
  (setq-local buffer-offer-save nil
              header-line-format '(:eval (kargu-bash--job-header kargu-bash--buffer-job))))

(defun kargu-bash--job-header (job)
  "Return a status line describing JOB."
  (when job
    (format "[%s] %s | %.1fs | %s | C-c C-k cancels"
            (kargu-bash--job-id job) (kargu-bash--job-state job)
            (- (or (kargu-bash--job-ended-at job) (float-time))
               (kargu-bash--job-started job))
            (kargu-bash--job-command job))))

(defun kargu-bash--owned-job-p (job)
  "Return non-nil when JOB belongs to the current project."
  (and (kargu-bash--job-p job)
       (equal (kargu-bash--job-root job) (kargu-permission-project-root))))

(defun kargu-bash--find-job (id &optional service)
  "Find job ID within the current project or SERVICE.
Signal an actionable error if not found or not owned."
  (let* ((svc (or service (kargu-job-service-for-project)))
         (table (if svc (kargu-job-service-jobs svc) kargu-bash--processes))
         (job (or (gethash id table) (gethash id kargu-bash--processes))))
    (unless (and job (kargu-bash--owned-job-p job))
      (error "No background process or foreground job found with ID '%s'" id))
    job))

(defun kargu-bash--prune-table (table limit)
  "Prune completed logs from TABLE to LIMIT, preserving visible or edited buffers."
  (let (completed)
    (maphash (lambda (_id job)
               (when (and (kargu-bash--job-p job)
                          (not (memq (kargu-bash--job-state job) '(:starting :running))))
                 (push job completed))) table)
    (dolist (job (nthcdr limit (sort completed
                                   (lambda (a b) (> (kargu-bash--job-started a)
                                                    (kargu-bash--job-started b))))))
      (let ((buffer (kargu-bash--job-buffer job)) (id (kargu-bash--job-id job)))
        (unless (and (buffer-live-p buffer)
                     (or (get-buffer-window buffer t)
                         (buffer-modified-p buffer)
                         (buffer-local-value 'buffer-file-name buffer)))
          (when (buffer-live-p buffer) (kill-buffer buffer))
          (remhash id table)
          (when (eq job (gethash id kargu-bash--processes))
            (remhash id kargu-bash--processes)))))))

(defun kargu-bash--prune-jobs (&optional service)
  "Prune only SERVICE's logs, or the legacy aggregate when SERVICE is nil."
  (kargu-bash--prune-table
   (if service (kargu-job-service-jobs service) kargu-bash--processes)
   (if service (min (kargu-job-service-completed-limit service) kargu-bash-completed-jobs)
     kargu-bash-completed-jobs)))

(defun kargu-bash--job-finished (job result callback)
  "Complete JOB with RESULT, then deliver its formatted result to CALLBACK."
  (setf (kargu-bash--job-result job)
        (list :code (plist-get result :code) :timed-out (plist-get result :timed-out)
              :truncated (plist-get result :truncated)))
  (setf (kargu-bash--job-ended-at job) (float-time))
  (unless (eq (kargu-bash--job-state job) :cancelled)
    (setf (kargu-bash--job-state job) :done))
  (let ((proc (kargu-bash--job-process job))
        (svc (kargu-bash--job-service job)))
    (when (and svc (eq proc (kargu-job-service-active-async-proc svc)))
      (setf (kargu-job-service-active-async-proc svc) nil))
    (when (eq proc kargu-bash--active-async-proc)
      (setq kargu-bash--active-async-proc nil)))
  (force-mode-line-update t)
  (when callback
    (funcall callback
             (format "%s%s\nexit %s\ncwd: %s\n%s"
                     (if (plist-get result :timed-out) "ERROR: bash timed out\n" "")
                     (kargu-bash--job-header job) (plist-get result :code)
                     (kargu-bash--job-directory job)
                     (concat (if (plist-get result :truncated)
                                 "[output truncated; recent tail retained in live log]\n" "")
                             (or (plist-get result :output) "")))))
  (kargu-bash--prune-jobs (kargu-bash--job-service job)))

(defun kargu-bash--started-text (job)
  "Return the startup status of background JOB."
  (let ((proc (kargu-bash--job-process job)) (id (kargu-bash--job-id job)))
    (if proc
        (format "Process started in background: ID=[%s], PID=%s. View %s; status %s / kill %s."
                id (process-id proc) (buffer-name (kargu-bash--job-buffer job)) id id)
      "ERROR: Shell job could not start; check its output buffer.")))

(cl-defun kargu-bash-start-job (command directory shell &key background callback)
  "Run COMMAND in DIRECTORY using SHELL with bounded, persistent output.
BACKGROUND jobs return a status message; CALLBACK receives foreground results."
  (let* ((root (kargu-permission-project-root))
         (service (kargu-job-service-for-project root))
         (id (format "p%d" (cl-incf kargu-bash--counter)))
         (buffer (generate-new-buffer (format "*kargu-proc-%s*" id)))
         (job (kargu-bash--make-job
               :id id :command command :directory directory
               :root root :service service :buffer buffer
               :started (float-time) :background background)))
    (cl-incf (kargu-job-service-counter service))
    (puthash id job (kargu-job-service-jobs service))
    (puthash id job kargu-bash--processes)
    (with-current-buffer buffer
      (kargu-bash-output-mode)
      (setq-local default-directory directory kargu-bash--buffer-job job
                  kargu-permission--override-root (kargu-bash--job-root job)))
    (let ((proc (kargu-process-run
                 shell (list "-c" command)
                 (lambda (result) (kargu-bash--job-finished job result callback))
                 :dir directory :timeout kargu-bash-timeout :output-policy 'tail
                 :stderr 'merge
                 :buffer buffer :keep-buffer t)))
      (setf (kargu-bash--job-process job) proc)
      (when (and kargu-execution--current kargu-async--current-task (not background))
        (kargu-async-add-cleanup kargu-async--current-task
                                 (lambda ()
                                   (when (memq (kargu-bash--job-state job) '(:starting :running))
                                     (kargu-job-cancel job)))))
      (when (process-live-p proc)
        (setf (kargu-bash--job-pgid job) (process-id proc))
        (set-process-buffer proc buffer)
        (setf (kargu-bash--job-state job) :running)
        (unless background
          (setf (kargu-job-service-active-async-proc service) proc)
          (setq kargu-bash--active-async-proc proc)))
      (if background
          (kargu-bash--started-text job)
        (message "Kargu: job [%s], live output %s; C-c C-k stops it" id (buffer-name buffer))
        proc))))

(defun kargu-job-cancel (job &optional grace-seconds)
  "Cancel JOB immediately, or optionally interrupt for GRACE-SECONDS first.
Force a graceful cancellation only while its original process is still live;
an exited parent does not prove that every descendant exited."
  (when (kargu-bash--job-p job)
    (setf (kargu-bash--job-state job) :cancelled)
    (let ((proc (kargu-bash--job-process job))
          (grace (or grace-seconds 0)))
      (when proc
        (kargu-process-cancel proc grace))
      (when-let* ((svc (kargu-bash--job-service job)))
        (when (eq (kargu-job-service-active-async-proc svc) proc)
          (setf (kargu-job-service-active-async-proc svc) nil)))
      (when (eq kargu-bash--active-async-proc proc)
        (setq kargu-bash--active-async-proc nil)))))

(defun kargu-bash-kill-active-async ()
  "Cancel the active foreground process and its child process group."
  (let* ((svc (kargu-job-service-for-project))
         (proc (kargu-job-service-active-async-proc svc)))
    (when proc
      (when svc
        (maphash (lambda (_id job)
                   (when (and (kargu-bash--job-p job)
                              (eq (kargu-bash--job-process job) proc))
                     (setf (kargu-bash--job-state job) :cancelled)))
                 (kargu-job-service-jobs svc))
        (setf (kargu-job-service-active-async-proc svc) nil))
      (maphash (lambda (_id job)
                 (when (and (kargu-bash--job-p job)
                            (eq (kargu-bash--job-process job) proc))
                   (setf (kargu-bash--job-state job) :cancelled)))
               kargu-bash--processes)
      (kargu-process-cancel proc)
      (setq kargu-bash--active-async-proc nil))))

(defun kargu-bash-show-process (id)
  "Display the bounded live output of job ID."
  (interactive (list (completing-read "Shell job: " (hash-table-keys kargu-bash--processes) nil t)))
  (pop-to-buffer (kargu-bash--job-buffer (kargu-bash--find-job id))))

(defun kargu-bash-cancel-process (&optional id)
  "Cancel job ID, or the job displayed in the current output buffer."
  (interactive)
  (let* ((target (or id (and kargu-bash--buffer-job
                             (kargu-bash--job-id kargu-bash--buffer-job))
                     (completing-read "Cancel job: " (hash-table-keys kargu-bash--processes) nil t)))
         (job (kargu-bash--find-job target)))
    (kargu-job-cancel job)
    (force-mode-line-update t)))

(defun kargu-bash--job-status (job)
  "Describe JOB and its recent output without changing the selected buffer."
  (let ((buffer (kargu-bash--job-buffer job)))
    (format "[%s] %s\n%s"
            (kargu-bash--job-id job)
            (if (process-live-p (kargu-bash--job-process job)) "RUNNING" "EXITED")
            (if (not (buffer-live-p buffer)) "(output buffer closed)"
              (with-current-buffer buffer
                (save-excursion
                  (goto-char (point-max))
                  (forward-line -25)
                  (buffer-substring-no-properties (point) (point-max))))))))

(defun kargu-bash-manage-job (command)
  "Handle COMMAND as list/status/kill management, returning nil otherwise."
  (save-match-data
    (condition-case err
        (cond
         ((equal (string-trim command) "list")
          (let* ((svc (kargu-job-service-for-project))
                 (table (if svc (kargu-job-service-jobs svc) kargu-bash--processes))
                 lines)
            (maphash (lambda (_id job)
                       (when (kargu-bash--owned-job-p job)
                         (push (kargu-bash--job-header job) lines)))
                     table)
            (string-join (or (nreverse lines) '("No active background processes.")) "\n")))
         ((string-match (rx string-start (group (or "status" "kill")) " "
                            (group "p" (+ digit)) string-end) (string-trim command))
          (let* ((action (match-string 1 (string-trim command)))
                 (id (match-string 2 (string-trim command)))
                 (job (kargu-bash--find-job id)))
            (if (equal action "status")
                (kargu-bash--job-status job)
              (kargu-job-cancel job)
              (when (buffer-live-p (kargu-bash--job-buffer job))
                (kill-buffer (kargu-bash--job-buffer job)))
              (when-let* ((svc (kargu-bash--job-service job)))
                (remhash id (kargu-job-service-jobs svc)))
              (remhash id kargu-bash--processes)
              (format "Process [%s] terminated." id)))))
      (error (concat "ERROR: " (error-message-string err))))))

(provide 'kargu/tools/bash/jobs)
;;; jobs.el ends here
