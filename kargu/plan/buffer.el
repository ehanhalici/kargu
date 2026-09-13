;;; kargu/plan/buffer.el --- In-memory plan buffer management -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Buffer lifecycle and major mode for reviewing plans in memory.

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

(defvar kargu--message-history)
(declare-function kargu-plan-approve "kargu/plan/dispatch" ())
(declare-function kargu-plan-reject "kargu/plan/dispatch" ())

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

(provide 'kargu/plan/buffer)

;;; kargu/plan/buffer.el ends here
