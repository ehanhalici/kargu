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
  (with-current-buffer chat-buf
    (let ((inhibit-read-only t))
      (when (and (markerp kargu-chat--output-marker)
                 (eq (marker-buffer kargu-chat--output-marker) chat-buf))
        (delete-region kargu-chat--output-marker (point-max))
        (setq kargu-chat--prompt-marker nil))
      (goto-char (point-max))
      (unless (or (bobp) (eq (char-before) ?\n))
        (insert "\n"))
      (insert "\n")
      (insert (propertize (format "  ⏸  [Turn limit reached (%d turns)]\n" max-iter)
                          'face '(:inherit warning :weight bold)))
      (insert (format "     Continue for another %d turns?\n     " batch))
      (insert-button
       (format "[✓ Continue (+%d turns)]" batch)
       'action (lambda (_)
                 (funcall set-decision-fn :continue)
                 (exit-recursive-edit))
       'face '(:inherit success :weight bold)
       'help-echo "Click to allow another turn batch")
      (insert "  ")
      (insert-button
       "[✗ Stop]"
       'action (lambda (_)
                 (funcall set-decision-fn :stop)
                 (exit-recursive-edit))
       'face '(:inherit error :weight bold)
       'help-echo "Click to stop the run")
      (insert "\n\n")
      (setq kargu-chat--output-marker (copy-marker (point) t)))))

(defun kargu-loop--decide-continue (chat-buf max-iter batch)
  "Gather user decision (:continue or :stop) for extending turn limit."
  (cond
   (kargu-loop--mock-continue-decision
    (when (and chat-buf (buffer-live-p chat-buf))
      (with-current-buffer chat-buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert "\n")
          (insert (propertize (format "  ⏸  [Turn limit reached (%d turns)]\n" max-iter)
                              'face '(:inherit warning :weight bold)))
          (insert (format "     Continue for another %d turns?\n     " batch))
          (insert (format "[✓ Continue (+%d turns)]  [✗ Stop]\n\n" batch)))))
    kargu-loop--mock-continue-decision)
   ((not (and chat-buf (buffer-live-p chat-buf) (not noninteractive)))
    (if (or noninteractive
            (y-or-n-p (format "Kargu reached %d turns limit. Continue for another %d turns? "
                              max-iter batch)))
        (if noninteractive :stop :continue)
      :stop))
   (t
    (let ((decision :stop))
      (kargu-loop--render-continue-prompt
       chat-buf max-iter batch (lambda (d) (setq decision d)))
      (let ((win (or (get-buffer-window chat-buf)
                     (and (fboundp 'kargu-chat-show)
                          (get-buffer-window (kargu-chat-show))))))
        (when win
          (select-window win)))
      (with-current-buffer chat-buf
        (goto-char (point-max)))
      (dolist (win (get-buffer-window-list chat-buf nil t))
        (set-window-point win (point-max))
        (with-selected-window win
          (goto-char (point-max))
          (recenter -1)))
      (message "Turn limit reached (%d turns): click [✓ Continue] or [✗ Stop]" max-iter)
      (condition-case _sig
          (recursive-edit)
        (quit
         (setq decision :stop)
         (message "kargu: run stopped at turn limit")))
      (with-current-buffer chat-buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (if (eq decision :continue)
              (insert (propertize (format "     -> [✓ Continuing for +%d turns...]\n\n" batch)
                                  'face 'font-lock-string-face))
            (insert (propertize "     -> [✗ Stopped]\n\n" 'face 'font-lock-warning-face)))
          (setq kargu-chat--output-marker (copy-marker (point) t))))
      (when (and (eq decision :continue)
                 (fboundp 'kargu-chat--ensure-running-prompt))
        (with-current-buffer chat-buf
          (kargu-chat--ensure-running-prompt)))
      (dolist (w (get-buffer-window-list chat-buf nil t))
        (set-window-point w (point-max))
        (with-selected-window w
          (goto-char (point-max))))
      decision))))

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
