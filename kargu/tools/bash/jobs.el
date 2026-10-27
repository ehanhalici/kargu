;;; jobs.el --- Bounded live output and shell job control -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Editor views of Rust-owned jobs.  No OS child or process group lives here.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/tools/process)
(require 'kargu/permission)
(require 'kargu/async)

(declare-function kargu-bash-native-start "kargu/tools/bash/native" (command directory shell background callback))
(declare-function kargu-bridge-job-cancel "kargu/bridge/jobs" (job callback))
(declare-function kargu-bridge-job-dispose "kargu/bridge/jobs" (job))
(declare-function kargu-bridge-job-pid "kargu/bridge/jobs" (job))

(defvar kargu-bash-timeout)
(defcustom kargu-bash-completed-jobs 20
  "Maximum completed, non-displayed shell logs to retain."
  :type 'natnum :group 'kargu-bash)

(cl-defstruct (kargu-job-service (:constructor kargu-job-service--create))
  "Owned job views for one project, source buffer and session."
  (id (format "job-svc-%06x" (random #xffffff)) :read-only t)
  key origin session cleanup
  (project-root nil)
  (counter 0)
  (jobs (make-hash-table :test #'equal))
  (active-async-proc nil)
  (completed-limit 20))

(defvar kargu-job--services (make-hash-table :test #'equal)
  "Job services keyed by canonical root, source buffer and session identity.")

(defun kargu-job-service-for-project (&optional root)
  "Return this source buffer/session's job service for explicit ROOT."
  (let* ((root (or root (kargu-permission-project-root)))
         (_valid (unless (stringp root) (user-error "An explicit project root is required for jobs")))
         (canonical (file-name-as-directory (file-truename root)))
         (session (kargu-session-context))
         (key (list canonical (current-buffer) (copy-sequence (kargu-session-id session))))
         (existing (gethash key kargu-job--services)))
    (dolist (service (hash-table-values kargu-job--services))
      (when (and (eq (current-buffer) (kargu-job-service-origin service))
                 (not (eq session (kargu-job-service-session service))))
        (kargu-job-service-close service)))
    (when (and existing (not (eq session (kargu-job-service-session existing))))
      (kargu-job-service-close existing) (setq existing nil))
    (or existing
        (let ((service (kargu-job-service--create :key key :project-root canonical
                                                 :origin (current-buffer) :session session
                                                 :completed-limit kargu-bash-completed-jobs)))
          (let ((cleanup (lambda () (kargu-job-service-close service))))
            (setf (kargu-job-service-cleanup service) cleanup)
            (add-hook 'kill-buffer-hook cleanup nil t)
            (add-hook 'change-major-mode-hook cleanup nil t))
          (puthash key service kargu-job--services)
          service))))

(defvar-local kargu-bash--buffer-job nil "Job displayed in this output buffer.")

(defun kargu-job-services-reset ()
  "Cancel and detach registered owned services without legacy mirror tables."
  (dolist (service (hash-table-values kargu-job--services))
    (kargu-job-service-close service))
  (clrhash kargu-job--services))

(cl-defstruct (kargu-bash--job (:constructor kargu-bash--make-job))
  "An editor view of a native job, not process or signal authority."
  id command directory root service handle task reader buffer started ended-at
  background result limit truncated (state :starting))

(defun kargu-job-service-close (service)
  "Cancel and detach only SERVICE's registered jobs."
  (when-let* ((cleanup (kargu-job-service-cleanup service))
              (origin (kargu-job-service-origin service)) ((buffer-live-p origin)))
    (with-current-buffer origin
      (remove-hook 'kill-buffer-hook cleanup t)
      (remove-hook 'change-major-mode-hook cleanup t))
    (setf (kargu-job-service-cleanup service) nil))
  (maphash
   (lambda (_id job)
     (when (kargu-bash--job-p job)
       (kargu-job-cancel job)
       (when-let* ((handle (kargu-bash--job-handle job)))
         (kargu-bridge-job-dispose handle))))
   (kargu-job-service-jobs service))
  (clrhash (kargu-job-service-jobs service))
  (setf (kargu-job-service-active-async-proc service) nil)
  (when (eq service (gethash (kargu-job-service-key service) kargu-job--services))
    (remhash (kargu-job-service-key service) kargu-job--services)))

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
       (equal (kargu-bash--job-root job) (kargu-permission-project-root))
       (let ((service (kargu-bash--job-service job)))
         (and service (eq (kargu-job-service-origin service) (current-buffer))
              (eq (kargu-job-service-session service) (kargu-session-context))))))

(defun kargu-bash--find-job (id &optional service)
  "Find job ID within the current project or SERVICE.
Signal an actionable error if not found or not owned."
  (let* ((svc (or service (kargu-job-service-for-project)))
         (table (kargu-job-service-jobs svc))
         (job (gethash id table)))
    (unless (and job (kargu-bash--owned-job-p job))
      (error "No background process or foreground job found with ID '%s'" id))
    job))

(defun kargu-bash--prune-table (table limit)
  "Prune completed logs from TABLE to LIMIT, preserving visible or edited buffers."
  (let (completed)
    (maphash (lambda (_id job)
               (when (and (kargu-bash--job-p job)
                          (memq (kargu-bash--job-state job) '(:done :cancelled :failed)))
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
          (when-let* ((handle (kargu-bash--job-handle job)))
            (kargu-bridge-job-dispose handle))
          (remhash id table))))))

(defun kargu-bash--prune-jobs (&optional service)
  "Prune only SERVICE's owned views, defaulting to the current source."
  (let ((service (or service (kargu-job-service-for-project))))
    (kargu-bash--prune-table (kargu-job-service-jobs service)
                            (min (kargu-job-service-completed-limit service) kargu-bash-completed-jobs))))

(defun kargu-bash--job-finished (job result callback)
  "Complete JOB with RESULT, then deliver its formatted result to CALLBACK."
  (setf (kargu-bash--job-result job)
        (list :code (plist-get result :code) :timed-out (plist-get result :timed-out)
              :truncated (plist-get result :truncated)))
  (setf (kargu-bash--job-ended-at job) (float-time))
  (setf (kargu-bash--job-state job)
        (cond ((plist-get result :failure) :failed)
              ((eq (plist-get result :outcome) 'cancelled) :cancelled)
              (t :done)))
  (let ((proc (kargu-bash--job-handle job))
        (svc (kargu-bash--job-service job)))
    (when (and svc (eq proc (kargu-job-service-active-async-proc svc)))
      (setf (kargu-job-service-active-async-proc svc) nil)))
  (force-mode-line-update t)
  (when callback
    (funcall callback
             (format "%s%s\nexit %s\ncwd: %s\n%s"
                     (cond ((plist-get result :failure) (concat "ERROR: " (plist-get result :failure) "\n"))
                           ((plist-get result :timed-out) "ERROR: bash timed out\n")
                           (t ""))
                     (kargu-bash--job-header job) (plist-get result :code)
                     (kargu-bash--job-directory job)
                     (concat (if (plist-get result :truncated)
                                 "[output truncated; recent tail retained in live log]\n" "")
                             (or (plist-get result :output) "")))))
  (kargu-bash--prune-jobs (kargu-bash--job-service job)))

(defun kargu-bash--started-text (job)
  "Return the startup status of background JOB."
  (let ((handle (kargu-bash--job-handle job)) (id (kargu-bash--job-id job)))
    (if handle
        (format "Process started in background: ID=[%s], PID=%s. View %s; status %s / kill %s."
                id (kargu-bridge-job-pid handle) (buffer-name (kargu-bash--job-buffer job)) id id)
      "ERROR: Shell job could not start; check its output buffer.")))

(cl-defun kargu-bash-start-job (command directory shell &key background callback)
  "Start COMMAND in DIRECTORY with SHELL through the owned Rust adapter.
CALLBACK receives the real BACKGROUND receipt or foreground terminal text."
  (require 'kargu/tools/bash/native)
  (kargu-bash-native-start command directory shell background callback))

(defun kargu-job-cancel (job &optional _legacy-grace)
  "Request JOB cancellation; Rust owns TERM/grace/KILL and the drain decision."
  (when (kargu-bash--job-p job)
    (let ((proc (kargu-bash--job-handle job)))
      (when (memq (kargu-bash--job-state job) '(:starting :running))
        (setf (kargu-bash--job-state job) :cancelling)
        (if proc (kargu-bridge-job-cancel proc #'ignore)
          (when-let* ((task (kargu-bash--job-task job))) (kargu-async-cancel task))
          (setf (kargu-bash--job-state job) :failed
                (kargu-bash--job-ended-at job) (float-time)
                (kargu-bash--job-result job) '(:failure "Startup cancelled; native receipt unconfirmed"))))
      (when-let* ((svc (kargu-bash--job-service job)))
        (when (eq (kargu-job-service-active-async-proc svc) proc)
          (setf (kargu-job-service-active-async-proc svc) nil))))))

(defun kargu-bash-kill-active-async ()
  "Cancel only this source/session's active foreground job."
  (let* ((service (kargu-job-service-for-project))
         (handle (kargu-job-service-active-async-proc service)))
    (when handle
      (maphash (lambda (_id job)
                 (when (and (kargu-bash--job-p job) (eq handle (kargu-bash--job-handle job)))
                   (kargu-job-cancel job))) (kargu-job-service-jobs service)))))

(defun kargu-bash-show-process (id)
  "Display the bounded live output of job ID."
  (interactive (list (completing-read "Shell job: " (hash-table-keys (kargu-job-service-jobs (kargu-job-service-for-project))) nil t)))
  (pop-to-buffer (kargu-bash--job-buffer (kargu-bash--find-job id))))

(defun kargu-bash-cancel-process (&optional id)
  "Cancel source-owned job ID, or the exact job displayed in its output view."
  (interactive)
  (let ((job (if (and (null id) kargu-bash--buffer-job) kargu-bash--buffer-job
               (kargu-bash--find-job (or id (completing-read "Cancel job: "
                  (hash-table-keys (kargu-job-service-jobs (kargu-job-service-for-project))) nil t))))))
    (kargu-job-cancel job) (force-mode-line-update t)))

(defun kargu-bash--job-status (job)
  "Describe JOB and its recent output without changing the selected buffer."
  (let ((buffer (kargu-bash--job-buffer job)))
    (format "[%s] %s\n%s"
            (kargu-bash--job-id job)
            (upcase (substring (symbol-name (kargu-bash--job-state job)) 1))
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
                 (table (kargu-job-service-jobs svc))
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
              (format "Process [%s] cancellation requested; Rust drains its process group." id)))))
      (error (concat "ERROR: " (error-message-string err))))))

(provide 'kargu/tools/bash/jobs)
;;; jobs.el ends here
