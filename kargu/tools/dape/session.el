;;; session.el --- Dape session access and launch -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Resolve debug connections and launch sessions asynchronously.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/json)
(require 'kargu/languages)
(require 'kargu/permission)
(require 'dape nil t)

(defvar dape--watched)

(declare-function dape "dape" (&optional config-diff))
(declare-function dape-stack-select-up "dape" (conn n))
(declare-function dape-stack-select-down "dape" (conn n))
(declare-function dape-select-stack "dape" (conn stack-id))
(declare-function dape-select-thread "dape" (conn thread-id))
(declare-function dape-watch-dwim "dape" (expression &optional remove-only-p add-only-p display-p))
(declare-function dape-kill "dape" (conn &optional cb with-disconnect))
(declare-function dape-disconnect-quit "dape" (conn))
(declare-function dape-quit "dape" ())
(declare-function kargu-seq-to-list "kargu/json" (seq))

;;;; Customization --------------------------------------------------------

(defgroup kargu-dape nil
  "Dape integration of kargu."
  :group 'kargu
  :prefix "kargu-dape-")

(defcustom kargu-dape-max-frames 12
  "Stack frames reported by `kargu-dape-get-context'."
  :type 'natnum
  :group 'kargu-dape)

(defcustom kargu-dape-max-scopes 4
  "Scopes (Locals, Arguments, Registers, ...) reported per frame."
  :type 'natnum
  :group 'kargu-dape)

(defcustom kargu-dape-max-variables 60
  "Variables reported per scope."
  :type 'natnum
  :group 'kargu-dape)

(defcustom kargu-dape-variable-value-width 160
  "Maximum characters of one variable value fed to the model."
  :type 'natnum
  :group 'kargu-dape)

;;;; Session access --------------------------------------------------------

(defalias 'kargu-dape--seq->list #'kargu-seq-to-list)

(defun kargu-dape--target-buffer ()
  "Return the best source/code buffer for launching dape.
Prefers `kargu-context-buffer' if valid and live, or a buffer in another
visible window visiting a file, or any project file buffer."
  (or (and (boundp 'kargu-context-buffer)
           (bufferp kargu-context-buffer)
           (buffer-live-p kargu-context-buffer)
           (not (with-current-buffer kargu-context-buffer (derived-mode-p 'kargu-chat-mode)))
           kargu-context-buffer)
      (and (boundp 'kargu-context-buffer)
           (stringp kargu-context-buffer)
           (get-file-buffer kargu-context-buffer))
      ;; Check visible windows in the current frame
      (cl-some (lambda (w)
                 (let ((b (window-buffer w)))
                   (and (buffer-live-p b)
                        (with-current-buffer b
                          (and (buffer-file-name b)
                               (derived-mode-p 'prog-mode)
                               (not (derived-mode-p 'kargu-chat-mode))))
                        b)))
               (window-list))
      ;; Check any buffer visiting a project file
      (cl-find-if (lambda (b)
                    (and (buffer-live-p b)
                         (buffer-file-name b)
                         (with-current-buffer b
                           (and (derived-mode-p 'prog-mode)
                                (not (derived-mode-p 'kargu-chat-mode))))))
                  (buffer-list))
      (current-buffer)))

(defun kargu-dape--ensure-stop-on-entry (config)
  "Ensure CONFIG has :stopOnEntry t so program pauses on startup."
  (let ((copy (copy-sequence config)))
    (if (plist-member copy :stopOnEntry)
        (plist-put copy :stopOnEntry t)
      (append copy '(:stopOnEntry t)))))

(defun kargu-dape--raw-connection ()
  "Return the live dape connection object, or nil."
  (when (fboundp 'dape--live-connections)
    (let ((conns (ignore-errors (dape--live-connections))))
      (when conns
        (or (and (fboundp 'dape--live-connection)
                 (or (ignore-errors (dape--live-connection 'stopped t))
                     (ignore-errors (dape--live-connection 'last t))))
            (car conns))))))

(defun kargu-dape-live-p ()
  "Return non-nil if a live dape session exists."
  (let ((conn (kargu-dape--raw-connection)))
    (and conn (not (stringp conn)))))

(defun kargu-dape-ready-p ()
  "Return non-nil only when a live Dape session has a stopped thread."
  (let ((conn (kargu-dape--raw-connection)))
    (and conn
         (not (stringp conn))
         (fboundp 'dape--stopped-threads)
         (dape--stopped-threads conn))))

(declare-function kargu-dape-selected-config "kargu/tools/dape/preflight" ())
(declare-function kargu-dape-launch-config "kargu/tools/dape/preflight" (name))

(defun kargu-dape--interactive-launch-dape (target-buf)
  "Launch the verified adapter in TARGET-BUF with stop-on-entry enabled."
  (let ((name (kargu-dape-selected-config)))
    (unless name (user-error "Kargu: Verify an adapter by selecting debug mode first"))
    (when (buffer-live-p target-buf)
      (setq kargu-context-buffer target-buf))
    (with-current-buffer target-buf
      (kargu-dape-launch-config name))))

(defconst kargu-dape--session-poll-interval 0.5
  "Seconds between debug session readiness checks.")

(defconst kargu-dape--session-launch-timeout 60.0
  "Seconds allowed for a debug adapter to become ready.")

(cl-defstruct (kargu-dape--session-wait
               (:constructor kargu-dape--make-session-wait))
  "Resources owned by one asynchronous debug session launch."
  started timer deferred stop-hook start-hook on-ready on-cancel
  (state :waiting))

(defun kargu-dape--finish-session-wait (wait state &optional reason)
  "Finish WAIT once in STATE, reporting cancellation REASON when supplied."
  (save-match-data
    (when (eq (kargu-dape--session-wait-state wait) :waiting)
      (setf (kargu-dape--session-wait-state wait) state)
      (dolist (timer (list (kargu-dape--session-wait-timer wait)
                           (kargu-dape--session-wait-deferred wait)))
        (when (timerp timer) (cancel-timer timer)))
      (remove-hook 'dape-stopped-hook (kargu-dape--session-wait-stop-hook wait))
      (remove-hook 'dape-start-hook (kargu-dape--session-wait-start-hook wait))
      (pcase state
        (:ready
         (message "kargu: debug session ready!")
         (funcall (kargu-dape--session-wait-on-ready wait)))
        (:cancelled
         (message "kargu: %s" reason)
         (when-let* ((on-cancel (kargu-dape--session-wait-on-cancel wait)))
           (funcall on-cancel reason)))))))

(defun kargu-dape--poll-session-wait (wait)
  "Check readiness or timeout of launch WAIT."
  (when (eq (kargu-dape--session-wait-state wait) :waiting)
    (cond
     ((kargu-dape-ready-p)
      (kargu-dape--finish-session-wait wait :ready))
     ((> (- (float-time) (kargu-dape--session-wait-started wait))
         kargu-dape--session-launch-timeout)
      (kargu-dape--finish-session-wait wait :cancelled "dape launch timed out")))))

(defun kargu-dape--session-started (wait)
  "Schedule a readiness probe for the adapter associated with WAIT."
  (when (eq (kargu-dape--session-wait-state wait) :waiting)
    (when-let* ((timer (kargu-dape--session-wait-deferred wait)))
      (cancel-timer timer))
    (setf (kargu-dape--session-wait-deferred wait)
          (run-at-time
           kargu-dape--session-poll-interval nil
           (lambda ()
             (when (kargu-dape-ready-p)
               (kargu-dape--finish-session-wait wait :ready)))))))

(defun kargu-dape--wait-for-session-ready (on-ready &optional on-cancel)
  "Wait asynchronously for a session, calling ON-READY or ON-CANCEL once."
  (let* ((wait (kargu-dape--make-session-wait
                :started (float-time) :on-ready on-ready :on-cancel on-cancel))
         (stop (lambda (&rest _) (kargu-dape--finish-session-wait wait :ready)))
         (start (lambda (&rest _) (kargu-dape--session-started wait))))
    (setf (kargu-dape--session-wait-stop-hook wait) stop
          (kargu-dape--session-wait-start-hook wait) start)
    (when (boundp 'dape-stopped-hook) (add-hook 'dape-stopped-hook stop))
    (when (boundp 'dape-start-hook) (add-hook 'dape-start-hook start))
    (setf (kargu-dape--session-wait-timer wait)
          (run-at-time kargu-dape--session-poll-interval
                       kargu-dape--session-poll-interval
                       #'kargu-dape--poll-session-wait wait))
    wait))

(defun kargu-dape-ensure-session (on-ready &optional on-cancel)
  "Ensure a dape debug session is running and ready.
If already ready, calls ON-READY immediately.
Otherwise, interactively invokes `dape' in the context of the project
source buffer (so minibuffer completion works), ensures :stopOnEntry t,
and waits asynchronously until the session connects and stops.
If cancelled or start fails within timeout, calls ON-CANCEL."
  (cond
   ((kargu-dape-ready-p)
    (funcall on-ready))
   ((kargu-dape-live-p)
    (kargu-dape--wait-for-session-ready on-ready on-cancel))
   ((not (fboundp 'dape))
    (message "kargu: dape is not installed or loaded")
    (when on-cancel (funcall on-cancel "dape is not installed")))
   (t
    (condition-case err
        (let ((target-buf (kargu-dape--target-buffer)))
          (kargu-dape--interactive-launch-dape target-buf)
          (kargu-dape--wait-for-session-ready on-ready on-cancel))
      (quit
       (message "kargu: debug session launch cancelled.")
       (when on-cancel (funcall on-cancel "cancelled by user")))
      (error
       (message "kargu: dape launch error: %s" (error-message-string err))
       (when on-cancel (funcall on-cancel (error-message-string err))))))))

(defun kargu-dape--connection ()
  "Return a live dape connection, or an explanatory string.
A connection with a stopped (paused) thread is preferred; when the
session is running, the string tells the model how to proceed."
  (cond
   ((not (fboundp 'dape--live-connection))
    "ERROR: dape is not installed or not loaded (install dape, then \
start a session with M-x dape)")
   ((not (or (bound-and-true-p dape-active-mode)
             (and (fboundp 'dape--live-connections)
                  (dape--live-connections))))
    "ERROR: no live dape session — start one with M-x dape (or \
dape-attach) first")
   (t
    (let ((conn (or (dape--live-connection 'stopped t)
                    (dape--live-connection 'last t))))
      (cond
       ((null conn)
        "ERROR: no live dape connection found")
       ((null (dape--stopped-threads conn))
        (format "The debug session is RUNNING; there is no paused thread \
to inspect. Set a breakpoint with debug_toggle_breakpoint and let the \
program reach it (or pause it), then call debug_get_context again. \
Threads: %s"
                (mapconcat
                 (lambda (thread)
                   (format "#%s (%s)"
                           (or (plist-get thread :id) "?")
                           (or (plist-get thread :status) "?")))
                 (kargu-dape--seq->list (dape--threads conn))
                 ", ")))
       (t conn))))))

(provide 'kargu/tools/dape/session)

;;; session.el ends here
