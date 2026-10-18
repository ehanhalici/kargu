;;; preflight.el --- Non-blocking debugger admission checks -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Check concrete adapter commands, scripts and modules before debug mode.

;;; Code:

(require 'kargu/tools/dape/session)
(require 'kargu/tools/process)
(require 'kargu/async)

(defvar dape-configs)
(defcustom kargu-dape-config nil
  "Dape configuration to use, or nil to discover an installed language match."
  :type '(choice (const :tag "Detect from language" nil) symbol)
  :group 'kargu-dape)

(defvar kargu-dape--verified nil
  "Verified adapter identity for the selected project and configuration.")

(defconst kargu-dape--module-probe
  "import importlib, sys; importlib.import_module(sys.argv[1])"
  "Program used to check Python-style module adapters without a shell.")

(defun kargu-dape--matching-configs ()
  "Return configured adapters appropriate to the current language context."
  (let* ((spec (kargu-language-active))
         (modes (and spec (kargu-language-spec-modes spec)))
         (adapter (and spec (plist-get (kargu-language-spec-debugger spec) :adapter)))
         (preferred (and adapter (assoc (intern adapter) dape-configs))))
    (cond
     (kargu-dape-config (list (assq kargu-dape-config dape-configs)))
     (t (delete-dups
         (append (and preferred (list preferred))
                 (seq-filter
                  (lambda (config)
                    (let ((supported (plist-get (cdr config) 'modes)))
                      (and supported (seq-intersection modes supported))))
                  dape-configs)))))))

(defun kargu-dape--config-error (config)
  "Return a missing dependency description for CONFIG, or nil."
  (let* ((data (cdr config))
         (command (plist-get data 'command))
         (args (plist-get data 'command-args)))
    (cond
     ((null config) "No matching Dape configuration; set `kargu-dape-config' or configure Dape for this language")
     ((and (not command) (not (integerp (plist-get data 'port))))
      (format "Adapter %s needs a concrete command or attach port" (car config)))
     ((and command (not (stringp command)))
      (format "Adapter %s has a dynamic command; provide a concrete configuration" (car config)))
     ((and command (not (executable-find command)))
      (format "Adapter %s requires executable %s; install it or update dape-configs" (car config) command))
     ((seq-find (lambda (arg) (and (stringp arg) (file-name-absolute-p arg)
                                   (not (file-exists-p arg))))
                (if (listp args) args (and (vectorp args) (append args nil))))
      (format "Adapter %s references a missing script or dependency in command-args; install the adapter" (car config))))))

(defun kargu-dape--config-key (config)
  "Identity used to reject stale verification of CONFIG."
  (list (kargu-permission-project-root) (copy-tree config) (copy-sequence exec-path)))

(defun kargu-dape-debug-refusal ()
  "Return the reason debug mode cannot be entered, or nil after verification."
  (cond
   ((not (fboundp 'dape)) "Dape is unavailable; install it with M-x package-install RET dape")
   ((kargu-dape-live-p) nil)
   ((not kargu-dape--verified) "Debugger dependencies are not verified; select debug using M-x kargu-set-mode")
   (t
    (let ((config (assq (car (cadr kargu-dape--verified)) dape-configs)))
      (or (kargu-dape--config-error config)
          (when (and kargu-dape-config (not (eq kargu-dape-config (car config))))
            "Debugger selection changed; verify the selected adapter again")
          (unless (equal kargu-dape--verified (kargu-dape--config-key config))
            "Debugger project or configuration changed; select debug again"))))))

(defun kargu-dape--guard-mode (mode)
  "Reject MODE before mutating state if debugger admission failed."
  (when (eq mode 'debug)
    (when-let* ((reason (kargu-dape-debug-refusal)))
      (user-error "Kargu: %s" reason))))

(defun kargu-dape--verify-config (config callback)
  "Check CONFIG asynchronously and deliver a refusal or nil to CALLBACK."
  (let* ((data (cdr config))
         (command (plist-get data 'command))
         (args (plist-get data 'command-args))
         (module (cadr (member "-m" (if (vectorp args) (append args nil) args)))))
    (if (and command (stringp module))
        (let* ((task kargu-async--current-task)
               (process (kargu-process-run
			 command (list "-c" kargu-dape--module-probe module)
			 (lambda (result)
			   (funcall callback (unless (eql (plist-get result :code) 0)
					       (format "Adapter %s: module %s is unavailable in %s; install it in that environment"
						       (car config) module command)))) :timeout 5)))
          (setf (kargu-async-task-cancel task)
                (lambda () (kargu-process-cancel process))))
      (funcall callback nil))))

(cl-defun kargu-dape--prepare-next (configs key done &key errors)
  "Verify CONFIGS for project KEY, invoking DONE or reporting ERRORS."
  (if (null configs)
      (error "Debug unavailable: %s"
             (string-join (or (nreverse errors) '("No adapter configured for this language")) "; "))
    (let* ((config (car configs))
           (error (kargu-dape--config-error config)))
      (if error
          (kargu-dape--prepare-next (cdr configs) key done :errors (cons error errors))
        (kargu-dape--verify-config
         config
         (kargu-async-wrap
          kargu-async--current-task
          (lambda (refusal)
            (cond
             (refusal
              (kargu-dape--prepare-next (cdr configs) key done :errors (cons refusal errors)))
             ((not (equal key (kargu-permission-project-root)))
              (error "Debug selection cancelled: project changed"))
             (t
              (setq kargu-dape--verified (kargu-dape--config-key config))
              (funcall done))))))))))

(defun kargu-dape-prepare-debug (done &optional on-error)
  "Verify debugger dependencies without blocking, then invoke DONE.
Failures leave the mode and prompt unchanged and report through ON-ERROR."
  (unless (fboundp 'dape)
    (user-error "Kargu: Dape is unavailable; install it using M-x package-install RET dape"))
  (if (kargu-dape-live-p) (funcall done)
    (let* ((root (kargu-permission-project-root))
           (task (kargu-async-start
                  (lambda (_value error)
                    (condition-case err
                        (if error
                            (if on-error (funcall on-error error) (message "Kargu: %s" error))
                          (funcall done))
                      (user-error
                       (if on-error (funcall on-error (error-message-string err))
                         (message "%s" (error-message-string err))))))
                  :timeout 10)))
      (funcall
       (kargu-async-wrap
        task (lambda ()
               (kargu-dape--prepare-next
                (kargu-dape--matching-configs) root
                (lambda () (kargu-async-finish task t))))))
      task)))

(defun kargu-dape-selected-config ()
  "Return the verified Dape configuration name for the current project."
  (when (and kargu-dape--verified (not (kargu-dape-debug-refusal)))
    (car (cadr kargu-dape--verified))))

(defun kargu-dape-launch-config (name)
  "Launch verified configuration NAME using Dape's plist API."
  (let ((config (assq name dape-configs)))
    (unless config (user-error "Unknown Dape configuration: %s" name))
    (dape (kargu-dape--ensure-stop-on-entry (copy-tree (cdr config))))))

(cl-defun kargu-dape--approve-launch (task name &key buffer root)
  "Request approval to launch NAME for TASK in BUFFER under ROOT."
  (kargu-permission-request-approval-async
   (format "start debug adapter %s" name) root
   '("The adapter can execute the target program")
   (kargu-async-wrap
    task (lambda (approved)
           (if (not approved) (kargu-async-finish task nil "Debugger startup rejected")
             (with-current-buffer buffer (kargu-dape-launch-config name))
             (kargu-async-finish task
                                 (format "Debug session started with configuration %s" name)))))))

(defun kargu-dape-start (&optional config-name callback)
  "Verify CONFIG-NAME and start its adapter after approval through CALLBACK."
  (unless callback (user-error "Debugger startup requires an asynchronous callback"))
  (let* ((preferred (or (and config-name (intern config-name)) kargu-dape-config))
         (root (kargu-permission-project-root))
         (buffer (kargu-dape--target-buffer))
         (task (kargu-async-start
                (lambda (value error) (funcall callback (if error (concat "ERROR: " error) value))))))
    (funcall
     (kargu-async-wrap
      task (lambda ()
             (if (kargu-dape-live-p)
                 (kargu-async-finish task "Debug session is already running")
               (let ((kargu-dape-config preferred))
                 (kargu-dape-prepare-debug
                  (kargu-async-wrap
                   task (lambda ()
                          (let ((kargu-dape-config preferred))
                            (kargu-dape--approve-launch
                             task (kargu-dape-selected-config) :buffer buffer :root root))))
                  (lambda (error) (kargu-async-finish task nil error))))))))
    task))

(setf (alist-get 'debug kargu-mode-prepare-functions) #'kargu-dape-prepare-debug)
(add-hook 'kargu-state-before-mode-change-hook #'kargu-dape--guard-mode)

(provide 'kargu/tools/dape/preflight)
;;; preflight.el ends here
