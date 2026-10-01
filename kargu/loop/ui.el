;;; kargu/loop/ui.el --- UI prompts and pause/continue interaction -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Interactive continue/stop prompts, turn limit banners, and PAUSE state UI for the loop.
;; Separated from `kargu/loop/machine' for modularity.

;;; Code:

(require 'cl-lib)

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
(declare-function kargu--loop-request "kargu/loop/machine" (run prompt))
(declare-function kargu-loop--live-p "kargu/loop" (run))
(declare-function kargu-loop--turn-cap "kargu/loop/machine" (run))
(declare-function kargu-notify "kargu/ui/notify" (type &optional msg))

(defvar kargu-loop--mock-continue-decision nil
  "Mock decision for `kargu-loop--prompt-continue' in unit tests.
When non-nil, may be `:continue' or `:stop'.")

(defun kargu-loop--decide-continue (chat-buf max-iter batch on-decision)
  "Ask whether to extend the turn limit; ON-DECISION gets :continue or :stop."
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
     :notify 'permission
     :on-decision on-decision)))

(defun kargu-loop--continue-batch ()
  "How many extra turns one continue offers."
  (or (and (boundp 'kargu-max-iterations) kargu-max-iterations) 12))

(defun kargu-loop--apply-continue-decision (run prompt decision max-iter batch)
  "Apply DECISION (:continue or :stop) to RUN unless it was stopped meanwhile.
MAX-ITER is the cap already reached.  BATCH is the extension.
Continuing raises the cap and sends through the normal request path."
  (cond
   ((not (kargu-loop--live-p run)) nil)
   ((eq decision :continue)
    (plist-put run :max-iterations (+ max-iter batch))
    (kargu-log 'info "loop: extended turn limit by %d (new cap: %d)"
               batch (+ max-iter batch))
    (kargu--loop-request run prompt))
   (t
    (kargu--loop-finish
     run :limit
     (format "iteration limit reached (%d model round-trips); stopped by user."
             max-iter)))))

(defun kargu-loop--prompt-continue (run prompt)
  "Ask the user whether RUN may continue after reaching its turn cap.
The run waits in the `pause' state; the answer arrives by callback."
  (kargu-loop--set-state run 'pause)
  (when (fboundp 'kargu-notify)
    (kargu-notify 'limit))
  (let ((max-iter (kargu-loop--turn-cap run))
        (batch (kargu-loop--continue-batch)))
    (kargu-loop--decide-continue
     (plist-get run :chat-buffer) max-iter batch
     (lambda (decision)
       (kargu-loop--apply-continue-decision run prompt decision max-iter batch)))))

(provide 'kargu/loop/ui)

;;; kargu/loop/ui.el ends here
