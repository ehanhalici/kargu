;;; transcript.el --- Chat transcript insertion and faces -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Insert read-only transcript text while keeping prompt and window positions.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'kargu/core)
(require 'kargu/state/selectors)
(require 'kargu/chat/prompt)
(require 'kargu/chat/routing)

(defface kargu-chat-user-heading
  '((t :inherit font-lock-preprocessor-face :weight bold))
  "Face for user turn headings in the chat log."
  :group 'kargu-ui)

(defface kargu-chat-agent-heading
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for assistant turn headings in the chat log."
  :group 'kargu-ui)

(defface kargu-chat-meta
  '((t :inherit font-lock-comment-face))
  "Face for meta lines (run reports, notices) in the chat log."
  :group 'kargu-ui)

(defface kargu-chat-tool
  '((t :inherit font-lock-builtin-face))
  "Face for tool activity lines in the chat log."
  :group 'kargu-ui)

(defface kargu-chat-error
  '((t :inherit error))
  "Face for error reports in the chat log."
  :group 'kargu-ui)

(defface kargu-chat-thought
  '((((class color) (background dark))
     :foreground "#8a8a8a" :slant italic)
    (((class color) (background light))
     :foreground "#666666" :slant italic)
    (t :inherit shadow :slant italic))
  "Face for model thoughts and reasoning in the chat log."
  :group 'kargu-ui)

(defun kargu-chat-output-buffer ()
  "Return the active chat buffer for rendering."
  (or (and (bound-and-true-p kargu--loop-run)
           (plist-get kargu--loop-run :chat-buffer)
           (buffer-live-p (plist-get kargu--loop-run :chat-buffer))
           (plist-get kargu--loop-run :chat-buffer))
      (and (derived-mode-p 'kargu-chat-mode) (current-buffer))
      (kargu-chat-find-buffer)))

(defun kargu-chat--compute-window-follow-states (windows in-start at)
  "Choose follow targets for WINDOWS using prompt IN-START and output AT."
  (mapcar
   (lambda (window)
     (let ((wp (window-point window)))
       (cons window
             (cond
              ((and in-start (>= wp in-start))
               (cons 'input (- wp in-start)))
              ((or (>= wp at) (>= wp (1- at))) 'output)
              ((and (fboundp 'kargu-loop-running-p)
                    (kargu-loop-running-p)
                    (>= wp (- at 300)))
               'output)
              (t nil)))))
   windows))

(defun kargu-chat--apply-window-follow-states (follow-pairs)
  "Update window points according to computed FOLLOW-PAIRS."
  (let ((out-pos (if (markerp kargu-chat--output-marker)
                     (marker-position kargu-chat--output-marker)
                   (point-max))))
    (dolist (pair follow-pairs)
      (pcase (cdr pair)
        ('output
         (set-window-point (car pair) out-pos))
        (`(input . ,offset)
         (set-window-point (car pair) (+ kargu-chat--prompt-marker offset)))
        (_ nil)))))

(defun kargu-chat-insert (text &optional face)
  "Insert TEXT with optional FACE above the transcript's prompt.
Keep windows in the prompt following their input, and windows at the
output marker following new output.  Preserve other window positions.
Never signal from a process filter or callback."
  (let ((buffer (kargu-chat-output-buffer)))
    (when (and buffer (stringp text) (not (string-empty-p text)))
      (condition-case-unless-debug err
          (with-current-buffer buffer
            (let* ((inhibit-read-only t)
                   (inhibit-modification-hooks t)
                   (at (if (and (markerp kargu-chat--output-marker)
                                (eq (marker-buffer kargu-chat--output-marker)
                                    (current-buffer)))
                           (marker-position kargu-chat--output-marker)
                         (point-max)))
                   (in-start (and (markerp kargu-chat--prompt-marker)
                                  (eq (marker-buffer kargu-chat--prompt-marker)
                                      (current-buffer))
                                  (marker-position kargu-chat--prompt-marker)))
                   (at-end (and (>= (point) at)
                                (not (and in-start (>= (point) in-start)))))
                   (windows (get-buffer-window-list buffer nil t))
                   (follow (kargu-chat--compute-window-follow-states windows in-start at)))
              (save-excursion
                (goto-char at)
                (insert (kargu-chat--propertize-log text face)))
              (when at-end
                (goto-char (if (markerp kargu-chat--output-marker)
                               (marker-position kargu-chat--output-marker)
                             (point-max))))
              (kargu-chat--apply-window-follow-states follow)))
        (error
         (kargu-log 'warn "chat insert failed: %s"
                    (error-message-string err)))))))

(defun kargu-chat--render-user-turn (prompt)
  "Render PROMPT as the next user turn in the chat log."
  (kargu-chat-insert "\n\n")
  (kargu-chat-insert
   (format "## you · %s\n" (format-time-string "%H:%M"))
   'kargu-chat-user-heading)
  (kargu-chat-insert prompt)
  (kargu-chat-insert "\n"))

(defun kargu-chat--render-agent-heading ()
  "Open the next assistant turn in the chat log."
  (kargu-chat-insert "\n")
  (kargu-chat-insert
   (format "## kargu · %s\n" (kargu--model))
   'kargu-chat-agent-heading))

(provide 'kargu/chat/transcript)

;;; transcript.el ends here
