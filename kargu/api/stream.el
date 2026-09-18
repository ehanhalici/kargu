;;; kargu/api/stream.el --- SSE parse and stream accumulation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Turn an SSE body into a normal chat-completions alist.
;; Requires: `kargu/core', `kargu/json'.

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
(require 'kargu/json)

;;;; SSE stream parsing ---------------------------------------------------

(defun kargu--sse-parse (text)
  "Parse a complete OpenAI-style SSE TEXT body.
Return the list of decoded data objects, ignoring comments,
keep-alive pings and the terminal \"data: [DONE]\" marker."
  (let (events)
    (dolist (line (split-string text "\n" t))
      (setq line (string-trim-right line "\r"))
      (when (string-prefix-p "data:" line)
        (let ((data (string-trim (substring line (length "data:")))))
          (when (and (not (string-empty-p data))
                     (not (equal data "[DONE]")))
            (when-let* ((event (kargu--json-decode-safe data)))
              (push event events))))))
    (nreverse events)))

(defun kargu--sse-event-error-message (event)
  "Provider error text when EVENT carries an `error' field, or nil."
  (and (kargu--object-p event)
       (assoc "error" event)
       (or (kargu--provider-error-text event) "streaming error")))

(defun kargu--tool-args-fragment-string (new)
  "Normalize a streamed tool-arguments fragment NEW to a string, or nil."
  (cond
   ((stringp new) new)
   ((null new) nil)
   ((eq new :json-null) nil)
   ((or (kargu--object-p new) (vectorp new))
    (kargu--json-encode new))
   (t (format "%s" new))))

(defun kargu--merge-tool-args (old new)
  "Merge streamed argument fragments OLD and NEW.
Concatenates true deltas; replaces when the provider sends
complete JSON snapshots (empty/`{}` then a full object, or two
complete objects)."
  (let ((new-s (kargu--tool-args-fragment-string new))
        (old-s (or old "")))
    (cond
     ((null new-s) old-s)
     ((string-empty-p old-s) new-s)
     ((and (or (equal (string-trim old-s) "{}")
               (equal (string-trim old-s) "[]"))
           (kargu--json-complete-value-string-p new-s))
      new-s)
     ((and (kargu--json-complete-value-string-p old-s)
           (kargu--json-complete-value-string-p new-s))
      new-s)
     (t (concat old-s new-s)))))

(defun kargu--merge-tool-call-fragment (calls-map frag)
  "Merge one streamed tool-call FRAGMENT into CALLS-MAP.
CALLS-MAP maps the fragment \"index\" to the call alist being
assembled.  OpenAI streams tool calls in fragments: the id and
name arrive once, the \"arguments\" JSON string in pieces.
Some providers send complete argument snapshots; those replace
rather than concatenate."
  (let* ((idx (or (kargu--aget frag "index") 0))
         (fn (kargu--aget frag "function"))
         (call (or (gethash idx calls-map)
                   (puthash idx
                            `(("id" . ,(or (kargu--aget frag "id") ""))
                              ("type" . "function")
                              ("function" .
                               (("name" . ,(or (and fn (kargu--aget fn "name")) ""))
                                ("arguments" . ""))))
                            calls-map)))
         (cfn (kargu--aget call "function")))
    (when (kargu--aget frag "id")
      (setcdr (assoc "id" call) (kargu--aget frag "id")))
    (when fn
      (when-let* ((name (kargu--aget fn "name")))
        (setcdr (assoc "name" cfn) name))
      (let ((args (kargu--aget fn "arguments")))
        (unless (memq args '(nil :json-null))
          (setcdr (assoc "arguments" cfn)
                  (kargu--merge-tool-args
                   (kargu--aget cfn "arguments") args)))))))

(defun kargu--extract-stream-tool-frags (delta)
  "Extract normalized list of tool call fragments from DELTA."
  (let* ((raw-frags (or (kargu--aget delta "tool_calls")
                        (let ((legacy (kargu--aget delta "function_call")))
                          (and legacy (kargu--object-p legacy)
                               (list `(("index" . 0)
                                       ("id" . "call_legacy")
                                       ("function" . ,legacy))))))))
    (cond
     ((vectorp raw-frags) (append raw-frags nil))
     ((listp raw-frags) raw-frags)
     (t nil))))

(defun kargu--assemble-stream-message (text reasoning calls)
  "Assemble assistant message alist from TEXT, REASONING, and CALLS."
  (let ((message `(("role" . "assistant")))
        (has-text (not (string-empty-p text)))
        (has-reason (not (string-empty-p reasoning))))
    (when has-text
      (push `("content" . ,text) message))
    (when has-reason
      (push `("reasoning_content" . ,reasoning) message))
    (when calls
      (push `("tool_calls" . ,calls) message))
    (unless (or has-text calls)
      (push `("content" . "") message))
    message))

(defun kargu--accumulate-stream-deltas (events)
  "Reduce parsed SSE EVENTS into a response shaped like an
ordinary chat-completions reply, so every consumer (loop, UI,
history) stays on a single code path regardless of transport.
Content and reasoning are concatenated separately; tool-call
fragments are merged by index.  An SSE `error' event becomes an
error alist; it does not invent an empty assistant turn."
  (catch 'kargu-sse
    (dolist (event events)
      (when-let* ((err (kargu--sse-event-error-message event)))
        (throw 'kargu-sse `(("error" . (("message" . ,err)))))))
    (let ((text-chunks nil)
          (reasoning-chunks nil)
          (finish nil)
          (usage nil)
          (calls-map (make-hash-table :test #'eql)))
      (dolist (event events)
        (let* ((choices (kargu--aget event "choices"))
               (choice (cond
                        ((consp choices) (car choices))
                        ((vectorp choices) (and (> (length choices) 0) (aref choices 0)))
                        (t nil))))
          (when choice
            (let ((delta (kargu--aget choice "delta"))
                  (fr (kargu--aget choice "finish_reason")))
              (unless (memq delta '(nil :json-null))
                (when-let* ((chunk (kargu--content-text delta)))
                  (push chunk text-chunks))
                (when-let* ((rchunk (kargu--reasoning-text delta)))
                  (push rchunk reasoning-chunks))
                (dolist (frag (kargu--extract-stream-tool-frags delta))
                  (kargu--merge-tool-call-fragment calls-map frag)))
              (unless (memq fr '(nil :json-null))
                (setq finish fr)))))
        (when-let* ((u (kargu--aget event "usage")))
          (unless (eq u :json-null)
            (setq usage u))))
      (let* ((text (if text-chunks (apply #'concat (nreverse text-chunks)) ""))
             (reasoning (if reasoning-chunks (apply #'concat (nreverse reasoning-chunks)) ""))
             (calls (mapcar (lambda (idx) (gethash idx calls-map))
                            (sort (hash-table-keys calls-map) #'<)))
             (message (kargu--assemble-stream-message text reasoning calls)))
        `(("choices" . ((("index" . 0)
                         ("message" . ,message)
                         ("finish_reason" . ,(or finish "stop")))))
          ,@(when usage `(("usage" . ,usage))))))))

(provide 'kargu/api/stream)

;;; kargu/api/stream.el ends here
