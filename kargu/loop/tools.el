;;; kargu/loop/tools.el --- Tool queue, doom loop, mode gate -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Execute every tool call of an assistant turn, then re-trigger
;; the model.  Doom-loop: three identical signatures stop the run.

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
(require 'kargu/history)
(require 'kargu/api)
(require 'kargu/tools/diff)
(require 'kargu/ui/confirm)

(defvar kargu--loop-call-seq)
(defvar kargu-max-healing-steps)
(declare-function kargu-loop--live-p "kargu/loop" (run))
(declare-function kargu-loop--set-state "kargu/loop" (run state))
(declare-function kargu-loop--gate-tool "kargu/loop" (name))
(declare-function kargu--loop-request "kargu/loop/machine" (run prompt))
(declare-function kargu--loop-finish "kargu/loop" (run status &optional text))
(declare-function kargu--loop-verify-files "kargu/loop/heal"
                 (run id name result queue files))

(defun kargu--loop-next-call (run queue)
  "Execute the next queued tool call of RUN, or continue the loop."
  (when (kargu-loop--live-p run)
    (if queue
        (kargu--loop-run-call run (car queue) (cdr queue))
      ;; Clear turn batch cache when all tool calls of this turn are answered
      (plist-put run :batch-cache nil)
      (kargu-log 'debug "loop: all tool calls answered; continuing")
      (kargu--loop-request run nil))))

(defun kargu--loop-tool-sig (name args)
  "Signature of a tool call for doom-loop detection."
  (concat name "\0" (if (stringp args) args (format "%S" args))))

(defun kargu--loop-doom-p (run sig)
  "Non-nil when SIG is the third consecutive identical tool call on RUN."
  (let ((next (cons sig (plist-get run :doom-sigs))))
    (plist-put run :doom-sigs next)
    (and (>= (length next) 3)
         (equal (nth 0 next) (nth 1 next))
         (equal (nth 1 next) (nth 2 next)))))

(defun kargu--loop-call-id (call)
  "Tool-call id of CALL, synthesizing one if the provider omitted it."
  (if (stringp (kargu--aget call "id"))
      (kargu--aget call "id")
    (format "call_%d" (cl-incf kargu--loop-call-seq))))

(defvar kargu-chat--output-marker)
(defvar kargu-chat--prompt-marker)
(defvar kargu-chat-buffer-name)
(declare-function kargu-loop-running-p "kargu/loop" ())
(declare-function kargu-chat-show "kargu/chat" ())
(declare-function kargu-chat--ensure-running-prompt "kargu/chat/prompt" ())
(declare-function kargu-chat--ensure-idle-prompt "kargu/chat/prompt" ())
(declare-function kargu-notify "kargu/ui/notify" (type &optional msg))

(defun kargu-loop--tool-cacheable-p (name)
  "Return non-nil if tool NAME results may be cached within a single turn batch.
Stepping, execution, and mutating tools are never cached."
  (not (or (string-prefix-p "debug_" name)
           (string-prefix-p "bash" name)
           (member name '("debug" "next" "step" "step_in" "step_over" "step_out" "out" "finish"
                          "continue" "pause" "up" "down" "threads" "stack" "modules" "sources"
                          "breakpoints" "scope" "watch" "eval" "restart" "kill" "disconnect" "quit"
                          "set_breakpoint" "clear_breakpoint" "toggle_breakpoint")))))

(defvar kargu-loop--mock-doom-decision nil
  "Dynamically bound decision (:approve | :reject) used for unit testing.")

(defun kargu-loop--render-doom-approval-prompt (chat-buf name args set-decision-fn)
  "Render tool repetition approval prompt with action buttons in CHAT-BUF."
  (let* ((args-str (when (and args (or (stringp args) (consp args)))
                     (let ((s (if (stringp args) args (format "%S" args))))
                       (unless (string-empty-p (string-trim s))
                         (replace-regexp-in-string "[\r\n]+" " " s)))))
         (details (concat (format "Tool: %s" name)
                          (when args-str (format "\nArguments: %s" args-str)))))
    (kargu-confirm--render-prompt
     chat-buf "⚡ [Tool Repetition Approval]" details
     "Notice: Identical tool call repeated 3 times consecutively."
     '((:key :approved :label "[✓ Approve (Grant 3 More)]" :face (:inherit success :weight bold))
       (:key :rejected :label "[✗ Stop Run]" :face (:inherit error :weight bold)))
     set-decision-fn)))

(defun kargu-loop--request-doom-approval (run name args)
  "Request user approval when identical tool NAME with ARGS repeats 3 times.
Presents approval and stop buttons in the chat buffer.  If approved,
resets `:doom-sigs' on RUN (granting 3 more calls) and returns non-nil."
  (let* ((args-str (when (and args (or (stringp args) (consp args)))
                     (let ((s (if (stringp args) args (format "%S" args))))
                       (unless (string-empty-p (string-trim s))
                         (replace-regexp-in-string "[\r\n]+" " " s)))))
         (details (concat (format "Tool: %s" name)
                          (when args-str (format "\nArguments: %s" args-str))))
         (kargu-confirm--mock-decision
          (or (and (eq kargu-loop--mock-doom-decision :approve) :approve)
              (and (eq kargu-loop--mock-doom-decision :reject) :stop)
              kargu-confirm--mock-decision))
         (decision
          (kargu-ui-confirm
           :title "⚡ [Tool Repetition Approval]"
           :details details
           :notice "Notice: Identical tool call repeated 3 times consecutively."
           :actions '((:key :approve
                       :label "[✓ Approve (Grant 3 More)]"
                       :face (:inherit success :weight bold)
                       :help "Click to approve and grant 3 additional calls"
                       :message "     -> [✓ Approved: granted 3 additional calls]\n\n")
                      (:key :stop
                       :label "[✗ Stop Run]"
                       :face (:inherit error :weight bold)
                       :help "Click to stop the agent run"
                       :message "     -> [✗ Stopped by user]\n\n"))
           :chat-buffer (plist-get run :chat-buffer)
           :fallback-prompt (format "Tool `%s` called 3 times consecutively. Allow 3 more calls? " name)
           :default-action :stop
           :notify 'permission)))
    (let ((approved (eq decision :approve)))
      (when approved
        (plist-put run :doom-sigs nil))
      approved)))

(defun kargu--loop-doom-stop (run id name queue)
  "Record a doom-loop error for the current call and stop RUN."
  (kargu--history-add-tool-result
   id name
   "ERROR: identical tool call repeated 3 times in a row (doom loop). Stopping.")
  (dolist (call queue)
    (let* ((fn (kargu--aget call "function"))
           (n (or (and fn (kargu--aget fn "name")) "unknown"))
           (cid (kargu--loop-call-id call)))
      (kargu--history-add-tool-result
       cid n "ERROR: run stopped (doom loop).")))
  (kargu--loop-finish
   run :error
   "doom loop: identical tool called 3 times consecutively"))

(defun kargu--loop-run-call (run call queue)
  "Execute one tool CALL of RUN, then continue with QUEUE."
  (when (kargu-loop--live-p run)
    (kargu-loop--set-state run 'tools)
    (let* ((fn (kargu--aget call "function"))
           (name (if (and fn (stringp (kargu--aget fn "name")))
                     (kargu--aget fn "name")
                   "unknown"))
           (args (and fn (kargu--aget fn "arguments")))
           (id (kargu--loop-call-id call))
           (sig (kargu--loop-tool-sig name args))
           (batch-cache (plist-get run :batch-cache))
           (cached (and batch-cache (gethash sig batch-cache))))
      (kargu-log 'info "loop: tool call %s (id=%s)" name id)
      (cond
       ;; In-turn duplicate tool call deduplication: reuse result from earlier in this batch
       ((and cached (kargu-loop--tool-cacheable-p name))
        (kargu-log 'info "loop: tool call %s (id=%s) is duplicate in current turn; reusing cached result" name id)
        (kargu--loop-after-tool run id name cached queue))
       ;; Doom-loop detection across consecutive turns: ask user for approval
       ((and (kargu--loop-doom-p run sig)
             (not (kargu-loop--request-doom-approval run name args)))
        (kargu--loop-doom-stop run id name queue))
       ;; Normal execution
       (t
        (let ((on-result
               (lambda (result)
                 (when (kargu-loop--live-p run)
                   ;; Record into batch cache for subsequent calls within this turn
                   (when (kargu-loop--tool-cacheable-p name)
                     (unless batch-cache
                       (setq batch-cache (make-hash-table :test 'equal))
                       (plist-put run :batch-cache batch-cache))
                     (puthash sig result batch-cache))
                   (kargu--loop-after-tool run id name result queue)))))
          (condition-case-unless-debug err
              (let ((gate (kargu-loop--gate-tool name)))
                (if gate
                    (funcall on-result gate)
                  (kargu-execute-tool name args on-result)))
            (error
             (funcall on-result
                      (format "ERROR: executing tool `%s' raised: %s"
                              name (error-message-string err)))))))))))

(defun kargu-loop--classify-after-tool (run files)
  "Event after a tool result: `verify', `budget', or `plain'."
  (cond
   ((null files) 'plain)
   ((>= (or (plist-get run :healing) 0) kargu-max-healing-steps) 'budget)
   (t 'verify)))

(defconst kargu-loop--on-after-tool
  '((plain  . kargu-loop--after-plain)
    (verify . kargu-loop--after-verify)
    (budget . kargu-loop--after-budget))
  "After-tool event -> handler (RUN ID NAME RESULT QUEUE FILES).")

(defun kargu-loop--after-plain (run id name result queue _files)
  "Store RESULT and continue QUEUE with no diagnostics."
  (kargu--loop-add-result-and-continue run id name result queue))

(defun kargu-loop--after-verify (run id name result queue files)
  "Verify FILES after an applied edit."
  (plist-put run :verifications
             (1+ (or (plist-get run :verifications) 0)))
  (kargu--loop-verify-files run id name result queue files))

(defun kargu-loop--after-budget (run id name result queue files)
  "Healing budget spent: consume FILES and tell the model to self-check."
  (dolist (file files)
    (kargu-diff-consume-file file))
  (kargu-log 'warn "loop: healing budget spent; %d changed file(s) not auto-verified"
             (length files))
  (kargu--loop-add-result-and-continue
   run id name
   (concat result
           (format
            "\n\nSELF-HEALING BUDGET SPENT (%d of %d error rounds used): this edit is NOT auto-verified.  Check it with lsp_diagnostics yourself before claiming success, or say explicitly that it is unverified."
            (or (plist-get run :healing) 0)
            kargu-max-healing-steps))
   queue))

(defun kargu--loop-after-tool (run id name result queue)
  "Deliver the tool RESULT of NAME to the model, with verification."
  (when (kargu-loop--live-p run)
    (let ((files (kargu-diff-changed-files)))
      (funcall (alist-get (kargu-loop--classify-after-tool run files)
                          kargu-loop--on-after-tool)
               run id name result queue files))))

(defun kargu--loop-add-result-and-continue (run id name result queue)
  "Store the tool RESULT for call ID and continue with QUEUE."
  (when (kargu-loop--live-p run)
    (kargu--history-add-tool-result id name result)
    (kargu--loop-next-call run queue)))

(provide 'kargu/loop/tools)

;;; kargu/loop/tools.el ends here
