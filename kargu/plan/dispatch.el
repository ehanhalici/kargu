;;; kargu/plan/dispatch.el --- Plan review actions and dispatch -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; User actions for approving, editing, or rejecting implementation plans.

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

(require 'kargu/core)
(require 'kargu/plan/buffer)

(defvar kargu-chat-buffer-name)
(declare-function kargu-chat-prompt "kargu/chat" (&optional prompt))

(defun kargu-plan-view ()
  "Display the in-memory plan buffer in a suitable window for editing."
  (interactive)
  (let ((buf (get-buffer kargu-plan-buffer-name)))
    (if (not (and buf (buffer-live-p buf)))
        (message "kargu: no active plan buffer found")
      (let ((win (display-buffer buf '(display-buffer-pop-up-window
                                       display-buffer-use-some-window))))
        (when win
          (select-window win))
        (message "Edit plan freely in memory. Press C-c C-c to approve & apply, C-c C-k to cancel.")))))

(defun kargu-plan-approve ()
  "Approve the current in-memory plan and dispatch it to AI in agent mode."
  (interactive)
  (let* ((buf (get-buffer kargu-plan-buffer-name))
         (plan-text (if (and buf (buffer-live-p buf))
                        (with-current-buffer buf
                          (string-trim (buffer-substring-no-properties (point-min) (point-max))))
                      (or kargu-plan--current-plan ""))))
    (if (string-empty-p plan-text)
        (message "kargu: no plan text found to approve")
      (setq kargu-plan--decision-pending nil)
      (when-let ((win (and buf (get-buffer-window buf))))
        (quit-window nil win))
      (let ((chat-buf (get-buffer (or (bound-and-true-p kargu-chat-buffer-name) "*kargu-chat*"))))
        (when (and chat-buf (buffer-live-p chat-buf))
          (with-current-buffer chat-buf
            (let ((inhibit-read-only t))
              (save-excursion
                (goto-char (point-max))
                (insert (propertize "  ✓ [Plan Approved] — Switching to agent mode and applying plan...\n\n"
                                    'face '(:inherit success :weight bold))))))))
      (kargu-set-mode 'agent)
      (let ((prompt (format "Apply the following approved plan step-by-step:\n\n%s" plan-text)))
        (if (fboundp 'kargu-chat-prompt)
            (kargu-chat-prompt prompt)
          (message "kargu-chat-prompt unavailable"))))))

(defun kargu-plan-reject ()
  "Reject and cancel the pending plan."
  (interactive)
  (setq kargu-plan--decision-pending nil)
  (let ((buf (get-buffer kargu-plan-buffer-name)))
    (when (and buf (buffer-live-p buf))
      (when-let ((win (get-buffer-window buf)))
        (quit-window nil win))))
  (let ((chat-buf (get-buffer (or (bound-and-true-p kargu-chat-buffer-name) "*kargu-chat*"))))
    (when (and chat-buf (buffer-live-p chat-buf))
      (with-current-buffer chat-buf
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (point-max))
            (insert (propertize "  ✗ [Plan Rejected] — Plan cancelled.\n\n"
                                'face 'font-lock-warning-face)))))))
  (message "kargu: plan cancelled"))

(defun kargu-plan-handle-response (report)
  "Render plan approval buttons and populate `*kargu-plan*' for REPORT."
  (let ((plan-text (kargu-plan-extract-text report)))
    (when (and (stringp plan-text) (not (string-empty-p plan-text)))
      (kargu-plan-setup-buffer plan-text)
      (let ((chat-buf (get-buffer (or (bound-and-true-p kargu-chat-buffer-name) "*kargu-chat*"))))
        (when (and chat-buf (buffer-live-p chat-buf))
          (with-current-buffer chat-buf
            (let ((inhibit-read-only t))
              (save-excursion
                (goto-char (point-max))
                (insert "\n")
                (insert (propertize "  📋 [Plan Ready] — Choose an option below:\n"
                                    'face '(:inherit font-lock-doc-face :weight bold)))
                (insert "     ")
                (insert-button
                 "[✓ Approve & Apply]"
                 'action (lambda (_) (kargu-plan-approve))
                 'face '(:inherit success :weight bold)
                 'help-echo "Approve plan and start autonomous execution in Agent mode")
                (insert "   ")
                (insert-button
                 "[✏ View / Edit Plan]"
                 'action (lambda (_) (kargu-plan-view))
                 'face '(:inherit warning :weight bold)
                 'help-echo "Open and edit plan in a side window (in-memory, no disk save)")
                (insert "   ")
                (insert-button
                 "[✗ Reject]"
                 'action (lambda (_) (kargu-plan-reject))
                 'face '(:inherit error :weight bold)
                 'help-echo "Reject and cancel plan")
                (insert "\n\n"))))))
      (message "kargu plan: click [✓ Approve & Apply], [✏ View / Edit Plan], or [✗ Reject]."))))

(provide 'kargu/plan/dispatch)

;;; kargu/plan/dispatch.el ends here
