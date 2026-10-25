;;; setup.el --- Owned setup verification through the connection port -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; One origin-owned root covers config refresh and connection resolution.
;; Setup neither starts model discovery nor borrows an agent's connection.
;; Credentials use the shared editor interop port and are wiped after reporting.

;;; Code:

(require 'kargu/config/connection)

(defvar-local kargu-setup--task nil
  "This origin's current setup check, independent of an agent run.")

(defun kargu-setup--report (result error)
  "Present captured connection RESULT or safe task ERROR without retaining keys."
  (if (or error (kargu-err-p result))
      (message "Kargu: setup preparation unavailable; check configuration and credentials")
    (let* ((snapshot (kargu-result-value result))
           (key (kargu-connection-snapshot-secret snapshot)))
      (unwind-protect
          (kargu-connection-call snapshot #'kargu-config--report-setup (kargu-ok key))
        (when (stringp key) (clear-string key))))))

(defun kargu-setup--resolved (task result)
  "Deliver RESULT only to live TASK and always wipe its private credential scope."
  (unwind-protect
      (funcall (kargu-async-wrap task (lambda () (kargu-async-finish task result))))
    (when (kargu-ok-p result)
      (kargu-connection-snapshot-wipe (kargu-result-value result)))))

(defun kargu-setup--configured (task result)
  "Advance TASK from config RESULT through the existing connection resolver."
  (if (kargu-err-p result)
      (kargu-async-finish task result)
    (let ((kargu-connection--bound nil))
      (kargu-connection-resolve-async
       (kargu--provider-name) (kargu--model)
       :origin (kargu-async-task-buffer task) :parent task :owner nil
       :callback (lambda (value) (kargu-setup--resolved task value))))))

(cl-defun kargu-setup--current-p (origin &key session selection application-owner)
  "Check ORIGIN's captured SESSION, SELECTION and APPLICATION-OWNER."
  (and (buffer-live-p origin)
       (with-current-buffer origin
         (and (eq application-owner kargu-application-owner)
              (eq session (kargu-session-context))
              (eq selection (kargu-selection-context session))))))

(defun kargu-setup--bind-origin (task)
  "Bind TASK's cleanup to its origin's lifetime and remove hooks on every exit."
  (let* ((origin (kargu-async-task-buffer task))
         (cancel (lambda () (kargu-async-cancel task))))
    (add-hook 'kill-buffer-hook cancel nil t)
    (add-hook 'change-major-mode-hook cancel nil t)
    (kargu-async-add-cleanup
     task (lambda ()
            (when (buffer-live-p origin)
              (with-current-buffer origin
                (remove-hook 'kill-buffer-hook cancel t)
                (remove-hook 'change-major-mode-hook cancel t)
                (when (eq kargu-setup--task task) (setq kargu-setup--task nil))))))))

;;;###autoload
(defun kargu-check-setup ()
  "Check config and credentials through one cancellable, origin-owned task.
Return the task.  A repeated check replaces only this buffer's earlier check;
origin close, mode/session/selection change and deadline reject late reports."
  (interactive)
  (when kargu-setup--task (kargu-async-cancel kargu-setup--task))
  (let* ((kargu-connection--bound nil)
         (app (kargu-application-context))
         (origin (current-buffer))
         (session (kargu-session-context))
         (selection (kargu-selection-context session))
         (application-owner kargu-application-owner)
         (task (kargu-async-start
                (kargu-application-wrap app #'kargu-setup--report)
                :owner nil :parent nil :buffer origin
                :timeout kargu-config-worker-default-timeout
                :valid-p (lambda ()
                           (kargu-setup--current-p
                            origin :session session :selection selection
                            :application-owner application-owner)))))
    (setq kargu-setup--task task)
    (kargu-setup--bind-origin task)
    (funcall
     (kargu-async-wrap
      task (lambda ()
             (kargu-config-refresh-async
              (kargu-application-wrap
               app (kargu-async-wrap task (lambda (value) (kargu-setup--configured task value))))
              :parent task :owner nil))))
    task))

(provide 'kargu/config/setup)
;;; setup.el ends here
