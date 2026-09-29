;;; kargu/permission/policy.el --- Approval confirmation UI -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Approval policy for commands and mutating tools.  Human answers are
;; asked through the non-blocking `kargu-ui-confirm' and delivered by
;; callback; nothing here waits for the user.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/permission/guards)
(require 'kargu/ui/confirm)

(defvar kargu--loop-run)
(defvar kargu-permission--deferring nil
  "Non-nil while `kargu-permission-call-async' collects an approval request.")
(defvar kargu-permission--preapproved nil
  "Commands the user already approved during the current tool call.")

(defun kargu-permission--auto-decision (risks)
  "Decision that needs no human: `approve', `reject', or nil to ask.
RISKS are reasons the path validator cannot vouch for the command; with
risks the opt-out `kargu-permission-confirm-bash' does not apply.  Batch
Emacs never approves on its own."
  (cond
   (kargu-permission--mock-decision
    (if (eq kargu-permission--mock-decision :approve) 'approve 'reject))
   ((and (not risks) (not kargu-permission-confirm-bash)) 'approve)
   (noninteractive 'reject)
   (t nil)))

(defun kargu-permission--shown-command (command risks)
  "COMMAND as displayed in the prompt, with RISKS as a warning line."
  (if risks
      (format "%s\n     WARNING: %s" command (string-join risks "; "))
    command))

(defun kargu-permission--ask-user (command dir risks on-decision)
  "Ask the human whether to run COMMAND in DIR; RISKS explain the warning.
ON-DECISION gets non-nil for approve.  It runs when a button is clicked,
never by waiting."
  (kargu-ui-confirm
   :title "⚡ [Bash Permission Approval]"
   :details (format "Command: $ %s\nDirectory: %s"
                    (kargu-permission--shown-command command risks) dir)
   :actions '((:key :approve
               :label "[✓ Approve]"
               :face (:inherit success :weight bold)
               :help "Click to approve and execute command"
               :message "     -> [✓ Approved, executing...]\n\n")
              (:key :reject
               :label "[✗ Reject]"
               :face (:inherit error :weight bold)
               :help "Click to reject command"
               :message "     -> [✗ Rejected]\n\n"))
   :chat-buffer (and (bound-and-true-p kargu--loop-run)
                     (plist-get kargu--loop-run :chat-buffer))
   :fallback-prompt (format "Execute Kargu command? $ %s (dir: %s) "
                            (kargu-permission--shown-command command risks) dir)
   :default-action :reject
   :notify 'permission
   :on-decision (lambda (decision)
                  (funcall on-decision (eq decision :approve)))))

(defun kargu-permission-request-approval-async (command dir risks on-decision)
  "Decide whether COMMAND may run in DIR and pass the verdict to ON-DECISION.
The verdict is t or nil.  Nothing blocks: a human answer arrives by callback."
  (pcase (kargu-permission--auto-decision risks)
    ('approve (funcall on-decision t))
    ('reject (funcall on-decision nil))
    (_ (kargu-permission--ask-user command dir risks on-decision))))

(defun kargu-permission-request-approval (_command _dir &optional risks)
  "Synchronous verdict for a command and directory, without asking anyone.
RISKS are the reasons the validator cannot vouch for the command.
Return non-nil only when policy decides without a human (mock decision or
the `kargu-permission-confirm-bash' opt-out).  A command that needs a human
answer is refused here; go through `kargu-permission-request-approval-async'
or `kargu-permission-call-async' for that."
  (eq (kargu-permission--auto-decision risks) 'approve))

(defun kargu-permission-approve (command dir &optional risks)
  "Return t when COMMAND in DIR is approved, or nil when it is rejected.
Inside `kargu-permission-call-async' an unanswered request unwinds the tool
body to ask the human; the body then runs again with the approval recorded."
  (cond
   ((member command kargu-permission--preapproved) t)
   ((and kargu-permission--deferring
         (null (kargu-permission--auto-decision risks)))
    (throw 'kargu-permission-defer (list command dir risks)))
   (t (kargu-permission-request-approval command dir risks))))

(defun kargu-permission--run-thunk (thunk done)
  "Call THUNK with DONE; a signal becomes an ERROR result passed to DONE."
  (condition-case-unless-debug err
      (funcall thunk done)
    (error (funcall done (format "ERROR: %s" (error-message-string err))))))

(defun kargu-permission-call-async (thunk callback &optional preapproved)
  "Run THUNK for a tool call; the result string reaches CALLBACK exactly once.
THUNK takes a DONE function and must call it with the result, now or later.
It asks for approvals with `kargu-permission-approve' before any side
effect.  When one needs the human, the question is put through
`kargu-ui-confirm', and THUNK runs again after the answer; a rejection
becomes an ERROR result.  PREAPPROVED lists commands already approved."
  (let* ((kargu-permission--preapproved preapproved)
         (in-catch t)
         (early :pending)
         (done (lambda (result)
                 (if in-catch
                     (setq early result)
                   (funcall callback result))))
         (request (catch 'kargu-permission-defer
                    (let ((kargu-permission--deferring t))
                      (kargu-permission--run-thunk thunk done))
                    nil)))
    (setq in-catch nil)
    (cond
     (request (kargu-permission--defer-to-user request thunk callback preapproved))
     ((not (eq early :pending)) (funcall callback early)))))

(defun kargu-permission--defer-to-user (request thunk callback preapproved)
  "Ask about REQUEST, then re-run THUNK or report the rejection to CALLBACK."
  (pcase-let ((`(,command ,dir ,risks) request))
    (kargu-permission-request-approval-async
     command dir risks
     (lambda (ok)
       (if ok
           (kargu-permission-call-async thunk callback (cons command preapproved))
         (funcall callback
                  (format "ERROR: %s was not approved by the user" command)))))))

(provide 'kargu/permission/policy)

;;; kargu/permission/policy.el ends here
