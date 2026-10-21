;;; mode.el --- Owned asynchronous mode preparation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Preparation has one owner and one terminal result.  Preparing a mode does
;; not publish it: the caller commits only after its own work is ready.

;;; Code:

(require 'kargu/core/session)
(require 'kargu/async)
(require 'kargu/contract/types)

(declare-function kargu-loop-running-p "kargu/loop" ())
(declare-function kargu-busy-p "kargu/api/http" ())

(defvar kargu-mode-prepare-functions nil
  "Mode preparation extensions accepting ready and optional error callbacks.
Legacy single-continuation preparers remain supported at this boundary.")

(cl-defstruct (kargu-mode-preparation (:constructor kargu-mode--create))
  "A mode intent bound to a captured origin, session and workspace."
  (origin nil :read-only t) (session nil :read-only t)
  (directory nil :read-only t) (mode nil :read-only t) task)

(defun kargu-mode-cancel (&optional session)
  "Cancel SESSION's pending preparation and deliver its cancellation once."
  (let* ((owner (or session (kargu-session-context)))
         (request (kargu-session-mode-request owner)))
    (when request
      (setf (kargu-session-mode-request owner) nil)
      (kargu-async-finish (kargu-mode-preparation-task request)
                          nil "Mode preparation cancelled"))))

(defun kargu-mode--current-p (request)
  "Return non-nil when REQUEST still owns the same session and directory."
  (let ((origin (kargu-mode-preparation-origin request))
        (session (kargu-mode-preparation-session request)))
    (and (buffer-live-p origin)
         (eq session (kargu-session-context origin))
         (eq request (kargu-session-mode-request session))
         (equal (kargu-mode-preparation-directory request)
                (buffer-local-value 'default-directory origin)))))

(defun kargu-mode--finish (request error)
  "Complete REQUEST with ERROR, or its prepared mode, without publishing it."
  (let ((current (kargu-mode--current-p request)))
    (kargu-async-finish
     (kargu-mode-preparation-task request)
     (and current (null error) (kargu-mode-preparation-mode request))
     (or error (unless current "Mode preparation owner changed")))))

(defun kargu-mode--release (request close)
  "Release REQUEST's intent and its origin CLOSE hook."
  (let ((session (kargu-mode-preparation-session request))
        (origin (kargu-mode-preparation-origin request)))
    (when (eq request (kargu-session-mode-request session))
      (setf (kargu-session-mode-request session) nil))
    (when (buffer-live-p origin)
      (with-current-buffer origin (remove-hook 'kill-buffer-hook close t)))))

(defun kargu-mode--invoke (request prepare)
  "Invoke PREPARE for REQUEST through single-delivery callbacks."
  (let ((ready (lambda () (kargu-mode--finish request nil)))
        (failed (lambda (error) (kargu-mode--finish request error)))
        (kargu-async--current-task (kargu-mode-preparation-task request)))
    (cond
     ((null prepare) (funcall ready))
     ((equal (cdr (func-arity prepare)) 1) (funcall prepare ready))
     (t (funcall prepare ready failed)))))

(defun kargu-mode-prepare (mode callback)
  "Prepare MODE, delivering (MODE ERROR) to CALLBACK exactly once.
Return the owned task.  A new intent supersedes the previous one; closing,
resetting or stopping the owner cancels its preparation and children."
  (kargu-contract-assert #'kargu-contract-mode-p mode)
  (kargu-contract-assert #'functionp callback)
  (when (or (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
            (and (fboundp 'kargu-busy-p) (kargu-busy-p)))
    (user-error "Kargu: stop active work before preparing a mode"))
  (let* ((session (kargu-session-context))
         (request (kargu-mode--create :origin (current-buffer) :session session
                                     :directory default-directory :mode mode))
         (close (lambda () (kargu-mode-cancel session))))
    (kargu-mode-cancel session)
    (unless (and (eq session (kargu-session-context))
                 (null (kargu-session-mode-request session)))
      (user-error "Kargu: mode preparation owner changed"))
    (setf (kargu-mode-preparation-task request) (kargu-async-start callback)
          (kargu-session-mode-request session) request)
    (add-hook 'kill-buffer-hook close nil t)
    (kargu-async-add-cleanup (kargu-mode-preparation-task request)
                             (lambda () (kargu-mode--release request close)))
    (condition-case failure
        (kargu-mode--invoke request (alist-get mode kargu-mode-prepare-functions))
      (error (kargu-mode--finish request (error-message-string failure))))
    (kargu-mode-preparation-task request)))

(add-hook 'kargu-session-before-replace-hook #'kargu-mode-cancel)

(defun kargu/application/mode-unload-function ()
  "Cancel this adapter's pending intents before detaching its lifecycle hook."
  (dolist (buffer (buffer-list))
    (when-let* ((session (buffer-local-value 'kargu-session--context buffer)))
      (kargu-mode-cancel session)))
  (remove-hook 'kargu-session-before-replace-hook #'kargu-mode-cancel)
  nil)

(provide 'kargu/application/mode)
;;; mode.el ends here
