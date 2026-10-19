;;; launch.el --- Owned deferred debugger launches -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Guard Dape's deferred compile continuation and final connection boundary.
;; Compilation processes, buffers and finish hooks remain owned by Dape.

;;; Code:

(require 'kargu/async)
(require 'kargu/state)
(require 'kargu/permission)

(declare-function kargu-session-id "kargu/core/session" ())
(declare-function dape "dape" (config &optional skip-compile))

(defconst kargu-dape--deferred-launch-timeout 60
  "Seconds allowed for a deferred adapter launch to finish.")

(defconst kargu-dape--obsolete-launch-error
  "Debugger startup cancelled: launch ownership changed"
  "Refusal at the final adapter creation boundary.")

(cl-defstruct (kargu-dape--operation (:constructor kargu-dape--make-operation))
  "One launch's captured source, origin, parent and continuation state."
  origin root session mode owner source file tick source-mode directory environment path
  validator parent task (phase :launching))

(defun kargu-dape--operation-valid-p (operation)
  "Return non-nil while OPERATION still owns its captured launch intent."
  (condition-case nil
      (let ((origin (kargu-dape--operation-origin operation))
            (source (kargu-dape--operation-source operation))
            (parent (kargu-dape--operation-parent operation)))
        (and (buffer-live-p origin) (buffer-live-p source)
             (eq (kargu-dape--operation-owner operation) kargu--loop-run)
             (or (null parent) (kargu-async-pending-p parent))
             (with-current-buffer origin
               (and (equal (kargu-dape--operation-root operation) (kargu-permission-project-root))
                    (equal (kargu-dape--operation-session operation) (kargu-session-id))
                    (eq (kargu-dape--operation-mode operation) (kargu-state-mode))
                    (or (null parent) (null (kargu-async-task-valid-p parent))
                        (funcall (kargu-async-task-valid-p parent)))))
             (with-current-buffer source
               (and (equal (kargu-dape--operation-file operation) buffer-file-name)
                    (or (null (kargu-dape--operation-validator operation))
                        (funcall (kargu-dape--operation-validator operation)))
                    (= (kargu-dape--operation-tick operation) (buffer-chars-modified-tick))
                    (eq (kargu-dape--operation-source-mode operation) major-mode)
                    (equal (kargu-dape--operation-directory operation) default-directory)
                    (equal (kargu-dape--operation-environment operation) process-environment)
                    (equal (kargu-dape--operation-path operation) exec-path)
                    (or (null buffer-file-name)
                        (kargu-permission-within-project-p
                         buffer-file-name (kargu-dape--operation-root operation)))))))
    (file-error nil)))

(defun kargu-dape--run-launch (operation function)
  "Run OPERATION's guarded FUNCTION, treating editor quit as cancellation."
  (let ((task (kargu-dape--operation-task operation)))
    (condition-case nil
        (funcall (kargu-async-wrap task function))
      (quit (kargu-async-finish task nil "Debugger startup cancelled by user")))))

(defun kargu-dape--resume-compile (operation continuation)
  "Resume OPERATION's CONTINUATION once, closing replaced run ownership."
  (save-match-data
    (let ((task (kargu-dape--operation-task operation)))
      (if (not (kargu-async-pending-p task)) (kargu-async-cancel task)
        (kargu-dape--run-launch
         operation (lambda ()
                     (unless (eq (kargu-dape--operation-phase operation) :compiling)
                       (error "Debugger compile continuation was already consumed"))
                     (setf (kargu-dape--operation-phase operation) :launching)
                     (funcall continuation)
                     (kargu-async-finish task t)))))))

(defun kargu-dape--compile-owned (original config continuation)
  "Call ORIGINAL with CONFIG and a lifetime-guarded CONTINUATION if owned."
  (if-let* ((operation (plist-get config 'kargu--launch-operation)))
      (progn
        (setf (kargu-dape--operation-phase operation) :compiling)
        (funcall original config (lambda () (kargu-dape--resume-compile operation continuation))))
    (funcall original config continuation)))

(defun kargu-dape--create-owned (original config &optional parent)
  "Call ORIGINAL for CONFIG and PARENT only if its owned launch is valid."
  (if-let* ((operation (plist-get config 'kargu--launch-operation)))
      (save-match-data
        (unless (and (eq (kargu-dape--operation-phase operation) :launching)
                     (kargu-async-pending-p (kargu-dape--operation-task operation))
                     (kargu-dape--operation-valid-p operation))
          (kargu-async-finish (kargu-dape--operation-task operation)
                              nil kargu-dape--obsolete-launch-error)
          (error "%s" kargu-dape--obsolete-launch-error))
        (setf (kargu-dape--operation-phase operation) :creating)
        ;; Child adapters must not inherit an already consumed launch guard.
        (let ((clean (copy-sequence config)))
          (cl-remf clean 'kargu--launch-operation)
          (funcall original clean parent)))
    (funcall original config parent)))

(cl-defun kargu-dape-launch (config &key valid-p on-start)
  "Launch CONFIG with owned deferred compilation and final VALID-P checking.
Run VALID-P in the captured source buffer.  Call ON-START only after
Dape's launch call actually completes, not when
compilation is merely scheduled.  Parent cancellation suppresses late work."
  (let* ((parent kargu-async--current-task)
         (origin (if parent (kargu-async-task-buffer parent) (current-buffer)))
         (operation
          (kargu-dape--make-operation
           :origin origin :root (with-current-buffer origin (kargu-permission-project-root))
           :session (with-current-buffer origin (copy-sequence (kargu-session-id)))
           :mode (with-current-buffer origin (kargu-state-mode)) :owner kargu--loop-run
           :source (current-buffer) :file buffer-file-name :tick (buffer-chars-modified-tick)
           :source-mode major-mode
           :directory default-directory :environment (copy-sequence process-environment)
           :path (copy-sequence exec-path) :validator valid-p :parent parent))
         (task (kargu-async-start
                (lambda (_value error)
                  (cond
                   ((and error parent) (kargu-async-finish parent nil error))
                   (error (message "Kargu: %s" error))
                   (on-start (funcall on-start))))
                :timeout kargu-dape--deferred-launch-timeout
                :valid-p (lambda () (kargu-dape--operation-valid-p operation)))))
    (setf (kargu-dape--operation-task operation) task)
    (kargu-dape--run-launch
     operation (lambda ()
                 (dape (plist-put (copy-sequence config) 'kargu--launch-operation operation))
                 (unless (eq (kargu-dape--operation-phase operation) :compiling)
                   (kargu-async-finish task t))))
    task))

(with-eval-after-load 'dape
  (when (fboundp 'kargu-dape--compile-owned)
    (advice-add 'dape--compile :around #'kargu-dape--compile-owned)
    (advice-add 'dape--create-connection :around #'kargu-dape--create-owned)))

(defun kargu/tools/dape/launch-unload-function ()
  "Remove owned launch guards when this feature is unloaded."
  (advice-remove 'dape--compile #'kargu-dape--compile-owned)
  (advice-remove 'dape--create-connection #'kargu-dape--create-owned)
  nil)

(provide 'kargu/tools/dape/launch)
;;; launch.el ends here
