;;; kargu/chat/render.el --- Transcript formatting and streaming rendering -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Transcript formatting, insertion above prompt, streaming deltas,
;; thoughts styling, tool activity timeline, and finish reporting.
;; Requires: `kargu/core', `kargu/chat/prompt', `kargu/tools/diff'.
;; Public: `kargu-chat--insert`, `kargu-chat--render-user-turn`,
;; `kargu-chat--render-agent-heading`, `kargu-chat--on-delta`,
;; `kargu-chat--on-finish`.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
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
(require 'kargu/api/tools)
(require 'kargu/chat/prompt)
(require 'kargu/tools/diff)

(declare-function kargu-plan-handle-response "kargu/plan" (report))

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

(defcustom kargu-chat-drop-preamble nil
  "When non-nil, delete assistant text that preceded a tool call.
When nil (default), pre-tool explanations are kept in the chat
transcript above the tool activity lines."
  :type 'boolean
  :group 'kargu-ui)

(defvar kargu-chat--streamed-text nil
  "Whether the current run has streamed any answer text.
When the plain (non-streaming) transport is used, the final answer
arrives only with the run report; the chat then prints it once
instead of relying on deltas.")

(defvar kargu-chat--in-thought nil
  "Non-nil when currently streaming thought/reasoning tokens.")

(defvar kargu-chat--answer-start nil
  "Marker at the start of streamed assistant text for the current turn.")

(defvar kargu-chat--preamble-dropped nil
  "Non-nil after streamed CoT was removed because a tool call started.")

(defun kargu-chat--target-buffer ()
  "Return the active chat buffer for rendering."
  (or (and (bound-and-true-p kargu--loop-run)
           (plist-get kargu--loop-run :chat-buffer)
           (buffer-live-p (plist-get kargu--loop-run :chat-buffer))
           (plist-get kargu--loop-run :chat-buffer))
      (and (derived-mode-p 'kargu-chat-mode) (current-buffer))
      (get-buffer kargu-chat-buffer-name)))

(defun kargu-chat--insert (text &optional face)
  "Insert TEXT into the transcript above the prompt.
Windows whose point is at the output marker follow the insert;
windows in the prompt stay in the prompt; windows scrolled
elsewhere stay untouched.  Never signals, so it is safe from
process filters and callbacks."
  (let ((buffer (kargu-chat--target-buffer)))
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
                   (at-end (>= (point) at))
                   (windows (get-buffer-window-list buffer nil t))
                   (follow
                    (mapcar
                     (lambda (window)
                       (let ((wp (window-point window)))
                         (cons window
                               (cond
                                ((and in-start (>= wp in-start)) 'input)
                                ((or (>= wp at) (>= wp (1- at))) 'output)
                                ((and (fboundp 'kargu-loop-running-p)
                                      (kargu-loop-running-p)
                                      (>= wp (- at 300)))
                                 'output)
                                (t nil)))))
                     windows)))
              (save-excursion
                (goto-char at)
                (insert (kargu-chat--propertize-log text face)))
              (when at-end
                (goto-char (if (markerp kargu-chat--output-marker)
                               (marker-position kargu-chat--output-marker)
                             (point-max))))
              (dolist (pair follow)
                (pcase (cdr pair)
                  ('output
                   (set-window-point
                    (car pair)
                    (if (markerp kargu-chat--output-marker)
                        (marker-position kargu-chat--output-marker)
                      (point-max))))
                  ('input
                   (set-window-point
                    (car pair)
                    (point-max)))
                  (_ nil)))))
        (error
         (kargu-log 'warn "chat insert failed: %s"
                          (error-message-string err)))))))

(defun kargu-chat--render-user-turn (prompt)
  "Render PROMPT as the next user turn in the chat log."
  (kargu-chat--insert "\n\n")
  (kargu-chat--insert
   (format "## you · %s\n" (format-time-string "%H:%M"))
   'kargu-chat-user-heading)
  (kargu-chat--insert prompt)
  (kargu-chat--insert "\n"))

(defun kargu-chat--render-agent-heading ()
  "Open the next assistant turn in the chat log."
  (kargu-chat--insert "\n")
  (kargu-chat--insert
   (format "## kargu · %s\n" (kargu--model))
   'kargu-chat-agent-heading))

(defun kargu-chat--on-delta (text &optional kind)
  "Append one streamed TEXT fragment of the assistant answer.
KIND may be `thought' when streaming reasoning tokens."
  (when (and (stringp text) (not (string-empty-p text))
             (not kargu-chat--preamble-dropped))
    (setq kargu-chat--streamed-text t)
    (cond
     ((eq kind 'thought)
      (kargu-chat--insert text 'kargu-chat-thought))
     ((string-match "<think>" text)
      (let* ((idx (string-match "<think>" text))
             (before (substring text 0 idx))
             (after (substring text (+ idx (length "<think>")))))
        (when (not (string-empty-p before))
          (kargu-chat--insert before (if kargu-chat--in-thought 'kargu-chat-thought nil)))
        (setq kargu-chat--in-thought t)
        (if (string-match "</think>" after)
            (let* ((end-idx (string-match "</think>" after))
                   (thought (substring after 0 end-idx))
                   (rest (substring after (+ end-idx (length "</think>")))))
              (when (not (string-empty-p thought))
                (kargu-chat--insert thought 'kargu-chat-thought))
              (setq kargu-chat--in-thought nil)
              (when (not (string-empty-p rest))
                (kargu-chat--insert rest nil)))
          (when (not (string-empty-p after))
            (kargu-chat--insert after 'kargu-chat-thought)))))
     ((string-match "</think>" text)
      (let* ((idx (string-match "</think>" text))
             (thought (substring text 0 idx))
             (after (substring text (+ idx (length "</think>")))))
        (when (not (string-empty-p thought))
          (kargu-chat--insert thought 'kargu-chat-thought))
        (setq kargu-chat--in-thought nil)
        (when (not (string-empty-p after))
          (kargu-chat--insert after nil))))
     (kargu-chat--in-thought
      (kargu-chat--insert text 'kargu-chat-thought))
     (t
      (kargu-chat--insert text nil)))))

(defun kargu-chat--drop-streamed-preamble ()
  "Delete streamed assistant text that preceded the first tool call.
Only used when `kargu-chat-drop-preamble' is non-nil."
  (when (and kargu-chat-drop-preamble
             (not kargu-chat--preamble-dropped)
             (markerp kargu-chat--answer-start))
    (let ((buffer (kargu-chat--target-buffer)))
      (when (and buffer (eq (marker-buffer kargu-chat--answer-start) buffer))
        (with-current-buffer buffer
          (let* ((inhibit-read-only t)
                 (beg (marker-position kargu-chat--answer-start))
                 (end (and (markerp kargu-chat--output-marker)
                           (eq (marker-buffer kargu-chat--output-marker)
                               buffer)
                           (marker-position kargu-chat--output-marker))))
            (when (and beg end (> end beg))
              (delete-region beg end))
            (setq kargu-chat--streamed-text nil
                  kargu-chat--preamble-dropped t)))))))

(defun kargu-chat--result-summary (result)
  "One-line summary of a tool RESULT for the chat timeline."
  (cond
   ((not (stringp result)) "no output")
   ((string-prefix-p "ERROR:" result)
    (truncate-string-to-width result 100))
   (t (format "%d chars" (length result)))))

(defun kargu-chat--clear-running-prompt-banner (buffer)
  "Clear any in-flight prompt banner from BUFFER before printing final report."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (markerp kargu-chat--output-marker)
                 (eq (marker-buffer kargu-chat--output-marker) buffer)
                 (null kargu-chat--prompt-marker))
        (let ((inhibit-read-only t))
          (delete-region kargu-chat--output-marker (point-max)))))))

(defun kargu-chat--render-finish-status (status report text error)
  "Render the summary status banner for STATUS in REPORT."
  ;; Plain transport: print answer here if no deltas arrived
  (when (and (eq status :done) (not kargu-chat--streamed-text))
    (if (kargu--nonempty text)
        (progn
          (kargu-chat--insert text)
          (kargu-chat--insert "\n"))
      (kargu-chat--insert "— empty model response\n" 'kargu-chat-meta)))
  ;; Interrupted runs carry reason as report text
  (when (and (memq status '(:stopped :limit))
             (stringp text) (not (string-empty-p text)))
    (kargu-chat--insert (concat text "\n") 'kargu-chat-meta))
  (pcase status
    (:done
     (kargu-chat--insert
      (format "— done · %d model turn(s) · %d healing round(s) · %d verification(s)\n"
              (or (plist-get report :iterations) 0)
              (or (plist-get report :healing) 0)
              (or (plist-get report :verifications) 0))
      'kargu-chat-meta))
    (:error
     (kargu-chat--insert
      (format "— ERROR: %s\n" (or error "unknown error"))
      'kargu-chat-error))
    (:stopped
     (kargu-chat--insert "— run stopped\n" 'kargu-chat-meta))
    (:limit
     (kargu-chat--insert "— stopped: iteration limit\n" 'kargu-chat-meta))
    (_
     (kargu-chat--insert "— run ended\n" 'kargu-chat-meta))))

(defun kargu-chat--render-modified-file (file)
  "Render stats and ediff/rollback action buttons for modified FILE."
  (let* ((stats (if (fboundp 'kargu-diff-file-stats)
                    (kargu-diff-file-stats file)
                  (cons 0 0)))
         (added (car stats))
         (deleted (cdr stats))
         (stat-str (concat (propertize (format "+%d" added) 'face 'font-lock-string-face)
                           " "
                           (propertize (format "-%d" deleted) 'face 'font-lock-warning-face)))
         (diff-btn (buttonize "[ediff]"
                              (lambda (_)
                                (if (fboundp 'kargu-diff-review)
                                    (kargu-diff-review file)
                                  (message "kargu-diff-review unavailable")))))
         (rb-btn (buttonize "[rollback]"
                            (lambda (_)
                              (if (fboundp 'kargu-diff-rollback)
                                  (kargu-diff-rollback file)
                                (message "kargu-diff-rollback unavailable"))))))
    (kargu-chat--insert (format "  • %s (%s)  " file stat-str))
    (kargu-chat--insert diff-btn)
    (kargu-chat--insert "  ")
    (kargu-chat--insert rb-btn)
    (kargu-chat--insert "\n")))

(defun kargu-chat--render-modified-files (modified)
  "Render summary list of MODIFIED files."
  (when (and (listp modified) modified)
    (kargu-chat--insert "\nModified file(s):\n" 'kargu-chat-meta)
    (dolist (file modified)
      (kargu-chat--render-modified-file file))))

(defun kargu-chat--on-finish (report)
  "Render the final REPORT plist of an agent run.
See `kargu-loop-send' for the shape of the report."
  (setq kargu-chat--in-thought nil)
  (let ((status (plist-get report :status))
        (text (plist-get report :text))
        (error (plist-get report :error))
        (pending (plist-get report :pending-files))
        (modified (plist-get report :modified-files))
        (buffer (kargu-chat--target-buffer)))
    (kargu-chat--clear-running-prompt-banner buffer)
    (kargu-chat--insert "\n")
    (kargu-chat--render-finish-status status report text error)
    (kargu-chat--render-modified-files modified)
    (when (and (listp pending) pending)
      (kargu-chat--insert
       (format "unverified changed file(s): %s\nroll back with M-x kargu-diff-rollback or the menu's r\n"
               (string-join pending ", "))
       'kargu-chat-error))
    (kargu-chat--insert "\n")
    (when (and (eq status :done)
               (eq kargu-active-mode 'plan)
               (fboundp 'kargu-plan-handle-response))
      (kargu-plan-handle-response report))
    (when (fboundp 'kargu-notify)
      (kargu-notify (if (eq status :error) 'error 'finish)))
    (kargu-chat--ensure-idle-prompt)
    (force-mode-line-update t)
    (let ((buf (kargu-chat--target-buffer)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (goto-char (point-max)))
        (dolist (win (get-buffer-window-list buf nil t))
          (set-window-point win (point-max)))))))

(defun kargu-chat--tool-activity (fn name arguments)
  "Around advice on `kargu-execute-tool' for the chat timeline.
Prints the tool NAME before it runs — visible while long tools or
the human ediff gate block — and a one-line summary of the result
afterwards.  FN is the original function."
  (kargu-chat--drop-streamed-preamble)
  (let ((live (kargu-chat--target-buffer)))
    (when live
      (with-current-buffer live
        (let ((pos (if (and (markerp kargu-chat--output-marker)
                            (eq (marker-buffer kargu-chat--output-marker) live))
                       (marker-position kargu-chat--output-marker)
                     (point-max))))
          (unless (or (<= pos (point-min))
                      (eq (char-before pos) ?\n))
            (kargu-chat--insert "\n"))))
      (kargu-chat--insert (format "  → %s " name)
                          'kargu-chat-tool))
    (let ((result (funcall fn name arguments)))
      (when live
        (kargu-chat--insert
         (format "[%s]\n" (kargu-chat--result-summary result))
         'kargu-chat-tool)
        (setq kargu-chat--preamble-dropped nil)
        (with-current-buffer live
          (when (markerp kargu-chat--output-marker)
            (setq kargu-chat--answer-start (copy-marker kargu-chat--output-marker nil)))))
      result)))

(when (fboundp 'kargu-execute-tool)
  (advice-add 'kargu-execute-tool :around
              #'kargu-chat--tool-activity))

(provide 'kargu/chat/render)

;;; kargu/chat/render.el ends here
