;;; kargu/history/compact.el --- History size compaction -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Size threshold, tail extraction, and applying a compaction summary.
;; Requires: `kargu/history'.
;; Public: `kargu-history-char-count', `kargu-history-compact-tail',
;; `kargu-history-apply-compaction'.

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
(require 'kargu/prompt)
(require 'kargu/history/protocol)

(declare-function kargu--validate-history "kargu/history/repair")
(declare-function kargu-model-context-window "kargu/api" (&optional model-id))

(defcustom kargu-history-compact-chars 45000
  "Baseline character threshold for compaction when dynamic detection is disabled.
When positive, serves as the minimum floor for dynamic compaction."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-history-compact-keep 8
  "How many trailing non-system messages to keep after compaction.
The suffix is walked back so it does not start on an orphan `tool' result."
  :type 'natnum
  :group 'kargu)

;;;; Compaction -----------------------------------------------------------

(defun kargu-history-compact-threshold ()
  "Dynamic character threshold to trigger history compaction.
Calculated as 70% of the active model's context window capacity,
bounded between `kargu-history-compact-chars' (default 45k) and 800k characters."
  (let* ((ctx-tokens (if (fboundp 'kargu-model-context-window)
                         (kargu-model-context-window)
                       128000))
         ;; 1 token ≈ 3.5 characters in code/prose
         (calc (round (* ctx-tokens 3.5 0.70)))
         (floor-val (or kargu-history-compact-chars 45000)))
    (max floor-val (min calc 800000))))

(defun kargu-history-char-count ()
  "Approximate character cost of `kargu--message-history'."
  (let ((n 0))
    (dolist (msg kargu--message-history)
      (let ((content (kargu--aget msg "content")))
        (when (stringp content)
          (setq n (+ n (length content)))))
      (let ((calls (kargu--aget msg "tool_calls")))
        (when calls
          (setq n (+ n (length (format "%s" calls)))))))
    n))

(defun kargu-history-non-system-count ()
  "Number of non-system messages in the history."
  (let ((n 0))
    (dolist (msg kargu--message-history)
      (unless (equal (kargu--aget msg "role") "system")
        (setq n (1+ n))))
    n))

(defun kargu-history-needs-compact-p ()
  "Non-nil when the history is large enough to compact."
  (let ((threshold (kargu-history-compact-threshold)))
    (and (natnump threshold)
         (> threshold 0)
         (> (kargu-history-char-count) threshold)
         (> (kargu-history-non-system-count) 4))))

(defun kargu--history-compaction-msg-p (msg)
  "Non-nil when MSG is a compaction request or ack."
  (let ((c (kargu--aget msg "content")))
    (and (stringp c)
         (or (string-prefix-p "COMPACTION_REQUEST:" c)
             (string-prefix-p "COMPACTION_ACK:" c)))))

(defun kargu-history-compact-tail ()
  "Copy of the last `kargu-history-compact-keep' recoverable messages.
System messages and compaction notices are dropped.  The suffix
starts on a `user' role so the preceding assistant acknowledgment
in the compaction summary preserves user/assistant turn alternation."
  (let (msgs)
    (dolist (msg kargu--message-history)
      (unless (or (equal (kargu--aget msg "role") "system")
                  (kargu--history-compaction-msg-p msg))
        (push (copy-tree msg) msgs)))
    (setq msgs (nreverse msgs))
    (let* ((slice (last msgs (max 1 kargu-history-compact-keep)))
           (tail slice))
      ;; Walk forward past leading tool or assistant messages if a user turn exists
      (while (and tail (not (equal (kargu--aget (car tail) "role") "user")))
        (setq tail (cdr tail)))
      ;; If a user turn was found, use tail.  Otherwise keep the slice (skipping
      ;; leading orphan tool results) so recent context is not entirely lost.
      (or tail
          (let ((s slice))
            (while (and s (equal (kargu--aget (car s) "role") "tool"))
              (setq s (cdr s)))
            s)))))

(defun kargu--history-drop-trailing-compaction ()
  "Remove a trailing compaction user turn if the request failed."
  (when-let* ((last (car (last kargu--message-history))))
    (when (and (equal (kargu--aget last "role") "user")
               (kargu--history-compaction-msg-p last))
      (setq kargu--message-history (butlast kargu--message-history)))))

(defun kargu-history-apply-compaction (summary tail)
  "Replace the history with SUMMARY plus preserved TAIL.
The usual system prompt is restored (compaction overlay cleared)."
  (setq kargu--compaction-system nil)
  (let* ((kept (cl-remove-if #'kargu--history-compaction-msg-p tail))
         (first-kept-role (and kept (kargu--aget (car kept) "role"))))
    (setq kargu--message-history
          (append
           (list `(("role" . "system")
                   ("content" . ,(kargu--get-system-prompt)))
                 `(("role" . "user")
                   ("content" . ,(format "COMPACTION_ACK: Prior work summary:\n%s"
                                         summary)))
                 `(("role" . "assistant")
                   ("content" . "Acknowledged. Continuing from the summary.")))
           ;; If kept still starts with assistant (defensive), inject a bridging user turn
           (when (and kept (kargu--assistant-role-p first-kept-role))
             (list `(("role" . "user")
                     ("content" . "Please proceed with the task."))))
           kept))
    (kargu-log 'info "history compacted to %d messages (%d chars)"
                     (length kargu--message-history)
                     (kargu-history-char-count))
    (kargu--validate-history)))

(provide 'kargu/history/compact)

;;; kargu/history/compact.el ends here
