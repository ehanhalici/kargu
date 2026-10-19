;;; buffer.el --- In-memory plan buffer management -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Buffer lifecycle and major mode for reviewing plans in memory.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/contract/constants)
(require 'kargu/plan/store)

(defgroup kargu-plan nil
  "In-memory plan buffer and approval workflow for Kargu."
  :group 'kargu
  :prefix "kargu-plan-")

(defcustom kargu-plan-buffer-name kargu-buffer-plan
  "Base name of per-chat in-memory plan review buffers."
  :type 'string
  :group 'kargu-plan)

(declare-function kargu-plan-approve "kargu/plan/dispatch" (&optional record))
(declare-function kargu-plan-reject "kargu/plan/dispatch" (&optional record))

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
  (let* ((old (kargu-plan-current))
         (origin (if (and old (derived-mode-p 'kargu-plan-mode))
                     (kargu-plan-record-origin old) (current-buffer)))
         (buf (if (and old (buffer-live-p (kargu-plan-record-buffer old)))
                  (kargu-plan-record-buffer old)
                (generate-new-buffer kargu-plan-buffer-name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text))
      (kargu-plan-mode)
      (set-buffer-modified-p nil)
      (goto-char (point-min)))
    (kargu-plan-create origin buf)
    buf))

(defun kargu-plan-extract-text (report)
  "Extract the assistant's final plan text from its owned REPORT.
Never fall back to another chat's globally active conversation history."
  (let ((text (plist-get report :text)))
    (when (and (stringp text) (not (string-empty-p (string-trim text))))
      (string-trim text))))

(provide 'kargu/plan/buffer)

;;; buffer.el ends here
