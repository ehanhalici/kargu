;;; command.el --- Capture editor authority for native commands -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Shared editor snapshot, not an execution engine or approval grant.

;;; Code:

(require 'kargu/bridge/approval)
(require 'kargu/permission/execute)
(require 'kargu/state/selectors)

(declare-function kargu-execution-call "kargu/application/execution" (context function &rest args))
(declare-function kargu-execution-live-p "kargu/application/execution" (context))

(cl-defstruct (kargu-bridge-command (:constructor kargu-bridge-command--create))
  "Captured JSON arguments and editor freshness; neither confers execution authority."
  (arguments nil :read-only t) (valid-p nil :read-only t) (owner nil :read-only t))

(defun kargu-bridge-command--environment ()
  "Capture child environment explicitly, with first entry taking priority."
  (let ((result (make-hash-table :test #'equal)) (seen (make-hash-table :test #'equal)))
    (dolist (entry process-environment)
      (let* ((at (string-search "=" entry)) (name (if at (substring entry 0 at) entry)))
        (unless (gethash name seen)
          (puthash name t seen)
          (when at (puthash name (substring entry (1+ at)) result)))))
    result))

(defun kargu-bridge-command--fresh-p (operation context mode revision)
  "Check captured OPERATION, MODE and REVISION inside execution CONTEXT."
  (condition-case nil
      (let ((check (lambda ()
                     (and (eq mode (or (plist-get kargu--loop-run :mode) (kargu-state-mode)))
                          (eql revision (kargu-session-mode-revision (kargu-session-context)))
                          (kargu-permission--operation-valid-p operation)))))
        (if context
            (and (kargu-execution-live-p context) (kargu-execution-call context check))
          (with-current-buffer (kargu-permission-operation-origin operation) (funcall check))))
    (error nil)))

(cl-defun kargu-bridge-command-capture
    (program argv directory &key timeout idle-timeout (output-bytes 1048576)
             (stderr "separate") valid-p)
  "Capture PROGRAM and ARGV in DIRECTORY for a native explicit approval.
TIMEOUT and IDLE-TIMEOUT are seconds or nil; OUTPUT-BYTES bounds retention.
STDERR selects separate or merged pipes.  VALID-P rechecks consumer policy.
This function does not start a process, ask for permission or wait for IPC."
  (let* ((root (kargu-permission-project-root))
         (mode (or (plist-get kargu--loop-run :mode) (kargu-state-mode)))
         (revision (kargu-session-mode-revision (kargu-session-context)))
         (context kargu-execution--current)
         (operation (kargu-permission-capture program directory :valid-p valid-p)))
    (unless (eq mode 'agent) (error "Native commands require Agent mode"))
    (unless (and (natnump output-bytes) (<= output-bytes 4194304))
      (error "Native output capacity must be 0..4194304 bytes"))
    (kargu-bridge-command--create
     :owner (current-buffer)
     :arguments (kargu-bridge-approval--copy
                 (kargu-bridge--object
                  "root" root "mode" (symbol-name mode) "program" program "arguments" (vconcat argv)
                  "cwd" directory "timeout_ms" (if timeout (ceiling (* 1000 timeout)) :json-null)
                  "idle_timeout_ms" (if idle-timeout (ceiling (* 1000 idle-timeout)) :json-null)
                  "environment" (kargu-bridge-command--environment) "config_revision" 0
                  "policy_revision" (or (kargu-permission-operation-policy-revision operation) 0)
                  "output_bytes" output-bytes "stderr" stderr))
     :valid-p (lambda () (kargu-bridge-command--fresh-p operation context mode revision)))))

(provide 'kargu/bridge/command)
;;; command.el ends here
