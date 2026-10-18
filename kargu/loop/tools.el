;;; tools.el --- Tool queue, doom loop, mode gate -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Execute every tool call of an assistant turn, then re-trigger
;; the model.  Doom-loop: three identical signatures stop the run.

;;; Code:

(require 'cl-lib)
(require 'kargu/core)
(require 'kargu/history)
(require 'kargu/api)
(require 'kargu/tools/diff)
(require 'kargu/ui/confirm)

(defvar kargu-max-healing-steps)
(declare-function kargu-loop--live-p "kargu/loop" (run))
(declare-function kargu-loop--set-state "kargu/loop" (run state))
(declare-function kargu-loop--gate-tool "kargu/loop" (name))
(declare-function kargu--loop-request "kargu/loop/machine" (run prompt))
(declare-function kargu--loop-finish "kargu/loop" (run status &optional text))
(declare-function kargu--loop-verify-files "kargu/loop/heal"
                  (run id name result queue files))

(defun kargu--loop-next-call (run queue)
  "Execute the next call in QUEUE for RUN, or continue the loop."
  (when (kargu-loop--live-p run)
    (if queue
        (kargu--loop-run-call run (car queue) (cdr queue))
      ;; Clear turn batch cache when all tool calls of this turn are answered
      (plist-put run :batch-cache nil)
      (kargu-log 'debug "loop: all tool calls answered; continuing")
      (kargu--loop-request run nil))))

(defun kargu--loop-tool-sig (name args)
  "Return a signature for tool NAME and ARGS for doom-loop detection."
  (concat name "\0" (if (stringp args) args (format "%S" args))))

(defun kargu--loop-doom-p (run sig)
  "Non-nil when SIG is the third consecutive identical tool call on RUN."
  (let ((next (seq-take (cons sig (plist-get run :doom-sigs)) 3)))
    (plist-put run :doom-sigs next)
    (and (>= (length next) 3)
         (equal (nth 0 next) (nth 1 next))
         (equal (nth 1 next) (nth 2 next)))))

(defun kargu--loop-call-id (call)
  "Return CALL's canonical identity; never invent one during execution."
  (or (kargu-nonempty (kargu-aget call "id"))
      (error "Tool call was not normalized before execution")))

(defvar kargu-chat--output-marker)
(defvar kargu-chat--prompt-marker)
(defvar kargu-chat-buffer-name)
(declare-function kargu-loop-running-p "kargu/loop" ())
(declare-function kargu-chat-show "kargu/chat" ())
(declare-function kargu-chat--ensure-running-prompt "kargu/chat/prompt" ())
(declare-function kargu-chat--ensure-idle-prompt "kargu/chat/prompt" ())
(declare-function kargu-notify "kargu/ui/notify" (type &optional msg))

(defconst kargu-loop--cacheable-tools
  '("read_file" "read_file_symbols" "read_symbol" "read_file_outline"
    "list_files" "find_files" "workspace_grep" "grep_search" "grep"
    "lsp_definitions" "lsp_references" "lsp_hover" "lsp_project_skeleton"
    "lsp_skeleton" "git_status" "git_diff" "git_log" "git_show" "git_blame")
  "Read-only tool results safe to reuse until the next uncacheable operation.")

(defun kargu-loop--tool-cacheable-p (name)
  "Return non-nil only for explicitly read-only tool NAME, including aliases."
  (member (kargu-canonical-tool-name name) kargu-loop--cacheable-tools))

(defvar kargu-loop--mock-doom-decision nil
  "Dynamically bound decision (:approve | :reject) used for unit testing.")

(defun kargu-loop--doom-details (name args)
  "Prompt details naming tool NAME and its one-line ARGS."
  (let ((args-str (when (and args (or (stringp args) (consp args)))
                    (let ((s (if (stringp args) args (format "%S" args))))
                      (unless (string-empty-p (string-trim s))
                        (replace-regexp-in-string "[\r\n]+" " " s))))))
    (concat (format "Tool: %s" name)
            (when args-str (format "\nArguments: %s" args-str)))))

(defun kargu-loop--request-doom-approval (run name args on-decision)
  "Ask whether RUN may repeat tool NAME with ARGS a fourth time.
ON-DECISION receives non-nil when approved; approval resets `:doom-sigs'
on RUN, which grants three more identical calls."
  (let ((kargu-confirm--mock-decision
         (or (and (eq kargu-loop--mock-doom-decision :approve) :approve)
             (and (eq kargu-loop--mock-doom-decision :reject) :stop)
             kargu-confirm--mock-decision)))
    (kargu-ui-confirm
     :title "⚡ [Tool Repetition Approval]"
     :details (kargu-loop--doom-details name args)
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
     :notify 'permission
     :on-decision
     (lambda (decision)
       (let ((approved (eq decision :approve)))
         (when (and approved (kargu-loop--live-p run))
           (plist-put run :doom-sigs nil))
         (funcall on-decision approved))))))

(defun kargu--loop-doom-stop (run id name queue)
  "Record a doom error for ID and NAME, finish QUEUE and stop RUN."
  (when (kargu-loop--live-p run)
    (kargu--history-add-tool-result
     id name
     "ERROR: identical tool call repeated 3 times in a row (doom loop). Stopping.")
    (dolist (call queue)
      (kargu--history-add-tool-result
       (kargu--loop-call-id call) (kargu--loop-call-name call)
       "ERROR: run stopped (doom loop)."))
    (kargu--loop-finish
     run :error
     "doom loop: identical tool called 3 times consecutively")))

(defun kargu--loop-call-name (call)
  "Function name of tool CALL, or \"unknown\"."
  (let ((fn (kargu-aget call "function")))
    (if (and fn (stringp (kargu-aget fn "name")))
        (kargu-aget fn "name")
      "unknown")))

(defun kargu--loop-cache-result (run name sig result)
  "Cache successful read-only RESULT of NAME under SIG on RUN."
  (when (and (kargu-loop--tool-cacheable-p name)
             (not (string-prefix-p "ERROR:" result)))
    (unless (plist-get run :batch-cache)
      (plist-put run :batch-cache (make-hash-table :test #'equal)))
    (puthash sig result (plist-get run :batch-cache))))

(cl-defun kargu--loop-complete-tool (run &key id name result queue sig)
  "Deliver RESULT for ID and NAME on RUN, cache SIG and continue QUEUE safely."
  (condition-case err
      (progn
        (when sig (kargu--loop-cache-result run name sig result))
        (kargu--loop-after-tool run id name result queue))
    (error (kargu--loop-finish run :error
                               (format "Tool continuation failed: %s" (error-message-string err))))))

(defun kargu--loop-execute-call (run id name args sig queue)
  "Run tool NAME with ARGS for call ID of RUN and continue with QUEUE.
SIG keys the read-only cache; delivery is claimed before any continuation."
  (unless (kargu-loop--tool-cacheable-p name)
    (plist-put run :batch-cache nil))
  (let* ((state :pending)
         (on-result
          (lambda (result)
            (when (and (eq state :pending) (kargu-loop--live-p run))
              (setq state :delivered)
              (kargu--loop-complete-tool run :id id :name name :result result
                                         :queue queue :sig sig)))))
    (condition-case err
        (if-let* ((gate (kargu-loop--gate-tool name)))
            (funcall on-result gate)
          (kargu-execute-tool name args on-result))
      (error (funcall on-result (format "ERROR: executing tool %s: %s"
					name (error-message-string err)))))))

(defun kargu--loop-run-call (run call queue)
  "Execute one tool CALL of RUN, then continue with QUEUE."
  (when (kargu-loop--live-p run)
    (kargu-loop--set-state run 'tools)
    (let* ((fn (kargu-aget call "function"))
           (name (kargu--loop-call-name call))
           (args (and fn (kargu-aget fn "arguments")))
           (id (kargu--loop-call-id call))
           (sig (kargu--loop-tool-sig name args))
           (batch-cache (plist-get run :batch-cache))
           (cached (and batch-cache (gethash sig batch-cache))))
      (kargu-log 'info "loop: tool call %s (id=%s)" name id)
      (cond
       ((and cached (kargu-loop--tool-cacheable-p name)
             (not (kargu-loop--gate-tool name)))
        (kargu-log 'info "loop: tool call %s (id=%s) repeats an earlier call of this turn; reusing its result" name id)
        (kargu--loop-complete-tool run :id id :name name :result cached :queue queue))
       ((kargu--loop-doom-p run sig)
        (kargu-loop--request-doom-approval
         run name args
         (lambda (approved)
           (cond ((not (kargu-loop--live-p run)) nil)
                 (approved (kargu--loop-execute-call run id name args sig queue))
                 (t (kargu--loop-doom-stop run id name queue))))))
       (t (kargu--loop-execute-call run id name args sig queue))))))

(defun kargu-loop--classify-after-tool (run files)
  "Classify FILES after a tool result on RUN."
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
  "Store RESULT for ID and NAME on RUN; continue QUEUE without diagnostics."
  (kargu--loop-add-result-and-continue run id name result queue))

(defun kargu-loop--after-verify (run id name result queue files)
  "Verify FILES for ID and NAME after RESULT on RUN, then continue QUEUE."
  (plist-put run :verifications
             (1+ (or (plist-get run :verifications) 0)))
  (kargu--loop-verify-files run id name result queue files))

(defun kargu-loop--after-budget (run id name result queue files)
  "Consume FILES for ID and NAME on RUN; extend RESULT and continue QUEUE."
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
  "Deliver RESULT for ID and NAME on RUN with verification, then QUEUE."
  (when (kargu-loop--live-p run)
    (let ((files (kargu-diff-changed-files)))
      (funcall (alist-get (kargu-loop--classify-after-tool run files)
                          kargu-loop--on-after-tool)
               run id name result queue files))))

(defun kargu--loop-add-result-and-continue (run id name result queue)
  "Store RESULT for ID and NAME on RUN and continue QUEUE."
  (when (kargu-loop--live-p run)
    (kargu--history-add-tool-result id name result)
    (kargu--loop-next-call run queue)))

(provide 'kargu/loop/tools)

;;; tools.el ends here
