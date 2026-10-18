;;; stream.el --- SSE parse and stream accumulation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Turn an SSE body into a normal chat-completions alist.
;; Requires: `kargu/core', `kargu/json'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rx)
(require 'kargu/core)
(require 'kargu/json)

;;;; SSE stream parsing ---------------------------------------------------

(defun kargu-sse-decode-data (data)
  "Decode one SSE DATA payload, retaining malformed JSON as an error event."
  (condition-case nil
      (kargu--json-decode data)
    (error '(("error" . (("message" . "Invalid JSON in SSE data event")))))))

(defun kargu--sse-parse (text)
  "Parse a complete OpenAI-style SSE TEXT body.
Return decoded data objects and `:done' for the terminal marker.
Ignore comments and keep-alive pings."
  (let (events)
    (dolist (line (split-string text "\n" t))
      (setq line (string-trim-right line "\r"))
      (when (string-prefix-p "data:" line)
        (let ((data (string-trim (substring line (length "data:")))))
          (cond
           ((equal data "[DONE]") (push :done events))
           ((not (string-empty-p data))
            (when-let* ((event (kargu-sse-decode-data data)))
              (push event events)))))))
    (nreverse events)))

(defun kargu--sse-event-error-message (event)
  "Provider error text when EVENT carries an `error' field, or nil."
  (and (kargu--object-p event)
       (not (memq (kargu-aget event "error") '(nil :json-null :json-false)))
       (or (kargu--provider-error-text event) "streaming error")))

(defun kargu--stream-fragment-index (frag)
  "Return FRAG's nonnegative integer index, accepting decimal strings."
  (let ((index (kargu-aget frag "index")))
    (cond
     ((null index) 0)
     ((natnump index) index)
     ((and (stringp index) (string-match-p (rx bos (+ digit) eos) index))
      (string-to-number index))
     (t (error "Invalid streamed tool-call index: %S" index)))))

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
  "Merge one streamed tool-call FRAG into CALLS-MAP.
CALLS-MAP maps the fragment \"index\" to the call alist being
assembled.  OpenAI streams tool calls in fragments: the id and
name arrive once, the \"arguments\" JSON string in pieces.
Some providers send complete argument snapshots; those replace
rather than concatenate."
  (let* ((idx (kargu--stream-fragment-index frag))
         (fn (kargu-aget frag "function"))
         (call (or (gethash idx calls-map)
                   (puthash idx
                            (list (cons "id" (or (kargu-aget frag "id") ""))
                                  (cons "type" "function")
                                  (cons "function"
                                        (list (cons "name" (or (and fn (kargu-aget fn "name")) ""))
                                              (cons "arguments" ""))))
                            calls-map)))
         (cfn (kargu-aget call "function")))
    (when-let* ((id (kargu-nonempty (kargu-aget frag "id"))))
      (when (and (kargu-nonempty (kargu-aget call "id"))
                 (not (equal id (kargu-aget call "id"))))
        (error "Conflicting tool-call identities at stream index %s" idx))
      (setcdr (assoc "id" call) id))
    (when fn
      (when-let* ((name (kargu-nonempty (kargu-aget fn "name"))))
        (setcdr (assoc "name" cfn) name))
      (let ((args (kargu-aget fn "arguments")))
        (unless (memq args '(nil :json-null))
          (setcdr (assoc "arguments" cfn)
                  (kargu--merge-tool-args
                   (kargu-aget cfn "arguments") args)))))))

(defun kargu--extract-stream-tool-frags (delta)
  "Extract normalized list of tool call fragments from DELTA."
  (let* ((raw-frags (or (kargu-aget delta "tool_calls")
                        (let ((legacy (kargu-aget delta "function_call")))
                          (and legacy (kargu--object-p legacy)
                               (list `(("index" . 0)
                                       ("function" . ,legacy))))))))
    (cond
     ((vectorp raw-frags) (append raw-frags nil))
     ((listp raw-frags) raw-frags)
     (t nil))))

(defun kargu--assemble-stream-message (text reasoning call-list)
  "Build an assistant message from TEXT, REASONING and CALL-LIST."
  (let ((message `(("role" . "assistant")))
        (has-text (not (string-empty-p text)))
        (has-reason (not (string-empty-p reasoning))))
    (when has-text
      (push `("content" . ,text) message))
    (when has-reason
      (push `("reasoning_content" . ,reasoning) message))
    (when call-list
      (push `("tool_calls" . ,call-list) message))
    (unless (or has-text call-list)
      (push `("content" . "") message))
    message))


(cl-defstruct (kargu-stream--state (:constructor kargu-stream--make-state))
  "Content and completion state of one streamed response."
  (status :pending) text reasoning finish usage error
  (calls (make-hash-table :test #'eql)))

(defun kargu-stream--accept-choice (state choice)
  "Accumulate CHOICE content and explicit completion into STATE."
  (let ((delta (kargu-aget choice "delta"))
        (finish (kargu-aget choice "finish_reason")))
    (unless (memq delta '(nil :json-null))
      (when-let* ((text (kargu--content-text delta))) (push text (kargu-stream--state-text state)))
      (when-let* ((reason (kargu--reasoning-text delta))) (push reason (kargu-stream--state-reasoning state)))
      (dolist (frag (kargu--extract-stream-tool-frags delta))
        (kargu--merge-tool-call-fragment (kargu-stream--state-calls state) frag)))
    (when (and (stringp finish) (not (string-empty-p finish)))
      (setf (kargu-stream--state-finish state) finish
            (kargu-stream--state-status state) :finished))))

(defun kargu-stream--accept-event (state event)
  "Accumulate decoded EVENT or the internal terminal marker into STATE."
  (unless (eq (kargu-stream--state-status state) :error)
    (cond
     ((eq event :done) (setf (kargu-stream--state-status state) :finished))
     ((kargu--sse-event-error-message event)
      (setf (kargu-stream--state-status state) :error
            (kargu-stream--state-error state) (kargu--sse-event-error-message event)))
     (t
      (when-let* ((choice (car (kargu-seq-to-list (kargu-aget event "choices")))))
        (kargu-stream--accept-choice state choice))
      (when-let* ((usage (kargu-aget event "usage")))
        (unless (eq usage :json-null) (setf (kargu-stream--state-usage state) usage)))))))

(defun kargu-stream--render-response (state)
  "Build a canonical response from completed STATE, never from partial data."
  (let* ((table (kargu-stream--state-calls state))
         (call-list (mapcar (lambda (index) (gethash index table)) (sort (hash-table-keys table) #'<)))
         (message (kargu--assemble-stream-message
                   (apply #'concat (nreverse (kargu-stream--state-text state)))
                   (apply #'concat (nreverse (kargu-stream--state-reasoning state)))
                   call-list))
         (usage (kargu-stream--state-usage state)))
    `(("choices" . ((("index" . 0) ("message" . ,message)
                     ("finish_reason" . ,(or (kargu-stream--state-finish state)
                                             (if call-list "tool_calls" "stop"))))))
      ,@(when usage `(("usage" . ,usage))))))

(defun kargu--accumulate-stream-deltas (events)
  "Convert decoded SSE EVENTS to a response only after explicit completion.
A finish reason or :done marker establishes completion.  Partial content
and tool fragments without either produce an error, never executable calls."
  (condition-case err
      (let ((state (kargu-stream--make-state)))
        (dolist (event events) (kargu-stream--accept-event state event))
        (pcase (kargu-stream--state-status state)
          (:finished (kargu-stream--render-response state))
          (:error `(("error" . (("message" . ,(kargu-stream--state-error state))))))
          (_ '(("error" . (("message" . "Incomplete SSE response: no finish_reason or [DONE] before EOF")))))))
    (error `(("error" . (("message" . ,(format "Invalid SSE response: %s" (error-message-string err)))))))))

(provide 'kargu/api/stream)

;;; stream.el ends here
