;;; repair.el --- Protocol history repair and firewall -*- lexical-binding: t; -*-

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
  "Extend OUT-REV with synthetic results for unanswered invocations.
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

(defun kargu--history-fresh-system-message (&optional history)
  "Build HISTORY's system message and record its current prompt identity."
  (setf (kargu-history-system-key history) (kargu-prompt-system-key history))
  `(("role" . "system")
    ("content" . ,(kargu--get-system-prompt history))))

(defun kargu--history-system-current-p (sys &optional history)
  "Non-nil when the stored system message SYS still matches the session.
An unchanged prompt is kept byte for byte so the provider prompt cache hits;
a changed mode, tool support, model or HISTORY overlay rebuilds it."
  (let ((content (kargu-aget sys "content")))
    (and (stringp content)
         (not (string-empty-p (string-trim content)))
         (equal (kargu-history-system-key history) (kargu-prompt-system-key history)))))

(defun kargu--history-refresh-system-head (messages &optional force-refresh history)
  "Return cons of (HEAD-MSG . REMAINING-MSGS) for draft MESSAGES.
The existing system message is preserved while `kargu-prompt-system-key'
is unchanged.  A missing, empty or stale one, or FORCE-REFRESH, builds a
fresh message for explicit HISTORY or the current owner."
  (let* ((rest (copy-tree messages t))
         (sys (and rest
                   (equal (kargu-aget (car rest) "role") "system")
                   (copy-tree (pop rest) t))))
    (if (and sys (not force-refresh) (kargu--history-system-current-p sys history))
        (cons sys rest)
      (cons (kargu--history-fresh-system-message history) rest))))

(defun kargu--history-process-tool-result (msg pending out)
  "Validate tool result MSG against PENDING table and return updated OUT."
  (let ((id (kargu-aget msg "tool_call_id")))
    (if (and id (gethash id pending))
        (progn
          (remhash id pending)
          (cons msg out))
      (kargu-log 'warn "validate: dropping orphan tool result %s" (or id "(no id)"))
      out)))

(declare-function kargu-prompt-system-key "kargu/prompt" (&optional history))
(declare-function kargu--history-compaction-msg-p "kargu/history/compact" (msg))

(defun kargu--history-content-present-p (content)
  "Check CONTENT for text or structured content blocks."
  (or (and (stringp content) (not (string-empty-p (string-trim content))))
      (and (or (vectorp content) (consp content))
           (seq-some (lambda (block)
                       (if (equal (kargu-aget block "type") "text")
                           (kargu--history-content-present-p (kargu-aget block "text"))
                         t)) content))))

(defun kargu--history-content-blocks (content)
  "Return CONTENT as a list of blocks without discarding attachments."
  (cond
   ((stringp content)
    (unless (string-empty-p content)
      (list (list '("type" . "text") (cons "text" content)))))
   ((or (vectorp content) (consp content)) (append content nil))))

(defun kargu--history-merged-content (left right &optional trim-p)
  "Combine LEFT and RIGHT, applying TRIM-P only to plain text."
  (when (memq left '(nil :json-null :json-false)) (setq left ""))
  (when (memq right '(nil :json-null :json-false)) (setq right ""))
  (if (and (stringp left) (stringp right))
      (let ((merged (concat left "\n\n" right)))
        (if trim-p (string-trim merged) merged))
    (let ((before (kargu--history-content-blocks left))
          (after (kargu--history-content-blocks right)))
      (vconcat before
               (and before after '((("type" . "text") ("text" . "\n\n"))))
               after))))

(defun kargu--history-merge-consecutive-content (msg out &optional trim-p)
  "Merge MSG content into the head of OUT, optionally applying TRIM-P."
  (let* ((prev (car out))
         (final (kargu--history-merged-content
                 (kargu-aget prev "content") (kargu-aget msg "content") trim-p)))
    (if (assoc "content" prev)
        (setcdr (assoc "content" prev) final)
      (setcar out (cons (cons "content" final) prev)))
    out))

(defun kargu--history-merge-consecutive-user (msg out)
  "Merge consecutive user MSG into head of OUT and return updated OUT."
  (kargu--history-merge-consecutive-content msg out nil))

(defun kargu--history-merge-consecutive-assistant (msg out)
  "Merge consecutive assistant text MSG into head of OUT and return updated OUT."
  (kargu--history-merge-consecutive-content msg out t))

(cl-defun kargu--history-process-assistant-with-calls (msg &key pending out next-seq-fn)
  "Register assistant MSG's invocations in PENDING and extend OUT.
NEXT-SEQ-FN supplies each invocation's stable sequence number."
  (let* ((clean (kargu--clean-assistant-message
                 (kargu--normalize-assistant-role msg)))
         (calls (kargu--calls-to-list (kargu-aget clean "tool_calls"))))
    (if (and out (kargu--assistant-role-p (kargu-aget (car out) "role"))
             (not (kargu--calls-to-list (kargu-aget (car out) "tool_calls"))))
        (let* ((prev (pop out))
               (merged-txt (kargu--history-merged-content
                            (kargu-aget prev "content")
                            (kargu-aget clean "content") t)))
          (when (kargu--history-content-present-p merged-txt)
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

(cl-defun kargu--history-process-regular-turn (msg role &key pending out next-seq)
  "Process MSG with ROLE, flushing PENDING into OUT.
NEXT-SEQ supplies each invocation's stable sequence number."
  (let ((acc (kargu--flush-pending pending out)))
    (when (and (equal role "user")
               (not (kargu--history-content-present-p (kargu-aget msg "content"))))
      (if (assoc "content" msg)
          (setcdr (assoc "content" msg) kargu--continue-nudge)
        (push (cons "content" kargu--continue-nudge) msg)))
    (cond
     ((and (kargu--assistant-role-p role)
           (kargu--calls-to-list (kargu-aget msg "tool_calls")))
      (kargu--history-process-assistant-with-calls
       msg :pending pending :out acc :next-seq-fn next-seq))
     ((and (kargu--assistant-role-p role)
           (not (kargu--history-content-present-p (kargu-aget msg "content"))))
      acc)
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
        (kargu--normalize-assistant-role msg))
      (cons msg acc)))))

(defun kargu--history-ensure-user (history)
  "Insert a user nudge into HISTORY only if no user turn remains."
  (if (seq-some (lambda (message) (equal (kargu-aget message "role") "user")) history)
      history
    (let ((nudge (list '("role" . "user") (cons "content" kargu--continue-nudge))))
      (if history
          (progn (setcdr history (cons nudge (cdr history))) history)
        (list nudge)))))

(defun kargu--validate-history (&optional keep-assistant-tail history)
  "Enforce the protocol invariants required by chat providers.
Replace HISTORY's drafts with repaired messages and return them.
Default to the current owner's history.
The send path leaves KEEP-ASSISTANT-TAIL nil so a payload does
not end on an assistant turn.  A finished run and a compaction
pass non-nil: the stored answer stays, and the next user turn
is what makes the tail legal."
  (let* ((pending (make-hash-table :test #'equal))
         (seq 0)
         (next-seq (lambda () (cl-incf seq)))
         (history (kargu-history-context history))
         (head-and-rest (kargu--history-refresh-system-head
                         (kargu-history-messages history) nil history))
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
          (setq out (kargu--history-process-regular-turn
                     msg role :pending pending :out out :next-seq next-seq))))))
    (setq out (kargu--flush-pending pending out))
    (unless keep-assistant-tail
      (setq out (kargu--history-fix-trailing-turn out)))
    (setf (kargu-history-messages history) (kargu--history-ensure-user (nreverse out)))
    (kargu-log 'debug "validate: %d messages, last role %s"
               (length (kargu-history-messages history))
               (kargu--history-last-role history))
    (when (called-interactively-p 'any)
      (message "kargu history: %d messages, last role %s"
               (length (kargu-history-messages history))
               (kargu--history-last-role history)))
    (kargu-history-messages history)))

(defalias 'kargu-history-validate #'kargu--validate-history)

(provide 'kargu/history/repair)

;;; repair.el ends here
