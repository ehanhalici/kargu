;;; kargu/permission/policy.el --- Approval confirmation UI -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Interactive approval buttons and policy handling for bash commands.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory (Magit-style kargu/core features).
(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'kargu/permission/guards)

(defvar kargu-chat--output-marker)
(defvar kargu-chat--prompt-marker)
(defvar kargu-chat-buffer-name)
(defvar kargu--loop-run)
(declare-function kargu-chat--prompt-live-p "kargu/chat/prompt" ())
(declare-function kargu-chat--ensure-idle-prompt "kargu/chat/prompt" ())
(declare-function kargu-loop-running-p "kargu/loop" ())
(declare-function kargu-notify "kargu/ui/notify" (type &optional msg))

(declare-function kargu-chat--ensure-running-prompt "kargu/chat/prompt" ())
(declare-function kargu-chat-show "kargu/chat" ())

(defun kargu-permission--render-approval-prompt (chat-buf command dir set-decision-fn)
  "Render approval prompt with action buttons in CHAT-BUF for COMMAND in DIR."
  (with-current-buffer chat-buf
    (let ((inhibit-read-only t))
      (when (and (markerp kargu-chat--output-marker)
                 (eq (marker-buffer kargu-chat--output-marker) chat-buf))
        (delete-region kargu-chat--output-marker (point-max))
        (setq kargu-chat--prompt-marker nil))
      (goto-char (point-max))
      (unless (or (bobp) (eq (char-before) ?\n))
        (insert "\n"))
      (insert "\n")
      (insert (propertize "  ⚡ [Bash Permission Approval]" 'face '(:inherit warning :weight bold)) "\n")
      (insert (format "     Command: $ %s\n" (propertize command 'face 'font-lock-keyword-face)))
      (insert (format "     Directory: %s\n     " dir))
      (insert-button
       "[✓ Approve]"
       'action (lambda (_)
                 (funcall set-decision-fn :approved)
                 (exit-recursive-edit))
       'face '(:inherit success :weight bold)
       'help-echo "Click to approve and execute command")
      (insert "  ")
      (insert-button
       "[✗ Reject]"
       'action (lambda (_)
                 (funcall set-decision-fn :rejected)
                 (exit-recursive-edit))
       'face '(:inherit error :weight bold)
       'help-echo "Click to reject command")
      (insert "\n\n")
      (setq kargu-chat--output-marker (copy-marker (point-max) t)))))

(defun kargu-permission--wait-for-decision (chat-buf get-decision-fn)
  "Wait in recursive edit for user button choice in CHAT-BUF and return decision."
  (let ((win (get-buffer-window chat-buf)))
    (when (and (null win) (not noninteractive))
      (setq win (and (fboundp 'kargu-chat-show)
                     (get-buffer-window (kargu-chat-show)))))
    (when win
      (select-window win))
    (with-current-buffer chat-buf
      (goto-char (point-max)))
    (dolist (w (get-buffer-window-list chat-buf nil t))
      (set-window-point w (point-max))
      (with-selected-window w
        (goto-char (point-max))
        (recenter -1)))
    (message "Command approval pending: click [✓ Approve] or [✗ Reject] (or C-g to cancel)")
    (condition-case _sig
        (recursive-edit)
      (quit
       (message "kargu: command execution cancelled by user")))
    (let ((decision (funcall get-decision-fn)))
      (with-current-buffer chat-buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (if (eq decision :approved)
              (insert (propertize "     -> [✓ Approved, executing...]\n\n" 'face 'font-lock-string-face))
            (insert (propertize "     -> [✗ Rejected]\n\n" 'face 'font-lock-warning-face)))
          (setq kargu-chat--output-marker (copy-marker (point-max) t)))
        (when (derived-mode-p 'kargu-chat-mode)
          (if (kargu-loop-running-p)
              (when (fboundp 'kargu-chat--ensure-running-prompt)
                (kargu-chat--ensure-running-prompt))
            (when (fboundp 'kargu-chat--ensure-idle-prompt)
              (kargu-chat--ensure-idle-prompt)))))
      (dolist (w (get-buffer-window-list chat-buf nil t))
        (set-window-point w (point-max))
        (with-selected-window w
          (goto-char (point-max))))
      decision)))

(defun kargu-permission-request-approval (command dir)
  "Request user approval for executing COMMAND in DIR.
Presents '[✓ Approve]' and '[✗ Reject]' buttons in the chat buffer.
Returns non-nil if approved, or nil if rejected."
  (cond
   ;; Testing override
   (kargu-permission--mock-decision
    (eq kargu-permission--mock-decision :approve))
   ;; Non-interactive (batch mode) or confirmation disabled -> Auto-approve
   ((or noninteractive (not kargu-permission-confirm-bash))
    t)
   ;; Interactive with live chat buffer
   (t
    (when (fboundp 'kargu-notify)
      (kargu-notify 'permission))
    (let ((chat-buf (or (and (bound-and-true-p kargu--loop-run)
                             (plist-get kargu--loop-run :chat-buffer))
                        (get-buffer (or (bound-and-true-p kargu-chat-buffer-name) "*kargu-chat*")))))
      (if (not (and chat-buf (buffer-live-p chat-buf)))
          (y-or-n-p (format "Execute Kargu bash command? $ %s (dir: %s) " command dir))
        (let ((decision :rejected))
          (kargu-permission--render-approval-prompt
           chat-buf command dir (lambda (d) (setq decision d)))
          (setq decision (kargu-permission--wait-for-decision chat-buf (lambda () decision)))
          (eq decision :approved)))))))

(provide 'kargu/permission/policy)

;;; kargu/permission/policy.el ends here
