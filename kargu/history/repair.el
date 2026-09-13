;;; kargu/history/repair.el --- Protocol history repair and firewall -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Enforces protocol firewall invariants before a payload is sent to the LLM.

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

(defcustom kargu-trailing-assistant-fix 'strip
  "How to repair a history that ends on an assistant (model) turn.
`strip' removes trailing assistant messages (protocol default);
`nudge' appends a minimal user message asking the model to continue."
  :type '(choice (const :tag "Drop trailing assistant messages" strip)
                 (const :tag "Append a user \"continue\" message" nudge))
  :group 'kargu)

(defconst kargu--continue-nudge "Continue."
  "Content of the synthetic user message used by the `nudge' fix.")

(defun kargu--flush-pending (pending out-rev)
  "Extend OUT-REV with synthetic tool results for unanswered calls.
PENDING is a hash table mapping tool-call ids to tool names; it is cleared."
  (when (> (hash-table-count pending) 0)
    (kargu-log 'warn
               "validate: %d unanswered tool call(s); injecting synthetic error results"
               (hash-table-count pending)))
  (maphash (lambda (id name)
             (push `(("role" . "tool")
                     ("tool_call_id" . ,id)
                     ("name" . ,name)
                     ("content" . "ERROR: interrupted before response"))
                   out-rev))
           pending)
  (clrhash pending)
  out-rev)

(defun kargu--history-refresh-system-head (history)
  "Return cons of (HEAD-MSG . REMAINING-MSGS) ensuring fresh system prompt."
  (let ((rest history))
    (if (and rest (equal (kargu--aget (car rest) "role") "system"))
        (let ((sys (pop rest)))
          (if (assoc "content" sys)
              (setcdr (assoc "content" sys) (kargu--get-system-prompt))
            (push `("content" . ,(kargu--get-system-prompt)) sys))
          (cons sys rest))
      (cons `(("role" . "system")
              ("content" . ,(kargu--get-system-prompt)))
            rest))))

(defun kargu--history-process-tool-result (msg pending out)
  "Validate tool result MSG against PENDING table and return updated OUT."
  (let ((id (kargu--aget msg "tool_call_id")))
    (if (and id (gethash id pending))
        (progn
          (remhash id pending)
          (cons msg out))
      (kargu-log 'warn "validate: dropping orphan tool result %s" (or id "(no id)"))
      out)))

(defun kargu--history-merge-consecutive-user (msg out)
  "Merge consecutive user MSG into head of OUT and return updated OUT."
  (let* ((prev (car out))
         (extra (if (stringp (kargu--aget msg "content"))
                    (kargu--aget msg "content")
                  "")))
    (if (assoc "content" prev)
        (setcdr (assoc "content" prev)
                (concat (if (stringp (kargu--aget prev "content"))
                            (kargu--aget prev "content")
                          "")
                        "\n\n" extra))
      (setcar out (cons `("content" . ,extra) prev)))
    out))

(defun kargu--history-merge-consecutive-assistant (msg out)
  "Merge consecutive assistant text MSG into head of OUT and return updated OUT."
  (let* ((prev (car out))
         (extra (if (stringp (kargu--aget msg "content"))
                    (kargu--aget msg "content")
                  "")))
    (if (assoc "content" prev)
        (setcdr (assoc "content" prev)
                (string-trim
                 (concat (if (stringp (kargu--aget prev "content"))
                             (kargu--aget prev "content")
                           "")
                         "\n\n" extra)))
      (setcar out (cons `("content" . ,(string-trim extra)) prev)))
    out))

(defun kargu--history-process-assistant-with-calls (msg pending out)
  "Process assistant MSG containing tool calls into OUT and register in PENDING."
  (let* ((clean (kargu--clean-assistant-message
                 (kargu--normalize-assistant-role msg)))
         (calls (kargu--calls-to-list (kargu--aget clean "tool_calls"))))
    (if (and out (kargu--assistant-role-p (kargu--aget (car out) "role"))
             (not (kargu--calls-to-list (kargu--aget (car out) "tool_calls"))))
        (let* ((prev (pop out))
               (prev-txt (or (kargu--aget prev "content") ""))
               (curr-txt (or (kargu--aget clean "content") ""))
               (merged-txt (string-trim (concat prev-txt "\n\n" curr-txt))))
          (when (not (string-empty-p merged-txt))
            (if (assoc "content" clean)
                (setcdr (assoc "content" clean) merged-txt)
              (push `("content" . ,merged-txt) clean)))
          (push clean out))
      (push clean out))
    (dolist (call calls)
      (when-let* ((id (kargu--aget call "id")))
        (puthash id
                 (or (kargu--aget (kargu--aget call "function") "name") "unknown")
                 pending)))
    out))

(defun kargu--history-fix-trailing-turn (out)
  "Ensure history in OUT does not end on an assistant turn."
  (if (and out (kargu--assistant-role-p (kargu--aget (car out) "role")))
      (if (eq kargu-trailing-assistant-fix 'strip)
          (let ((trimmed out))
            (while (and trimmed
                        (kargu--assistant-role-p (kargu--aget (car trimmed) "role")))
              (pop trimmed))
            trimmed)
        (cons `(("role" . "user")
                ("content" . ,kargu--continue-nudge))
              out))
    out))

(defun kargu--validate-history ()
  "Enforce the protocol invariants required by chat providers.
Mutates `kargu--message-history' in place and returns it."
  (let* ((pending (make-hash-table :test #'equal))
         (head-and-rest (kargu--history-refresh-system-head kargu--message-history))
         (out (list (car head-and-rest)))
         (rest (cdr head-and-rest)))
    ;; Walk each turn in the rest of history
    (dolist (raw rest)
      (let* ((msg (copy-tree raw))
             (role (kargu--aget msg "role")))
        (cond
         ((equal role "tool")
          (setq out (kargu--history-process-tool-result msg pending out)))
         ((equal role "system")
          nil)
         (t
          (setq out (kargu--flush-pending pending out))
          (cond
           ((and (kargu--assistant-role-p role)
                 (kargu--calls-to-list (kargu--aget msg "tool_calls")))
            (setq out (kargu--history-process-assistant-with-calls msg pending out)))
           ((and (equal role "user")
                 (equal (kargu--aget (car out) "role") "user"))
            (setq out (kargu--history-merge-consecutive-user msg out)))
           ((and (kargu--assistant-role-p role)
                 out
                 (kargu--assistant-role-p (kargu--aget (car out) "role"))
                 (not (kargu--calls-to-list (kargu--aget (car out) "tool_calls"))))
            (setq out (kargu--history-merge-consecutive-assistant msg out)))
           (t
            (when (kargu--assistant-role-p role)
              (kargu--normalize-assistant-role msg)
              (unless (or (kargu--calls-to-list (kargu--aget msg "tool_calls"))
                          (kargu--nonempty (kargu--aget msg "content")))
                (if (assoc "content" msg)
                    (setcdr (assoc "content" msg) "")
                  (push '("content" . "") msg))))
            (push msg out)))))))
    ;; Flush any trailing dangling tool calls & fix trailing turn
    (setq out (kargu--flush-pending pending out))
    (setq out (kargu--history-fix-trailing-turn out))
    (setq kargu--message-history (nreverse out))
    (kargu-log 'debug "validate: %d messages, last role %s"
               (length kargu--message-history)
               (kargu--history-last-role))
    (when (called-interactively-p 'any)
      (message "kargu history: %d messages, last role %s"
               (length kargu--message-history)
               (kargu--history-last-role)))
    kargu--message-history))

(defalias 'kargu-history-validate #'kargu--validate-history)

(provide 'kargu/history/repair)

;;; kargu/history/repair.el ends here
