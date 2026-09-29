;;; kargu/history/repair.el --- Protocol history repair and firewall -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Enforces protocol firewall invariants before a payload is sent to the LLM.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
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
PENDING is a hash table mapping tool-call ids to (name . seq) or name.
The table is cleared upon completion."
  (when (> (hash-table-count pending) 0)
    (kargu-log 'warn
               "validate: %d unanswered tool call(s); injecting synthetic error results"
               (hash-table-count pending))
    (let (entries)
      (maphash (lambda (id val)
                 (let ((name (if (consp val) (car val) val))
                       (seq (if (consp val) (cdr val) 0)))
                   (push (list seq id name) entries)))
               pending)
      (setq entries (sort entries (lambda (a b)
                                    (if (= (nth 0 a) (nth 0 b))
                                        (string< (nth 1 a) (nth 1 b))
                                      (< (nth 0 a) (nth 0 b))))))
      (dolist (entry entries)
        (push `(("role" . "tool")
                ("tool_call_id" . ,(nth 1 entry))
                ("name" . ,(nth 2 entry))
                ("content" . "ERROR: interrupted before response"))
              out-rev))))
  (clrhash pending)
  out-rev)

(defun kargu--history-fresh-system-message ()
  "A new system message; records the key it was built for."
  (setq kargu--system-key (kargu-prompt-system-key))
  `(("role" . "system")
    ("content" . ,(kargu--get-system-prompt))))

(defun kargu--history-system-current-p (sys)
  "Non-nil when the stored system message SYS still matches the session.
An unchanged prompt is kept byte for byte so the provider prompt cache hits;
a changed mode, tool support, model or compaction overlay rebuilds it."
  (let ((content (kargu-aget sys "content")))
    (and (stringp content)
         (not (string-empty-p (string-trim content)))
         (equal kargu--system-key (kargu-prompt-system-key)))))

(defun kargu--history-refresh-system-head (history &optional force-refresh)
  "Return cons of (HEAD-MSG . REMAINING-MSGS) for HISTORY.
The existing system message is preserved while `kargu-prompt-system-key'
is unchanged.  A missing, empty or stale one, or FORCE-REFRESH, builds a
fresh message via `kargu--get-system-prompt'."
  (let* ((rest (copy-tree history t))
         (sys (and rest
                   (equal (kargu-aget (car rest) "role") "system")
                   (copy-tree (pop rest) t))))
    (if (and sys (not force-refresh) (kargu--history-system-current-p sys))
        (cons sys rest)
      (cons (kargu--history-fresh-system-message) rest))))

(defun kargu--history-process-tool-result (msg pending out)
  "Validate tool result MSG against PENDING table and return updated OUT."
  (let ((id (kargu-aget msg "tool_call_id")))
    (if (and id (gethash id pending))
        (progn
          (remhash id pending)
          (cons msg out))
      (kargu-log 'warn "validate: dropping orphan tool result %s" (or id "(no id)"))
      out)))

(defvar kargu--system-key)
(declare-function kargu-prompt-system-key "kargu/prompt" ())
(declare-function kargu--history-compaction-msg-p "kargu/history/compact" (msg))

(defun kargu--history-merge-consecutive-content (msg out &optional trim-p)
  "Merge content string of MSG into head of OUT, optionally applying TRIM-P."
  (let* ((prev (car out))
         (extra (if (stringp (kargu-aget msg "content"))
                    (kargu-aget msg "content")
                  ""))
         (prev-text (if (stringp (kargu-aget prev "content"))
                        (kargu-aget prev "content")
                      ""))
         (merged (concat prev-text "\n\n" extra))
         (final (if trim-p (string-trim merged) merged)))
    (if (assoc "content" prev)
        (setcdr (assoc "content" prev) final)
      (setcar out (cons `("content" . ,(if trim-p (string-trim extra) extra)) prev)))
    out))

(defun kargu--history-merge-consecutive-user (msg out)
  "Merge consecutive user MSG into head of OUT and return updated OUT."
  (kargu--history-merge-consecutive-content msg out nil))

(defun kargu--history-merge-consecutive-assistant (msg out)
  "Merge consecutive assistant text MSG into head of OUT and return updated OUT."
  (kargu--history-merge-consecutive-content msg out t))

(defun kargu--history-process-assistant-with-calls (msg pending out &optional next-seq-fn)
  "Process assistant MSG containing tool calls into OUT and register in PENDING."
  (let* ((clean (kargu--clean-assistant-message
                 (kargu--normalize-assistant-role msg)))
         (calls (kargu--calls-to-list (kargu-aget clean "tool_calls"))))
    (if (and out (kargu--assistant-role-p (kargu-aget (car out) "role"))
             (not (kargu--calls-to-list (kargu-aget (car out) "tool_calls"))))
        (let* ((prev (pop out))
               (prev-txt (or (kargu-aget prev "content") ""))
               (curr-txt (or (kargu-aget clean "content") ""))
               (merged-txt (string-trim (concat prev-txt "\n\n" curr-txt))))
          (when (not (string-empty-p merged-txt))
            (if (assoc "content" clean)
                (setcdr (assoc "content" clean) merged-txt)
              (push `("content" . ,merged-txt) clean)))
          (push clean out))
      (push clean out))
    (dolist (call calls)
      (when-let* ((id (kargu-aget call "id")))
        (let ((seq (if next-seq-fn (funcall next-seq-fn) 0)))
          (puthash id
                   (cons (or (kargu-aget (kargu-aget call "function") "name") "unknown")
                         seq)
                   pending))))
    out))

(defun kargu--history-fix-trailing-turn (out)
  "Ensure history in OUT does not end on an assistant turn."
  (if (and out (kargu--assistant-role-p (kargu-aget (car out) "role")))
      (if (eq kargu-trailing-assistant-fix 'strip)
          (let ((trimmed out))
            (while (and trimmed
                        (kargu--assistant-role-p (kargu-aget (car trimmed) "role")))
              (pop trimmed))
            trimmed)
        (cons `(("role" . "user")
                ("content" . ,kargu--continue-nudge))
              out))
    out))

(defun kargu--history-process-regular-turn (msg role pending out next-seq)
  "Process non-tool, non-system turn MSG with ROLE, flushing PENDING into OUT."
  (let ((acc (kargu--flush-pending pending out)))
    (cond
     ((and (kargu--assistant-role-p role)
           (kargu--calls-to-list (kargu-aget msg "tool_calls")))
      (kargu--history-process-assistant-with-calls msg pending acc next-seq))
     ((and (equal role "user")
           (equal (kargu-aget (car acc) "role") "user")
           (not (kargu--history-compaction-msg-p msg)))
      (kargu--history-merge-consecutive-user msg acc))
     ((and (kargu--assistant-role-p role)
           acc
           (kargu--assistant-role-p (kargu-aget (car acc) "role"))
           (not (kargu--calls-to-list (kargu-aget (car acc) "tool_calls"))))
      (kargu--history-merge-consecutive-assistant msg acc))
     (t
      (when (kargu--assistant-role-p role)
        (kargu--normalize-assistant-role msg)
        (unless (or (kargu--calls-to-list (kargu-aget msg "tool_calls"))
                    (kargu-nonempty (kargu-aget msg "content")))
          (if (assoc "content" msg)
              (setcdr (assoc "content" msg) "")
            (push '("content" . "") msg))))
      (cons msg acc)))))

(defun kargu--validate-history (&optional keep-assistant-tail)
  "Enforce the protocol invariants required by chat providers.
Mutates `kargu--message-history' in place and returns it.
The send path leaves KEEP-ASSISTANT-TAIL nil so a payload does
not end on an assistant turn.  A finished run and a compaction
pass non-nil: the stored answer stays, and the next user turn
is what makes the tail legal."
  (let* ((pending (make-hash-table :test #'equal))
         (seq 0)
         (next-seq (lambda () (cl-incf seq)))
         (head-and-rest (kargu--history-refresh-system-head kargu--message-history))
         (out (list (car head-and-rest)))
         (rest (cdr head-and-rest)))
    ;; Walk each turn in the rest of history
    (dolist (raw rest)
      (let* ((msg (copy-tree raw t))
             (role (kargu-aget msg "role")))
        (cond
         ((equal role "tool")
          (setq out (kargu--history-process-tool-result msg pending out)))
         ((equal role "system")
          nil)
         (t
          (setq out (kargu--history-process-regular-turn msg role pending out next-seq))))))
    (setq out (kargu--flush-pending pending out))
    (unless keep-assistant-tail
      (setq out (kargu--history-fix-trailing-turn out)))
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
