;;; kargu/tools/process.el --- Non-blocking external commands -*- lexical-binding: t; -*-

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

(defun kargu-process--finish (callback buffer state)
  "Deliver the result of a finished process in BUFFER to CALLBACK.
STATE is the mutable plist holding the exit code and the kill reasons."
  (let ((output (if (buffer-live-p buffer)
                    (with-current-buffer buffer (buffer-string))
                  "")))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))
    (condition-case-unless-debug err
        (funcall callback
                 (list :code (plist-get state :code)
                       :output output
                       :timed-out (plist-get state :timed-out)
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
  "Process filter appending to BUFFER; kills the process past MAX-BYTES.
STATE records that the output was cut."
  (lambda (proc chunk)
    (when (and (buffer-live-p buffer) (not (plist-get state :truncated)))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert chunk)
        (when (> (buffer-size) max-bytes)
          (delete-region (1+ max-bytes) (point-max))
          (plist-put state :truncated t)
          (when (process-live-p proc)
            (kill-process proc)))))))

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
`kargu-process-max-bytes').  Return the process, or nil when none started."
  (let ((exe (executable-find program)))
    (if (not exe)
        (progn (funcall callback (list :code 127 :output "" :timed-out nil :truncated nil))
               nil)
      (kargu-process--start exe args callback opts))))

(defun kargu-process--start (exe args callback opts)
  "Start EXE with ARGS per OPTS and wire timeout, cap and CALLBACK."
  (let* ((buffer (generate-new-buffer " *kargu-process*"))
         (state (list :done nil :timed-out nil :truncated nil :code nil))
         (timeout (or (plist-get opts :timeout) kargu-process-timeout))
         (max-bytes (or (plist-get opts :max-bytes) kargu-process-max-bytes))
         (default-directory (file-name-as-directory
                             (expand-file-name (or (plist-get opts :dir)
                                                   default-directory))))
         (timer nil)
         (proc nil))
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
          (setq timer (run-at-time
                       timeout nil
                       (lambda ()
                         (when (process-live-p proc)
                           (plist-put state :timed-out t)
                           (kill-process proc)))))
          (set-process-sentinel
           proc (kargu-process--sentinel callback buffer state timer))
          proc)
      (error
       (kill-buffer buffer)
       (kargu-process--fail callback (error-message-string err))
       nil))))

(defun kargu-process-deliver (callback thunk)
  "Call CALLBACK with the string THUNK returns, or with an ERROR string."
  (funcall callback
           (condition-case-unless-debug err
               (funcall thunk)
             (error (format "ERROR: %s" (error-message-string err))))))

(defun kargu-process-failure (label result)
  "Error text for a failed RESULT of the command named LABEL."
  (cond
   ((plist-get result :timed-out)
    (format "%s timed out after %ss" label kargu-process-timeout))
   ((eql (plist-get result :code) 127)
    (format "%s is not installed" label))
   (t
    (format "%s failed (exit %s): %s" label (plist-get result :code)
            (string-trim (or (plist-get result :output) ""))))))

(provide 'kargu/tools/process)

;;; kargu/tools/process.el ends here
