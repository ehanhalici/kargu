;;; bridge.el --- Bounded asynchronous Rust IPC client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Opt-in lifecycle client.  Loading this file never starts a process and does
;; not replace the Elisp agent.  Callbacks receive (RESULT ERROR); wire null and
;; false are :json-null and :json-false.  Arrays remain vectors.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'kargu/core/group)

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
  dispatch-timer stop-timer reverse-timers)

(cl-defstruct (kargu-bridge--pending (:constructor kargu-bridge--pending-create))
  "Take-once request waiter and its owner cleanup."
  callback timer deadline owner owner-cleanup)

(defvar kargu-bridge--connection nil
  "Default client handle; callbacks always retain their actual connection.")

(defun kargu-bridge--object (&rest pairs)
  "Construct a wire object from alternating key/value PAIRS."
  (let ((object (make-hash-table :test #'equal)))
    (while pairs (puthash (pop pairs) (pop pairs) object))
    object))

(defun kargu-bridge--fault (status)
  "Construct a sanitized local error with machine-readable STATUS."
  (kargu-bridge--object "code" -32000 "message" "Kargu bridge request failed"
                        "data" (kargu-bridge--object "status" status)))

(defun kargu-bridge--callback (callback result error)
  "Deliver RESULT and ERROR to CALLBACK without compromising transport cleanup."
  (when callback
    (condition-case nil (funcall callback result error)
      ((error quit) (message "Kargu bridge callback failed")))))

(defun kargu-bridge--finish (connection id result error)
  "Take ID from CONNECTION and deliver RESULT or ERROR at most once."
  (when-let* ((entry (gethash id (kargu-bridge-connection-pending connection))))
    (remhash id (kargu-bridge-connection-pending connection))
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
          (kargu-bridge-connection-partial connection) "")
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

(cl-defun kargu-bridge-call (connection method params callback &key owner timeout)
  "Call METHOD with PARAMS on CONNECTION and asynchronously deliver CALLBACK.
CALLBACK receives (RESULT ERROR).  OWNER is an optional live source buffer;
its closure or major-mode change cancels delivery.  TIMEOUT overrides the
default deadline.  Return the correlation id, or nil on local rejection."
  (let ((deadline (or timeout kargu-bridge-request-timeout)))
    (unless (and (functionp callback) (stringp method) (hash-table-p params)
                 (numberp deadline) (> deadline 0)
                 (or (null owner) (buffer-live-p owner)))
      (error "Invalid Rust request arguments"))
    (if (or (not (memq (kargu-bridge-connection-state connection) '(starting ready stopping)))
            (and (eq (kargu-bridge-connection-state connection) 'starting)
                 (not (equal method "initialize")))
            (and (eq (kargu-bridge-connection-state connection) 'stopping)
                 (not (equal method "shutdown")))
            (>= (hash-table-count (kargu-bridge-connection-pending connection))
                kargu-bridge--max-pending))
        (progn (kargu-bridge--callback callback nil (kargu-bridge--fault "unavailable")) nil)
      (let* ((id (format "e:%s:%d" (kargu-bridge-connection-epoch connection)
                         (cl-incf (kargu-bridge-connection-counter connection))))
             (cleanup (and owner (lambda () (kargu-bridge--cancel connection id "owner_closed"))))
             (entry (kargu-bridge--pending-create :callback callback :owner owner
                                                  :deadline (+ (float-time) deadline)
                                                  :owner-cleanup cleanup)))
        (puthash id entry (kargu-bridge-connection-pending connection))
        (setf (kargu-bridge--pending-timer entry)
              (run-at-time deadline nil #'kargu-bridge--cancel connection id "timeout"))
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
          ;; No delegated editor capability is advertised in stage one.
          (unless (eq id :missing)
            (kargu-bridge--send
             connection (kargu-bridge--object
                         "jsonrpc" "2.0" "id" id
                         "error" (kargu-bridge--object "code" -32601 "message" "Method not found")))))
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
                           (kargu-bridge-connection-frame-limit connection) limit)
                     (kargu-bridge--send connection
                                         (kargu-bridge--object "jsonrpc" "2.0" "method" "initialized"))
                     (setf (kargu-bridge-connection-state connection) 'ready)
                     (unless callback (message "Kargu Rust core ready"))
                     (kargu-bridge--callback callback connection nil))
                 (error (kargu-bridge--close connection "protocol_error")
                        (unless callback (message "Kargu Rust core handshake rejected"))
                        (kargu-bridge--callback callback nil (kargu-bridge--fault "protocol_error")))))))
          connection)
      (error (kargu-bridge--close connection "startup_failed") (signal (car err) (cdr err))))))

(defun kargu-bridge-stop (&optional connection)
  "Request shutdown of CONNECTION, defaulting to the current bridge.
Force transport cleanup after five seconds if the peer fails to exit."
  (interactive)
  (let ((conn (or connection kargu-bridge--connection)))
    (when (and conn (not (eq (kargu-bridge-connection-state conn) 'closed)))
      (if (not (eq (kargu-bridge-connection-state conn) 'ready))
          (kargu-bridge--close conn "cancelled")
        (setf (kargu-bridge-connection-state conn) 'stopping
              (kargu-bridge-connection-stop-timer conn)
              (run-at-time 5 nil #'kargu-bridge--close conn "shutdown_timeout"))
        (kargu-bridge-call
         conn "shutdown" (kargu-bridge--object)
         (lambda (_result error-data)
           (if error-data (kargu-bridge--close conn "shutdown_failed")
             (condition-case nil
                 (progn
                   (kargu-bridge--send conn (kargu-bridge--object "jsonrpc" "2.0" "method" "exit"))
                   (process-send-eof (kargu-bridge-connection-process conn)))
               (error (kargu-bridge--close conn "disconnected")))))
         :timeout 5)))))

(defun kargu-bridge-status (&optional connection)
  "Return CONNECTION state, or `stopped' when no bridge exists."
  (interactive)
  (let ((state (if-let* ((conn (or connection kargu-bridge--connection)))
                   (kargu-bridge-connection-state conn) 'stopped)))
    (when (called-interactively-p 'interactive) (message "Kargu Rust core: %s" state))
    state))

(provide 'kargu/bridge)
;;; bridge.el ends here
