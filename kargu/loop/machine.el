;;; kargu/loop/machine.el --- Classify events, dispatch handlers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Request and model-response paths are: classify -> alist lookup.
;; Caps: one compaction and one `Continue.' per run.

;;; Code:

(require 'cl-lib)

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
(require 'kargu/history)
(require 'kargu/history-compact)
(require 'kargu/api)
(require 'kargu/api/circuit)

(defvar kargu-loop-empty-retries)
(defvar kargu-loop-upstream-retries)
(defvar kargu-max-iterations)
(defvar kargu-chat--output-marker)
(defvar kargu-chat--prompt-marker)

(declare-function kargu-chat--prompt-live-p "kargu/chat/prompt")
(declare-function kargu--api-error-looks-retryable-p "kargu/api/http" (message))
(declare-function kargu--api-retry-delay "kargu/api/http" (attempt err))

(declare-function kargu-loop--live-p "kargu/loop" (run))
(declare-function kargu-loop--set-state "kargu/loop" (run state))
(declare-function kargu--loop-finish "kargu/loop" (run status &optional text))
(declare-function kargu--loop-compact-allowed-p "kargu/loop/compact" (run))
(declare-function kargu--loop-start-compact "kargu/loop/compact" (run prompt))
(declare-function kargu--loop-next-call "kargu/loop/tools" (run queue))
(declare-function kargu-model-get-metadata "kargu/api/catalog" (id))
(declare-function kargu-model-set-metadata "kargu/api/catalog" (id plist))
(declare-function kargu--model "kargu/config/key" ())

(defconst kargu-loop--length-reasons '("length" "max_tokens")
  "finish_reason values that mean the completion was truncated.")

(defconst kargu--loop-empty-notice
  "System Notice: You returned an empty response without calling any tools. Please inspect the code using the available tools and address the user query."
  "User message injected when the model returns neither text nor tools.")

;;;; Request --------------------------------------------------------------

(defun kargu-loop--classify-request (run)
  "Event for the next model request of RUN: `stale', `busy', `compact', or `send'."
  (cond
   ((not (kargu-loop--live-p run)) 'stale)
   ((plist-get run :compacting) 'busy)
   ((and (kargu--loop-compact-allowed-p run)
         (kargu-history-needs-compact-p))
    'compact)
   (t 'send)))

(defconst kargu-loop--on-request
  '((stale   . ignore)
    (busy    . ignore)
    (compact . kargu-loop--request-compact)
    (send    . kargu-loop--request-send))
  "Request event -> handler (RUN PROMPT).")

(defun kargu-loop--request-compact (run prompt)
  "Start compaction for RUN, then resume PROMPT."
  (kargu--loop-start-compact run prompt))

(defun kargu-loop--max-steps-prompt (prompt)
  "PROMPT for the last iteration, with tools hidden."
  (if (and prompt (not (string-empty-p prompt)))
      (concat prompt "\n\n" kargu-prompt-max-steps-nudge)
    kargu-prompt-max-steps-nudge))

(require 'kargu/loop/ui)

(defun kargu-loop--request-send (run prompt)
  "Send one model turn for RUN."
  (let* ((max-iter (or (plist-get run :max-iterations) kargu-max-iterations))
         (iterations (1+ (or (plist-get run :iterations) 0))))
    (plist-put run :iterations iterations)
    (cond
     ((> iterations max-iter)
      (kargu-loop--prompt-continue run prompt))
     (t
      (kargu-loop--set-state run 'wait)
      (let ((on-delta (and (plist-get run :on-delta)
                           (lambda (event)
                             (kargu--loop-forward-delta run event)))))
        (kargu-api-send
         prompt
         (lambda (response)
           (kargu--loop-handle-response run response))
         on-delta))))))

(defun kargu--loop-request (run prompt)
  "Send one model request for RUN.
PROMPT nil means continue from the existing history."
  (let* ((event (kargu-loop--classify-request run))
         (handler (alist-get event kargu-loop--on-request)))
    (unless (eq handler 'ignore)
      (funcall handler run prompt))))

(defun kargu--loop-forward-delta (run event)
  "Forward the text or thought delta of one decoded SSE EVENT to RUN's on-delta."
  (when (kargu-loop--live-p run)
    (let* ((on-delta (plist-get run :on-delta))
           (choices (and on-delta (kargu--aget event "choices")))
           (choice (cond
                    ((vectorp choices) (and (> (length choices) 0) (aref choices 0)))
                    ((consp choices) (car choices))
                    (t nil)))
           (delta (and choice (kargu--aget choice "delta")))
           (text (kargu--content-text delta))
           (reason (kargu--reasoning-text delta)))
      (when (and reason on-delta)
        (condition-case-unless-debug _err
            (condition-case nil
                (funcall on-delta reason 'thought)
              (wrong-number-of-arguments
               (funcall on-delta reason)))
          (error nil)))
      (when (and text on-delta)
        (condition-case-unless-debug _err
            (funcall on-delta text)
          (error nil))))))

;;;; Response -------------------------------------------------------------

(defun kargu--loop-finish-reason (response)
  "Lowercase finish_reason string of RESPONSE, or nil."
  (let ((r (kargu-response-finish-reason response)))
    (cond
     ((stringp r) (downcase r))
     ((symbolp r) (downcase (symbol-name r)))
     (t nil))))

(defun kargu--loop-tool-calls (response)
  "Tool-call list of RESPONSE, or nil."
  (let ((calls (kargu-response-tool-calls response)))
    (cond
     ((vectorp calls) (append calls nil))
     ((listp calls) calls)
     (t nil))))

(defun kargu-loop--classify-response (run response)
  "Event for RESPONSE inside RUN.
Order: stale, overflow, error, tools, length (once), answer, empty.
Reasoning-only replies are empty, not answers."
  (let ((err (kargu-response-error-message response))
        (calls (kargu--loop-tool-calls response))
        (reason (kargu--loop-finish-reason response))
        (answer (kargu--nonempty (kargu-response-answer-text response)))
        (continues (or (plist-get run :length-continues) 0)))
    (cond
     ((not (kargu-loop--live-p run)) 'stale)
     ((and err (kargu-response-overflow-p response)
           (kargu--loop-compact-allowed-p run))
      'overflow)
     (err 'error)
     ((member reason '("content-filter" "content_filter")) 'error)
     ((and (listp calls) calls (not (plist-get run :no-tools))) 'tools)
     ((and (member reason kargu-loop--length-reasons)
           (< continues 1)
           (< (or (plist-get run :iterations) 0) kargu-max-iterations))
      'length)
     ((member reason kargu-loop--length-reasons)
      (if answer 'answer 'empty))
     (answer 'answer)
     (t 'empty))))

(defconst kargu/loop--on-response
  '((stale    . ignore)
    (overflow . kargu-loop--on-overflow)
    (error    . kargu-loop--on-error)
    (tools    . kargu-loop--on-tools)
    (length   . kargu-loop--on-length)
    (answer   . kargu-loop--on-answer)
    (visible  . kargu-loop--on-visible)
    (empty    . kargu-loop--on-empty))
  "Model-response event -> handler (RUN RESPONSE).")

(defun kargu-loop--on-overflow (run response)
  "Compact RUN after a context-window overflow.
 Records a circuit breaker success (API responded, just context overflow)."
  (kargu-circuit-record-success)
  (if (kargu--loop-start-compact run nil)
      (kargu-log 'warn "loop: context overflow; compacting")
    (kargu--loop-finish run :error
                       (or (kargu-response-error-message response)
                           "context overflow"))))

(defun kargu-loop--retry-upstream (run err)
  "Resend RUN from current history after retryable upstream error ERR.
 Records the failure in the circuit breaker; if the circuit trips
 to :open, the run is finished with an error instead of retrying."
  (kargu-circuit-record-failure err)
  (let* ((n (1+ (or (plist-get run :upstream-retries) 0)))
         (cap (or kargu-loop-upstream-retries 0))
         (delay (kargu--api-retry-delay (1- n) nil)))
    (plist-put run :upstream-retries n)
    (if (not (kargu-circuit-allow-request-p))
        (progn
          (kargu-log 'error "loop: circuit breaker OPEN after %d upstream failures; aborting: %s"
                     n err)
          (kargu--loop-finish run :error
                             (format "circuit breaker tripped (upstream: %s)" err)))
      (kargu-log 'warn "loop: upstream error; retry %d/%d in %.1fs: %s"
                 n cap delay err)
      (run-at-time delay nil
                   (lambda ()
                     (when (kargu-loop--live-p run)
                       (kargu--loop-request run nil)))))))

(defun kargu--error-no-tools-support-p (err)
  "Return non-nil if ERR indicates the provider rejected tool use."
  (and (stringp err)
       (string-match-p
        "no endpoints found that support tool use\\|does not support tools\\|tools are not supported\\|function calling is not supported\\|try disabling"
        (downcase err))))

(defun kargu-loop--handle-tools-unsupported (run err)
  "Handle provider tool rejection ERR on RUN.
In `agent' mode, aborts with a descriptive error.  In `ask' or `plan' mode,
records :supports-tools nil and retries without tools."
  (let ((mid (kargu--model)))
    (when (fboundp 'kargu-model-set-metadata)
      (let ((meta (copy-sequence (kargu-model-get-metadata mid))))
        (setq meta (plist-put meta :supports-tools nil))
        (kargu-model-set-metadata mid meta)))
    (if (eq kargu-active-mode 'agent)
        (progn
          (kargu-log 'error "loop: model '%s' does not support tools in agent mode: %s" mid err)
          (kargu--loop-finish
           run :error
           (format "Model '%s' does not support tool use. Switch to a tool-capable model (e.g. Claude 3.5 Sonnet, GPT-4o, DeepSeek V3) or switch to Ask mode."
                   mid)))
      (kargu-log 'warn "loop: model does not support tool use; retrying without tools in %s mode"
                 kargu-active-mode)
      (plist-put run :no-tools t)
      (kargu--loop-request run nil))))

(defun kargu-loop--on-error (run response)
  "Retry RUN on 502/overload, otherwise finish with the error in RESPONSE."
  (let ((err (or (kargu-response-error-message response)
                 (and (member (kargu--loop-finish-reason response)
                              '("content-filter" "content_filter"))
                      "The response was blocked by the provider's content filter")
                 "unknown error")))
    (cond
     ((and (kargu--error-no-tools-support-p err)
           (not (plist-get run :no-tools)))
      (kargu-loop--handle-tools-unsupported run err))
     ((and (kargu--api-error-looks-retryable-p err)
           (< (or (plist-get run :upstream-retries) 0)
              (or kargu-loop-upstream-retries 0)))
      (kargu-loop--retry-upstream run err))
     (t
      (kargu-log 'error "loop: request failed: %s" err)
      (kargu--loop-finish run :error err)))))

(defun kargu-loop--on-tools (run response)
  "Queue tool calls from RESPONSE.
 Records a circuit breaker success (model responded with tool calls)."
  (kargu-circuit-record-success)
  (let ((calls (kargu--loop-tool-calls response)))
    (kargu-log 'info "loop: %d tool call(s) to execute" (length calls))
    (kargu--loop-next-call run (append calls nil))))

(defun kargu-loop--on-length (run _response)
  "One `Continue.' after a truncated completion.
 Records a circuit breaker success (model did respond)."
  (kargu-circuit-record-success)
  (plist-put run :length-continues
             (1+ (or (plist-get run :length-continues) 0)))
  (kargu-log 'info "loop: truncated; continuing")
  (kargu--loop-request run kargu--continue-nudge))

(defun kargu-loop--on-answer (run response)
  "Finish RUN with the assistant content of RESPONSE.
 Records a circuit breaker success (model answered successfully)."
  (kargu-circuit-record-success)
  (kargu--loop-finish
   run :done
   (kargu--nonempty (kargu-response-answer-text response))))

(defun kargu-loop--on-visible (run response)
  "Finish RUN with visible text of RESPONSE (including reasoning)."
  (kargu--loop-finish
   run :done
   (kargu--nonempty (kargu-response-text response))))

(defun kargu-loop--on-empty (run _response)
  "Retry RUN after an empty tool-less reply, or finish it."
  (let ((n (or (plist-get run :empty-retries) 0))
        (cap (or kargu-loop-empty-retries 0)))
    (if (>= n cap)
        (kargu--loop-finish
         run :error "(the model returned an empty response)")
      (plist-put run :empty-retries (1+ n))
      (kargu-log 'warn "loop: empty response, retry %d/%d"
                 (1+ n) cap)
      (kargu--loop-request run kargu--loop-empty-notice))))

(defun kargu--loop-handle-response (run response)
  "Dispatch one model RESPONSE within RUN."
  (let* ((event (kargu-loop--classify-response run response))
         (handler (alist-get event kargu/loop--on-response)))
    (kargu--log-wire "loop classify-response -> %s" event)
    (unless (eq handler 'ignore)
      (funcall handler run response))))

(provide 'kargu/loop/machine)

;;; kargu/loop/machine.el ends here
