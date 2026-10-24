;;; session.el --- Editor adapter for native interactive jobs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; No OS process, stdin writer, idle timer or PGID authority is owned here.
;; Startup is asynchronous; await on-ready before sending input or EOF.

;;; Code:

(require 'cl-lib)
(require 'kargu/tools/process)
(require 'kargu/bridge/command)
(require 'kargu/bridge/job-output)

(cl-defstruct (kargu-process-session (:constructor kargu-process-session--create))
  "One native interactive handle and its private editor view."
  id handle owner owner-cleanup context-session (owner-live t)
  buffer dir task reader result failure (state :starting)
  on-ready on-output on-exit max-bytes truncated (bytes-read 0))

(defun kargu-process-session-live-p (session)
  "Whether SESSION is running or still waiting for actual native drain."
  (and (kargu-process-session-p session)
       (memq (kargu-process-session-state session) '(:running :closing))
       (kargu-bridge-job-p (kargu-process-session-handle session))
       (not (memq (kargu-bridge-job-state (kargu-process-session-handle session))
                  '(:forgotten :disconnected)))))

(defun kargu-process-session--notify (session callback &rest arguments)
  "Deliver ARGUMENTS to SESSION's CALLBACK only inside its still-live source."
  (when (and callback (kargu-process-session-owner-live session)
             (buffer-live-p (kargu-process-session-owner session))
             (eq (kargu-process-session-context-session session)
                 (kargu-session-context (kargu-process-session-owner session))))
    (condition-case nil
        (with-current-buffer (kargu-process-session-owner session)
          (save-match-data (apply callback arguments)))
      (error
       (setf (kargu-process-session-failure session) (kargu-bridge--fault "callback_failed"))
       (kargu-process-session-kill session)))))

(defun kargu-process-session--finish (session &optional result error-data)
  "Close SESSION once from actual native RESULT or explicit ERROR-DATA."
  (unless (eq (kargu-process-session-state session) :closed)
    (unless (or result error-data) (error "Interactive completion requires native evidence"))
    (setf (kargu-process-session-state session) :closed
          (kargu-process-session-result session) result)
    (when (buffer-live-p (kargu-process-session-owner session))
      (with-current-buffer (kargu-process-session-owner session)
        (remove-hook 'kill-buffer-hook (kargu-process-session-owner-cleanup session) t)
        (remove-hook 'change-major-mode-hook (kargu-process-session-owner-cleanup session) t)))
    (when error-data (setf (kargu-process-session-failure session) error-data))
    (when (and result (or (equal (gethash "outcome" result) "outcome_unknown")
                          (not (eq (gethash "cleanup_complete" result) t))))
      (setf (kargu-process-session-failure session)
            (kargu-bridge--fault "outcome_unknown" "Native cleanup is unconfirmed; do not replay")))
    (when (kargu-process-session-reader session)
      (kargu-bridge-output-close (kargu-process-session-reader session)))
    (when (buffer-live-p (kargu-process-session-buffer session))
      (kill-buffer (kargu-process-session-buffer session)))
    (when-let* ((handle (kargu-process-session-handle session)))
      (if result
          (kargu-bridge-job-forget
           handle (lambda (_value failure) (when failure (kargu-bridge-job-dispose handle))))
        (kargu-bridge-job-dispose handle)))
    (kargu-process-session--notify
     session (kargu-process-session-on-exit session)
     (kargu-process-session--exit-code result))))

(defun kargu-process-session--exit-code (result)
  "Return a legacy code for RESULT, never zero for cancelled or unknown effects."
  (when (and result (eq (gethash "cleanup_complete" result) t)
             (not (equal (gethash "outcome" result) "outcome_unknown")))
    (let ((code (gethash "exit_code" result)) (signal (gethash "signal" result)))
      (cond ((and (integerp code) (= code 0) (not (equal (gethash "outcome" result) "ok"))) -1)
            ((integerp code) code)
            ((integerp signal) signal)))))

(defun kargu-process-session--filter (session chunk &optional cursor)
  "Append CHUNK to SESSION's bounded view; CURSOR is the native byte position."
  (unless (eq (kargu-process-session-state session) :closed)
    (let ((buffer (kargu-process-session-buffer session)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let ((inhibit-read-only t) (modified (buffer-modified-p)))
            (save-excursion
              (save-restriction
                (widen)
                (goto-char (point-max))
                (insert chunk)
                (kargu-process--retain-tail (kargu-process-session-max-bytes session))))
            (set-buffer-modified-p modified)))))
    (setf (kargu-process-session-bytes-read session)
          (or cursor (+ (kargu-process-session-bytes-read session) (string-bytes chunk))))
    (unless (string-empty-p chunk)
      (kargu-process-session--notify session (kargu-process-session-on-output session) chunk))))

(defun kargu-process-session--admitted (session task handle error-data)
  "Bind native HANDLE to SESSION and TASK, or close from ERROR-DATA."
  (cond
   ((not (kargu-async-pending-p task))
    (when handle (kargu-bridge-job-dispose handle))
    (unless (eq (kargu-process-session-state session) :closed)
      (setf (kargu-process-session-owner-live session) nil)
      (kargu-async-cancel task)))
   (error-data
    (kargu-process-session--finish session nil error-data)
    (kargu-async-finish task nil "Native interactive startup failed"))
   (t
    (setf (kargu-process-session-handle session) handle
          (kargu-process-session-id session) (kargu-bridge-job-id handle)
          (kargu-process-session-state session) :running
          (kargu-process-session-reader session)
          (kargu-bridge-output-start
           handle
           (lambda (text truncated)
             (setf (kargu-process-session-truncated session)
                   (or truncated (kargu-process-session-truncated session)))
             (kargu-process-session--filter
              session text (and (kargu-process-session-reader session)
                                (kargu-bridge-output-cursor (kargu-process-session-reader session)))))
           (lambda (result failure) (kargu-process-session--finish session result failure))))
    (kargu-async-finish task session)
    (kargu-process-session--notify session (kargu-process-session-on-ready session) session))))

(cl-defun kargu-process-session-start
    (program args &key dir on-ready on-output on-exit idle-timeout max-bytes)
  "Prepare PROGRAM with ARGS in DIR; return an owned starting session.
ON-READY receives the session after exact approval and actual native claim.
ON-OUTPUT receives text; ON-EXIT receives a legacy exit code/signal, or nil
on unknown failure.  Cancellation/timeout cannot report legacy success zero.
RESULT and FAILURE accessors retain typed native evidence.  Callbacks stop
after source loss.  IDLE-TIMEOUT is positive seconds or nil; MAX-BYTES is
0..4 MiB.  Agent mode and a compatible native core are required."
  (unless (and (stringp program) (listp args) (cl-every #'stringp args)
               (or (null idle-timeout) (and (numberp idle-timeout) (> idle-timeout 0)))
               (or (null max-bytes) (natnump max-bytes))
               (cl-every (lambda (callback) (or (null callback) (functionp callback)))
                         (list on-ready on-output on-exit)))
    (error "Invalid interactive process parameters"))
  (let* ((executable (or (executable-find program) (error "Executable %s not found on PATH" program)))
         (directory (file-name-as-directory (expand-file-name (or dir default-directory))))
         (limit (or max-bytes kargu-process-max-bytes))
         (capture (kargu-bridge-command-capture executable args directory
                                                :idle-timeout idle-timeout :output-bytes limit :stderr "merge"))
         (buffer (generate-new-buffer " *kargu-session*"))
         (session (kargu-process-session--create
                   :owner (current-buffer) :context-session (kargu-session-context)
                   :buffer buffer :dir directory :id (buffer-name buffer)
                   :on-ready on-ready :on-output on-output :on-exit on-exit :max-bytes limit))
         (task (kargu-async-start #'ignore)))
    (setf (kargu-process-session-task session) task)
    (setf (kargu-process-session-owner-cleanup session)
          (lambda ()
            (setf (kargu-process-session-owner-live session) nil)
            (kargu-process-session-kill session)))
    ;; Revoke editor callbacks before ordinary RPC/handle cleanup hooks run.
    (add-hook 'kill-buffer-hook (kargu-process-session-owner-cleanup session) -100 t)
    (add-hook 'change-major-mode-hook (kargu-process-session-owner-cleanup session) -100 t)
    (with-current-buffer buffer (buffer-disable-undo))
    (kargu-async-add-cleanup
     task (lambda ()
            (when (eq (kargu-process-session-state session) :starting)
              (kargu-process-session--finish
               session nil (kargu-bridge--fault "startup_unconfirmed" "Interactive startup cancelled; receipt unconfirmed")))))
    (kargu-async-add-cleanup
     task (kargu-bridge-ensure
           (kargu-async-wrap
            task (lambda (connection failure)
                   (if failure (kargu-process-session--admitted session task nil failure)
                     (kargu-bridge-job-start
                      connection (kargu-bridge-command-arguments capture)
                      (lambda (handle error-data) (kargu-process-session--admitted session task handle error-data))
                      :owner (kargu-bridge-command-owner capture) :valid-p (kargu-bridge-command-valid-p capture)))))))
    session))

(defun kargu-process-session-send (session text &optional send-eof callback)
  "Send bounded TEXT to SESSION; SEND-EOF follows actual acknowledgement.
TEXT is at most 32768 UTF-8 bytes.
CALLBACK receives (RESULT ERROR).  Uncertain input delivery is never retried."
  (unless (stringp text) (error "Session input must be a string"))
  (unless (eq (kargu-process-session-state session) :running)
    (error "Await interactive on-ready before sending input"))
  (kargu-bridge-job-write
   (kargu-process-session-handle session) text
   (lambda (result failure)
     (when failure
       (setf (kargu-process-session-failure session) failure)
       (kargu-process-session-kill session))
     (when (and send-eof (not failure)) (kargu-process-session-close session))
     (kargu-process-session--notify session callback result failure))))

(defun kargu-process-session-close (session &optional callback)
  "Close SESSION's stdin once; CALLBACK receives actual native acceptance.
Output stays live until native terminal drain, not just EOF acknowledgement."
  (unless (eq (kargu-process-session-state session) :running)
    (error "Await interactive on-ready before closing stdin"))
  (setf (kargu-process-session-state session) :closing)
  (kargu-bridge-job-eof
   (kargu-process-session-handle session)
   (lambda (result failure)
     (when failure
       (setf (kargu-process-session-failure session) failure)
       (kargu-process-session-kill session))
     (kargu-process-session--notify session callback result failure))))

(defun kargu-process-session-kill (session &optional _legacy-grace)
  "Request SESSION cancellation; Rust owns TERM/grace/KILL/reap.
A starting session is cancelled locally with unconfirmed startup evidence."
  (when (and (kargu-process-session-p session)
             (not (eq (kargu-process-session-state session) :closed)))
    (if (kargu-process-session-handle session)
        (progn
          (setf (kargu-process-session-state session) :closing)
          (kargu-bridge-job-cancel (kargu-process-session-handle session) #'ignore))
      (kargu-async-cancel (kargu-process-session-task session)))))

(provide 'kargu/tools/process/session)
;;; session.el ends here
