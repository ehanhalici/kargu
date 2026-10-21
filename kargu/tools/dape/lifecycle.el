;;; lifecycle.el --- Scoped nonblocking Dape connection shutdown -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Keep Dape's protocol interpretation, but replace its global, waiting shutdown
;; for captured connections.  Resource handles live on their transport process,
;; not in a second global debugger registry.  No global buffer sweep is used.

;;; Code:

(require 'kargu/async)
(require 'kargu/contract/assert)
(require 'kargu/tools/dape/workspace)
(require 'kargu/tools/dape/events)
(require 'jsonrpc)
(require 'dape nil t)

(defvar dape--connections)
(defvar dape--connection-selected)
(defvar dape--request-blocking)
(defvar dape-request-timeout)
(defvar dape-active-mode)
(defvar dape-update-ui-hook)
(defvar dape-stopped-hook)
(defvar dape--breakpoints)

(declare-function dape-request "dape" (conn command arguments &optional cb))
(declare-function dape--capable-p "dape" (conn thing))
(declare-function dape--children "dape" (conn))
(declare-function dape--parent "dape" (conn))
(declare-function dape--root-of "dape" (conn))
(declare-function dape--server-process "dape" (conn))
(declare-function dape--stderr-buffer "dape" (conn))
(declare-function dape--state "dape" (conn))
(declare-function dape--thread-id "dape" (conn))
(declare-function dape--threads "dape" (conn))
(declare-function dape--current-thread "dape" (conn))
(declare-function dape--current-stack-frame "dape" (conn))
(declare-function dape--stack-trace "dape" (conn thread nof cb))
(declare-function dape--scopes "dape" (conn stack-frame cb))
(declare-function dape--threads-set-status "dape"
                  (conn thread-id all-threads status &optional update-handle))
(declare-function dape--source-buffers "dape" (conn))
(declare-function dape--initialize "dape" (conn))
(declare-function dape--breakpoint-id "dape" (breakpoint))
(declare-function dape--breakpoint-verified "dape" (breakpoint))
(declare-function dape--stack-frame-cleanup "dape" ())
(declare-function dape-active-mode "dape" (&optional arg))

(defcustom kargu-dape-close-timeout 3
  "Seconds allowed for graceful shutdown before forcing only owned resources."
  :type 'number
  :group 'kargu)

(cl-defstruct (kargu-dape-resource (:constructor kargu-dape-resource--create))
  "One adapter's transport resources and monotonic closing phase."
  (connection nil :read-only t) (process nil :read-only t)
  (server nil :read-only t) (buffers nil :read-only t) (pipes nil :read-only t)
  (parent nil :read-only t) children
  (event-handler nil :read-only t) (request-handler nil :read-only t)
  preserve-selected close-operation (phase :open))

(cl-defstruct (kargu-dape-close-operation (:constructor kargu-dape-close--create))
  "The exact connection set admitted to one asynchronous close."
  (resources nil :read-only t) (origin nil :read-only t)
  (session nil :read-only t) (directory nil :read-only t) task)

(defun kargu-dape-lifecycle-supported-p ()
  "Return non-nil when the installed Dape/JSONRPC ownership shape is supported."
  (and (featurep 'dape)
       (cl-every #'fboundp '(dape-request dape--children dape--parent
                             dape--server-process dape--stderr-buffer dape--state
                             dape--stack-frame-cleanup dape-active-mode
                             jsonrpc--process-sentinel jsonrpc--on-shutdown
                             jsonrpc--notification-dispatcher jsonrpc--request-dispatcher))
       (cl-every (lambda (slot) (slot-exists-p 'dape-connection slot))
                 '(-process -on-shutdown -request-dispatcher -notification-dispatcher
                   server-process stderr-buffer children parent))))

(defun kargu-dape-resource (connection)
  "Return CONNECTION's adopted transport handle, or nil when unsupported."
  (when (and (eieio-object-p connection) (slot-exists-p connection '-process))
    (let* ((process (jsonrpc--process connection))
           (resource (and (processp process) (process-get process 'kargu-dape-resource))))
      (and (kargu-dape-resource-p resource)
           (eq connection (kargu-dape-resource-connection resource)) resource))))

(defun kargu-dape-closing-p (connection)
  "Return non-nil when CONNECTION's owned lifecycle no longer permits work."
  (when-let* ((resource (kargu-dape-resource connection)))
    (not (eq (kargu-dape-resource-phase resource) :open))))

(defun kargu-dape-resource--check (connection)
  "Refuse CONNECTION if the installed private adapter capabilities differ."
  (unless (and (kargu-dape-lifecycle-supported-p) (eieio-object-p connection)
               (object-of-class-p connection 'dape-connection)
               (processp (jsonrpc--process connection))
               (eq connection (process-get (jsonrpc--process connection) 'jsonrpc-connection)))
    (user-error "Kargu: this Dape/JSONRPC lifecycle capability is unsupported")))

(defun kargu-dape--foreign-selected-p (connection)
  "Return non-nil when another live adapter tree owns Dape's UI selection."
  (let ((selected (or (and (boundp 'dape--connection-selected) dape--connection-selected)
                      (and (kargu-dape-resource connection)
                           (kargu-dape-resource-preserve-selected (kargu-dape-resource connection))))))
    (and selected
         (not (eq selected connection))
         (or (not (and (fboundp 'dape--root-of)
                       (eieio-object-p selected)
                       (eieio-object-p connection)))
             (not (eq (dape--root-of selected) (dape--root-of connection))))
         (or (not (eieio-object-p selected))
             (jsonrpc-running-p selected)))))

(defun kargu-dape-resource--handle-continued (connection body)
  "Update CONNECTION's running state from BODY without touching foreign UI."
  (let ((thread-id (plist-get body :threadId))
        (all-continued (if (plist-member body :allThreadsContinued)
                           (eq (plist-get body :allThreadsContinued) t)
                         t)))
    (setf (dape--state connection) 'running)
    (when (and (eieio-object-p connection) (slot-exists-p connection 'state-reason))
      (oset connection state-reason nil))
    (when (and thread-id (not (dape--thread-id connection)))
      (setf (dape--thread-id connection) thread-id))
    (when (fboundp 'dape--threads-set-status)
      (dape--threads-set-status connection thread-id all-continued "running"))
    (kargu-dape-publish-event connection 'continued)))

(defun kargu-dape-resource--event (resource event body)
  "Route RESOURCE's EVENT/BODY without Dape's global shutdown or foreign UI paths."
  (let ((connection (kargu-dape-resource-connection resource)))
    (cond
     ((memq (kargu-dape-resource-phase resource) '(:closing :releasing :closed)) nil)
     ((eq event 'terminated) (kargu-dape-resource-stop resource))
     ((and (eq event 'exited) (eq (kargu-dape-resource-phase resource) :open))
      (setf (dape--state connection) 'exited)
      (kargu-dape-publish-event connection event))
     ((and (eq event 'continued) (eq (kargu-dape-resource-phase resource) :open)
           (kargu-dape--foreign-selected-p connection))
      (kargu-dape-resource--handle-continued connection body))
     ((and (eq (kargu-dape-resource-phase resource) :open)
           (kargu-dape--foreign-selected-p connection))
      (let ((selected dape--connection-selected)
            (dape-update-ui-hook nil)
            (dape-stopped-hook nil))
        (unwind-protect
            (funcall (kargu-dape-resource-event-handler resource) connection event body)
          (setq dape--connection-selected selected))))
     ((eq (kargu-dape-resource-phase resource) :open)
      (funcall (kargu-dape-resource-event-handler resource) connection event body)))))

(defun kargu-dape-resource--request (resource command body)
  "Route COMMAND/BODY only while RESOURCE is open."
  (unless (eq (kargu-dape-resource-phase resource) :open)
    (jsonrpc-error "Kargu: captured debug adapter is closing"))
  (catch 'kargu-dape--async-connecting
    (funcall (kargu-dape-resource-request-handler resource)
             (kargu-dape-resource-connection resource) command body)))

(defun kargu-dape-resource--snapshot (connection)
  "Capture only CONNECTION's declared transport resources and callbacks."
  (let* ((process (jsonrpc--process connection))
         (server (dape--server-process connection))
         (parent (dape--parent connection))
         (stderr (delq nil (list (dape--stderr-buffer connection)
                                 (and (processp server) (process-get server 'stderr-pipe)))))
         (buffers (delete-dups
                   (delq nil (list (process-buffer process)
                                   (process-get process 'jsonrpc-stderr)
                                   (dape--stderr-buffer connection)
                                   (and (processp server) (process-get server 'stderr-pipe))
                                   (jsonrpc-events-buffer connection))))))
    (kargu-dape-resource--create
     :connection connection :process process :server server :buffers buffers
     :pipes (seq-filter (lambda (pipe) (and pipe (eq (process-type pipe) 'pipe)))
                         (mapcar #'get-buffer-process stderr))
     :parent (and parent (kargu-dape-resource parent))
     :event-handler (jsonrpc--notification-dispatcher connection)
     :request-handler (jsonrpc--request-dispatcher connection)
     :preserve-selected (and (kargu-dape--foreign-selected-p connection)
                             dape--connection-selected))))

(defun kargu-dape-adopt (connection)
  "Adopt CONNECTION's exact transport resources and nonblocking shutdown."
  (or (kargu-dape-resource connection)
      (progn
        (kargu-dape-resource--check connection)
        (let* ((process (jsonrpc--process connection))
               (sentinel (process-sentinel process))
               (resource (kargu-dape-resource--snapshot connection)))
          (process-put process 'kargu-dape-resource resource)
          (setf (jsonrpc--on-shutdown connection)
                (lambda (_connection) (kargu-dape-resource--shutdown resource)))
          (oset connection -notification-dispatcher
                (lambda (_conn event body) (kargu-dape-resource--event resource event body)))
          (oset connection -request-dispatcher
                (lambda (_conn command body) (kargu-dape-resource--request resource command body)))
          (set-process-sentinel
           process (lambda (proc change)
                     (unless (process-get proc 'jsonrpc-sentinel-cleanup-started)
                       (funcall sentinel proc change))))
          (when-let* ((parent (kargu-dape-resource-parent resource)))
            (push resource (kargu-dape-resource-children parent))
            (unless (eq (kargu-dape-resource-phase parent) :open)
              (kargu-dape-resource-stop resource)
              (user-error "Kargu: parent debug adapter closed during child startup")))
          resource))))

(defun kargu-dape-resource--kill-buffer (buffer)
  "Release owned transport BUFFER, never a visiting file or another process."
  (when (and (buffer-live-p buffer) (not (buffer-file-name buffer)))
    (unless (get-buffer-process buffer)
      (with-current-buffer buffer
        (let ((kill-buffer-query-functions nil) (kill-buffer-hook nil))
          (kill-buffer buffer))))))

(defun kargu-dape-resource--shutdown (resource)
  "Release RESOURCE exactly once after JSONRPC has drained its continuations."
  (unless (memq (kargu-dape-resource-phase resource) '(:releasing :closed))
    (setf (kargu-dape-resource-phase resource) :releasing)
    (mapc #'kargu-dape-resource-stop (copy-sequence (kargu-dape-resource-children resource)))
    (when-let* ((parent (kargu-dape-resource-parent resource)))
      (setf (kargu-dape-resource-children parent)
            (delq resource (kargu-dape-resource-children parent))))
    (when-let* ((server (kargu-dape-resource-server resource)))
      (when (process-live-p server) (delete-process server)))
    (let* ((connection (kargu-dape-resource-connection resource))
           (parent (dape--parent connection)))
      (setq dape--connections (delq connection dape--connections))
      (when parent (setf (dape--children parent) (delq connection (dape--children parent))))
      (when (eq dape--connection-selected connection)
        (dape--stack-frame-cleanup)
        (setq dape--connection-selected nil)))
    (dolist (pipe (kargu-dape-resource-pipes resource))
      (when (process-live-p pipe)
        (set-process-sentinel pipe #'ignore)
        (delete-process pipe)))
    (dolist (buffer (kargu-dape-resource-buffers resource))
      (kargu-dape-resource--kill-buffer buffer))
    (setf (kargu-dape-resource-phase resource) :closed)
    (unless dape--connections
      (condition-case err (dape-active-mode -1)
        (error (kargu-log 'warn "Debugger mode observer failed: %s" (error-message-string err)))))
    (kargu-dape-publish-event (kargu-dape-resource-connection resource) 'terminated)
    (when-let* ((operation (kargu-dape-resource-close-operation resource)))
      (when (cl-every (lambda (item) (eq (kargu-dape-resource-phase item) :closed))
                      (kargu-dape-close-operation-resources operation))
        (kargu-async-finish (kargu-dape-close-operation-task operation) t)))))

(defun kargu-dape-resource-stop (resource)
  "Force only RESOURCE's captured processes without waiting or global cleanup."
  (unless (memq (kargu-dape-resource-phase resource) '(:closing :releasing :closed))
    (setf (kargu-dape-resource-phase resource) :closing)
    (let ((process (kargu-dape-resource-process resource)))
      (when (process-live-p process) (delete-process process))
      ;; Some process implementations defer sentinel delivery.  The wrapper
      ;; guards the native JSONRPC cleanup, including a later duplicate event.
      (unless (or (process-live-p process)
                  (process-get process 'jsonrpc-sentinel-cleanup-started))
        (funcall (process-sentinel process) process "killed\n")))))

(defun kargu-dape-resource--shutdown-owned (original connection)
  "Use nonblocking shutdown for an adopted CONNECTION, otherwise call ORIGINAL."
  (if-let* ((resource (kargu-dape-resource connection)))
      (kargu-dape-resource-stop resource)
    (funcall original connection)))

(defun kargu-dape--maybe-select-thread-owned (original conn thread-id &optional force)
  "Update CONN's thread without stealing selection from a foreign adapter."
  (if (and (kargu-dape-resource conn) (kargu-dape--foreign-selected-p conn))
      (let ((selected dape--connection-selected))
        (unwind-protect
            (funcall original conn thread-id force)
          (setq dape--connection-selected selected)))
    (funcall original conn thread-id force)))

(defun kargu-dape--update-owned (original conn &optional invalidate display-source-p)
  "Hydrate CONN without moving the source overlay if a foreign adapter is active.
Delegate to ORIGINAL with INVALIDATE and DISPLAY-SOURCE-P otherwise."
  (if (and (kargu-dape-resource conn) (kargu-dape--foreign-selected-p conn))
      (progn
        (when invalidate
          (dolist (thread (dape--threads conn))
            (pcase invalidate
              ('stack-frames
               (setf (plist-get thread :stackFrames) nil
                     (plist-get thread :totalFrames) nil))
              ('variables
               (dolist (frame (plist-get thread :stackFrames))
                 (setf (plist-get frame :scopes) nil))))))
        (when (and (fboundp 'dape--stack-trace) (fboundp 'dape--current-thread))
          (dape--stack-trace
           conn (dape--current-thread conn) 1
           (lambda (&rest _)
             (when (and (fboundp 'dape--scopes) (fboundp 'dape--current-stack-frame))
               (dape--scopes conn (dape--current-stack-frame conn) #'ignore))))))
    (funcall original conn invalidate display-source-p)))

(defun kargu-dape--reset-connection-breakpoints (conn)
  "Clear breakpoint IDs and verification entries only for CONN."
  (when (and (boundp 'dape--breakpoints)
             (fboundp 'dape--breakpoint-id)
             (fboundp 'dape--breakpoint-verified))
    (dolist (breakpoint dape--breakpoints)
      (when (plist-member (dape--breakpoint-id breakpoint) conn)
        (setf (dape--breakpoint-id breakpoint)
              (plist-put (dape--breakpoint-id breakpoint) conn nil)))
      (when (plist-member (dape--breakpoint-verified breakpoint) conn)
        (setf (dape--breakpoint-verified breakpoint)
              (plist-put (dape--breakpoint-verified breakpoint) conn nil))))))

(defun kargu-dape--start-debugging-owned (original conn)
  "Start CONN without clearing foreign UI overlays or foreign breakpoints."
  (let ((resource (kargu-dape-resource conn)))
    (when (and resource (kargu-dape-resource-preserve-selected resource))
      (let ((preserved (kargu-dape-resource-preserve-selected resource)))
        (setf (kargu-dape-resource-preserve-selected resource) nil)
        (when (or (not (eieio-object-p preserved)) (jsonrpc-running-p preserved))
          (setq dape--connection-selected preserved))))
    (if (and resource (kargu-dape--foreign-selected-p conn))
        (let ((selected dape--connection-selected)
              (dape-update-ui-hook nil))
          (unwind-protect
              (progn
                (unless (dape--parent conn)
                  (kargu-dape--reset-connection-breakpoints conn)
                  (when (fboundp 'dape--source-buffers)
                    (cl-loop for (_ buffer) on (dape--source-buffers conn) by #'cddr
                             when (buffer-live-p buffer)
                             do (kill-buffer buffer))
                    (setf (dape--source-buffers conn) nil))
                  (unless dape-active-mode
                    (dape-active-mode +1))
                  (setf (dape--state conn) 'starting)
                  (when (and (eieio-object-p conn) (slot-exists-p conn 'state-reason))
                    (oset conn state-reason nil)))
                (dape--initialize conn))
            (setq dape--connection-selected selected)))
      (funcall original conn))))

(defun kargu-dape-close--resources (connection admitted)
  "Capture CONNECTION's child graph within ADMITTED workspace connections."
  (let ((pending (list connection)) (seen (make-hash-table :test #'eq)) resources)
    (while pending
      (let ((item (pop pending)))
        (unless (gethash item seen)
          (puthash item t seen)
          (push (kargu-dape-adopt item) resources)
          (dolist (child (dape--children item))
            (when (and (memq child admitted)
                       (or (eq (dape--parent child) item) (eq (dape--parent child) connection)))
              (push child pending))))))
    resources))

(defun kargu-dape-close--disconnect (resource terminate)
  "Ask RESOURCE to disconnect, setting TERMINATE only when supported."
  (setf (kargu-dape-resource-phase resource) :disconnecting)
  (let ((dape--request-blocking nil) (dape-request-timeout kargu-dape-close-timeout))
    (dape-request
     (kargu-dape-resource-connection resource) :disconnect
     (if terminate '(:restart :json-false :terminateDebuggee t)
       '(:restart :json-false :terminateDebuggee :json-false))
     (lambda (&rest _)
       (when (eq (kargu-dape-resource-phase resource) :disconnecting)
         (kargu-dape-resource-stop resource))))))

(defun kargu-dape-close--request (resource action)
  "Send the scoped shutdown ACTION for RESOURCE without blocking."
  (condition-case err
      (let* ((connection (kargu-dape-resource-connection resource))
             (terminate (not (eq action :disconnect)))
             (dape--request-blocking nil) (dape-request-timeout kargu-dape-close-timeout))
        (if (and terminate (dape--capable-p connection :supportsTerminateRequest))
            (progn
              (setf (kargu-dape-resource-phase resource) :terminating)
              (dape-request connection :terminate nil
                            (lambda (_body error)
                              (when (eq (kargu-dape-resource-phase resource) :terminating)
                                (if error (kargu-dape-close--disconnect resource t)
                                  (kargu-dape-resource-stop resource))))))
          (kargu-dape-close--disconnect resource terminate)))
    (error
     (kargu-log 'warn "Debugger close request failed: %s" (error-message-string err))
     (kargu-dape-resource-stop resource))))

(defun kargu-dape-close--task (operation callback)
  "Bind OPERATION's resources and CALLBACK to its origin's exact lifetime."
  (let* ((origin (kargu-dape-close-operation-origin operation))
         (session (kargu-dape-close-operation-session operation))
         (task
          (kargu-async-start
           (lambda (_value error)
             (when (and (buffer-live-p origin) (eq session (kargu-session-context origin))
                        (equal (kargu-dape-close-operation-directory operation)
                               (buffer-local-value 'default-directory origin)))
               (funcall callback (if error (concat "ERROR: debugger close: " error)
                                   "Captured debug adapter and owned children closed."))))
           :timeout kargu-dape-close-timeout))
         (cancel (lambda (&rest _) (kargu-async-cancel task))))
    (setf (kargu-dape-close-operation-task operation) task)
    (dolist (hook '(kill-buffer-hook change-major-mode-hook kargu-session-before-replace-hook))
      (add-hook hook cancel nil t))
    (kargu-async-add-cleanup
     task (lambda ()
            (when (buffer-live-p origin)
              (with-current-buffer origin
                (dolist (hook '(kill-buffer-hook change-major-mode-hook kargu-session-before-replace-hook))
                  (remove-hook hook cancel t))))
            (mapc #'kargu-dape-resource-stop (kargu-dape-close-operation-resources operation))))
    task))

(defun kargu-dape-close--admit (resources)
  "Require all captured RESOURCES and owned children to be idle."
  (unless (cl-every
           (lambda (resource)
             (and (eq (kargu-dape-resource-phase resource) :open)
                  (cl-every (lambda (child) (eq (kargu-dape-resource-phase child) :open))
                            (kargu-dape-resource-children resource)))) resources)
    (user-error "Kargu: a captured debug adapter is already closing")))

(cl-defun kargu-dape-close (&key connection action callback root)
  "Close captured CONNECTION with ACTION, reporting once through CALLBACK.
ROOT must still admit the connection.  Deadline or cancellation force-closes
only this operation's adapter and child resources, never a foreign session."
  (kargu-contract-assert (lambda (value) (memq value '(:kill :disconnect :quit))) action)
  (kargu-contract-assert #'functionp callback)
  (kargu-contract-assert (lambda (seconds) (and (numberp seconds) (> seconds 0)))
                          kargu-dape-close-timeout)
  (unless (memq connection (kargu-dape-project-connections root))
    (user-error "Kargu: debug adapter is not live in the captured workspace"))
  (let* ((resources (kargu-dape-close--resources
                    connection (kargu-dape-project-connections root)))
         (_admitted (kargu-dape-close--admit resources))
         (operation (kargu-dape-close--create :resources resources :origin (current-buffer)
                                             :session (kargu-session-context)
                                             :directory default-directory))
         (task (kargu-dape-close--task operation callback)))
    (dolist (resource resources)
      (when (and (kargu-async-pending-p task)
                 (eq (kargu-dape-resource-phase resource) :open))
        (setf (kargu-dape-resource-close-operation resource) operation
              (kargu-dape-resource-phase resource) :disconnecting)))
    (dolist (resource resources)
      (when (and (kargu-async-pending-p task)
                 (eq (kargu-dape-resource-phase resource) :disconnecting))
        (kargu-dape-close--request resource action)))
    (when (cl-every (lambda (resource) (eq (kargu-dape-resource-phase resource) :closed)) resources)
      (kargu-async-finish task t))
    task))

(defun kargu/tools/dape/lifecycle-unload-function ()
  "Refuse unloading callbacks still owned by live adapter processes."
  (when (seq-some (lambda (process) (process-get process 'kargu-dape-resource)) (process-list))
    (user-error "Kargu: close owned debug adapters before unloading their lifecycle"))
  (advice-remove 'dape--shutdown #'kargu-dape-resource--shutdown-owned)
  (advice-remove 'dape--maybe-select-thread #'kargu-dape--maybe-select-thread-owned)
  (advice-remove 'dape--update #'kargu-dape--update-owned)
  (advice-remove 'dape--start-debugging #'kargu-dape--start-debugging-owned)
  nil)

(with-eval-after-load 'dape
  (when (fboundp 'kargu-dape-resource--shutdown-owned)
    (advice-add 'dape--shutdown :around #'kargu-dape-resource--shutdown-owned)
    (advice-add 'dape--maybe-select-thread :around #'kargu-dape--maybe-select-thread-owned)
    (advice-add 'dape--update :around #'kargu-dape--update-owned)
    (advice-add 'dape--start-debugging :around #'kargu-dape--start-debugging-owned)))

(provide 'kargu/tools/dape/lifecycle)
;;; lifecycle.el ends here
