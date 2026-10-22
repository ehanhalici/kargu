;;; session.el --- Interactive process session transport -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Owned stdin, byte-bounded tail output and one terminal callback.
;; Starting/running/closing/closed describe resources, not remote side effects.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/tools/process)

(cl-defstruct (kargu-process-session (:constructor kargu-process-session--create))
  "One interactive process and its private output/timer resources."
  id process pgid buffer dir (state :starting)
  on-output on-exit idle-timer idle-timeout max-bytes (bytes-read 0))

(defun kargu-process-session-live-p (session)
  "Return non-nil if SESSION still owns a live process."
  (and (kargu-process-session-p session)
       (not (eq (kargu-process-session-state session) :closed))
       (processp (kargu-process-session-process session))
       (process-live-p (kargu-process-session-process session))))

(defun kargu-process-session--clear-idle (session)
  "Release SESSION's idle timer."
  (when-let* ((timer (kargu-process-session-idle-timer session)))
    (setf (kargu-process-session-idle-timer session) nil)
    (cancel-timer timer)))

(defun kargu-process-session--reset-idle (session)
  "Rearm SESSION's idle timer only while the process remains live."
  (kargu-process-session--clear-idle session)
  (when (and (kargu-process-session-live-p session)
             (kargu-process-session-idle-timeout session))
    (setf (kargu-process-session-idle-timer session)
          (run-at-time (kargu-process-session-idle-timeout session) nil
                       #'kargu-process-session-kill session))))

(defun kargu-process-session--notify (session callback value)
  "Deliver VALUE to SESSION's CALLBACK without leaking callback exceptions."
  (when callback
    (condition-case nil
        (save-match-data (funcall callback value))
      (error
       (kargu-log 'warn "Interactive process callback failed")
       (kargu-process-session-kill session)))))

(defun kargu-process-session--finish (session)
  "Close SESSION once, releasing private resources before terminal delivery."
  (unless (eq (kargu-process-session-state session) :closed)
    (setf (kargu-process-session-state session) :closed)
    (kargu-process-session--clear-idle session)
    (when (buffer-live-p (kargu-process-session-buffer session))
      (kill-buffer (kargu-process-session-buffer session)))
    (when-let* ((process (kargu-process-session-process session)))
      (kargu-process-session--notify
       session (kargu-process-session-on-exit session) (process-exit-status process)))))

(defun kargu-process-session--filter (session chunk)
  "Append CHUNK to SESSION's byte-bounded tail without changing reader state."
  (unless (eq (kargu-process-session-state session) :closed)
    (let ((buffer (kargu-process-session-buffer session)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (save-excursion
              (save-restriction
                (widen)
                (goto-char (point-max))
                (insert chunk)
                (kargu-process--retain-tail (kargu-process-session-max-bytes session))))))))
    (cl-incf (kargu-process-session-bytes-read session) (string-bytes chunk))
    (kargu-process-session--reset-idle session)
    (when (memq (kargu-process-session-state session) '(:running :closing))
      (kargu-process-session--notify session
                                    (kargu-process-session-on-output session) chunk))))

(defun kargu-process-session--spawn (session program args)
  "Spawn PROGRAM with ARGS and publish SESSION before callbacks can finish it."
  (let ((default-directory (kargu-process-session-dir session)))
    (condition-case failure
        (let ((process
               (make-process
                :name (kargu-process-session-id session)
                :buffer (kargu-process-session-buffer session)
                :command (cons program args) :connection-type 'pipe :noquery t
                :filter (lambda (_process chunk)
                          (kargu-process-session--filter session chunk))
                :sentinel (lambda (child _event)
                            (when (and (not (process-live-p child))
                                       (not (eq (kargu-process-session-state session) :starting)))
                              (kargu-process-session--finish session))))))
          (setf (kargu-process-session-process session) process
                (kargu-process-session-pgid session) (process-id process)
                (kargu-process-session-state session) :running)
          (process-put process 'kargu-pgid (process-id process))
          (if (process-live-p process)
              (kargu-process-session--reset-idle session)
            (kargu-process-session--finish session))
          session)
      (error
       (kargu-process-session--finish session)
       (signal (car failure) (cdr failure))))))

(cl-defun kargu-process-session-start
    (program args &key dir on-output on-exit idle-timeout max-bytes)
  "Start PROGRAM with ARGS in DIR; return an owned interactive session.
ON-OUTPUT receives chunks; ON-EXIT receives one terminal exit code.
IDLE-TIMEOUT is positive seconds or nil.  MAX-BYTES bounds retained output."
  (unless (and (stringp program) (listp args) (cl-every #'stringp args)
               (or (null idle-timeout) (and (numberp idle-timeout) (> idle-timeout 0)))
               (or (null max-bytes) (natnump max-bytes))
               (or (null on-output) (functionp on-output))
               (or (null on-exit) (functionp on-exit)))
    (error "Invalid interactive process parameters"))
  (let* ((executable (or (executable-find program)
                         (error "Executable %s not found on PATH" program)))
         (buffer (generate-new-buffer " *kargu-session*"))
         (session (kargu-process-session--create
                   :id (buffer-name buffer) :buffer buffer
                   :dir (file-name-as-directory (expand-file-name (or dir default-directory)))
                   :on-output on-output :on-exit on-exit :idle-timeout idle-timeout
                   :max-bytes (or max-bytes kargu-process-max-bytes))))
    (with-current-buffer buffer (buffer-disable-undo))
    (kargu-process-session--spawn session executable args)))

(defun kargu-process-session-send (session text &optional send-eof)
  "Send TEXT to SESSION; optionally close stdin with SEND-EOF."
  (unless (stringp text) (error "Session input must be a string"))
  (when (and (kargu-process-session-live-p session)
             (eq (kargu-process-session-state session) :running))
    (process-send-string (kargu-process-session-process session) text)
    (kargu-process-session--reset-idle session)
    (when send-eof (kargu-process-session-close session))))

(defun kargu-process-session-close (session)
  "Close SESSION's stdin once; output remains live until process exit."
  (when (and (kargu-process-session-live-p session)
             (eq (kargu-process-session-state session) :running))
    (setf (kargu-process-session-state session) :closing)
    (process-send-eof (kargu-process-session-process session))))

(defun kargu-process-session-kill (session &optional grace-seconds)
  "Cancel SESSION's process group with optional GRACE-SECONDS."
  (when (and (kargu-process-session-p session)
             (not (eq (kargu-process-session-state session) :closed)))
    (setf (kargu-process-session-state session) :closing)
    (kargu-process-session--clear-idle session)
    (when-let* ((process (kargu-process-session-process session)))
      (kargu-process-cancel process grace-seconds))
    (unless (kargu-process-session-live-p session)
      (kargu-process-session--finish session))))

(provide 'kargu/tools/process/session)
;;; session.el ends here
