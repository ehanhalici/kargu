;;; tests/test-fake-agent.el --- Batch agent run without a network or a window -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;; The chat commands, history firewall, loop, and payload builder stay
;; real.  Only `kargu--api-post' is replaced, by a synchronous queue.

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

(require 'ert)
(require 'cl-lib)
(require 'kargu)
(require 'kargu/chat)
(require 'kargu/api/select)
(require 'kargu/ui/confirm)
(require 'kargu/tools/deps)
(require 'kargu/tools/dape)

(unless (fboundp 'company-manual-begin)
  (defalias 'company-manual-begin #'ignore))

(defvar kargu-fake--queue nil
  "Scripted responses, oldest first.")

(defvar kargu-fake--seen nil
  "Payloads `kargu--api-post' received, oldest first.")

(defvar kargu-fake--held nil
  "In-flight request waiting for `kargu-fake-release'.")

(defvar kargu-fake--delivered nil
  "Non-nil when a scripted response reached its callback.")

(defvar kargu-fake--reads nil
  "Answers for `kargu--completing-read-with-company', oldest first.
The symbol `quit' cancels the read.")

(defconst kargu-fake--responses
  '(text deltas tools xml empty overflow tool-reject http-502
         disconnect filter length)
  "Response axis.  Each symbol is one scripted model turn.")

(defconst kargu-fake--modes '(ask plan debug agent)
  "Mode axis.")

(defconst kargu-fake--tool-states '(on off)
  "Tool-metadata axis.  `off' stores `:supports-tools' nil.")

(defconst kargu-fake--actions
  '(send empty stop-during stop-idle select-mode select-provider
         cancel-select reset)
  "User-action axis.")

(defun kargu-fake-reset ()
  "Drop the script, the captured payloads, and any held request."
  (setq kargu-fake--queue nil
        kargu-fake--seen nil
        kargu-fake--held nil
        kargu-fake--delivered nil
        kargu-fake--reads nil))

(defun kargu-fake-push (kind &rest plist)
  "Append one scripted response of KIND and PLIST."
  (setq kargu-fake--queue
        (nconc kargu-fake--queue (list (append (list :kind kind) plist)))))

(defun kargu-fake--choice (finish message)
  "One chat-completion choice with FINISH reason and MESSAGE alist."
  `(("choices" . [(("finish_reason" . ,finish)
                   ("message" . ,message))])))

(defun kargu-fake--assistant (text)
  "Assistant message alist whose content is TEXT."
  `(("role" . "assistant") ("content" . ,text)))

(defun kargu-fake--body (item)
  "Decoded response alist for script ITEM."
  (pcase (plist-get item :kind)
    ('text (kargu-fake--choice "stop" (kargu-fake--assistant (plist-get item :text))))
    ('empty (kargu-fake--choice "stop" (kargu-fake--assistant "")))
    ('length (kargu-fake--choice "length" (kargu-fake--assistant (plist-get item :text))))
    ('tools
     (kargu-fake--choice
      "tool_calls"
      `(("role" . "assistant")
        ("content" . nil)
        ("tool_calls" .
         ((("id" . "call_fake_1")
           ("type" . "function")
           ("function" . (("name" . "read_file")
                          ("arguments" . "{\"file_path\":\"README.md\"}")))))))))
    ('filter (kargu-fake--choice "content_filter" (kargu-fake--assistant "")))
    ('error (kargu--api-error-alist (plist-get item :text)))
    ('overflow (kargu--api-error-alist "maximum context length exceeded"))
    (_ (kargu-fake--choice "stop" (kargu-fake--assistant "plain answer")))))

(defun kargu-fake--delta (text)
  "SSE event whose content delta is TEXT."
  `(("choices" . [(("delta" . (("content" . ,text))))])))

(defun kargu-fake--deliver (gen callback on-delta item)
  "Give ITEM to CALLBACK when GEN is still current.
A cancelled generation drops the reply.  Deltas go out first.
A successful body is stored in history, as the real transport does
inside `kargu--api-handle-success'."
  (when (= gen kargu--generation)
    (setq kargu-fake--delivered t)
    (dolist (piece (plist-get item :deltas))
      (when (functionp on-delta)
        (funcall on-delta (kargu-fake--delta piece))))
    (let ((response (kargu-fake--body item)))
      (unless (kargu-response-error-message response)
        (kargu--history-append-assistant response))
      (funcall callback response))))

(defun kargu-fake--post (_url _headers payload gen callback &optional on-delta _attempt)
  "Synchronous stand-in for `kargu--api-post'."
  (setq kargu-fake--seen (nconc kargu-fake--seen (list payload)))
  (let ((item (or (pop kargu-fake--queue)
                  '(:kind text :text "unscripted"))))
    (if (eq (plist-get item :kind) 'hold)
        (setq kargu-fake--held
              (list :gen gen :callback callback :on-delta on-delta
                    :item '(:kind text :text "late reply")))
      (kargu-fake--deliver gen callback on-delta item))))

(defun kargu-fake-release ()
  "Deliver the held reply.  A bumped generation drops it."
  (when kargu-fake--held
    (let ((held kargu-fake--held))
      (setq kargu-fake--held nil)
      (kargu-fake--deliver (plist-get held :gen)
                           (plist-get held :callback)
                           (plist-get held :on-delta)
                           (plist-get held :item)))))

(defun kargu-fake--read (_prompt candidates &optional default _annotations)
  "Return the next scripted candidate, or signal `quit'."
  (let ((next (pop kargu-fake--reads)))
    (cond
     ((eq next 'quit) (signal 'quit nil))
     ((and (stringp next) (member next candidates)) next)
     (t (or default (car candidates))))))

(defun kargu-fake--enqueue (response mode tools)
  "Queue the posts RESPONSE needs for MODE and TOOLS."
  (pcase response
    ('text (kargu-fake-push 'text :text "plain answer"))
    ('deltas (kargu-fake-push 'text :text "hello world" :deltas '("hello " "world")))
    ('tools
     (kargu-fake-push 'tools)
     (when (eq tools 'on)
       (kargu-fake-push 'text :text "tool follow-up")))
    ('xml
     (kargu-fake-push 'text :text "<function=read_file>{\"file_path\":\"README.md\"}</function>"))
    ('empty (kargu-fake-push 'empty))
    ('overflow
     (kargu-fake-push 'overflow)
     (kargu-fake-push 'text :text "compacted summary of the task")
     (kargu-fake-push 'text :text "after overflow"))
    ('tool-reject
     (kargu-fake-push 'error :text "This model does not support tools")
     (when (and (eq tools 'on) (not (eq mode 'agent)))
       (kargu-fake-push 'text :text "plain after reject")))
    ('http-502 (kargu-fake-push 'error :text "HTTP 502: upstream error"))
    ('disconnect (kargu-fake-push 'error :text "connection reset by peer"))
    ('filter (kargu-fake-push 'filter))
    ('length
     (kargu-fake-push 'length :text "partial answer")
     (kargu-fake-push 'text :text "finished after length"))
    ('hold (kargu-fake-push 'hold))
    (_ nil)))

(defun kargu-fake--posts-p (mode tools action)
  "Non-nil when ACTION in MODE with TOOLS reaches `kargu--api-post'."
  (cond
   ((and (eq mode 'agent) (eq tools 'off)
         (memq action '(send empty stop-during)))
    nil)
   ((eq action 'send) t)
   ((and (eq action 'empty) (eq mode 'debug)) t)
   ((eq action 'stop-during) t)
   (t nil)))

(defun kargu-fake--responses-for (action mode)
  "Response symbols that change ACTION in MODE.
An action that never posts runs once."
  (cond
   ((eq action 'send) kargu-fake--responses)
   ((and (eq action 'empty) (eq mode 'debug)) kargu-fake--responses)
   ((eq action 'stop-during) '(hold))
   (t '(none))))

(defun kargu-fake--needle (mode tools action response)
  "Transcript text ACTION/RESPONSE must leave, or nil."
  (cond
   ((and (eq mode 'agent) (eq tools 'off)
         (memq action '(send stop-during)))
    "does not support tool calling")
   ((and (eq action 'empty) (not (eq mode 'debug))) nil)
   ((eq action 'empty) (kargu-fake--needle mode tools 'send response))
   ((eq action 'stop-during) "run stopped")
   ((eq action 'reset) "session reset")
   ((eq response 'text) "plain answer")
   ((eq response 'deltas) "hello world")
   ((and (eq response 'tools) (eq tools 'on)) "tool follow-up")
   ((eq response 'tools) "empty response")
   ((eq response 'xml) "<function=read_file>")
   ((eq response 'empty) "empty response")
   ((eq response 'overflow) "after overflow")
   ((and (eq response 'tool-reject) (or (eq mode 'agent) (eq tools 'off)))
    "does not support tool")
   ((eq response 'tool-reject) "plain after reject")
   ((eq response 'http-502) "502")
   ((eq response 'disconnect) "connection reset")
   ((eq response 'filter) "content filter")
   ((eq response 'length) "finished after length")
   (t nil)))

(defun kargu-fake--payload-text (payload)
  "Concatenated string contents of PAYLOAD's messages."
  (mapconcat
   (lambda (msg)
     (let ((content (kargu--aget msg "content")))
       (if (stringp content) content "")))
   (append (kargu--aget payload "messages") nil)
   "\n"))

(defun kargu-fake--fresh-chat ()
  "Clear history, the circuit, and the chat transcript."
  (kargu-fake-reset)
  (when (fboundp 'kargu-history-reset) (kargu-history-reset))
  (when (fboundp 'kargu-circuit-reset) (kargu-circuit-reset))
  (setq kargu--loop-run nil
        kargu--busy nil
        kargu--current-process nil)
  (kargu-chat-show)
  (with-current-buffer (get-buffer kargu-chat-buffer-name)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (setq kargu-chat--output-marker nil
            kargu-chat--prompt-marker nil))
    (kargu-chat--ensure-idle-prompt)))

(defun kargu-fake--arm-tools (tools)
  "Apply TOOLS (`on' or `off') to the active model's metadata.
An earlier tool rejection is remembered in `kargu--tools-refused';
each row starts with that record cleared so it cannot leak."
  (clrhash kargu--tools-refused)
  (let ((id (kargu--model)))
    (when (and (stringp id) (not (string-empty-p id)))
      (kargu-model-set-metadata
       id (list :supports-tools (eq tools 'on))))))

(defun kargu-fake--type (text)
  "Insert TEXT at the end of the live prompt."
  (with-current-buffer (get-buffer kargu-chat-buffer-name)
    (goto-char (point-max))
    (insert text)))

(defun kargu-fake--other-mode (mode)
  "A mode other than MODE."
  (if (eq mode 'agent) 'ask
    (cadr (memq mode kargu-fake--modes))))

(defun kargu-fake--drive (mode tools action response)
  "Perform ACTION.  Return nil, or the error message it signaled."
  (kargu-set-mode mode)
  (kargu-fake--arm-tools tools)
  (when (kargu-fake--posts-p mode tools action)
    (kargu-fake--enqueue
     (if (eq action 'stop-during) 'hold response)
     mode tools))
  (condition-case err
      (progn
        (pcase action
          ('send
           (kargu-fake--type "Say hello from the fake agent.")
           (kargu-chat-send))
          ('empty
           (kargu-chat-send))
          ('stop-during
           (kargu-fake--type "Say hello from the fake agent.")
           (kargu-chat-send)
           (kargu-chat-stop)
           (setq kargu-fake--delivered nil)
           (kargu-fake-release))
          ('stop-idle
           (kargu-chat-stop))
          ('select-mode
           (setq kargu-fake--reads
                 (list (symbol-name (kargu-fake--other-mode mode))))
           (kargu-chat-select-mode-company))
          ('select-provider
           (when (hash-table-p kargu--live-models-cache)
             (clrhash kargu--live-models-cache))
           (setq kargu-fake--reads '("openrouter" "fake/model-a"))
           (kargu-chat-select-provider-company))
          ('cancel-select
           (setq kargu-fake--reads '(quit))
           (kargu-chat-select-mode-company))
          ('reset
           (kargu-chat-reset)))
        nil)
    (error (error-message-string err))))

(defun kargu-fake--transcript ()
  "Plain text of the chat buffer."
  (with-current-buffer (get-buffer kargu-chat-buffer-name)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun kargu-fake--prompt-live-p ()
  "Non-nil when the chat buffer ends on an editable prompt."
  (with-current-buffer (get-buffer kargu-chat-buffer-name)
    (kargu-chat--prompt-live-p)))

(defun kargu-fake--tool-count ()
  "Number of tool-result messages in the history."
  (cl-count-if (lambda (msg) (equal (kargu--aget msg "role") "tool"))
               kargu--message-history))

(defun kargu-fake--history-closed-p ()
  "Non-nil when no tool call is left unanswered.
A second firewall pass must not drop a tool result.  Refreshing
the system prompt is not an orphan."
  (let ((open nil)
        (ok t)
        (before (kargu-fake--tool-count)))
    (dolist (msg kargu--message-history)
      (let ((role (kargu--aget msg "role")))
        (cond
         ((equal role "assistant")
          (setq open (and (kargu--calls-to-list (kargu--aget msg "tool_calls")) t)))
         ((equal role "tool")
          (if open (setq open nil) (setq ok nil))))))
    (kargu--validate-history)
    (and ok (not open) (= before (kargu-fake--tool-count)))))

(defun kargu-fake--tool-result-p ()
  "Non-nil when history holds the canned tool result."
  (cl-some
   (lambda (msg)
     (and (equal (kargu--aget msg "role") "tool")
          (stringp (kargu--aget msg "content"))
          (string-match-p "fake tool result" (kargu--aget msg "content"))))
   kargu--message-history))

(defun kargu-fake--check (mode tools action response err)
  "Return a failure string for this row, or nil."
  (let ((problems nil)
        (needle (kargu-fake--needle mode tools action response))
        (text (ignore-errors (kargu-fake--transcript)))
        (refused (and (eq mode 'agent) (eq tools 'off)
                      (memq action '(send stop-during)))))
    (when (and (not refused) err)
      (push (format "signaled %s" err) problems))
    (when (and refused (not (and err (string-match-p "does not support tool calling" err))))
      (push (format "expected tool refusal, got %S" err) problems))
    (unless (or (null kargu--loop-run) (not (kargu-loop-running-p)))
      (push "run still active" problems))
    (unless (kargu-fake--prompt-live-p)
      (push "prompt is not editable" problems))
    (when (and text (string-match-p "kargu running" text))
      (push "running banner left behind" problems))
    (unless (kargu-fake--history-closed-p)
      (push "history firewall left an open tool" problems))
    (when (and needle text (not (string-match-p (regexp-quote needle) text))
               (not (and err (string-match-p (regexp-quote needle) err))))
      (push (format "missing %S" needle) problems))
    (if (kargu-fake--posts-p mode tools action)
        (let ((payload (car kargu-fake--seen)))
          (unless payload
            (push "request was not sent" problems))
          (when payload
            (if (eq tools 'off)
                (when (or (kargu--aget payload "tools")
                          (string-match-p "read_file" (kargu-fake--payload-text payload)))
                  (push "tools leaked into a tools-off request" problems))
              (unless (kargu--aget payload "tools")
                (push "tools missing from a tools-on request" problems))))
          (when (and (eq response 'tool-reject) (eq tools 'on) (not (eq mode 'agent)))
            (let ((second (nth 1 kargu-fake--seen)))
              (unless second
                (push "tool rejection did not retry" problems))
              (when (and second (kargu--aget second "tools"))
                (push "retry after tool rejection still sent tools" problems)))))
      (when kargu-fake--seen
        (push "request was sent" problems)))
    (when (and (eq response 'tools) (eq tools 'on)
               (kargu-fake--posts-p mode tools action)
               (not (kargu-fake--tool-result-p)))
      (push "tool result missing" problems))
    (when (and (eq response 'tools) (eq tools 'off)
               (kargu-fake--tool-result-p))
      (push "tools-off run executed a tool" problems))
    (when (and (eq action 'stop-during) (not refused) kargu-fake--delivered)
      (push "late reply was delivered after cancel" problems))
    (when (and (eq action 'select-mode)
               (not (eq (kargu-state-mode) (kargu-fake--other-mode mode))))
      (push "mode selection did not apply" problems))
    (when (and (eq action 'cancel-select)
               (not (eq (kargu-state-mode) mode)))
      (push "cancelled selection changed the mode" problems))
    (when (and (eq action 'select-provider)
               (not (equal (kargu--model) "fake/model-a")))
      (push (format "model is %S" (kargu--model)) problems))
    (when (and (eq action 'send) refused text
               (not (string-match-p "Say hello from the fake agent" text)))
      (push "refused prompt was not left in the input" problems))
    (when problems
      (format "%s/%s/%s/%s: %s"
              mode tools action response
              (mapconcat #'identity (nreverse problems) "; ")))))

(defun kargu-fake--cleanup-row ()
  "Stop a row that failed to finish so the next one can start."
  (when (kargu-loop-running-p)
    (ignore-errors (kargu-loop-stop "test cleanup")))
  (setq kargu--busy nil
        kargu--current-process nil
        kargu-fake--held nil))

(defun kargu-fake--run-row (mode tools action response saved-provider saved-model)
  "Run one matrix row.  Return a failure string or nil."
  (kargu-fake--fresh-chat)
  (setq kargu--session-provider saved-provider
        kargu--session-model saved-model)
  (when (and (stringp saved-model) (not (string-empty-p saved-model)))
    (ignore-errors (kargu-state-set-model saved-model)))
  (unless (and (stringp kargu--session-provider) (not (string-empty-p kargu--session-provider)))
    (setq kargu--session-provider "openrouter"))
  (unless (and (stringp (kargu--model)) (not (string-empty-p (kargu--model))))
    (setq kargu--session-model "fake/model-a")
    (kargu-state-set-model "fake/model-a"))
  (with-current-buffer (get-buffer kargu-chat-buffer-name)
    (setq-local kargu-chat--session-provider kargu--session-provider
                kargu-chat--session-model kargu--session-model))
  (let ((failure
         (condition-case err
             (let ((signaled (kargu-fake--drive mode tools action response)))
               (kargu-fake--check mode tools action response signaled))
           (error (format "%s/%s/%s/%s: %s"
                          mode tools action response
                          (error-message-string err))))))
    (kargu-fake--cleanup-row)
    failure))

(ert-deftest kargu-fake-late-reply-is-dropped ()
  "A reply that arrives after the generation counter moves is ignored."
  (let ((kargu-fake--queue (list '(:kind hold)))
        (kargu-fake--seen nil)
        (kargu-fake--held nil)
        (kargu-fake--delivered nil)
        (kargu--generation 3)
        (called nil))
    (kargu-fake--post "http://example/chat/completions" nil
                      '(("model" . "m"))
                      3
                      (lambda (_response) (setq called t)))
    (cl-incf kargu--generation)
    (kargu-fake-release)
    (should kargu-fake--seen)
    (should-not called)
    (should-not kargu-fake--delivered)))

(ert-deftest kargu-fake-agent-matrix ()
  "Drive every mode, tool, user action, and response through the real loop.
No Emacs window, no network, no Company popup, no `y-or-n-p'."
  (let* ((saved-provider kargu--session-provider)
         (saved-model kargu--session-model)
         (saved-mode (kargu-state-mode))
         (saved-key (and (boundp 'kargu-api-key) kargu-api-key))
         (saved-history (copy-tree kargu--message-history t))
         (saved-meta (copy-hash-table kargu--model-metadata-table))
         (saved-models (and (hash-table-p kargu--live-models-cache)
                            (copy-hash-table kargu--live-models-cache)))
         (kargu--tools-refused (make-hash-table :test #'equal))
         (kargu-api-key "sk-fake")
         (kargu-loop-empty-retries 0)
         (kargu-loop-upstream-retries 0)
         (kargu-confirm--mock-decision :stop)
         (kargu-session-auto-save nil)
         (failures nil))
    (unwind-protect
        (cl-letf (((symbol-function 'kargu--api-post) #'kargu-fake--post)
                  ((symbol-function 'kargu-execute-tool)
                   (lambda (_name _arguments &optional callback)
                     (if callback (funcall callback "fake tool result")
                       "fake tool result")))
                  ((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
                  ((symbol-function 'kargu-dape-ready-p) (lambda (&rest _) t))
                  ((symbol-function 'kargu-api-prefetch-models) (lambda (&rest _) nil))
                  ((symbol-function 'kargu-api-fetch-model-ids)
                   (lambda (_provider callback) (funcall callback '("fake/model-a"))))
                  ((symbol-function 'kargu-api-select--provider-candidates)
                   (lambda () '("openrouter")))
                  ((symbol-function 'kargu--completing-read-with-company)
                   #'kargu-fake--read)
                  ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                  ((symbol-function 'company-manual-begin)
                   (lambda (&rest _) (error "Company opened")))
                  ((symbol-function 'kargu-chat-activate-selection)
                   (lambda (&rest _) nil))
                  ((symbol-function 'kargu-chat-note-selection)
                   (lambda (&rest _) nil)))
          (dolist (mode kargu-fake--modes)
            (dolist (tools kargu-fake--tool-states)
              (dolist (action kargu-fake--actions)
                (dolist (response (kargu-fake--responses-for action mode))
                  (let ((failure (kargu-fake--run-row
                                  mode tools action response
                                  saved-provider saved-model)))
                    (when failure
                      (push failure failures))))))))
      (setq kargu--session-provider saved-provider
            kargu--session-model saved-model
            kargu-api-key saved-key
            kargu--message-history saved-history
            kargu--loop-run nil
            kargu--busy nil)
      (ignore-errors (kargu-set-mode saved-mode))
      (when (hash-table-p kargu--model-metadata-table)
        (clrhash kargu--model-metadata-table)
        (maphash (lambda (key value)
                   (puthash key value kargu--model-metadata-table))
                 saved-meta))
      (when (and saved-models (hash-table-p kargu--live-models-cache))
        (clrhash kargu--live-models-cache)
        (maphash (lambda (key value)
                   (puthash key value kargu--live-models-cache))
                 saved-models)))
    (when failures
      (ert-fail (mapconcat #'identity (nreverse failures) "\n")))))

(provide 'tests/test-fake-agent)
;;; test-fake-agent.el ends here
