;;; readiness.el --- Owned debugger readiness waits -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Bind readiness to a captured origin and adapter, never global UI hooks.
;; Cancelling a wait does not cancel Dape's deferred compilation or adapter.

;;; Code:

(require 'cl-lib)
(require 'kargu/async)
(require 'kargu/state)
(require 'kargu/tools/dape/events)
(require 'kargu/tools/dape/selection)
(require 'kargu/tools/dape/workspace)

(defconst kargu-dape--session-poll-interval 0.5
  "Seconds between owned debug readiness checks.")

(defconst kargu-dape--session-launch-timeout 60.0
  "Seconds allowed for an owned debug adapter to become ready.")

(cl-defstruct (kargu-dape--readiness (:constructor kargu-dape--make-readiness))
  "One origin's captured ownership and asynchronous readiness resources."
  origin root session mode owner source file connection token task timer deadline listener kill-hook)

(defvar-local kargu-dape--readiness-wait nil
  "The single readiness wait currently owned by this origin buffer.")

(defun kargu-dape--readiness-valid-p (wait)
  "Return non-nil while WAIT's captured origin and source still match."
  (condition-case nil
      (let ((origin (kargu-dape--readiness-origin wait))
            (source (kargu-dape--readiness-source wait)))
        (and (buffer-live-p origin)
             (with-current-buffer origin
               (and (eq (kargu-dape--readiness-owner wait) kargu--loop-run)
                    (equal (kargu-dape--readiness-root wait) (kargu-permission-project-root))
                    (equal (kargu-dape--readiness-session wait) (kargu-session-id))
                    (eq (kargu-dape--readiness-mode wait) (kargu-state-mode))))
             (or (null source)
                 (and (buffer-live-p source)
                      (stringp (kargu-dape--readiness-file wait))
                      (equal (kargu-dape--readiness-file wait) (buffer-file-name source))
                      (kargu-permission-within-project-p (buffer-file-name source)
                                                         (kargu-dape--readiness-root wait))))))
    (file-error nil)))

(defun kargu-dape--readiness-cleanup (wait)
  "Release only WAIT's listeners, timer and origin reference."
  (dolist (timer (list (kargu-dape--readiness-timer wait) (kargu-dape--readiness-deadline wait)))
    (when (timerp timer) (cancel-timer timer)))
  (when-let* ((listener (kargu-dape--readiness-listener wait)))
    (remove-hook 'kargu-dape-event-hook listener))
  (when (buffer-live-p (kargu-dape--readiness-origin wait))
    (with-current-buffer (kargu-dape--readiness-origin wait)
      (remove-hook 'kill-buffer-hook (kargu-dape--readiness-kill-hook wait) t)
      (when (eq kargu-dape--readiness-wait wait) (setq kargu-dape--readiness-wait nil)))))

(defun kargu-dape-cancel-session-wait (&optional buffer)
  "Cancel BUFFER's pending debugger wait silently, defaulting to this buffer.
Return non-nil if a wait was cancelled; leave all debug adapters untouched."
  (when (buffer-live-p (or buffer (current-buffer)))
    (with-current-buffer (or buffer (current-buffer))
      (when-let* ((wait kargu-dape--readiness-wait))
        (kargu-async-cancel (kargu-dape--readiness-task wait))
        t))))

(defun kargu-dape--readiness-probe (wait)
  "Adopt WAIT's uniquely tagged root adapter, then check its paused thread."
  (let* ((root (kargu-dape--readiness-root wait))
         (candidates (kargu-dape-launch-connections root (kargu-dape--readiness-token wait)))
         (task (kargu-dape--readiness-task wait)))
    (when (> (length candidates) 1) (error "Ambiguous debugger launch: multiple root adapters"))
    (unless (kargu-dape--readiness-connection wait)
      (setf (kargu-dape--readiness-connection wait) (car candidates)))
    (when-let* ((conn (kargu-dape--readiness-connection wait)))
      (unless (memq conn (kargu-dape-project-connections root))
        (error "Debugger connection disappeared or was replaced"))
      (when (and (kargu-dape--readiness-token wait) (not (memq conn candidates)))
        (error "Debugger launch identity changed"))
      (when (kargu-dape-inspection-thread conn) (kargu-async-finish task t)))))

(defun kargu-dape--poll-readiness (wait)
  "Probe WAIT or silently close stale ownership, even after a run replacement."
  (save-match-data
    (let ((task (kargu-dape--readiness-task wait)))
      (when (eq (kargu-async-task-state task) :pending)
        (if (not (kargu-dape--readiness-valid-p wait)) (kargu-async-cancel task)
          (funcall (kargu-async-wrap task (lambda () (kargu-dape--readiness-probe wait)))))))))

(defun kargu-dape--readiness-event (wait connection event)
  "Check WAIT only for a matching CONNECTION's state EVENT."
  (save-match-data
    (let ((task (kargu-dape--readiness-task wait)))
      (when (eq (kargu-async-task-state task) :pending)
        (cond
         ((not (kargu-dape--readiness-valid-p wait)) (kargu-async-cancel task))
         ((and (eq connection (kargu-dape--readiness-connection wait))
               (memq event '(exited terminated)))
          (kargu-async-finish task nil "Debugger exited before becoming ready"))
         ((or (eq connection (kargu-dape--readiness-connection wait))
              (memq connection (kargu-dape-launch-connections
                                (kargu-dape--readiness-root wait) (kargu-dape--readiness-token wait))))
          (kargu-dape--poll-readiness wait)))))))

(defun kargu-dape--install-readiness (wait)
  "Publish WAIT and install only resources released by its task cleanup."
  (let* ((task (kargu-dape--readiness-task wait))
         (listener (lambda (conn event) (kargu-dape--readiness-event wait conn event)))
         (kill (lambda () (kargu-async-cancel task))))
    (kargu-async-add-cleanup task (lambda () (kargu-dape--readiness-cleanup wait)))
    (setq kargu-dape--readiness-wait wait)
    (setf (kargu-dape--readiness-listener wait) listener
          (kargu-dape--readiness-kill-hook wait) kill)
    (add-hook 'kill-buffer-hook kill nil t)
    (add-hook 'kargu-dape-event-hook listener)
    (setf (kargu-dape--readiness-timer wait)
          (run-at-time kargu-dape--session-poll-interval kargu-dape--session-poll-interval
                       #'kargu-dape--poll-readiness wait))
    (setf (kargu-dape--readiness-deadline wait)
          (run-at-time kargu-dape--session-launch-timeout nil #'kargu-dape--readiness-expired wait))))

(defun kargu-dape--readiness-expired (wait)
  "Finish WAIT's owned deadline without invoking a stale continuation."
  (save-match-data
    (let ((task (kargu-dape--readiness-task wait)))
      (when (eq (kargu-async-task-state task) :pending)
        (if (kargu-dape--readiness-valid-p wait)
            (kargu-async-finish task nil "Debugger launch timed out")
          (kargu-async-cancel task))))))

(cl-defun kargu-dape-wait-for-session (on-ready &key on-cancel connection source launch)
  "Wait for CONNECTION or LAUNCH and complete ON-READY in its captured origin.
LAUNCH receives a unique token after the wait is installed.  SOURCE must
remain live and unchanged in identity.  ON-CANCEL receives a failure reason.
Return an owned async task; stale ownership or Stop cancels it silently."
  (kargu-dape-cancel-session-wait)
  (let* ((wait (kargu-dape--make-readiness
                :origin (current-buffer) :root (kargu-permission-project-root)
                :session (copy-sequence (kargu-session-id)) :mode (kargu-state-mode)
                :owner kargu--loop-run :source source :file (and source (buffer-file-name source))
                :connection connection :token (and launch (make-symbol "kargu-launch"))))
         (task (kargu-async-start
                (lambda (_value error)
                  (when (kargu-dape--readiness-valid-p wait)
                    (if error (when on-cancel (funcall on-cancel error))
                      (funcall on-ready)))))))
    (setf (kargu-dape--readiness-task wait) task)
    (condition-case err
        (progn
          (kargu-dape--install-readiness wait)
          (funcall (kargu-async-wrap
                    task (lambda ()
                           (if (not (kargu-dape--readiness-valid-p wait)) (kargu-async-cancel task)
                             (when launch (funcall launch (kargu-dape--readiness-token wait)))
                             (kargu-dape--poll-readiness wait))))))
      (quit (kargu-async-finish task nil "Debugger startup cancelled by user"))
      (error (kargu-async-finish task nil (error-message-string err))))
    task))

(provide 'kargu/tools/dape/readiness)
;;; readiness.el ends here
