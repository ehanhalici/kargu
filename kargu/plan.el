;;; kargu/plan.el --- In-memory plan buffer, review and agent execution -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Plan mode lifecycle:
;; When the AI finishes an implementation plan in `plan' mode, the plan
;; is loaded into an unsaved, in-memory buffer (`*kargu-plan*').
;; The user is presented with three options:
;;   [✓ Approve & Apply]   [✏ View / Edit Plan]   [✗ Reject]
;; Clicking [✏ View / Edit Plan] opens `*kargu-plan*' in a side window
;; where the user can freely inspect and edit the plan without saving to disk.
;; Clicking [✓ Approve & Apply] (or C-c C-c in the plan buffer) reads the
;; latest buffer content, switches the mode to `agent', and submits the
;; plan for autonomous execution.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Ensure the package root is on `load-path' during byte/native compilation.
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
(require 'kargu/constants)

(defgroup kargu-plan nil
  "In-memory plan buffer and approval workflow for Kargu."
  :group 'kargu
  :prefix "kargu-plan-")

(defcustom kargu-plan-buffer-name kargu-buffer-plan
  "Name of the in-memory plan review buffer."
  :type 'string
  :group 'kargu-plan)

(defvar kargu-plan--current-plan nil
  "Cached string of the latest generated or edited plan.")

(defvar kargu-plan--decision-pending nil
  "Non-nil when an implementation plan is awaiting user approval.")

;; Forward declarations for byte-compiler
(defvar kargu-chat-buffer-name)
(defvar kargu--message-history)
(declare-function kargu-chat-prompt "kargu/chat" (&optional prompt))
(declare-function kargu-set-mode "kargu/core" (mode))

;;;; Plan Mode & Keymap ----------------------------------------------------

(defvar-keymap kargu-plan-mode-map
  :doc "Keymap for `kargu-plan-mode'."
  "C-c C-c" #'kargu-plan-approve
  "C-c C-k" #'kargu-plan-reject
  "C-c C-q" #'quit-window)

(define-derived-mode kargu-plan-mode text-mode "kargu-plan"
  "Major mode for editing Kargu implementation plans before approval.
Changes are kept in memory and never written to disk.

\\{kargu-plan-mode-map}"
  (setq-local buffer-file-name nil)
  (setq-local buffer-offer-save nil)
  (setq-local buffer-save-without-query t)
  (setq-local header-line-format
              " [C-c C-c] Approve & Apply | [C-c C-k] Reject | [C-c C-q] Hide | ⚡ In-memory buffer (no saving needed)"))

;;;; Buffer Management -----------------------------------------------------

(defun kargu-plan-setup-buffer (text)
  "Populate the in-memory plan buffer with TEXT without associating a file."
  (let ((buf (get-buffer-create kargu-plan-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text))
      (kargu-plan-mode)
      (set-buffer-modified-p nil)
      (goto-char (point-min)))
    (setq kargu-plan--current-plan text)
    (setq kargu-plan--decision-pending t)
    buf))

(defun kargu-plan-extract-text (report)
  "Extract the assistant's final plan text from REPORT or history."
  (let ((text (plist-get report :text)))
    (if (and (stringp text) (not (string-empty-p (string-trim text))))
        (string-trim text)
      (when (boundp 'kargu--message-history)
        (let ((last-assistant
               (car (last (cl-remove-if-not
                           (lambda (m)
                             (equal (alist-get "role" m nil nil #'equal) "assistant"))
                           kargu--message-history)))))
          (when last-assistant
            (let ((c (alist-get "content" last-assistant nil nil #'equal)))
              (and (stringp c) (string-trim c)))))))))

;;;; User Actions ----------------------------------------------------------

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
      ;; Close window showing plan buffer if open
      (when-let ((win (and buf (get-buffer-window buf))))
        (quit-window nil win))
      ;; Show approval in chat buffer
      (let ((chat-buf (get-buffer (or (bound-and-true-p kargu-chat-buffer-name) "*kargu-chat*"))))
        (when (and chat-buf (buffer-live-p chat-buf))
          (with-current-buffer chat-buf
            (let ((inhibit-read-only t))
              (save-excursion
                (goto-char (point-max))
                (insert (propertize "  ✓ [Plan Approved] — Switching to agent mode and applying plan...\n\n"
                                    'face '(:inherit success :weight bold))))))))
      ;; Switch to agent mode
      (kargu-set-mode 'agent)
      ;; Dispatch to AI agent
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

;;;; Response Handler ------------------------------------------------------

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

(provide 'kargu/plan)

;;; kargu/plan.el ends here
