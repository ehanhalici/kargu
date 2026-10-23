;;; store.el --- Session-owned protocol message storage -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; All container mutations pass through this store.  Public snapshots detach
;; lists and vectors; borrowed views must never be mutated or retained.

;;; Code:

(require 'gv)
(require 'kargu/core/session)
(require 'kargu/contract/history)
(require 'kargu/json)

(defun kargu-history-context (&optional history)
  "Validate explicit HISTORY, or resolve the current session's history."
  (let ((history (or history (kargu-session-history-value (kargu-session-context)))))
    (kargu-contract-assert #'kargu-history-p history)
    history))

(defun kargu-history-messages (&optional history)
  "Borrow HISTORY's message containers read-only, defaulting to current.
Do not retain this view across mutation; use `kargu-history-snapshot'."
  (kargu-history-messages-value (kargu-history-context history)))

(defun kargu-history-snapshot (&optional history)
  "Copy HISTORY's lists and vectors, defaulting to the current owner.
Scalar strings are borrowed read-only values."
  (copy-tree (kargu-history-messages history) t))

(defun kargu-history-replace (messages &optional history)
  "Replace HISTORY with copied draft MESSAGES; default to current owner.
The protocol firewall, not storage, repairs draft message semantics."
  (kargu-contract-assert #'proper-list-p messages)
  (let ((history (kargu-history-context history)) (copy (copy-tree messages t)))
    (setf (kargu-history-messages-value history) copy
          (kargu-history-tail-value history) (last copy)
          (kargu-history-measured-tail-value history) nil
          (kargu-history-char-count-value history) nil)
    copy))

(gv-define-setter kargu-history-messages (value &optional history)
  `(kargu-history-replace ,value ,history))

(defun kargu-history-append (message &optional history)
  "Append copied draft MESSAGE to HISTORY in constant queue-link time.
Default to the current owner; return its read-only stored message.
Snapshots remain independent when later turns are appended or repaired."
  (kargu-contract-assert #'proper-list-p message)
  (let* ((history (kargu-history-context history))
         (cell (list (copy-tree message t)))
         (tail (kargu-history-tail-value history)))
    (if tail (setcdr tail cell)
      (setf (kargu-history-messages-value history) cell))
    (setf (kargu-history-tail-value history) cell)
    (car cell)))

(defun kargu-history-last-message (&optional history)
  "Borrow HISTORY's last message read-only; default to current owner."
  (car (kargu-history-tail-value (kargu-history-context history))))

(defun kargu-history-message-char-count (&optional history)
  "Measure HISTORY's serialized message array, defaulting to current owner.
Only newly appended messages are encoded.  Replacement invalidates the
measurement and cursor; unchanged queries allocate no full JSON string.
This synchronous cursor belongs to the queue, not an asynchronous revision."
  (let* ((history (kargu-history-context history))
         (cursor (kargu-history-measured-tail-value history))
         (pending (if cursor (cdr cursor) (kargu-history-messages-value history)))
         (total (or (kargu-history-char-count-value history) 2))
         (seen cursor))
    (cl-loop for cell on pending do
             (setq total (+ total (if seen 1 0)
                            (length (kargu-json-encode-record (car cell))))
                   seen t cursor cell))
    (setf (kargu-history-measured-tail-value history) cursor
          (kargu-history-char-count-value history) total)
    total))

(defun kargu-history-system-key (&optional history)
  "Return HISTORY's stored prompt identity, defaulting to current owner."
  (kargu-history-system-key-value (kargu-history-context history)))

(gv-define-setter kargu-history-system-key (value &optional history)
  `(setf (kargu-history-system-key-value (kargu-history-context ,history)) ,value))

(defun kargu-history-overlay (&optional history)
  "Return HISTORY's temporary system overlay, defaulting to current owner."
  (kargu-history-overlay-value (kargu-history-context history)))

(defun kargu-history-set-overlay (overlay &optional history)
  "Set HISTORY's system OVERLAY string or nil; default to current owner."
  (kargu-contract-assert (lambda (value) (or (null value) (stringp value))) overlay)
  (setf (kargu-history-overlay-value (kargu-history-context history)) overlay))

(gv-define-setter kargu-history-overlay (value &optional history)
  `(kargu-history-set-overlay ,value ,history))

(provide 'kargu/history/store)
;;; store.el ends here
