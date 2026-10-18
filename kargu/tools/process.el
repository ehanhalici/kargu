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

(defun kargu-process--finish (callback buffer state)
  "Deliver the result of a finished process in BUFFER to CALLBACK.
STATE is the mutable plist holding the exit code and the kill reasons."
  (let ((output (if (buffer-live-p buffer)
                    (with-current-buffer buffer (buffer-string))
                  "")))
    (when (and (buffer-live-p buffer) (not (plist-get state :keep-buffer)))
      (kill-buffer buffer))
    (condition-case-unless-debug err
        (funcall callback
                 (list :code (plist-get state :code)
                       :output output
                       :timed-out (plist-get state :timed-out)
                       :timeout (plist-get state :timeout)
                       :truncated (plist-get state :truncated)))
      (error
       (kargu-log 'error "process callback failed: %s" (error-message-string err))))))

(defun kargu-process--sentinel (callback buffer state timer)
  "Process sentinel delivering to CALLBACK once, then cancelling TIMER.
BUFFER holds the output; STATE records how the process ended."
  (lambda (proc _event)
    (unless (process-live-p proc)
      (unless (plist-get state :done)
        (plist-put state :done t)
        (when (timerp timer) (cancel-timer timer))
        (plist-put state :code (process-exit-status proc))
        (kargu-process--finish callback buffer state)))))

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
                  (kargu-process-cancel proc))))))))))

(defun kargu-process--retain-tail (max-bytes)
  "Keep at most MAX-BYTES of recent output without splitting characters."
  (let* ((byte-start (max 1 (- (position-bytes (point-max)) max-bytes)))
         (position (byte-to-position byte-start)))
    (delete-region (point-min)
                   (if (< (position-bytes position) byte-start)
                       (1+ position) position))))

(defun kargu-process-cancel (process)
  "Terminate PROCESS and its process group on supported platforms."
  (when (and (processp process) (process-live-p process))
    (kill-process process)))

(defun kargu-process--deadline (process timeout state)
  "Schedule PROCESS termination after TIMEOUT seconds, recording STATE."
  (when timeout
    (unless (and (numberp timeout) (> timeout 0))
      (error "Timeout must be positive or nil"))
    (run-at-time timeout nil
                 (lambda ()
                   (when (process-live-p process)
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
  (funcall callback (list :code -1 :output message :timed-out nil :truncated nil)))

(defun kargu-process-run (program args callback &rest opts)
  "Run PROGRAM with ARGS without waiting; pass the result to CALLBACK.
CALLBACK gets a plist (:code :output :timed-out :truncated).  :code is 127
when PROGRAM is not on PATH, and -1 when it could not be started.  stdout
and stderr arrive interleaved in :output.
OPTS: `:dir' working directory, `:timeout' seconds (default
`kargu-process-timeout'), `:max-bytes' output cap (default
`kargu-process-max-bytes').  An explicit nil timeout disables the deadline.
`:output-policy' can be `tail' to retain recent output without killing;
`:buffer' and `:keep-buffer' provide a persistent live output buffer.
Standard input is closed immediately; interactive commands are unsupported.
Return the process, or nil when none started."
  (let ((exe (executable-find program)))
    (if (not exe)
        (progn (funcall callback (list :code 127 :output "" :timed-out nil :truncated nil))
               nil)
      (kargu-process--start exe args callback opts))))

(defun kargu-process--start (exe args callback opts)
  "Start EXE with ARGS per OPTS and wire timeout, cap and CALLBACK."
  (let* ((buffer (or (plist-get opts :buffer)
                     (generate-new-buffer kargu-process--buffer-name)))
         (state (list :done nil :keep-buffer (plist-get opts :keep-buffer)
                      :output-policy (plist-get opts :output-policy)))
         (timeout (if (plist-member opts :timeout) (plist-get opts :timeout)
                    kargu-process-timeout))
         (max-bytes (or (plist-get opts :max-bytes) kargu-process-max-bytes))
         (default-directory (file-name-as-directory
                             (expand-file-name (or (plist-get opts :dir)
                                                   default-directory))))
         (timer nil)
         (proc nil))
    (plist-put state :timeout timeout)
    (condition-case err
        (progn
          (setq proc (make-process
                      :name (file-name-nondirectory exe)
                      :buffer nil
                      :command (cons exe args)
                      :connection-type 'pipe
                      :noquery t
                      :coding 'utf-8
                      :filter (kargu-process--filter buffer max-bytes state)))
          (setq timer (kargu-process--deadline proc timeout state))
          (set-process-sentinel
           proc (kargu-process--sentinel callback buffer state timer))
          (when (process-live-p proc) (process-send-eof proc))
          proc)
      (error
       (plist-put state :done t)
       (when (timerp timer) (cancel-timer timer))
       (when (process-live-p proc) (delete-process proc))
       (when (and (buffer-live-p buffer) (not (plist-get opts :buffer)))
         (kill-buffer buffer))
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
   ((eql (plist-get result :code) 127)
    (format "%s is not installed" label))
   (t
    (format "%s failed (exit %s): %s" label (plist-get result :code)
            (string-trim (or (plist-get result :output) ""))))))

(provide 'kargu/tools/process)

;;; process.el ends here
