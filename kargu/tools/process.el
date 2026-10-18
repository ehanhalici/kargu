;;; process.el --- Non-blocking external commands -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; One way to run an external program from a tool: `kargu-process-run'.
;; It starts the program with `make-process', never waits for it, kills it
;; when it outlives its timeout or writes more than its output cap, and
;; delivers one result plist to a callback.  git, rg, grep, fd, curl and
;; diff all go through it, so none of them can freeze Emacs.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)

(defcustom kargu-process-timeout 30
  "Seconds an external command may run before it is killed."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-process-max-bytes 4000000
  "Output bytes after which an external command is killed."
  :type 'natnum
  :group 'kargu)

(defconst kargu-process--buffer-name " *kargu-process*"
  "Name used for temporary command output buffers.")

(defconst kargu-process--stderr-name " *kargu-stderr*"
  "Name used for private standard-error buffers and pipes.")

(defun kargu-process--finish (callback buffer state)
  "Deliver the result of a finished process in BUFFER to CALLBACK.
STATE is the mutable plist holding the exit code and the kill reasons."
  (let ((stderr (plist-get state :stderr-buffer))
        (output (if (buffer-live-p buffer)
                    (with-current-buffer buffer (buffer-string))
                  "")))
    (setq stderr (if (buffer-live-p stderr)
                     (prog1 (with-current-buffer stderr (buffer-string))
                       (kill-buffer stderr))
                   ""))
    (when (and (buffer-live-p buffer) (not (plist-get state :keep-buffer)))
      (kill-buffer buffer))
    (condition-case-unless-debug err
        (funcall callback
                 (list :code (plist-get state :code)
                       :output output
                       :stderr stderr
                       :timed-out (plist-get state :timed-out)
                       :timeout (plist-get state :timeout)
                       :truncated (plist-get state :truncated)))
      (error
       (kargu-log 'error "process callback failed: %s" (error-message-string err))))))

(defun kargu-process--maybe-finish (callback buffer state)
  "Deliver CALLBACK from BUFFER when both streams in STATE have closed."
  (when (and (eq (plist-get state :lifecycle) :running)
             (plist-get state :main-exited) (plist-get state :stderr-closed))
    (plist-put state :lifecycle :closed)
    (when-let* ((timer (plist-get state :timer))) (cancel-timer timer))
    (kargu-process--finish callback buffer state)))

(defun kargu-process--sentinel (callback buffer state)
  "Record the exit in STATE and deliver CALLBACK after BUFFER is drained."
  (lambda (proc _event)
    (unless (process-live-p proc)
      (plist-put state :main-exited t)
      (plist-put state :code (process-exit-status proc))
      (kargu-process--maybe-finish callback buffer state))))

(defun kargu-process--filter (buffer max-bytes state)
  "Return an output filter for BUFFER with cap MAX-BYTES and shared STATE."
  (lambda (proc chunk)
    (when (and (buffer-live-p buffer)
               (or (eq (plist-get state :output-policy) 'tail)
                   (not (plist-get state :truncated))))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (save-excursion
            (save-restriction
              (widen)
              (goto-char (point-max))
              (insert chunk)
              (when (> (1- (position-bytes (point-max))) max-bytes)
		(plist-put state :truncated t)
		(if (eq (plist-get state :output-policy) 'tail)
                    (kargu-process--retain-tail max-bytes)
                  (kargu-process--truncate-output max-bytes)
                  (kargu-process-cancel
                   (or (plist-get state :process) proc)))))))))))

(defun kargu-process--retain-tail (max-bytes)
  "Keep at most MAX-BYTES of recent output without splitting characters."
  (let* ((byte-start (max 1 (- (position-bytes (point-max)) max-bytes)))
         (position (byte-to-position byte-start)))
    (delete-region (point-min)
                   (if (< (position-bytes position) byte-start)
                       (1+ position) position))))

(defun kargu-process-cancel (process)
  "Terminate PROCESS and close its owned stderr pipe.
The process group is signaled on supported platforms.  A separate stderr
pipe is closed even when the main process has already exited."
  (when (processp process)
    (when (process-live-p process) (kill-process process))
    (when-let* ((stderr (process-get process 'kargu-stderr-process)))
      (when (process-live-p stderr) (delete-process stderr)))))

(defun kargu-process--deadline (process timeout state)
  "Schedule PROCESS termination after TIMEOUT seconds, recording STATE."
  (when timeout
    (unless (and (numberp timeout) (> timeout 0))
      (error "Timeout must be positive or nil"))
    (run-at-time timeout nil
                 (lambda ()
                   (unless (eq (plist-get state :lifecycle) :closed)
                     (plist-put state :timed-out t)
                     (kargu-process-cancel process))))))

(defun kargu-process--truncate-output (max-bytes)
  "Limit the current buffer to MAX-BYTES without splitting a character."
  (let ((byte-end (1+ max-bytes)))
    (while (not (byte-to-position byte-end))
      (setq byte-end (1- byte-end)))
    (delete-region (byte-to-position byte-end) (point-max))))

(defun kargu-process--fail (callback message)
  "Deliver a failed start with MESSAGE to CALLBACK."
  (funcall callback (list :code -1 :output message :stderr ""
                          :timed-out nil :truncated nil)))

(defun kargu-process-run (program args callback &rest opts)
  "Run PROGRAM with ARGS without waiting; pass the result to CALLBACK.
CALLBACK gets a plist (:code :output :stderr :timed-out :truncated).
:code is 127 when PROGRAM is not on PATH, and -1 on startup failure.
By default :output is stdout only and :stderr is captured separately.
OPTS: `:dir' working directory, `:timeout' seconds (default
`kargu-process-timeout'), `:max-bytes' output cap (default
`kargu-process-max-bytes') per stream.  An explicit nil timeout disables
the deadline, which otherwise also bounds stderr drainage.
`:stderr' can be `merge' to combine both streams in :output.
`:output-policy' can be `tail' to retain recent output without killing;
`:buffer' and `:keep-buffer' provide a persistent live output buffer.
Standard input is closed immediately; interactive commands are unsupported.
Return the process, or nil when none started."
  (let ((exe (executable-find program)))
    (if (not exe)
        (progn (funcall callback (list :code 127 :output "" :stderr ""
                                      :timed-out nil :truncated nil))
               nil)
      (kargu-process--start exe args :callback callback :opts opts))))

(cl-defun kargu-process--make-stderr (callback &key buffer state max-bytes)
  "Create a bounded stderr pipe for CALLBACK, BUFFER, STATE and MAX-BYTES."
  (let ((stderr-buffer (generate-new-buffer kargu-process--stderr-name)))
    (plist-put state :stderr-buffer stderr-buffer)
    (plist-put
     state :stderr-process
     (make-pipe-process
      :name kargu-process--stderr-name :buffer nil :noquery t :coding 'utf-8
      :filter (kargu-process--filter stderr-buffer max-bytes state)
      :sentinel (lambda (pipe _event)
                  (unless (process-live-p pipe)
                    (plist-put state :stderr-closed t)
                    (kargu-process--maybe-finish callback buffer state)))))
    (plist-get state :stderr-process)))

(cl-defun kargu-process--launch (exe args &key callback buffer state opts)
  "Launch EXE with ARGS, delivering CALLBACK from BUFFER using STATE and OPTS."
  (let* ((max-bytes (or (plist-get opts :max-bytes) kargu-process-max-bytes))
         (stderr (unless (eq (plist-get opts :stderr) 'merge)
                   (kargu-process--make-stderr
                    callback :buffer buffer :state state :max-bytes max-bytes)))
         (proc (make-process
                :name (file-name-nondirectory exe) :buffer nil
                :command (cons exe args) :connection-type 'pipe :noquery t
                :coding 'utf-8 :stderr stderr
                :filter (kargu-process--filter buffer max-bytes state))))
    (plist-put state :process proc)
    (process-put proc 'kargu-stderr-process stderr)
    (plist-put state :timer (kargu-process--deadline proc (plist-get state :timeout) state))
    (set-process-sentinel proc (kargu-process--sentinel callback buffer state))
    (plist-put state :lifecycle :running)
    (when (process-live-p proc) (process-send-eof proc))
    (kargu-process--maybe-finish callback buffer state)
    proc))

(defun kargu-process--cleanup-start (buffer state opts)
  "Release BUFFER and resources in STATE after startup with OPTS fails."
  (plist-put state :lifecycle :closed)
  (when-let* ((timer (plist-get state :timer))) (cancel-timer timer))
  (when-let* ((proc (plist-get state :process))) (kargu-process-cancel proc))
  (when-let* ((stderr (plist-get state :stderr-process)))
    (when (process-live-p stderr) (delete-process stderr)))
  (when-let* ((stderr-buffer (plist-get state :stderr-buffer)))
    (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer)))
  (when (and (buffer-live-p buffer) (not (plist-get opts :buffer)))
    (kill-buffer buffer)))

(cl-defun kargu-process--start (exe args &key callback opts)
  "Start EXE with ARGS per OPTS and wire timeout, cap and CALLBACK."
  (let* ((buffer (or (plist-get opts :buffer)
                     (generate-new-buffer kargu-process--buffer-name)))
         (state (list :lifecycle :starting :keep-buffer (plist-get opts :keep-buffer)
                      :stderr-closed (eq (plist-get opts :stderr) 'merge)
                      :output-policy (plist-get opts :output-policy)))
         (timeout (if (plist-member opts :timeout) (plist-get opts :timeout)
                    kargu-process-timeout))
         (default-directory (file-name-as-directory
                             (expand-file-name (or (plist-get opts :dir)
                                                   default-directory)))))
    (plist-put state :timeout timeout)
    (condition-case err
        (kargu-process--launch exe args :callback callback :buffer buffer
                               :state state :opts opts)
      (error
       (kargu-process--cleanup-start buffer state opts)
       (kargu-process--fail callback (error-message-string err))
       nil))))

(defun kargu-process-deliver (callback thunk)
  "Deliver THUNK's result to CALLBACK, converting failures to error text."
  (funcall callback
           (condition-case-unless-debug err
               (funcall thunk)
             (error (format "ERROR: %s" (error-message-string err))))))

(defun kargu-process-failure (label result)
  "Error text for a failed RESULT of the command named LABEL."
  (cond
   ((plist-get result :timed-out)
    (format "%s timed out after %ss" label
            (if (plist-member result :timeout) (plist-get result :timeout)
              kargu-process-timeout)))
   ((plist-get result :truncated)
    (format "%s exceeded its output limit; result is incomplete" label))
   ((eql (plist-get result :code) 127)
    (format "%s is not installed" label))
   (t
    (format "%s failed (exit %s): %s" label (plist-get result :code)
            (string-trim (or (kargu-nonempty (plist-get result :stderr))
                             (plist-get result :output) ""))))))

(provide 'kargu/tools/process)

;;; process.el ends here
