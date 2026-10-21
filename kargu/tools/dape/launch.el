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
(require 'kargu/tools/dape/lifecycle)

(defvar dape--connections)
(defvar dape--connection-selected)
(defvar dape--connection-counter)
(defvar dape-debug)

(declare-function kargu-session-id "kargu/core/session" ())
(declare-function dape "dape" (config &optional skip-compile))
(declare-function dape-connection "dape" (&rest slots))
(declare-function dape-handle-request "dape" (conn command arguments))
(declare-function dape-handle-event "dape" (conn event body))
(declare-function dape--guess-root "dape" (config))
(declare-function dape--start-debugging "dape" (conn))
(declare-function dape--children "dape" (conn))
(declare-function dape--repl-insert "dape" (string))
(declare-function dape--repl-insert-error "dape" (string))

(defconst kargu-dape--deferred-launch-timeout 60
  "Seconds allowed for a deferred adapter launch to finish.")

(defcustom kargu-dape-port-max-retries 30
  "Maximum nonblocking connection attempts for a socket debug adapter."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-dape-port-retry-interval 0.1
  "Seconds between nonblocking socket connection attempts."
  :type 'number
  :group 'kargu)

(defconst kargu-dape--obsolete-launch-error
  "Debugger startup cancelled: launch ownership changed"
  "Refusal at the final adapter creation boundary.")

(cl-defstruct (kargu-dape--operation (:constructor kargu-dape--make-operation))
  "One launch's captured source, origin, parent and continuation state."
  origin root session mode owner source file tick source-mode directory environment path
  validator parent task (phase :launching))

(cl-defstruct (kargu-dape--port-connect (:constructor kargu-dape--make-port-connect))
  "Owned nonblocking TCP adapter connection state and transport resources."
  config operation parent parent-resource
  host port command directory environment
  server stderr-buffer stderr-pipe socket timer
  (retries kargu-dape-port-max-retries)
  (phase :connecting))

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
        (catch 'kargu-dape--async-connecting
          (funcall (kargu-async-wrap task function)))
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
                     (unless (memq (kargu-dape--operation-phase operation)
                                   '(:connecting :started :aborted))
                       (kargu-async-finish task t))))))))

(defun kargu-dape--compile-owned (original config continuation)
  "Call ORIGINAL with CONFIG and a lifetime-guarded CONTINUATION if owned."
  (if-let* ((operation (plist-get config 'kargu--launch-operation)))
      (progn
        (setf (kargu-dape--operation-phase operation) :compiling)
        (funcall original config (lambda () (kargu-dape--resume-compile operation continuation))))
    (funcall original config continuation)))

(defun kargu-dape--port-connect-valid-p (state)
  "Return non-nil while STATE's operation and parent still own the launch."
  (let ((operation (kargu-dape--port-connect-operation state))
        (parent (kargu-dape--port-connect-parent state))
        (parent-res (kargu-dape--port-connect-parent-resource state)))
    (and (or (null operation)
             (and (eq (kargu-dape--operation-phase operation) :connecting)
                  (kargu-async-pending-p (kargu-dape--operation-task operation))
                  (kargu-dape--operation-valid-p operation)))
         (or (null parent)
             (and (not (kargu-dape-closing-p parent))
                  (or (null parent-res)
                      (eq (kargu-dape-resource-phase parent-res) :open)))))))

(defun kargu-dape--port-connect-release (state)
  "Release STATE's owned timer, socket, server process and stderr resources."
  (when-let* ((timer (kargu-dape--port-connect-timer state)))
    (setf (kargu-dape--port-connect-timer state) nil)
    (cancel-timer timer))
  (when-let* ((socket (kargu-dape--port-connect-socket state)))
    (setf (kargu-dape--port-connect-socket state) nil)
    (when (processp socket)
      (set-process-sentinel socket #'ignore)
      (when (process-live-p socket) (delete-process socket))))
  (when-let* ((server (kargu-dape--port-connect-server state)))
    (setf (kargu-dape--port-connect-server state) nil)
    (when (processp server)
      (set-process-sentinel server #'ignore)
      (when (process-live-p server) (delete-process server))))
  (when-let* ((pipe (kargu-dape--port-connect-stderr-pipe state)))
    (setf (kargu-dape--port-connect-stderr-pipe state) nil)
    (when (processp pipe)
      (set-process-sentinel pipe #'ignore)
      (when (process-live-p pipe) (delete-process pipe))))
  (when-let* ((buffer (kargu-dape--port-connect-stderr-buffer state)))
    (setf (kargu-dape--port-connect-stderr-buffer state) nil)
    (kargu-dape-resource--kill-buffer buffer)))

(defun kargu-dape--port-connect-abort (state &optional reason)
  "Abort STATE once, releasing owned resources and reporting REASON."
  (when (eq (kargu-dape--port-connect-phase state) :connecting)
    (setf (kargu-dape--port-connect-phase state) :aborted)
    (kargu-dape--port-connect-release state)
    (when-let* ((operation (kargu-dape--port-connect-operation state))
                (task (kargu-dape--operation-task operation)))
      (setf (kargu-dape--operation-phase operation) :aborted)
      (when (and reason (kargu-async-pending-p task))
        (kargu-async-finish task nil reason)))))

(defun kargu-dape--port-connect-fail (state)
  "Report server stderr and abort STATE with a connection refusal."
  (when (eq (kargu-dape--port-connect-phase state) :connecting)
    (when-let* ((buffer (kargu-dape--port-connect-stderr-buffer state))
                ((buffer-live-p buffer))
                (content (with-current-buffer buffer (buffer-string)))
                ((not (string-empty-p content)))
                ((fboundp 'dape--repl-insert-error)))
      (ignore-errors (dape--repl-insert-error (concat content "\n"))))
    (kargu-dape--port-connect-abort state "Unable to connect to server")))

(defun kargu-dape--make-port-dape-connection (state socket)
  "Construct and adopt a `dape-connection' from STATE and connected SOCKET."
  (let* ((config (kargu-dape--port-connect-config state))
         (parent (kargu-dape--port-connect-parent state))
         (command (kargu-dape--port-connect-command state))
         (host (kargu-dape--port-connect-host state))
         (port (kargu-dape--port-connect-port state))
         (server (kargu-dape--port-connect-server state))
         (stderr (kargu-dape--port-connect-stderr-buffer state))
         (counter (if (boundp 'dape--connection-counter)
                      (cl-incf dape--connection-counter)
                    1))
         (connection
          (dape-connection
           :name (format "dape-%s<%d>"
                         (or (and (car command) command)
                             (format "%s:%s" host port))
                         counter)
           :config config
           :parent parent
           :server-process server
           :events-buffer-config `(:size ,(if (and (boundp 'dape-debug) dape-debug) nil 0)
                                         :format full)
           :on-shutdown #'ignore
           :request-dispatcher #'dape-handle-request
           :notification-dispatcher #'dape-handle-event
           :process socket
           :stderr-buffer stderr)))
    ;; Transfer ownership of server, socket and stderr to the adopted resource.
    (setf (kargu-dape--port-connect-socket state) nil
          (kargu-dape--port-connect-server state) nil
          (kargu-dape--port-connect-stderr-pipe state) nil
          (kargu-dape--port-connect-stderr-buffer state) nil)
    (when (processp server)
      (set-process-sentinel server #'ignore))
    (kargu-dape-adopt connection)
    connection))

(defun kargu-dape--port-connect-complete (state socket)
  "Finalize STATE with connected SOCKET, adopting and starting debugging."
  (save-match-data
    (when (eq (kargu-dape--port-connect-phase state) :connecting)
      (when-let* ((timer (kargu-dape--port-connect-timer state)))
        (setf (kargu-dape--port-connect-timer state) nil)
        (cancel-timer timer))
      (if (not (kargu-dape--port-connect-valid-p state))
          (kargu-dape--port-connect-abort state kargu-dape--obsolete-launch-error)
        (setf (kargu-dape--port-connect-phase state) :connected)
        (let ((operation (kargu-dape--port-connect-operation state))
              (parent (kargu-dape--port-connect-parent state))
              (connection nil))
          (condition-case err
              (progn
                (when operation
                  (setf (kargu-dape--operation-phase operation) :creating))
                (setq connection (kargu-dape--make-port-dape-connection state socket))
                (if parent
                    (push connection (dape--children parent))
                  (push connection dape--connections)
                  (unless (kargu-dape--foreign-selected-p connection)
                    (setq dape--connection-selected connection)))
                (let ((source (and operation (kargu-dape--operation-source operation))))
                  (if (buffer-live-p source)
                      (with-current-buffer source (dape--start-debugging connection))
                    (dape--start-debugging connection)))
                (when operation
                  (setf (kargu-dape--operation-phase operation) :started)
                  (kargu-async-finish (kargu-dape--operation-task operation) t)))
            (quit
             (when (and connection (kargu-dape-resource connection))
               (kargu-dape-resource-stop (kargu-dape-resource connection)))
             (kargu-dape--port-connect-release state)
             (when operation
               (setf (kargu-dape--operation-phase operation) :aborted)
               (kargu-async-finish (kargu-dape--operation-task operation)
                                   nil "Debugger startup cancelled by user")))
            (error
             (when (and connection (kargu-dape-resource connection))
               (kargu-dape-resource-stop (kargu-dape-resource connection)))
             (kargu-dape--port-connect-release state)
             (when operation
               (setf (kargu-dape--operation-phase operation) :aborted)
               (kargu-async-finish (kargu-dape--operation-task operation)
                                   nil (error-message-string err))))))))))

(defun kargu-dape--port-schedule-retry (state)
  "Schedule STATE's next nonblocking connection attempt without sleeping."
  (when (eq (kargu-dape--port-connect-phase state) :connecting)
    (when-let* ((old (kargu-dape--port-connect-timer state)))
      (cancel-timer old))
    (setf (kargu-dape--port-connect-timer state)
          (run-at-time kargu-dape-port-retry-interval nil
                       #'kargu-dape--port-attempt-connect state))))

(defun kargu-dape--port-retry-or-fail (state)
  "Schedule another attempt for STATE, or fail if exhausted or server died."
  (let ((server (kargu-dape--port-connect-server state)))
    (if (or (<= (kargu-dape--port-connect-retries state) 0)
            (and (processp server) (not (process-live-p server))))
        (kargu-dape--port-connect-fail state)
      (kargu-dape--port-schedule-retry state))))

(defun kargu-dape--port-socket-sentinel (state socket _event)
  "Handle nonblocking SOCKET status changes for STATE."
  (save-match-data
    (when (and (eq (kargu-dape--port-connect-phase state) :connecting)
               (eq socket (kargu-dape--port-connect-socket state)))
      (let ((status (process-status socket)))
        (cond
         ((memq status '(open run))
          (kargu-dape--port-connect-complete state socket))
         ((not (eq status 'connect))
          (setf (kargu-dape--port-connect-socket state) nil)
          (set-process-sentinel socket #'ignore)
          (when (process-live-p socket) (delete-process socket))
          (kargu-dape--port-retry-or-fail state)))))))

(defun kargu-dape--port-server-sentinel (state server _event)
  "Abort STATE if SERVER exits before a socket connection is established."
  (save-match-data
    (when (and (eq (kargu-dape--port-connect-phase state) :connecting)
               (eq server (kargu-dape--port-connect-server state))
               (not (process-live-p server))
               (null (kargu-dape--port-connect-socket state)))
      (kargu-dape--port-connect-fail state))))

(defun kargu-dape--port-attempt-connect (state)
  "Perform one nonblocking socket connection attempt for STATE."
  (save-match-data
    (when (eq (kargu-dape--port-connect-phase state) :connecting)
      (setf (kargu-dape--port-connect-timer state) nil)
      (let ((server (kargu-dape--port-connect-server state)))
        (cond
         ((not (kargu-dape--port-connect-valid-p state))
          (kargu-dape--port-connect-abort state kargu-dape--obsolete-launch-error))
         ((and (processp server) (not (process-live-p server)))
          (kargu-dape--port-connect-fail state))
         ((<= (kargu-dape--port-connect-retries state) 0)
          (kargu-dape--port-connect-fail state))
         (t
          (cl-decf (kargu-dape--port-connect-retries state))
          (let ((default-directory (kargu-dape--port-connect-directory state))
                (process-environment (kargu-dape--port-connect-environment state))
                (proc nil))
            (condition-case nil
                (setq proc
                      (make-network-process
                       :name (format "dape adapter%s connection"
                                     (if (kargu-dape--port-connect-parent state) " child" ""))
                       :host (kargu-dape--port-connect-host state)
                       :coding 'utf-8-emacs-unix
                       :service (kargu-dape--port-connect-port state)
                       :nowait t
                       :noquery t
                       :sentinel (lambda (socket event)
                                   (kargu-dape--port-socket-sentinel state socket event))))
              (error (setq proc nil)))
            (cond
             ((null proc)
              (kargu-dape--port-retry-or-fail state))
             ((memq (process-status proc) '(open run))
              (setf (kargu-dape--port-connect-socket state) proc)
              (kargu-dape--port-connect-complete state proc))
             ((eq (process-status proc) 'connect)
              (setf (kargu-dape--port-connect-socket state) proc))
             (t
              (set-process-sentinel proc #'ignore)
              (when (process-live-p proc) (delete-process proc))
              (kargu-dape--port-retry-or-fail state))))))))))

(defun kargu-dape--prepare-port-environment (config)
  "Return process-environment list with CONFIG's `command-env' applied."
  (let ((process-environment (cl-copy-list process-environment)))
    (cl-loop for (key value) on (plist-get config 'command-env) by #'cddr do
             (setenv (pcase key
                       ((pred keywordp) (substring (format "%s" key) 1))
                       ((or (pred symbolp) (pred stringp)) (format "%s" key))
                       (_ (user-error "Bad type for `command-env' key %S" key)))
                     (format "%s" value)))
    process-environment))

(cl-defun kargu-dape--start-port-connection (config &key operation parent)
  "Start a nonblocking socket adapter connection for CONFIG, OPERATION and PARENT."
  (unless (plist-get config 'command-cwd)
    (plist-put config 'command-cwd
               (if (fboundp 'dape--guess-root)
                   (dape--guess-root config)
                 default-directory)))
  (let* ((directory (plist-get config 'command-cwd))
         (environment (kargu-dape--prepare-port-environment config))
         (command (when (plist-get config 'command)
                    (cons (plist-get config 'command)
                          (cl-map 'list #'identity (plist-get config 'command-args)))))
         (state (kargu-dape--make-port-connect
                 :config config :operation operation :parent parent
                 :parent-resource (and parent (kargu-dape-resource parent))
                 :host (or (plist-get config 'host) "localhost")
                 :port (plist-get config 'port)
                 :command command :directory directory :environment environment
                 :retries (max 1 kargu-dape-port-max-retries))))
    (when operation
      (kargu-async-add-cleanup
       (kargu-dape--operation-task operation)
       (lambda () (kargu-dape--port-connect-abort state))))
    (condition-case err
        (let ((default-directory directory)
              (process-environment environment))
          (when command
            (let* ((stderr
                    (with-current-buffer
                        (generate-new-buffer " *dape-adapter stderr*")
                      (when (and (plist-get config 'command-insert-stderr)
                                 (fboundp 'dape--repl-insert-error))
                        (add-hook 'after-change-functions
                                  (lambda (beg end _len)
                                    (dape--repl-insert-error
                                     (buffer-substring beg end)))
                                  nil t))
                      (current-buffer)))
                   (server
                    (progn
                      (setf (kargu-dape--port-connect-stderr-buffer state) stderr)
                      (make-process
                       :name "dape adapter"
                       :command command
                       :filter (lambda (_process string)
                                 (when (fboundp 'dape--repl-insert)
                                   (dape--repl-insert string)))
                       :file-handler t
                       :buffer nil
                       :noquery t
                       :stderr stderr
                       :sentinel (lambda (proc event)
                                   (kargu-dape--port-server-sentinel state proc event)))))
                   (pipe (get-buffer-process stderr)))
              (setf (kargu-dape--port-connect-server state) server
                    (kargu-dape--port-connect-stderr-pipe state) pipe)
              (process-put server 'stderr-pipe stderr)
              (when (processp pipe)
                (set-process-sentinel pipe #'ignore))))
          (if (file-remote-p directory)
              (kargu-dape--port-schedule-retry state)
            (kargu-dape--port-attempt-connect state)))
      (quit
       (kargu-dape--port-connect-abort state "Debugger startup cancelled by user"))
      (error
       (kargu-dape--port-connect-abort state (error-message-string err))))
    state))

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
        (unless (kargu-dape-lifecycle-supported-p)
          (user-error "Kargu: this Dape/JSONRPC lifecycle capability is unsupported"))
        ;; Child adapters must not inherit an already consumed launch guard.
        (let ((clean (copy-sequence config)))
          (cl-remf clean 'kargu--launch-operation)
          (if (plist-get clean 'port)
              (progn
                (setf (kargu-dape--operation-phase operation) :connecting)
                (kargu-dape--start-port-connection
                 clean :operation operation :parent parent)
                (throw 'kargu-dape--async-connecting
                       (kargu-dape--operation-task operation)))
            (setf (kargu-dape--operation-phase operation) :creating)
            (let ((connection (funcall original clean parent)))
              (kargu-dape-adopt connection)
              connection))))
    (when (and parent (kargu-dape-closing-p parent))
      (user-error "Kargu: parent debug adapter is closing"))
    (if (and parent (kargu-dape-resource parent) (plist-get config 'port))
        (progn
          (kargu-dape--start-port-connection (copy-sequence config) :parent parent)
          (throw 'kargu-dape--async-connecting nil))
      (let ((connection (funcall original config parent)))
        (when (and parent (kargu-dape-resource parent))
          (kargu-dape-adopt connection))
        connection))))

(defun kargu-dape--dape-owned (original config &optional skip-compile)
  "Allow owned asynchronous port launches in CONFIG to return before connecting."
  (catch 'kargu-dape--async-connecting
    (funcall original config skip-compile)))

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
                 (unless (memq (kargu-dape--operation-phase operation)
                               '(:compiling :connecting :started :aborted))
                   (kargu-async-finish task t))))
    task))

(with-eval-after-load 'dape
  (when (fboundp 'kargu-dape--compile-owned)
    (advice-add 'dape :around #'kargu-dape--dape-owned)
    (advice-add 'dape--compile :around #'kargu-dape--compile-owned)
    (advice-add 'dape--create-connection :around #'kargu-dape--create-owned)))

(defun kargu/tools/dape/launch-unload-function ()
  "Remove owned launch guards when this feature is unloaded."
  (advice-remove 'dape #'kargu-dape--dape-owned)
  (advice-remove 'dape--compile #'kargu-dape--compile-owned)
  (advice-remove 'dape--create-connection #'kargu-dape--create-owned)
  nil)

(provide 'kargu/tools/dape/launch)
;;; launch.el ends here
