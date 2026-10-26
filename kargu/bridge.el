;;; bridge.el --- Bounded asynchronous Rust IPC client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Lifecycle and native read-service client.  Loading this file never starts a
;; process and does not replace the Elisp agent.  Migrated tools may explicitly
;; ensure a connection on invocation.  Callbacks receive (RESULT ERROR); wire null and
;; false are :json-null and :json-false.  Arrays remain vectors.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'kargu/core/group)

(declare-function kargu-bridge-approval-execute "kargu/bridge/approval"
                  (connection arguments callback &rest options))
(declare-function kargu-bridge-approval-request "kargu/bridge/approval" (connection id params))
(declare-function kargu-bridge-job--disconnect "kargu/bridge/jobs" (job status))
(declare-function kargu-providers-install-projection "kargu/providers/projection" (snapshot))

(defgroup kargu-bridge nil
  "Opt-in Rust core connection."
  :group 'kargu)

(defcustom kargu-bridge-binary-path "kargu-core"
  "Rust binary, resolved as a path or through the variable `exec-path'."
  :type 'string :group 'kargu-bridge)

(defcustom kargu-bridge-request-timeout 30
  "Default pending request deadline in seconds."
  :type 'number :group 'kargu-bridge)

(defconst kargu-bridge--max-frame (* 1024 1024)
  "Maximum UTF-8 frame bytes, excluding LF.")
(defconst kargu-bridge--max-queue (* 4 1024 1024)
  "Maximum retained incoming frame bytes.")
(defconst kargu-bridge--max-pending 128
  "Maximum requests awaiting replies on one connection.")

(cl-defstruct (kargu-bridge-connection
               (:constructor kargu-bridge--connection-create))
  "One owned transport; state never belongs to a replacement process."
  process stderr-process stderr-buffer epoch (state 'starting)
  (frame-limit kargu-bridge--max-frame) (counter 0) (partial "")
  (pending (make-hash-table :test #'equal)) queue queue-tail (queue-bytes 0)
  dispatch-timer stop-timer reverse-timers capabilities read-scope ready-waiters
  (reverse-cleanups (make-hash-table :test #'equal))
  (jobs (make-hash-table :test #'equal)))

(cl-defstruct (kargu-bridge--pending (:constructor kargu-bridge--pending-create))
  "Take-once request waiter and its owner cleanup."
  callback timer deadline owner owner-cleanup review on-delta on-body on-retry api-scope
  (retry-delivery 0))

(declare-function kargu-bridge-api-retry "kargu/bridge/api" (connection id params))

(defun kargu-bridge--dismiss-reverse (connection &optional forward-id)
  "Dismiss CONNECTION's reverse requests, optionally only for FORWARD-ID."
  (let ((table (kargu-bridge-connection-reverse-cleanups connection)) cleanups)
    (maphash (lambda (_id entry)
               (when (or (null forward-id) (equal (car entry) forward-id))
                 (push (cdr entry) cleanups))) table)
    (dolist (cleanup cleanups)
      (condition-case nil (funcall cleanup) ((error quit) nil)))))

(defvar kargu-bridge--connection nil
  "Default client handle; callbacks always retain their actual connection.")

(defun kargu-bridge--object (&rest pairs)
  "Construct a wire object from alternating key/value PAIRS."
  (let ((object (make-hash-table :test #'equal)))
    (while pairs (puthash (pop pairs) (pop pairs) object))
    object))

(defun kargu-bridge--fault (status &optional message)
  "Construct a local error with STATUS and optional static sanitized MESSAGE."
  (kargu-bridge--object "code" -32000 "message" (or message "Kargu bridge request failed")
                        "data" (kargu-bridge--object "status" status)))

(defun kargu-bridge--callback (callback result error)
  "Deliver RESULT and ERROR to CALLBACK without compromising transport cleanup."
  (when callback
    (condition-case nil (funcall callback result error)
      ((error quit) (message "Kargu bridge callback failed")))))

(defun kargu-bridge--notify-ready (connection error-data)
  "Take CONNECTION's startup waiters and deliver ERROR-DATA at most once."
  (let ((waiters (kargu-bridge-connection-ready-waiters connection)))
    (setf (kargu-bridge-connection-ready-waiters connection) nil)
    (dolist (ticket waiters)
      (let ((callback (car ticket)))
        (setcar ticket nil)
        (kargu-bridge--callback callback (unless error-data connection) error-data)))))

(defun kargu-bridge--finish (connection id result error)
  "Take ID from CONNECTION and deliver RESULT or ERROR at most once."
  (when-let* ((entry (gethash id (kargu-bridge-connection-pending connection))))
    (remhash id (kargu-bridge-connection-pending connection))
    (kargu-bridge--dismiss-reverse connection id)
    (when (and (null error) (kargu-bridge--pending-deadline entry)
               (>= (float-time) (kargu-bridge--pending-deadline entry)))
      (setq result nil error (kargu-bridge--fault "timeout")))
    (when (timerp (kargu-bridge--pending-timer entry))
      (cancel-timer (kargu-bridge--pending-timer entry)))
    (when-let* ((owner (kargu-bridge--pending-owner entry))
                (cleanup (kargu-bridge--pending-owner-cleanup entry)))
      (when (buffer-live-p owner)
        (with-current-buffer owner
          (remove-hook 'kill-buffer-hook cleanup t)
          (remove-hook 'change-major-mode-hook cleanup t))))
    (kargu-bridge--callback (kargu-bridge--pending-callback entry) result error)))

(defun kargu-bridge--close (connection status)
  "Revoke CONNECTION and finish every waiter with STATUS before resource release."
  (unless (eq (kargu-bridge-connection-state connection) 'closed)
    (setf (kargu-bridge-connection-state connection) 'closed)
    (dolist (job (hash-table-values (kargu-bridge-connection-jobs connection)))
      (kargu-bridge-job--disconnect job status))
    (kargu-bridge--dismiss-reverse connection)
    (dolist (timer (append (list (kargu-bridge-connection-dispatch-timer connection)
                                 (kargu-bridge-connection-stop-timer connection))
                           (kargu-bridge-connection-reverse-timers connection)))
      (when (timerp timer) (cancel-timer timer)))
    (setf (kargu-bridge-connection-dispatch-timer connection) nil
          (kargu-bridge-connection-stop-timer connection) nil
          (kargu-bridge-connection-reverse-timers connection) nil
          (kargu-bridge-connection-queue connection) nil
          (kargu-bridge-connection-queue-tail connection) nil
          (kargu-bridge-connection-queue-bytes connection) 0
          (kargu-bridge-connection-partial connection) ""
          (kargu-bridge-connection-read-scope connection) nil)
    (kargu-bridge--notify-ready connection (kargu-bridge--fault status))
    (let ((ids (hash-table-keys (kargu-bridge-connection-pending connection))))
      (dolist (id ids)
        (kargu-bridge--finish connection id nil (kargu-bridge--fault status))))
    (dolist (proc (list (kargu-bridge-connection-process connection)
                        (kargu-bridge-connection-stderr-process connection)))
      (when (and proc (process-live-p proc)) (delete-process proc)))))

(defun kargu-bridge--send (connection object)
  "Write OBJECT to the existing CONNECTION; never start a replacement process."
  (let* ((proc (kargu-bridge-connection-process connection))
         (line (json-serialize object :null-object :json-null :false-object :json-false)))
    (unless (and (not (eq (kargu-bridge-connection-state connection) 'closed))
                 proc (process-live-p proc))
      (error "Rust core is disconnected"))
    (when (> (string-bytes line) (kargu-bridge-connection-frame-limit connection))
      (error "Rust core frame limit exceeded"))
    (process-send-string proc (concat line "\n"))))

(defun kargu-bridge--cancel (connection id status)
  "Cancel pending ID in CONNECTION with terminal STATUS."
  (when (gethash id (kargu-bridge-connection-pending connection))
    ;; Take ownership before sending; a send failure cannot redeliver it.
    (kargu-bridge--finish connection id nil (kargu-bridge--fault status))
    (condition-case nil
        (kargu-bridge--send
         connection (kargu-bridge--object
                     "jsonrpc" "2.0" "method" "rpc/cancel"
                     "params" (kargu-bridge--object "request_id" id
                                                    "scope" (kargu-bridge-connection-epoch connection))))
      (error nil))))

(defun kargu-bridge--capture-api-scope (params)
  "Detach PARAMS' native API identity for later observer correlation."
  (let* ((scope (gethash "scope" params))
         (app (and (hash-table-p scope) (gethash "application_id" scope)))
         (session (and (hash-table-p scope) (gethash "session_id" scope))))
    (unless (and (stringp app) (stringp session)) (error "Invalid API observer scope"))
    (kargu-bridge--object "application_id" (copy-sequence app) "session_id" (copy-sequence session))))

(cl-defun kargu-bridge-call (connection method params callback &key owner timeout on-delta on-body on-retry)
  "Call METHOD with PARAMS on CONNECTION and asynchronously deliver CALLBACK.
CALLBACK receives (RESULT ERROR).  OWNER is an optional live source buffer;
its closure or major-mode change cancels delivery.  TIMEOUT overrides the
default deadline; :unlimited disables only this forward-request timer.
ON-DELTA receives core API events while this exact waiter remains owned.
ON-BODY receives bounded final JSON body fragments, not provider events.
ON-RETRY observes an owned native retry before ACK, never schedules its IO.
Return the correlation id, or nil on local rejection."
  (let ((deadline (or timeout kargu-bridge-request-timeout)))
    (unless (and (functionp callback) (stringp method) (hash-table-p params)
                 (or (null on-delta) (functionp on-delta))
                 (or (null on-body) (functionp on-body))
                 (or (null on-retry) (and (equal method "api/request") (functionp on-retry)))
                 (or (eq deadline :unlimited) (and (numberp deadline) (> deadline 0)))
                 (or (null owner) (buffer-live-p owner)))
      (error "Invalid Rust request arguments"))
    (if (or (not (memq (kargu-bridge-connection-state connection) '(starting binding ready stopping)))
            (and (eq (kargu-bridge-connection-state connection) 'starting)
                 (not (equal method "initialize")))
            (and (eq (kargu-bridge-connection-state connection) 'binding)
                 (not (member method '("application/create" "session/create" "provider/catalog"))))
            (and (eq (kargu-bridge-connection-state connection) 'stopping)
                 (not (equal method "shutdown")))
            (>= (hash-table-count (kargu-bridge-connection-pending connection))
                kargu-bridge--max-pending))
        (progn (kargu-bridge--callback callback nil (kargu-bridge--fault "unavailable")) nil)
      (let* ((id (format "e:%s:%d" (kargu-bridge-connection-epoch connection)
                         (cl-incf (kargu-bridge-connection-counter connection))))
             (cleanup (and owner (lambda () (kargu-bridge--cancel connection id "owner_closed"))))
             (entry (kargu-bridge--pending-create :callback callback :owner owner
                                                  :on-delta on-delta
                                                  :on-body on-body
                                                  :on-retry on-retry
                                                  :api-scope (and on-retry (kargu-bridge--capture-api-scope params))
                                                  :deadline (when (numberp deadline) (+ (float-time) deadline))
                                                  :owner-cleanup cleanup)))
        (puthash id entry (kargu-bridge-connection-pending connection))
        (when (numberp deadline)
          (setf (kargu-bridge--pending-timer entry)
                (run-at-time deadline nil #'kargu-bridge--cancel connection id "timeout")))
        (when owner
          (with-current-buffer owner
            (add-hook 'kill-buffer-hook cleanup nil t)
            (add-hook 'change-major-mode-hook cleanup nil t)))
        (condition-case nil
            (kargu-bridge--send connection
                                (kargu-bridge--object "jsonrpc" "2.0" "id" id
                                                      "method" method "params" params))
          (error
           (kargu-bridge--finish connection id nil (kargu-bridge--fault "send_failed"))
           (kargu-bridge--close connection "disconnected")))
        id))))

(defun kargu-bridge-cancel (connection id)
  "Cancel only pending ID on its captured CONNECTION."
  (kargu-bridge--cancel connection id "cancelled"))

(defun kargu-bridge-ensure (callback)
  "Ensure a ready native service connection and call CALLBACK with (CONN ERROR).
Concurrent invocations share startup.  Return a function that removes only
this waiter; it never kills a connection used by another task."
  (let ((connection kargu-bridge--connection))
    (when (or (null connection) (eq (kargu-bridge-status connection) 'closed))
      (condition-case nil
          (setq connection (kargu-bridge-start #'ignore))
        (error (setq connection nil))))
    (cond
     ((null connection)
      (kargu-bridge--callback callback nil (kargu-bridge--fault "startup_failed"))
      #'ignore)
     ((eq (kargu-bridge-status connection) 'ready)
      (kargu-bridge--callback callback connection nil)
      #'ignore)
     ((and (memq (kargu-bridge-status connection) '(starting binding))
           (< (length (kargu-bridge-connection-ready-waiters connection)) kargu-bridge--max-pending))
      (let ((ticket (list callback)))
        (push ticket (kargu-bridge-connection-ready-waiters connection))
        (lambda ()
          (setcar ticket nil)
          (setf (kargu-bridge-connection-ready-waiters connection)
                (delq ticket (kargu-bridge-connection-ready-waiters connection))))))
     (t
      (kargu-bridge--callback callback nil (kargu-bridge--fault "unavailable"))
      #'ignore))))

(cl-defun kargu-bridge-find-files (connection arguments callback &key owner)
  "Run native file discovery with ARGUMENTS on CONNECTION for OWNER.
CALLBACK receives the native (RESULT ERROR).  No Elisp fallback is executed."
  (kargu-bridge--workspace-read connection arguments callback :owner owner
				:method "workspace/findFiles" :capability "workspace_find_files"))

(cl-defun kargu-bridge-list-files (connection arguments callback &key owner)
  "List a directory using ARGUMENTS on CONNECTION for OWNER.
CALLBACK receives the native (RESULT ERROR).  Never scan directories in Elisp."
  (kargu-bridge--workspace-read connection arguments callback :owner owner
				:method "workspace/listFiles" :capability "workspace_list_files_ls"))

(cl-defun kargu-bridge-grep (connection arguments callback &key owner)
  "Search with captured ARGUMENTS on CONNECTION for OWNER using native Unix tools.
CALLBACK receives (RESULT ERROR); no Elisp process fallback is executed."
  (kargu-bridge--workspace-read
   connection arguments callback :owner owner :method "workspace/grep"
   :capability "workspace_grep"
   :timeout (kargu-bridge--read-timeout arguments)))

(defun kargu-bridge--read-timeout (arguments)
  "Native read ARGUMENTS' deadline with eleven seconds for actual cleanup."
  (let ((timeout (gethash "timeout_ms" arguments 30000)))
    (if (eq timeout :json-null) :unlimited (+ 11 (/ timeout 1000.0)))))

(cl-defun kargu-bridge-git-status (connection arguments callback &key owner)
  "Read Git status with captured ARGUMENTS on CONNECTION for OWNER.
CALLBACK receives the native (RESULT ERROR); there is no Elisp fallback."
  (kargu-bridge--workspace-read
   connection arguments callback :owner owner :method "git/status" :capability "git_status"
   :timeout (kargu-bridge--read-timeout arguments)))

(cl-defun kargu-bridge-git-read (connection arguments callback &key owner)
  "Query Git using captured ARGUMENTS on CONNECTION for OWNER.
CALLBACK receives native (RESULT ERROR); no legacy process fallback exists."
  (kargu-bridge--workspace-read
   connection arguments callback :owner owner :method "git/read" :capability "git_read"
   :timeout (kargu-bridge--read-timeout arguments)))

(cl-defun kargu-bridge-execute (connection arguments callback &key owner)
  "Execute explicit program/argv ARGUMENTS on CONNECTION after user approval.
CALLBACK receives (RESULT ERROR).  OWNER defaults to the current buffer.
This noninteractive port does not replace the existing Bash job tool."
  (require 'kargu/bridge/approval)
  (kargu-bridge-approval-execute connection arguments callback :owner (or owner (current-buffer))))

(cl-defun kargu-bridge--workspace-read (connection arguments callback &key owner method capability timeout)
  "Call read METHOD with ARGUMENTS on CONNECTION for OWNER.
Require negotiated CAPABILITY and deliver CALLBACK once with (RESULT ERROR)."
  (if (not (and (eq (kargu-bridge-status connection) 'ready)
                (member capability (append (kargu-bridge-connection-capabilities connection) nil))
                (hash-table-p (kargu-bridge-connection-read-scope connection))))
      (progn (kargu-bridge--callback callback nil
                                     (kargu-bridge--fault "unavailable" "Native workspace read unavailable; rebuild kargu-core")) nil)
    (kargu-bridge-call
     connection method
     (kargu-bridge--object "scope" (kargu-bridge-connection-read-scope connection) "arguments" arguments)
     callback :owner owner :timeout timeout)))

(defun kargu-bridge--normalize (value &optional depth)
  "Convert parsed VALUE into typed JSON, rejecting duplicate keys at DEPTH."
  (when (> (or depth 0) 64) (error "JSON nesting limit exceeded"))
  (cond
   ((listp value)
    (let ((table (make-hash-table :test #'equal)))
      (dolist (pair value)
        (unless (eq (gethash (car pair) table :missing) :missing)
          (error "Duplicate JSON key"))
        (puthash (car pair) (kargu-bridge--normalize (cdr pair) (1+ (or depth 0))) table))
      table))
   ((vectorp value)
    (vconcat (mapcar (lambda (v) (kargu-bridge--normalize v (1+ (or depth 0)))) value)))
   (t value)))

(defun kargu-bridge--decode (line)
  "Parse one complete LINE, keeping object/array/null/false distinct."
  (let ((json-object-type 'alist) (json-key-type 'string)
        (json-array-type 'vector) (json-null :json-null) (json-false :json-false))
    (with-temp-buffer
      (insert line)
      (goto-char (point-min))
      (let ((value (json-read)))
        (skip-chars-forward " \t\r\n")
        (unless (eobp) (error "Trailing JSON input"))
        (kargu-bridge--normalize value)))))

(defun kargu-bridge--valid-id-p (id)
  "Whether ID is a supported non-null JSON-RPC identity."
  (or (stringp id) (and (integerp id) (<= (- (expt 2 63)) id (1- (expt 2 63))))))

(defun kargu-bridge--dispatch-line (connection line)
  "Validate LINE and route it within CONNECTION, outside the process filter."
  (condition-case nil
      (let* ((msg (kargu-bridge--decode line))
             (method (and (hash-table-p msg) (gethash "method" msg :missing)))
             (id (and (hash-table-p msg) (gethash "id" msg :missing)))
             (result (and (hash-table-p msg) (gethash "result" msg :missing)))
             (error-data (and (hash-table-p msg) (gethash "error" msg :missing))))
        (unless (and (hash-table-p msg) (equal (gethash "jsonrpc" msg) "2.0"))
          (error "Invalid envelope"))
        (cond
         ((not (eq method :missing))
          (unless (and (stringp method) (not (string-empty-p method))
                       (eq result :missing) (eq error-data :missing)
                       (or (eq id :missing) (kargu-bridge--valid-id-p id))
                       (let ((params (gethash "params" msg :missing)))
                         (or (eq params :missing) (hash-table-p params) (vectorp params))))
            (error "Invalid request envelope"))
          (cond
           ((and (eq id :missing) (member method '("api/delta" "api/body")))
            (let* ((params (gethash "params" msg))
                   (request-id (and (hash-table-p params) (gethash "request_id" params)))
                   (entry (gethash request-id (kargu-bridge-connection-pending connection))))
              (when-let* ((consumer (and entry (if (equal method "api/delta")
                                                   (kargu-bridge--pending-on-delta entry)
                                                 (kargu-bridge--pending-on-body entry)))))
                (condition-case nil
                    (funcall consumer (gethash (if (equal method "api/delta") "delta" "chunk") params))
                  ((error quit) (kargu-bridge--cancel connection request-id "consumer_failed"))))))
           ((and (eq id :missing) (equal method "rpc/cancel"))
            (let* ((params (gethash "params" msg))
                   (entry (and (hash-table-p params)
                               (equal (gethash "scope" params) (kargu-bridge-connection-epoch connection))
                               (gethash (gethash "request_id" params)
                                        (kargu-bridge-connection-reverse-cleanups connection)))))
              (when entry (funcall (cdr entry)))))
           ((and (not (eq id :missing)) (equal method "editor/request_approval"))
            (require 'kargu/bridge/approval)
            (kargu-bridge-approval-request connection id (gethash "params" msg)))
           ((and (not (eq id :missing)) (equal method "editor/api_retry"))
            (require 'kargu/bridge/api)
            (kargu-bridge-api-retry connection id (gethash "params" msg)))
           ((not (eq id :missing))
            (kargu-bridge--send
             connection (kargu-bridge--object
                         "jsonrpc" "2.0" "id" id
                         "error" (kargu-bridge--object "code" -32601 "message" "Method not found"))))))
         (t
          (unless (and (kargu-bridge--valid-id-p id)
                       (not (eq (eq result :missing) (eq error-data :missing)))
                       (or (eq error-data :missing)
                           (and (hash-table-p error-data)
                                (integerp (gethash "code" error-data))
                                (stringp (gethash "message" error-data)))))
            (error "Invalid response envelope"))
          (kargu-bridge--finish connection id
                                (unless (eq result :missing) result)
                                (unless (eq error-data :missing) error-data)))))
    (error (kargu-bridge--close connection "protocol_error"))))

(defun kargu-bridge--dispatch (connection)
  "Drain a bounded time slice of CONNECTION's incoming frame queue."
  (when (timerp (kargu-bridge-connection-dispatch-timer connection))
    (cancel-timer (kargu-bridge-connection-dispatch-timer connection)))
  (setf (kargu-bridge-connection-dispatch-timer connection) nil)
  (let ((until (+ (float-time) 0.005)) (count 0))
    (while (and (kargu-bridge-connection-queue connection)
                (not (eq (kargu-bridge-connection-state connection) 'closed))
                (< count 100) (< (float-time) until))
      (let ((line (pop (kargu-bridge-connection-queue connection))))
        (cl-decf (kargu-bridge-connection-queue-bytes connection) (string-bytes line))
        (unless (kargu-bridge-connection-queue connection)
          (setf (kargu-bridge-connection-queue-tail connection) nil))
        (cl-incf count)
        (kargu-bridge--dispatch-line connection line))))
  (when (and (kargu-bridge-connection-queue connection)
             (not (eq (kargu-bridge-connection-state connection) 'closed)))
    (setf (kargu-bridge-connection-dispatch-timer connection)
          (run-at-time 0 nil #'kargu-bridge--dispatch connection))))

(defun kargu-bridge--filter (connection proc chunk)
  "Frame CHUNK from PROC into CONNECTION's bounded dispatch queue."
  (when (and (eq proc (kargu-bridge-connection-process connection))
             (not (eq (kargu-bridge-connection-state connection) 'closed)))
    (save-match-data
      (let ((text (concat (kargu-bridge-connection-partial connection) chunk))
            (start 0) end)
        (while (and (not (eq (kargu-bridge-connection-state connection) 'closed))
                    (setq end (string-match "\n" text start)))
          (let* ((line (substring text start end)) (bytes (string-bytes line))
                 (cell (list line)))
            (if (or (> bytes (kargu-bridge-connection-frame-limit connection))
                    (>= (length (kargu-bridge-connection-queue connection)) 256)
                    (> (+ bytes (kargu-bridge-connection-queue-bytes connection))
                       kargu-bridge--max-queue))
                (kargu-bridge--close connection "resource_limit")
              (if (kargu-bridge-connection-queue-tail connection)
                  (setcdr (kargu-bridge-connection-queue-tail connection) cell)
                (setf (kargu-bridge-connection-queue connection) cell))
              (setf (kargu-bridge-connection-queue-tail connection) cell)
              (cl-incf (kargu-bridge-connection-queue-bytes connection) bytes)))
          (setq start (1+ end)))
        (unless (eq (kargu-bridge-connection-state connection) 'closed)
          (let ((partial (substring text start)))
            (if (> (string-bytes partial) (kargu-bridge-connection-frame-limit connection))
                (kargu-bridge--close connection "resource_limit")
              (setf (kargu-bridge-connection-partial connection) partial)))
          (when (and (kargu-bridge-connection-queue connection)
                     (not (timerp (kargu-bridge-connection-dispatch-timer connection))))
            (setf (kargu-bridge-connection-dispatch-timer connection)
                  (run-at-time 0 nil #'kargu-bridge--dispatch connection))))))))

(defun kargu-bridge--sentinel (connection proc _event)
  "Retire CONNECTION only when its captured PROC terminates."
  (when (and (eq proc (kargu-bridge-connection-process connection))
             (not (process-live-p proc)))
    ;; Final complete responses must be dispatched before EOF rejects waiters.
    (while (kargu-bridge-connection-queue connection)
      (kargu-bridge--dispatch connection))
    (kargu-bridge--close connection
                         (if (string-empty-p (kargu-bridge-connection-partial connection))
                             "disconnected" "protocol_error"))))

(defun kargu-bridge--stderr-filter (connection _proc chunk)
  "Retain a bounded sanitized diagnostic for CHUNK from CONNECTION.
Raw stderr is deliberately discarded: future backends may put secrets there."
  (when (and (buffer-live-p (kargu-bridge-connection-stderr-buffer connection))
             (not (string-empty-p chunk)))
    (with-current-buffer (kargu-bridge-connection-stderr-buffer connection)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert "Kargu core emitted a diagnostic (raw text withheld).\n")
        (when (> (buffer-size) kargu-bridge--max-frame)
          (delete-region (point-min) (- (point-max) kargu-bridge--max-frame)))))))

(defun kargu-bridge--start-finish (connection callback error-data)
  "Hydrate CONNECTION's provider projection before completing CALLBACK.
ERROR-DATA skips hydration; older peers retain the packaged projection."
  (if (and (null error-data)
           (member "provider_catalog" (append (kargu-bridge-connection-capabilities connection) nil)))
      (progn
        (setf (kargu-bridge-connection-state connection) 'binding)
        (kargu-bridge-call
         connection "provider/catalog" (kargu-bridge--object)
         (lambda (snapshot failure)
           (unless failure
             (condition-case nil
                 (progn (require 'kargu/providers/projection)
                        (kargu-providers-install-projection snapshot))
               (error (setq failure (kargu-bridge--fault "invalid_catalog")))))
           (kargu-bridge--start-ready connection callback failure))))
    (kargu-bridge--start-ready connection callback error-data)))

(defun kargu-bridge--start-ready (connection callback error-data)
  "Complete CONNECTION startup once and deliver CALLBACK or ERROR-DATA."
  (when (and (null error-data) (eq (kargu-bridge-status connection) 'closed))
    (setq error-data (kargu-bridge--fault "disconnected")))
  (if error-data
      (progn
        (kargu-bridge--close connection "startup_failed")
        (unless callback (message "Kargu Rust core initialization failed"))
        (kargu-bridge--callback callback nil error-data))
    (setf (kargu-bridge-connection-state connection) 'ready)
    (kargu-bridge--notify-ready connection nil)
    (unless callback (message "Kargu Rust core ready"))
    (kargu-bridge--callback callback connection nil)))

(defun kargu-bridge--bind-read-service (connection callback)
  "Bind CONNECTION's read-service session before completing startup CALLBACK.
This is an adapter service identity, not an imported user conversation or run."
  (if (not (cl-some (lambda (capability)
                      (member capability (append (kargu-bridge-connection-capabilities connection) nil)))
                    '("workspace_find_files" "workspace_list_files_ls" "workspace_grep" "git_status" "git_read" "command_execute" "api_request")))
      (kargu-bridge--start-finish connection callback nil)
    (setf (kargu-bridge-connection-state connection) 'binding)
    (kargu-bridge-call
     connection "application/create" (kargu-bridge--object)
     (lambda (application error-data)
       (if error-data (kargu-bridge--start-finish connection callback error-data)
         (let ((id (and (hash-table-p application) (gethash "application_id" application))))
           (if (not (and (stringp id) (string-prefix-p "app_" id)))
               (kargu-bridge--start-finish connection callback (kargu-bridge--fault "protocol_error"))
             (kargu-bridge-call
              connection "session/create" (kargu-bridge--object "application_id" id)
              (lambda (scope failure)
                (unless failure
                  (if (not (and (hash-table-p scope) (equal (gethash "application_id" scope) id)
                                (stringp (gethash "session_id" scope))
                                (string-prefix-p "sess_" (gethash "session_id" scope))))
                      (setq failure (kargu-bridge--fault "protocol_error"))
                    (setf (kargu-bridge-connection-read-scope connection) scope)))
                (kargu-bridge--start-finish connection callback failure))))))))))

(defun kargu-bridge-start (&optional callback)
  "Start the opt-in Rust core and asynchronously negotiate its capabilities.
CALLBACK receives (CONNECTION ERROR).  Return the starting connection handle."
  (interactive)
  (when (and kargu-bridge--connection
             (not (eq (kargu-bridge-connection-state kargu-bridge--connection) 'closed)))
    (user-error "Rust core is already starting or running"))
  (let* ((binary (if (file-name-directory kargu-bridge-binary-path)
                     (expand-file-name kargu-bridge-binary-path)
                   (executable-find kargu-bridge-binary-path)))
         (connection (kargu-bridge--connection-create
                      :epoch (format "%s-%s" (emacs-pid) (float-time))
                      :stderr-buffer (generate-new-buffer "*kargu-core-log*"))))
    (unless (and binary (file-executable-p binary))
      (kill-buffer (kargu-bridge-connection-stderr-buffer connection))
      (user-error "Rust binary unavailable; build kargu-core or set kargu-bridge-binary-path"))
    (condition-case err
        (let* ((stderr (make-pipe-process
                        :name "kargu-core-stderr" :buffer nil :coding 'utf-8-unix
                        :noquery t :filter (lambda (p s) (kargu-bridge--stderr-filter connection p s))))
               (proc (progn
                       (setf (kargu-bridge-connection-stderr-process connection) stderr)
                       (make-process
                        :name "kargu-core" :buffer nil :command (list binary "--stdio")
                        :connection-type 'pipe :coding 'utf-8-unix :stderr stderr :noquery t
                        :filter (lambda (p s) (kargu-bridge--filter connection p s))
                        :sentinel (lambda (p e) (kargu-bridge--sentinel connection p e))))))
          (setf (kargu-bridge-connection-process connection) proc)
          (setq kargu-bridge--connection connection)
          (kargu-bridge-call
           connection "initialize"
           (kargu-bridge--object "protocol_major" 1 "protocol_minor" 0 "client_version" "0.1.0"
                                 "capabilities" [] "limits"
                                 (kargu-bridge--object "max_frame_bytes" kargu-bridge--max-frame))
           (lambda (result error-data)
             (if error-data
                 (progn (kargu-bridge--close connection "handshake_failed")
                        (unless callback (message "Kargu Rust core initialization failed"))
                        (kargu-bridge--callback callback nil error-data))
               (condition-case nil
                   (let ((epoch (gethash "connection_epoch" result))
                         (limit (gethash "max_frame_bytes" (gethash "limits" result))))
                     (unless (and (eql (gethash "protocol_major" result) 1)
                                  (eql (gethash "protocol_minor" result) 0)
                                  (stringp epoch) (not (string-empty-p epoch))
                                  (integerp limit) (<= 1024 limit kargu-bridge--max-frame)
                                  (vectorp (gethash "capabilities" result)))
                       (error "Invalid handshake"))
                     (setf (kargu-bridge-connection-epoch connection) epoch
                           (kargu-bridge-connection-frame-limit connection) limit
                           (kargu-bridge-connection-capabilities connection) (gethash "capabilities" result))
                     (kargu-bridge--send connection
                                         (kargu-bridge--object "jsonrpc" "2.0" "method" "initialized"))
                     (kargu-bridge--bind-read-service connection callback))
                 (error (kargu-bridge--close connection "protocol_error")
                        (unless callback (message "Kargu Rust core handshake rejected"))
                        (kargu-bridge--callback callback nil (kargu-bridge--fault "protocol_error")))))))
          connection)
      (error (kargu-bridge--close connection "startup_failed") (signal (car err) (cdr err))))))

(defun kargu-bridge-stop (&optional connection)
  "Request shutdown of CONNECTION, defaulting to the current bridge.
Allow Rust TERM/grace/drain before forcing transport cleanup."
  (interactive)
  (let ((conn (or connection kargu-bridge--connection)))
    (when (and conn (not (eq (kargu-bridge-connection-state conn) 'closed)))
      (if (not (eq (kargu-bridge-connection-state conn) 'ready))
          (kargu-bridge--close conn "cancelled")
        (setf (kargu-bridge-connection-state conn) 'stopping
              (kargu-bridge-connection-stop-timer conn)
              (run-at-time 15 nil #'kargu-bridge--close conn "shutdown_timeout"))
        (kargu-bridge-call
         conn "shutdown" (kargu-bridge--object)
         (lambda (_result error-data)
           (if error-data (kargu-bridge--close conn "shutdown_failed")
             (condition-case nil
                 (progn
                   (kargu-bridge--send conn (kargu-bridge--object "jsonrpc" "2.0" "method" "exit"))
                   (process-send-eof (kargu-bridge-connection-process conn)))
               (error (kargu-bridge--close conn "disconnected")))))
         ;; Native shutdown may consume 5s TERM grace plus 5s pipe/reap drain.
         ;; Do not let the RPC waiter kill the core before that work completes.
         :timeout 12)))))

(defun kargu-bridge-status (&optional connection)
  "Return CONNECTION state, or `stopped' when no bridge exists."
  (interactive)
  (let ((state (if-let* ((conn (or connection kargu-bridge--connection)))
                   (kargu-bridge-connection-state conn) 'stopped)))
    (when (called-interactively-p 'interactive) (message "Kargu Rust core: %s" state))
    state))

(provide 'kargu/bridge)
;;; bridge.el ends here
