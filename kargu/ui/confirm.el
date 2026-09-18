;;; kargu/ui/confirm.el --- Reusable interactive confirmation and recovery UI -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Unified interactive confirmation engine for Kargu.
;; Used across doom-loop approval, turn limits, network timeouts,
;; HTTP errors, and rate limits without repeating UI logic.
;; Public: `kargu-ui-confirm', `kargu-confirm--mock-decision'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)

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

(defvar kargu-chat--output-marker)
(defvar kargu-chat--prompt-marker)
(defvar kargu-chat-buffer-name)

(declare-function kargu-chat-show "kargu/chat" ())
(declare-function kargu-notify "kargu/ui/notify" (type &optional msg))
(declare-function kargu-loop-running-p "kargu/loop" ())
(declare-function kargu-chat--ensure-running-prompt "kargu/chat/prompt" ())
(declare-function kargu-chat--ensure-idle-prompt "kargu/chat/prompt" ())

(defvar kargu-confirm--mock-decision nil
  "Dynamically bound decision key for unit tests (e.g. `:retry', `:stop').")

(defun kargu-confirm--render-prompt (chat-buf title details notice actions set-decision-fn)
  "Render confirmation banner, DETAILS, NOTICE, and button ACTIONS in CHAT-BUF.
SET-DECISION-FN is called with the chosen action key when clicked."
  (with-current-buffer chat-buf
    (let ((inhibit-read-only t))
      ;; Clear any existing running banner if at prompt
      (when (and (boundp 'kargu-chat--output-marker)
                 (markerp kargu-chat--output-marker)
                 (eq (marker-buffer kargu-chat--output-marker) chat-buf))
        (delete-region kargu-chat--output-marker (point-max))
        (when (boundp 'kargu-chat--prompt-marker)
          (setq kargu-chat--prompt-marker nil)))
      (goto-char (point-max))
      (unless (or (bobp) (eq (char-before) ?\n))
        (insert "\n"))
      (insert "\n")
      ;; Title banner
      (when title
        (insert (propertize (format "  %s\n" title)
                            'face '(:inherit warning :weight bold))))
      ;; Details (error string, tool arguments, etc.)
      (when (and details (stringp details) (not (string-empty-p (string-trim details))))
        (let ((lines (split-string (string-trim details) "\n")))
          (dolist (line lines)
            (insert (format "     %s\n"
                            (truncate-string-to-width (string-trim line) 140))))))
      ;; Notice / guidance
      (when (and notice (stringp notice) (not (string-empty-p (string-trim notice))))
        (insert (format "     %s\n" (string-trim notice))))
      (insert "     ")
      ;; Action buttons
      (let ((first t))
        (dolist (act actions)
          (let* ((act-key (plist-get act :key))
                 (label (or (plist-get act :label) (format "[%s]" act-key)))
                 (face (or (plist-get act :face) 'bold))
                 (help (or (plist-get act :help) (format "Click to %s" act-key)))
                 (captured act-key))
            (unless first
              (insert "  "))
            (setq first nil)
            (insert-button
             label
             'action (lambda (_)
                       (funcall set-decision-fn captured)
                       (exit-recursive-edit))
             'face face
             'help-echo help))))
      (insert "\n\n")
      (when (boundp 'kargu-chat--output-marker)
        (setq kargu-chat--output-marker (copy-marker (point-max) t))))))

(defun kargu-confirm--wait-decision (chat-buf actions default-action get-decision-fn)
  "Wait in recursive edit in CHAT-BUF for user button action or cancel.
Inserts audit message from ACTIONS and returns the chosen key."
  (let ((win (get-buffer-window chat-buf)))
    (when (and (null win) (not noninteractive))
      (setq win (and (fboundp 'kargu-chat-show)
                     (get-buffer-window (kargu-chat-show)))))
    (when win
      (select-window win))
    (with-current-buffer chat-buf
      (goto-char (point-max)))
    (dolist (w (get-buffer-window-list chat-buf nil t))
      (set-window-point w (point-max))
      (with-selected-window w
        (goto-char (point-max))
        (recenter -1)))
    (message "Action required: click an option button in chat (or C-g to cancel)")
    (condition-case _sig
        (recursive-edit)
      (quit
       (message "kargu: action cancelled by user")))
    (let* ((decision (or (funcall get-decision-fn) default-action))
           (matched-act (cl-find-if (lambda (a) (eq (plist-get a :key) decision)) actions))
           (msg (or (and matched-act (plist-get matched-act :message))
                    (format "     -> [%s]\n\n" decision))))
      (with-current-buffer chat-buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (propertize msg 'face (if (memq decision '(:stop :reject :cancel))
                                           'font-lock-warning-face
                                         'font-lock-string-face)))
          (when (boundp 'kargu-chat--output-marker)
            (setq kargu-chat--output-marker (copy-marker (point-max) t))))
        (when (derived-mode-p 'kargu-chat-mode)
          (if (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
              (when (fboundp 'kargu-chat--ensure-running-prompt)
                (kargu-chat--ensure-running-prompt))
            (when (fboundp 'kargu-chat--ensure-idle-prompt)
              (kargu-chat--ensure-idle-prompt)))))
      (dolist (w (get-buffer-window-list chat-buf nil t))
        (set-window-point w (point-max))
        (with-selected-window w
          (goto-char (point-max))))
      decision)))

(defun kargu-ui-confirm (&rest plist)
  "Present an interactive confirmation / recovery prompt with action buttons.
PLIST keys:
  `:title'           - Banner title string (e.g. \"⚠️  [Network Interruption]\")
  `:details'         - Optional details or error message string
  `:notice'          - Explanation or question text
  `:actions'         - List of action plists (:key :label :face :help :message)
  `:chat-buffer'     - Target chat buffer
  `:fallback-prompt' - Prompt for `y-or-n-p' if non-chat interactive fallback
  `:default-action'  - Action key when cancelled or headless (default `:stop')
  `:notify'          - Notification symbol for `kargu-notify'
Returns the chosen action key symbol."
  (let* ((title (plist-get plist :title))
         (details (plist-get plist :details))
         (notice (plist-get plist :notice))
         (actions (plist-get plist :actions))
         (target-buf (plist-get plist :chat-buffer))
         (fallback (or (plist-get plist :fallback-prompt) (format "%s Proceed? " (or title "Notice:"))))
         (default-action (or (plist-get plist :default-action) :stop))
         (notify-type (plist-get plist :notify)))
    (cond
     ;; Test mock override
     (kargu-confirm--mock-decision
      (let ((chat-buf (or (and (bufferp target-buf) (buffer-live-p target-buf) target-buf)
                          (and (bound-and-true-p kargu-chat-buffer-name)
                               (get-buffer kargu-chat-buffer-name))
                          (get-buffer "*kargu-chat*"))))
        (when (and chat-buf (buffer-live-p chat-buf))
          (kargu-confirm--render-prompt
           chat-buf title details notice actions (lambda (_d) nil)))
        kargu-confirm--mock-decision))
     ;; Headless / non-interactive (CI, batch)
     (noninteractive
      default-action)
     ;; Interactive environment
     (t
      (when (and notify-type (fboundp 'kargu-notify))
        (kargu-notify notify-type))
      (let ((chat-buf (or (and (bufferp target-buf) (buffer-live-p target-buf) target-buf)
                          (and (bound-and-true-p kargu-chat-buffer-name)
                               (get-buffer kargu-chat-buffer-name))
                          (get-buffer "*kargu-chat*"))))
        (if (not (and chat-buf (buffer-live-p chat-buf)))
            (let ((first-act (and actions (plist-get (car actions) :key))))
              (if (y-or-n-p fallback)
                  (or first-act :ok)
                default-action))
          (let ((decision default-action))
            (kargu-confirm--render-prompt
             chat-buf title details notice actions (lambda (d) (setq decision d)))
            (setq decision
                  (kargu-confirm--wait-decision
                   chat-buf actions default-action (lambda () decision)))
            decision)))))))

(provide 'kargu/ui/confirm)

;;; kargu/ui/confirm.el ends here
