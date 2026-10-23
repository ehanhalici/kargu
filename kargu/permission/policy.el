;;; policy.el --- Approval confirmation UI -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Approval policy for commands and mutating tools.  Human answers are
;; asked through the non-blocking `kargu-confirm' port and delivered by
;; callback; nothing here waits for the user.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/permission/guards)
(require 'kargu/confirm)

(defvar kargu--loop-run)
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
  (kargu-confirm
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
  "Evaluate RISKS for COMMAND in DIR and send the verdict to ON-DECISION.
Request a human decision asynchronously when necessary."
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
or `kargu-permission-execute' for a captured execution continuation."
  (eq (kargu-permission--auto-decision risks) 'approve))

(provide 'kargu/permission/policy)

;;; policy.el ends here
