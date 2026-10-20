;;; compact.el --- History size compaction -*- lexical-binding: t; -*-

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
(require 'kargu/core)
(require 'kargu/prompt)
(require 'kargu/history/protocol)

(declare-function kargu--validate-history "kargu/history/repair")
(declare-function kargu--history-fresh-system-message "kargu/history/repair" ())
(declare-function kargu-model-context-window "kargu/api/catalog" (&optional model-id provider))
(declare-function kargu-tool-schema-char-count "kargu/api/tools" ())

(defconst kargu-history--chars-per-token 3.5
  "Estimated characters per token for text and code.")
(defconst kargu-history--compact-ratio 0.70
  "Fraction of a known context window available before compaction.")
(defconst kargu-history--compact-ceiling 800000
  "Largest dynamic compaction threshold in characters.")

(defcustom kargu-history-compact-chars 45000
  "Fallback character threshold when the model's context window is unknown.
A known window takes precedence, even when smaller than this value."
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
Use 70% of the active model's window with 3.5 characters per token,
capped at 800k characters.  With no known window, use the configured
`kargu-history-compact-chars' fallback."
  (kargu-history-context-threshold
   (and (fboundp 'kargu-model-context-window) (kargu-model-context-window))))

(defun kargu-history-context-threshold (ctx-tokens)
  "Return the compaction character budget for explicit CTX-TOKENS.
Use the configured fallback when that context window is unknown."
  (let ((fallback (or kargu-history-compact-chars 45000)))
    ;; Budget heuristic; actual tokenization is provider-specific.
    (if (and (numberp ctx-tokens) (> ctx-tokens 0))
        (min kargu-history--compact-ceiling
             (max 1 (round (* ctx-tokens kargu-history--chars-per-token
                              kargu-history--compact-ratio))))
      fallback)))

(defun kargu-history-char-count ()
  "Estimate serialized history and advertised schema character cost.
Include system text, structured content, attachments and list/vector tool
invocations.  Image tokenization remains provider-dependent."
  (+ (length (kargu-json-encode-record (vconcat (kargu-history-messages))))
     (if (fboundp 'kargu-tool-schema-char-count)
         (kargu-tool-schema-char-count)
       0)))

(defun kargu-history-non-system-count ()
  "Number of non-system messages in the history."
  (let ((n 0))
    (dolist (msg (kargu-history-messages))
      (unless (equal (kargu-aget msg "role") "system")
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
  (let ((c (kargu-aget msg "content")))
    (and (stringp c)
         (or (string-prefix-p "COMPACTION_REQUEST:" c)
             (string-prefix-p "COMPACTION_ACK:" c)))))

(defun kargu-history-compact-tail ()
  "Copy of the last `kargu-history-compact-keep' recoverable messages.
System messages and compaction notices are dropped.  The suffix
starts on a `user' role so the preceding assistant acknowledgment
in the compaction summary preserves user/assistant turn alternation."
  (let (msgs)
    (dolist (msg (kargu-history-messages))
      (unless (or (equal (kargu-aget msg "role") "system")
                  (kargu--history-compaction-msg-p msg))
        (push (copy-tree msg) msgs)))
    (setq msgs (nreverse msgs))
    (let* ((slice (last msgs (max 1 kargu-history-compact-keep)))
           (tail slice))
      ;; Walk forward past leading tool or assistant messages if a user turn exists
      (while (and tail (not (equal (kargu-aget (car tail) "role") "user")))
        (setq tail (cdr tail)))
      ;; If a user turn was found, use tail.  Otherwise keep the slice (skipping
      ;; leading orphan tool results) so recent context is not entirely lost.
      (or tail
          (let ((s slice))
            (while (and s (equal (kargu-aget (car s) "role") "tool"))
              (setq s (cdr s)))
            s)))))

(defun kargu--history-drop-trailing-compaction ()
  "Remove a trailing compaction user turn if the request failed."
  (when-let* ((last (car (last (kargu-history-messages)))))
    (when (and (equal (kargu-aget last "role") "user")
               (kargu--history-compaction-msg-p last))
      (setf (kargu-history-messages) (butlast (kargu-history-messages))))))

(defun kargu-history-apply-compaction (summary tail)
  "Replace the history with SUMMARY plus preserved TAIL.
The usual system prompt is restored (compaction overlay cleared)."
  (setf (kargu-history-overlay) nil)
  (let* ((sys-msg (kargu--history-fresh-system-message))
         (kept (cl-remove-if #'kargu--history-compaction-msg-p tail))
         (first-kept-role (and kept (kargu-aget (car kept) "role"))))
    (setf (kargu-history-messages)
          (append
           (list sys-msg
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
               (length (kargu-history-messages))
               (kargu-history-char-count))
    (kargu--validate-history 'keep-assistant-tail)))

(provide 'kargu/history/compact)

;;; compact.el ends here
