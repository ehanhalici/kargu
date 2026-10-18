;;; render.el --- Tool activity and run reporting -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Render tool activity and completed run reports.

;;; Code:

(require 'kargu/chat/transcript)
(require 'kargu/chat/stream)
(require 'kargu/api/tools)
(require 'kargu/tools/diff)

(defvar kargu--loop-run)
(defvar kargu-loop-tool-start-hook)
(defvar kargu-loop-tool-finish-hook)
(declare-function kargu-plan-handle-response "kargu/plan/dispatch" (report))

(defun kargu-chat--result-summary (result)
  "One-line summary of a tool RESULT for the chat timeline.
Errors keep their first line.  A normal result is `ok'."
  (cond
   ((not (stringp result)) "no output")
   ((string-prefix-p "ERROR:" result)
    (truncate-string-to-width
     (replace-regexp-in-string "[\r\n]+" " " result) 100))
   (t "ok")))

(defun kargu-chat--tool-target-string (val)
  "VAL as a single-line tool target, or nil."
  (let ((text (cond
               ((and (stringp val) (not (string-empty-p (string-trim val))))
                (string-trim val))
               ((and (listp val) val)
                (mapconcat (lambda (item) (format "%s" item)) val " "))
               ((and val (not (eq val :json-null)))
                (format "%s" val)))))
    (when (and (stringp text) (not (string-empty-p text)))
      (truncate-string-to-width
       (replace-regexp-in-string "[\r\n]+" " " text) 80))))

(defun kargu-chat--tool-target (name arguments)
  "Short target of tool NAME from ARGUMENTS: command, URL, or path."
  (let* ((args (kargu--decode-tool-arguments arguments))
         (command (kargu-chat--tool-target-string
                   (kargu--tool-arg args "command")))
         (url (kargu-chat--tool-target-string
               (kargu--tool-arg args "url")))
         (path (kargu-chat--tool-target-string
                (or (kargu--tool-file-path args)
                    (kargu--tool-arg args "directory" "dir" "cwd"))))
         (pattern (kargu-chat--tool-target-string
                   (kargu--tool-arg args "pattern" "query"))))
    (cond
     ((and (stringp name)
           (or (string-prefix-p "bash" name) (equal name "shell"))
           command)
      command)
     (url url)
     ((and pattern path) (kargu-chat--tool-target-string (format "%s %s" pattern path)))
     (pattern pattern)
     (path path)
     (command command))))

(defun kargu-chat--tool-heading (name arguments)
  "Timeline heading for tool NAME called with ARGUMENTS."
  (let ((target (kargu-chat--tool-target name arguments)))
    (if target
        (format "  → %s %s" name target)
      (format "  → %s" name))))

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
  "Render STATUS from REPORT, with answer TEXT or ERROR details."
  ;; Plain transport: print answer here if no deltas arrived
  (when (and (eq status :done) (not kargu-chat--streamed-text))
    (if (kargu-nonempty text)
        (progn
          (kargu-chat-insert text)
          (kargu-chat-insert "\n"))
      (kargu-chat-insert "— empty model response\n" 'kargu-chat-meta)))
  ;; Interrupted runs carry reason as report text
  (when (and (memq status '(:stopped :limit))
             (stringp text) (not (string-empty-p text)))
    (kargu-chat-insert (concat text "\n") 'kargu-chat-meta))
  (pcase status
    (:done
     (kargu-chat-insert
      (format "— done · %d model turn(s) · %d healing round(s) · %d verification(s)\n"
              (or (plist-get report :iterations) 0)
              (or (plist-get report :healing) 0)
              (or (plist-get report :verifications) 0))
      'kargu-chat-meta))
    (:error
     (kargu-chat-insert
      (format "— ERROR: %s\n" (or error "unknown error"))
      'kargu-chat-error))
    (:stopped
     (kargu-chat-insert "— run stopped\n" 'kargu-chat-meta))
    (:limit
     (kargu-chat-insert "— stopped: iteration limit\n" 'kargu-chat-meta))
    (_
     (kargu-chat-insert "— run ended\n" 'kargu-chat-meta))))

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
    (kargu-chat-insert (format "  • %s (%s)  " file stat-str))
    (kargu-chat-insert diff-btn)
    (kargu-chat-insert "  ")
    (kargu-chat-insert rb-btn)
    (kargu-chat-insert "\n")))

(defun kargu-chat--render-modified-files (modified)
  "Render summary list of MODIFIED files."
  (when (and (listp modified) modified)
    (kargu-chat-insert "\nModified file(s):\n" 'kargu-chat-meta)
    (dolist (file modified)
      (kargu-chat--render-modified-file file))))

(defun kargu-chat--on-finish (report)
  "Render the final REPORT plist of an agent run in the run's chat buffer.
See `kargu-loop-send' for the shape of the report."
  (let ((buffer (kargu-chat-output-buffer)))
    (if (buffer-live-p buffer)
        (with-current-buffer buffer
          (kargu-chat--render-report report))
      (kargu-chat--render-report report))))

(defun kargu-chat--render-report (report)
  "Render REPORT into the current chat buffer (or only notify without one)."
  (kargu-chat-flush-stream)
  (setq kargu-chat--in-thought nil)
  (let ((status (plist-get report :status))
        (text (plist-get report :text))
        (error (plist-get report :error))
        (pending (plist-get report :pending-files))
        (modified (plist-get report :modified-files))
        (buffer (kargu-chat-output-buffer)))
    (kargu-chat--clear-running-prompt-banner buffer)
    (kargu-chat-insert "\n")
    (kargu-chat--render-finish-status status report text error)
    (kargu-chat--render-modified-files modified)
    (when (and (listp pending) pending)
      (kargu-chat-insert
       (format "unverified changed file(s): %s\nroll back with M-x kargu-diff-rollback or the menu's r\n"
               (string-join pending ", "))
       'kargu-chat-error))
    (kargu-chat-insert "\n")
    (when (and (eq status :done)
               (eq (kargu-state-mode)
                   'plan)
               (fboundp 'kargu-plan-handle-response))
      (kargu-plan-handle-response report))
    (when (fboundp 'kargu-notify)
      (kargu-notify (if (eq status :error) 'error 'finish)))
    (when (and (bound-and-true-p kargu-session-auto-save)
               (fboundp 'kargu-session-save)
               buffer)
      (ignore-errors (kargu-session-save buffer)))
    (kargu-chat--ensure-idle-prompt)
    (force-mode-line-update t)
    (let ((buf (kargu-chat-output-buffer)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (goto-char (point-max)))
        (dolist (win (get-buffer-window-list buf nil t))
          (set-window-point win (point-max)))))))

(defun kargu-chat--tool-event-buffer (run)
  "Return RUN's live chat buffer only while RUN owns the active loop."
  (and (eq run kargu--loop-run)
       (buffer-live-p (plist-get run :chat-buffer))
       (plist-get run :chat-buffer)))

(defun kargu-chat--finish-tool-activity (run result)
  "Render RESULT only in the chat buffer still owned by RUN."
  (when-let* ((buffer (kargu-chat--tool-event-buffer run)))
    (with-current-buffer buffer
      (kargu-chat-insert
       (format "[%s]\n" (kargu-chat--result-summary result))
       'kargu-chat-tool)
      (setq kargu-chat--preamble-dropped nil
            kargu-chat--in-thought nil)
      (when (markerp kargu-chat--output-marker)
        (setq kargu-chat--answer-start (copy-marker kargu-chat--output-marker nil))))))

(defun kargu-chat--start-tool-activity (run name arguments)
  "Render tool NAME and ARGUMENTS only in RUN's own chat buffer."
  (when-let* ((live (kargu-chat--tool-event-buffer run)))
      (with-current-buffer live
        (kargu-chat--drop-streamed-preamble)
        (kargu-chat-flush-stream)
        (let ((pos (if (and (markerp kargu-chat--output-marker)
                            (eq (marker-buffer kargu-chat--output-marker) live))
                       (marker-position kargu-chat--output-marker)
                     (point-max))))
          (unless (or (<= pos (point-min))
                      (eq (char-before pos) ?\n))
            (kargu-chat-insert "\n")))
        (kargu-chat-insert
         (concat (kargu-chat--tool-heading name arguments) " ")
         'kargu-chat-tool))))

;; Remove the old global wrapper when this module is reloaded in a live Emacs.
(advice-remove 'kargu-execute-tool 'kargu-chat--tool-activity)
(add-hook 'kargu-loop-tool-start-hook #'kargu-chat--start-tool-activity)
(add-hook 'kargu-loop-tool-finish-hook #'kargu-chat--finish-tool-activity)

(provide 'kargu/chat/render)

;;; render.el ends here
