;;; kargu/loop/ui.el --- UI prompts and pause/continue interaction -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Interactive continue/stop prompts, turn limit banners, and PAUSE state UI for the loop.
;; Separated from `kargu/loop/machine' for modularity.

;;; Code:

(require 'cl-lib)

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
(require 'kargu/api)
(require 'kargu/ui/confirm)

(defvar kargu-chat--output-marker)
(defvar kargu-chat--prompt-marker)
(defvar kargu-max-iterations)

(declare-function kargu-chat-show "kargu/chat" ())
(declare-function kargu-chat--ensure-running-prompt "kargu/chat/prompt" ())
(declare-function kargu-loop--set-state "kargu/loop" (run state))
(declare-function kargu--loop-finish "kargu/loop" (run status &optional text))
(declare-function kargu--loop-forward-delta "kargu/loop/machine" (run event))
(declare-function kargu--loop-handle-response "kargu/loop/machine" (run response))

(defvar kargu-loop--mock-continue-decision nil
  "Mock decision for `kargu-loop--prompt-continue' in unit tests.
When non-nil, may be `:continue' or `:stop'.")

(defun kargu-loop--render-continue-prompt (chat-buf max-iter batch set-decision-fn)
  "Render turn limit banner and buttons into CHAT-BUF.
Calls SET-DECISION-FN with chosen action when clicked."
  (kargu-confirm--render-prompt
   chat-buf (format "⏸  [Turn limit reached (%d turns)]" max-iter) nil
   (format "Continue for another %d turns?" batch)
   `((:key :continue :label ,(format "[✓ Continue (+%d turns)]" batch) :face (:inherit success :weight bold))
     (:key :stop :label "[✗ Stop]" :face (:inherit error :weight bold)))
   set-decision-fn))

(defun kargu-loop--decide-continue (chat-buf max-iter batch)
  "Gather user decision (:continue or :stop) for extending turn limit."
  (let ((kargu-confirm--mock-decision
         (or kargu-loop--mock-continue-decision
             kargu-confirm--mock-decision)))
    (kargu-ui-confirm
     :title (format "⏸  [Turn limit reached (%d turns)]" max-iter)
     :notice (format "Continue for another %d turns?" batch)
     :actions `((:key :continue
                 :label ,(format "[✓ Continue (+%d turns)]" batch)
                 :face (:inherit success :weight bold)
                 :help "Click to allow another turn batch"
                 :message ,(format "     -> [✓ Continuing for +%d turns...]\n\n" batch))
                (:key :stop
                 :label "[✗ Stop]"
                 :face (:inherit error :weight bold)
                 :help "Click to stop the run"
                 :message "     -> [✗ Stopped by user]\n\n"))
     :chat-buffer chat-buf
     :fallback-prompt (format "Kargu reached %d turns limit. Continue for another %d turns? "
                              max-iter batch)
     :default-action :stop
     :notify 'permission)))

(defun kargu-loop--apply-continue-decision (run prompt decision max-iter batch)
  "Apply DECISION (:continue or :stop) to RUN."
  (if (eq decision :continue)
      (progn
        (plist-put run :max-iterations (+ max-iter batch))
        (plist-put run :no-tools nil)
        (kargu-log 'info "loop: extended turn limit by %d (new cap: %d)"
                   batch (+ max-iter batch))
        (kargu-loop--set-state run 'wait)
        (let ((on-delta (and (plist-get run :on-delta)
                             (lambda (event)
                               (kargu--loop-forward-delta run event)))))
          (kargu-api-send
           prompt
           (lambda (response)
             (kargu--loop-handle-response run response))
           on-delta)))
    (kargu--loop-finish
     run :limit
     (format "iteration limit reached (%d model round-trips); stopped by user."
             max-iter))))

(defun kargu-loop--prompt-continue (run prompt)
  "Prompt the user interactively when RUN reaches its iteration limit.
Offers to add another batch of turns (`kargu-max-iterations') or stop."
  (kargu-loop--set-state run 'pause)
  (when (fboundp 'kargu-notify)
    (kargu-notify 'limit))
  (let* ((chat-buf (plist-get run :chat-buffer))
         (max-iter (or (plist-get run :iterations) 12))
         (batch (if (boundp 'kargu-max-iterations) kargu-max-iterations 12))
         (decision (kargu-loop--decide-continue chat-buf max-iter batch)))
    (kargu-loop--apply-continue-decision run prompt decision max-iter batch)))

(provide 'kargu/loop/ui)

;;; kargu/loop/ui.el ends here
