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
(declare-function kargu-session-id "kargu/core/session" ())
(defcustom kargu-dape-config nil
  "Dape configuration to use, or nil to discover an installed language match."
  :type '(choice (const :tag "Detect from language" nil) symbol)
  :group 'kargu-dape)

(defvar kargu-dape--verified nil
  "Map canonical project roots to verified adapter fingerprints, or nil.")

(cl-defstruct (kargu-dape--verification (:constructor kargu-dape--make-verification))
  "Immutable adapter name and configuration/environment fingerprint."
  name fingerprint)

(defun kargu-dape--project-verification ()
  "Return the current project's verified adapter identity, or nil."
  (when (hash-table-p kargu-dape--verified)
    (gethash (kargu-permission-project-root) kargu-dape--verified)))

(defun kargu-dape--remember-verification (root identity)
  "Store verified IDENTITY for ROOT without evicting other projects."
  (unless (hash-table-p kargu-dape--verified)
    (setq kargu-dape--verified (make-hash-table :test #'equal)))
  (puthash (copy-sequence root) identity kargu-dape--verified))

(defconst kargu-dape--module-probe
  "import importlib, sys; importlib.import_module(sys.argv[1])"
  "Program used to check Python-style module adapters without a shell.")

(defun kargu-dape--matching-configs (&optional preferred)
  "Return adapters for the current language, honoring PREFERRED when supplied."
  (let* ((spec (kargu-language-active))
         (modes (and spec (kargu-language-spec-modes spec)))
         (adapter (and spec (plist-get (kargu-language-spec-debugger spec) :adapter)))
         (language-config (and adapter (assoc (intern adapter) dape-configs))))
    (cond
     ((or preferred kargu-dape-config)
      (list (assq (or preferred kargu-dape-config) dape-configs)))
     (t (delete-dups
         (append (and language-config (list language-config))
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
  (let ((print-length nil) (print-level nil) (print-circle t)
        (command (plist-get (cdr config) 'command)))
    (kargu-dape--make-verification
     :name (car config)
     :fingerprint (secure-hash 'sha256 (prin1-to-string
                                       (list config exec-path process-environment
                                             (and (stringp command) (executable-find command))))))))

(defun kargu-dape-debug-refusal ()
  "Return the reason debug mode cannot be entered, or nil after verification."
  (let ((verified (kargu-dape--project-verification)))
    (cond
   ((not (fboundp 'dape)) "Dape is unavailable; install it with M-x package-install RET dape")
   ((kargu-dape-live-p) nil)
   ((not verified) "Debugger dependencies are not verified; select debug using M-x kargu-set-mode")
   (t
    (let ((config (assq (kargu-dape--verification-name verified) dape-configs)))
      (or (kargu-dape--config-error config)
          (when (and kargu-dape-config (not (eq kargu-dape-config (car config))))
            "Debugger selection changed; verify the selected adapter again")
          (unless (equal verified (kargu-dape--config-key config))
            "Debugger project or configuration changed; select debug again")))))))

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
          (kargu-async-add-cleanup task (lambda () (kargu-process-cancel process))))
      (funcall callback nil))))

(cl-defun kargu-dape--prepare-next (configs key done &key errors)
  "Verify CONFIGS for project KEY, invoking DONE or reporting ERRORS."
  (if (null configs)
      (error "Debug unavailable: %s"
             (string-join (or (nreverse errors) '("No adapter configured for this language")) "; "))
    (let* ((config (car configs))
           (identity (kargu-dape--config-key config))
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
             ((not (equal identity (kargu-dape--config-key (assq (car config) dape-configs))))
              (error "Debug selection cancelled: configuration changed during verification"))
             (t
              (kargu-dape--remember-verification key identity)
              (funcall done))))))))))

(defun kargu-dape-prepare-debug (done &optional on-error config-name)
  "Verify debugger dependencies without blocking, then invoke DONE.
Failures leave the mode and prompt unchanged and report through ON-ERROR.
CONFIG-NAME optionally selects an adapter without changing user preferences."
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
                (kargu-dape--matching-configs config-name) root
                (lambda () (kargu-async-finish task t))))))
      task)))

(defun kargu-dape-selected-config ()
  "Return the verified Dape configuration name for the current project."
  (when-let* ((verified (kargu-dape--project-verification))
              ((not (kargu-dape-debug-refusal))))
    (kargu-dape--verification-name verified)))

(cl-defun kargu-dape-launch-config (name &key token)
  "Launch verified configuration NAME using Dape's plist API.
TOKEN optionally identifies this launch without adding a wire argument."
  (let ((config (assq name dape-configs)))
    (unless config (user-error "Unknown Dape configuration: %s" name))
    (let ((copy (kargu-dape--ensure-stop-on-entry (copy-tree (cdr config)))))
      (when token (setq copy (plist-put copy 'kargu--launch-token token)))
      (dape copy))))

(cl-defstruct (kargu-dape--launch (:constructor kargu-dape--make-launch))
  "Captured startup intent, independent of subsequent editor selection."
  origin root session buffer file directory tick mode selection preferred verification)

(defun kargu-dape--launch-valid-p (launch)
  "Return non-nil when LAUNCH still owns its source, session and adapter."
  (let ((origin (kargu-dape--launch-origin launch))
        (buffer (kargu-dape--launch-buffer launch))
        (root (kargu-dape--launch-root launch))
        (verification (kargu-dape--launch-verification launch)))
    (and (buffer-live-p origin) (buffer-live-p buffer)
         (with-current-buffer origin
           (and (equal root (kargu-permission-project-root))
                (equal (kargu-dape--launch-session launch) (kargu-session-id))
                (eq (kargu-dape--launch-selection launch) kargu-dape-config)
                (eq buffer (kargu-dape-source-buffer root))
                (null (kargu-dape-project-connections root))
                (or (null verification)
                    (eq verification (kargu-dape--project-verification)))))
         (with-current-buffer buffer
           (and buffer-file-name
                (equal (kargu-dape--launch-file launch) (file-truename buffer-file-name))
                (kargu-permission-within-project-p buffer-file-name root)
                (equal (kargu-dape--launch-directory launch) default-directory)
                (= (kargu-dape--launch-tick launch) (buffer-chars-modified-tick))
                (eq (kargu-dape--launch-mode launch) major-mode)
                (or (null verification)
                    (equal verification
                           (kargu-dape--config-key
                            (assq (kargu-dape--verification-name verification)
                                  dape-configs)))))))))

(defun kargu-dape--capture-launch (preferred)
  "Capture startup identity for PREFERRED, requiring a workspace source."
  (let* ((root (kargu-permission-project-root))
         (buffer (kargu-dape-source-buffer root)))
    (unless buffer
      (user-error "Kargu: Open a source file in this project before launching Dape"))
    (kargu-dape--make-launch
     :origin (current-buffer) :root root :session (copy-sequence (kargu-session-id))
     :buffer buffer :file (file-truename (buffer-file-name buffer))
     :directory (buffer-local-value 'default-directory buffer)
     :tick (with-current-buffer buffer (buffer-chars-modified-tick))
     :mode (buffer-local-value 'major-mode buffer)
     :selection kargu-dape-config :preferred preferred)))

(defun kargu-dape--approve-launch (task launch)
  "Request approval for TASK's verified LAUNCH without adopting later state."
  (let* ((verification (kargu-dape--project-verification))
         (name (and verification (kargu-dape--verification-name verification))))
    (unless (and name (or (null (kargu-dape--launch-preferred launch))
                         (eq name (kargu-dape--launch-preferred launch))))
      (error "Debugger startup cancelled: verified adapter changed"))
    (setf (kargu-dape--launch-verification launch) verification)
    (unless (kargu-dape--launch-valid-p launch)
      (error "Debugger startup cancelled: source, session or adapter changed"))
    (kargu-permission-request-approval-async
     (format "start debug adapter %s" name) (kargu-dape--launch-root launch)
     '("The adapter can execute the target program")
     (kargu-async-wrap
      task (lambda (approved)
             (if (not approved) (kargu-async-finish task nil "Debugger startup rejected")
               (with-current-buffer (kargu-dape--launch-buffer launch)
                 (kargu-dape-launch-config name))
               (kargu-async-finish task
                                   (format "Debug session started with configuration %s" name))))))))

(defun kargu-dape-start (&optional config-name callback)
  "Verify CONFIG-NAME and start its adapter after approval through CALLBACK."
  (unless callback (user-error "Debugger startup requires an asynchronous callback"))
  (let* ((preferred (or (and config-name (intern config-name)) kargu-dape-config))
         (launch nil)
         (task (kargu-async-start
                (lambda (value error) (funcall callback (if error (concat "ERROR: " error) value)))
                :valid-p (lambda () (or (null launch) (kargu-dape--launch-valid-p launch))))))
    (funcall
     (kargu-async-wrap
      task (lambda ()
             (if (kargu-dape-live-p)
                 (kargu-async-finish task "Debug session is already running")
               (setq launch (kargu-dape--capture-launch preferred))
               (with-current-buffer (kargu-dape--launch-buffer launch)
                 (kargu-dape-prepare-debug
                  (kargu-async-wrap
                   task (lambda () (kargu-dape--approve-launch task launch)))
                  (lambda (error) (kargu-async-finish task nil error)) preferred))))))
    task))

(setf (alist-get 'debug kargu-mode-prepare-functions) #'kargu-dape-prepare-debug)
(add-hook 'kargu-state-before-mode-change-hook #'kargu-dape--guard-mode)

(provide 'kargu/tools/dape/preflight)
;;; preflight.el ends here
