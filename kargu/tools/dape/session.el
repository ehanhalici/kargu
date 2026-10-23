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
(require 'kargu/tools/dape/workspace)
(require 'kargu/tools/dape/selection)
(require 'kargu/tools/dape/readiness)
(require 'kargu/tools/dape/lifecycle)
(require 'dape nil t)

(defvar dape--connection-selected)
(defvar kargu-context-buffer)

(declare-function dape "dape" (&optional config-diff))

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

(defun kargu-dape--ensure-stop-on-entry (config)
  "Ensure CONFIG has :stopOnEntry t so program pauses on startup."
  (plist-put (copy-sequence config) :stopOnEntry t))

(defun kargu-dape--raw-connection ()
  "Return a workspace-owned connection, preferring a paused adapter."
  (let* ((connections (kargu-dape-project-connections))
         (selected (and (boundp 'dape--connection-selected)
                        (memq dape--connection-selected connections)
                        dape--connection-selected))
         (ordered (if selected (cons selected (remq selected connections))
                    (reverse connections))))
    (or (and (fboundp 'dape--stopped-threads)
             (seq-find #'dape--stopped-threads ordered))
        (car ordered))))

(defun kargu-dape-live-p ()
  "Return non-nil if a live dape session exists."
  (let ((conn (kargu-dape--raw-connection)))
    (and conn (not (stringp conn)))))

(defun kargu-dape-ready-p ()
  "Return non-nil only when a live Dape session's selected thread is paused."
  (let ((conn (kargu-dape--raw-connection)))
    (and conn
         (not (stringp conn))
         (kargu-dape-inspection-thread conn))))

(declare-function kargu-dape-selected-config "kargu/tools/dape/preflight" ())
(declare-function kargu-dape-launch-config "kargu/tools/dape/preflight" (name &rest options))

(defun kargu-dape--interactive-launch-dape (target-buf token)
  "Launch the verified adapter in TARGET-BUF with the captured launch TOKEN."
  (let ((name (kargu-dape-selected-config)))
    (unless name (user-error "Kargu: Verify an adapter by selecting debug mode first"))
    (unless (buffer-live-p target-buf)
      (user-error "Kargu: Open a source file in this project before launching Dape"))
    (when (buffer-live-p target-buf)
      (setq kargu-context-buffer target-buf))
    (with-current-buffer target-buf
      (kargu-dape-launch-config name :token token))))

(defun kargu-dape-ensure-session (on-ready &optional on-cancel)
  "Ensure an owned Dape session is ready, calling ON-READY or ON-CANCEL.
Call ON-READY immediately if ready.  Otherwise return an owned async task.
Stop or changed ownership silently cancels waiting, not the adapter launch."
  (kargu-dape-cancel-session-wait)
  (cond
   ((kargu-dape-ready-p)
    (funcall on-ready))
   ((kargu-dape-live-p)
    (kargu-dape-wait-for-session on-ready :on-cancel on-cancel
                                 :connection (kargu-dape--raw-connection)
                                 :source (kargu-dape-source-buffer)))
   ((not (fboundp 'dape))
    (message "kargu: dape is not installed or loaded")
    (when on-cancel (funcall on-cancel "dape is not installed")))
   (t
    (let ((target (kargu-dape-source-buffer)))
      (kargu-dape-wait-for-session
       on-ready :on-cancel on-cancel :source target
       :launch (lambda (token) (kargu-dape--interactive-launch-dape target token)))))))

(defun kargu-dape--connection ()
  "Return a live dape connection, or an explanatory string.
A connection with a stopped (paused) thread is preferred; when the
session is running, the string tells the model how to proceed."
  (cond
   ((not (fboundp 'dape--live-connections))
    "ERROR: dape is not installed or not loaded (install dape, then \
start a session with M-x dape)")
   (t
    (let ((conn (kargu-dape--raw-connection)))
      (cond
       ((null conn)
        "ERROR: no live Dape connection in this project; start its adapter first")
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
                 (kargu-seq-to-list (dape--threads conn))
                 ", ")))
       ((null (kargu-dape-inspection-thread conn))
        "ERROR: Inspection requires a live paused selected thread; select a paused thread first")
       (t conn))))))

(provide 'kargu/tools/dape/session)

;;; session.el ends here
