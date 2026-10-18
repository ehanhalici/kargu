;;; jobs.el --- Bounded live output and shell job control -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Foreground and background jobs share one process runner and live log.

;;; Code:

(require 'kargu/tools/process)
(require 'kargu/permission)

(defvar kargu-bash-timeout)
(defvar kargu-bash--counter 0 "Monotonic shell job identifier.")
(defvar kargu-bash--processes (make-hash-table :test #'equal)
  "Shell jobs keyed by stable identifiers.")
(defvar kargu-bash--active-async-proc nil
  "The foreground tool process, or nil when no foreground job runs.")
(defvar-local kargu-bash--buffer-job nil "Job displayed in this output buffer.")

(defcustom kargu-bash-completed-jobs 20
  "Maximum completed, non-displayed shell logs to retain."
  :type 'natnum :group 'kargu-bash)

(cl-defstruct (kargu-bash--job (:constructor kargu-bash--make-job))
  "A shell job and its bounded output buffer."
  id command directory root process buffer started ended-at background result (state :starting))

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
  (equal (kargu-bash--job-root job) (kargu-permission-project-root)))

(defun kargu-bash--find-job (id)
  "Find job ID within the current project, or signal an actionable error."
  (let ((job (gethash id kargu-bash--processes)))
    (unless (and job (kargu-bash--owned-job-p job))
      (error "No background process or foreground job found with ID '%s'" id))
    job))

(defun kargu-bash--prune-jobs ()
  "Release old completed job logs, retaining displayed and running jobs."
  (let (completed)
    (maphash (lambda (_id job)
               (unless (memq (kargu-bash--job-state job) '(:starting :running))
                 (push job completed))) kargu-bash--processes)
    (dolist (job (nthcdr kargu-bash-completed-jobs
                         (sort completed (lambda (a b) (> (kargu-bash--job-started a)
                                                          (kargu-bash--job-started b))))))
      (let ((buffer (kargu-bash--job-buffer job)))
        (unless (and (buffer-live-p buffer) (get-buffer-window buffer t))
          (when (buffer-live-p buffer) (kill-buffer buffer))
          (remhash (kargu-bash--job-id job) kargu-bash--processes))))))

(defun kargu-bash--job-finished (job result callback)
  "Complete JOB with RESULT, then deliver its formatted result to CALLBACK."
  (setf (kargu-bash--job-result job)
        (list :code (plist-get result :code) :timed-out (plist-get result :timed-out)
              :truncated (plist-get result :truncated)))
  (setf (kargu-bash--job-ended-at job) (float-time))
  (unless (eq (kargu-bash--job-state job) :cancelled)
    (setf (kargu-bash--job-state job) :done))
  (when (eq (kargu-bash--job-process job) kargu-bash--active-async-proc)
    (setq kargu-bash--active-async-proc nil))
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
  (kargu-bash--prune-jobs))

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
  (let* ((id (format "p%d" (cl-incf kargu-bash--counter)))
         (buffer (generate-new-buffer (format "*kargu-proc-%s*" id)))
         (job (kargu-bash--make-job
               :id id :command command :directory directory
               :root (kargu-permission-project-root) :buffer buffer
               :started (float-time) :background background)))
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
      (when (process-live-p proc)
        (set-process-buffer proc buffer)
        (setf (kargu-bash--job-state job) :running)
        (unless background (setq kargu-bash--active-async-proc proc)))
      (if background
          (kargu-bash--started-text job)
        (message "Kargu: job [%s], live output %s; C-c C-k stops it" id (buffer-name buffer))
        proc))))

(defun kargu-bash-kill-active-async ()
  "Cancel the active foreground process and its child process group."
  (when kargu-bash--active-async-proc
    (maphash (lambda (_id job)
               (when (eq (kargu-bash--job-process job) kargu-bash--active-async-proc)
                 (setf (kargu-bash--job-state job) :cancelled))) kargu-bash--processes)
    (kargu-process-cancel kargu-bash--active-async-proc)
    (setq kargu-bash--active-async-proc nil)))

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
    (setf (kargu-bash--job-state job) :cancelled)
    (kargu-process-cancel (kargu-bash--job-process job))
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
          (let (lines)
            (maphash (lambda (_id job)
                       (when (kargu-bash--owned-job-p job)
                         (push (kargu-bash--job-header job) lines))) kargu-bash--processes)
            (string-join (or (nreverse lines) '("No active background processes.")) "\n")))
         ((string-match (rx string-start (group (or "status" "kill")) " "
                            (group "p" (+ digit)) string-end) (string-trim command))
          (let* ((action (match-string 1 (string-trim command)))
                 (id (match-string 2 (string-trim command)))
                 (job (kargu-bash--find-job id)))
            (if (equal action "status") (kargu-bash--job-status job)
              (kargu-bash-cancel-process id)
              (when (buffer-live-p (kargu-bash--job-buffer job))
                (kill-buffer (kargu-bash--job-buffer job)))
              (remhash id kargu-bash--processes)
              (format "Process [%s] terminated." id)))))
      (error (concat "ERROR: " (error-message-string err))))))

(provide 'kargu/tools/bash/jobs)
;;; jobs.el ends here
