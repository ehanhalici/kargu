;;; native.el --- Shell presentation adapter for Rust jobs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Capture editor authority once; Rust owns execution and bounded output.
;; There is no Elisp engine fallback or synchronous startup wait.

;;; Code:

(require 'kargu/tools/bash/jobs)
(require 'kargu/bridge/job-output)
(require 'kargu/permission/execute)
(require 'kargu/state/selectors)
(defvar kargu-bash-timeout)
(declare-function kargu-execution-call "kargu/application/execution" (context function &rest args))
(declare-function kargu-execution-live-p "kargu/application/execution" (context))

(defun kargu-bash-native--environment ()
  "Capture Emacs child environment explicitly, with first entry taking priority."
  (let ((result (make-hash-table :test #'equal)) (seen (make-hash-table :test #'equal)))
    (dolist (entry process-environment)
      (let* ((at (string-search "=" entry)) (name (if at (substring entry 0 at) entry)))
        (unless (gethash name seen)
          (puthash name t seen)
          (when at (puthash name (substring entry (1+ at)) result)))))
    result))

(defun kargu-bash-native--append (job text truncated)
  "Append TEXT to JOB's bounded editor view, recording TRUNCATED output."
  (setf (kargu-bash--job-truncated job) (or truncated (kargu-bash--job-truncated job)))
  (when (buffer-live-p (kargu-bash--job-buffer job))
    (with-current-buffer (kargu-bash--job-buffer job)
      (let ((inhibit-read-only t) (modified (buffer-modified-p)))
        (save-excursion
          (save-restriction
            (widen)
            (goto-char (point-max))
            (insert text)
            (when (> (1- (position-bytes (point-max))) (kargu-bash--job-limit job))
              (setf (kargu-bash--job-truncated job) t)
              (kargu-process--retain-tail (kargu-bash--job-limit job)))))
        (set-buffer-modified-p modified)))))

(defun kargu-bash-native--finish (job task result error-data)
  "Complete JOB's editor state from Rust RESULT or ERROR-DATA through TASK."
  (let ((buffer (kargu-bash--job-buffer job)))
    (kargu-bash--job-finished
     job (list :code (and result (gethash "exit_code" result))
               :outcome (and result (intern (gethash "outcome" result)))
               :timed-out (and result (equal (gethash "outcome" result) "timeout"))
               :failure (cond (error-data (kargu-bash-native--failure-text job error-data))
                              ((and result (not (eq (gethash "cleanup_complete" result) t))) "Native cleanup outcome unknown"))
               :truncated (kargu-bash--job-truncated job)
               :output (and (buffer-live-p buffer)
                            (with-current-buffer buffer
                              (save-restriction (widen) (buffer-string)))))
     (unless (kargu-bash--job-background job)
       (lambda (text) (kargu-async-finish task text))))))

(defun kargu-bash-native--failure-text (job error-data)
  "Present ERROR-DATA for JOB without losing actionable rejection context."
  (let ((message (gethash "message" error-data "Native job failed"))
        (data (gethash "data" error-data)))
    (if (not (and (hash-table-p data) (equal (gethash "status" data) "rejected"))) message
      (format "%s\nRejected command: %S\nWorking directory: %S\nAllowed project root: %S\nGuidance: Do not repeat the identical command without user clarification."
              message (kargu-bash--job-command job) (kargu-bash--job-directory job) (kargu-bash--job-root job)))))

(defun kargu-bash-native--admitted (job task handle error-data)
  "Attach actual native HANDLE to JOB and TASK, or report ERROR-DATA."
  (cond
   ((not (kargu-async-pending-p task)) (when handle (kargu-bridge-job-dispose handle)))
   (error-data
    (kargu-bash-native--finish job task nil error-data)
    (when (kargu-bash--job-background job)
      (kargu-async-finish task nil (gethash "message" error-data "Native startup failed"))))
   (t
    (setf (kargu-bash--job-handle job) handle (kargu-bash--job-state job) :running)
    (unless (kargu-bash--job-background job)
      (setf (kargu-job-service-active-async-proc (kargu-bash--job-service job)) handle)
      (setq kargu-bash--active-async-proc handle))
    (kargu-bridge-job-eof handle #'ignore)
    (setf (kargu-bash--job-reader job)
          (kargu-bridge-output-start
           handle (lambda (text truncated) (kargu-bash-native--append job text truncated))
           (lambda (result failure) (kargu-bash-native--finish job task result failure))))
    (when (kargu-bash--job-background job)
      (kargu-async-finish task (kargu-bash--started-text job))))))

(defun kargu-bash-native--fresh-p (operation context mode)
  "Check captured OPERATION and MODE inside the original execution CONTEXT."
  (condition-case nil
      (let ((check (lambda ()
                     (and (eq mode (or (plist-get kargu--loop-run :mode) (kargu-state-mode)))
                          (kargu-permission--operation-valid-p operation)))))
        (if context
            (and (kargu-execution-live-p context) (kargu-execution-call context check))
          (with-current-buffer (kargu-permission-operation-origin operation) (funcall check))))
    (error nil)))

(defun kargu-bash-native-start (command directory shell background callback)
  "Start COMMAND in DIRECTORY using SHELL; deliver BACKGROUND or terminal CALLBACK."
  (unless (functionp callback) (error "Native Bash startup requires a CALLBACK"))
  (let* ((root (kargu-permission-project-root))
         (command (copy-sequence command))
         (directory (file-name-as-directory (file-truename directory)))
         (mode (or (plist-get kargu--loop-run :mode) (kargu-state-mode)))
         (context kargu-execution--current)
         (owner (current-buffer))
         (operation (kargu-permission-capture
                     command directory :valid-p (lambda () (kargu-permission-validate-command command root directory) t)))
         (limit kargu-process-max-bytes)
         (arguments (kargu-bridge--object
                     "root" root "mode" (symbol-name mode) "program" shell
                     "arguments" (vector "-c" command) "cwd" directory
                     "timeout_ms" (if kargu-bash-timeout (ceiling (* 1000 kargu-bash-timeout)) :json-null)
                     "environment" (kargu-bash-native--environment) "config_revision" 0
                     "policy_revision" (or (kargu-permission-operation-policy-revision operation) 0)
                     "output_bytes" limit "stderr" "merge")))
    (unless (eq mode 'agent) (error "Bash requires Agent mode"))
    (unless (and (natnump limit) (<= limit 4194304))
      (error "Native Bash output capacity must be 0..4194304 bytes"))
    (let* ((service (kargu-job-service-for-project root))
           (id (format "p%d" (cl-incf kargu-bash--counter)))
           (buffer (generate-new-buffer (format "*kargu-proc-%s*" id)))
           (job (kargu-bash--make-job :id id :command command :directory directory :root root
                                     :service service :buffer buffer :started (float-time)
                                     :background background :limit limit))
           (task (kargu-async-start (lambda (value failure) (funcall callback (if failure (concat "ERROR: " failure) value))))))
      (setf (kargu-bash--job-task job) task)
      (cl-incf (kargu-job-service-counter service))
      (puthash id job (kargu-job-service-jobs service))
      (puthash id job kargu-bash--processes)
      (with-current-buffer buffer
        (kargu-bash-output-mode)
        (buffer-disable-undo)
        (setq-local default-directory directory kargu-bash--buffer-job job
                    kargu-permission--override-root root))
      (kargu-async-add-cleanup
       task (lambda ()
              (when (and (memq (kargu-bash--job-state job) '(:starting :running))
                         (or (not background) (eq (kargu-bash--job-state job) :starting)))
                (kargu-job-cancel job))))
      (kargu-async-add-cleanup
       task (kargu-bridge-ensure
             (kargu-async-wrap
              task (lambda (connection failure)
                     (if failure (kargu-bash-native--admitted job task nil failure)
                       (kargu-bridge-job-start
                        connection arguments
                        (lambda (handle error-data) (kargu-bash-native--admitted job task handle error-data))
                        :owner owner :valid-p (lambda () (kargu-bash-native--fresh-p operation context mode))))))))
      task)))

(provide 'kargu/tools/bash/native)
;;; native.el ends here
