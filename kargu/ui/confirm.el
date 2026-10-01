;;; kargu/ui/confirm.el --- Reusable interactive confirmation and recovery UI -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Unified interactive confirmation engine for Kargu.
;; Used across doom-loop approval, turn limits, network timeouts,
;; HTTP errors, rate limits and shell approval without repeating UI logic.
;; The prompt never waits: it renders buttons in the chat buffer and
;; returns.  The decision arrives through the `:on-decision' callback,
;; so the Emacs command loop stays free while the human thinks.
;; Public: `kargu-ui-confirm', `kargu-confirm-dismiss-all',
;; `kargu-confirm--mock-decision'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)

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

(cl-defstruct (kargu-confirm--req (:constructor kargu-confirm--req-create))
  "One prompt on screen: its buffer, actions and pending callback."
  resolved chat-buf actions on-decision)

(defvar kargu-confirm--pending nil
  "Prompts that are on screen and not yet answered.")

(defvar-local kargu-confirm--focus nil
  "Marker on the first option button of the confirmation in this buffer.")

(defun kargu-confirm--lock (start end)
  "Mark START to END as transcript: visible, but not editable."
  (when (< start end)
    (add-text-properties
     start end
     '(read-only t
       front-sticky t
       rear-nonsticky (read-only face front-sticky)))))

(defun kargu-confirm--note-focus (pos)
  "Remember POS as the first option button in the current buffer."
  (if (markerp kargu-confirm--focus)
      (move-marker kargu-confirm--focus pos)
    (setq kargu-confirm--focus (copy-marker pos))))

(defun kargu-confirm--focus-position (chat-buf)
  "Position of the first option button in CHAT-BUF, or its end."
  (with-current-buffer chat-buf
    (if (and (markerp kargu-confirm--focus)
             (eq (marker-buffer kargu-confirm--focus) chat-buf))
        (marker-position kargu-confirm--focus)
      (point-max))))

(defun kargu-confirm--place-point (chat-buf)
  "Move CHAT-BUF's point onto its first option button.
Every window showing CHAT-BUF follows, and that line sits at the
bottom of the window.  The position is read from CHAT-BUF, never
from whichever buffer is current."
  (when (buffer-live-p chat-buf)
    (with-current-buffer chat-buf
      (let ((pos (kargu-confirm--focus-position chat-buf)))
        (goto-char pos)
        (dolist (w (get-buffer-window-list chat-buf nil t))
          (set-window-point w pos)
          (with-selected-window w (recenter -1)))))))

(defun kargu-confirm--show-end (chat-buf)
  "Move CHAT-BUF's point and its windows to the end of CHAT-BUF."
  (when (buffer-live-p chat-buf)
    (with-current-buffer chat-buf
      (let ((end (point-max)))
        (goto-char end)
        (dolist (w (get-buffer-window-list chat-buf nil t))
          (set-window-point w end)
          (with-selected-window w (recenter -1)))))))

(defun kargu-confirm--resolve-chat-buffer (&optional target-buf)
  "Resolve and return a live chat buffer, or nil."
  (or (and (bufferp target-buf) (buffer-live-p target-buf) target-buf)
      (and (bound-and-true-p kargu-chat-buffer-name)
           (get-buffer kargu-chat-buffer-name))
      (get-buffer "*kargu-chat*")))

(defun kargu-confirm--render-action-buttons (actions set-decision-fn)
  "Render clickable buttons for ACTIONS calling SET-DECISION-FN on click.
mouse-1, mouse-2 and RET all decide on the first press."
  (let ((first t))
    (dolist (act actions)
      (let* ((act-key (plist-get act :key))
             (label (or (plist-get act :label) (format "[%s]" act-key)))
             (face (or (plist-get act :face) 'bold))
             (help (or (plist-get act :help) (format "Click to %s" act-key)))
             (captured act-key)
             (command (lambda ()
                        (interactive)
                        (funcall set-decision-fn captured)))
             (map (make-sparse-keymap)))
        (set-keymap-parent map button-map)
        (define-key map [mouse-1] command)
        (define-key map [mouse-2] command)
        (define-key map (kbd "RET") command)
        (unless first
          (insert "  "))
        (setq first nil)
        (let ((start (point)))
          (insert-button
           label
           'action (lambda (_) (funcall set-decision-fn captured))
           'face face
           'mouse-face 'highlight
           'help-echo help
           'keymap map
           'follow-link t)
          (add-text-properties start (point) `(keymap ,map local-map ,map)))))))

(defun kargu-confirm--render-prompt (chat-buf title details notice actions set-decision-fn)
  "Render confirmation banner, DETAILS, NOTICE, and button ACTIONS in CHAT-BUF.
SET-DECISION-FN is called with the chosen action key when clicked."
  (with-current-buffer chat-buf
    (let ((inhibit-read-only t))
      (when (and (boundp 'kargu-chat--output-marker)
                 (markerp kargu-chat--output-marker)
                 (eq (marker-buffer kargu-chat--output-marker) chat-buf))
        (delete-region kargu-chat--output-marker (point-max))
        (when (boundp 'kargu-chat--prompt-marker)
          (setq kargu-chat--prompt-marker nil)))
      (goto-char (point-max))
      (let ((start (point)))
        (unless (or (bobp) (eq (char-before) ?\n))
          (insert "\n"))
        (insert "\n")
        (when title
          (insert (propertize (format "  %s\n" title)
                              'face '(:inherit warning :weight bold))))
        (when (and details (stringp details) (not (string-empty-p (string-trim details))))
          (dolist (line (split-string (string-trim details) "\n"))
            (insert (format "     %s\n"
                            (truncate-string-to-width (string-trim line) 140)))))
        (when (and notice (stringp notice) (not (string-empty-p (string-trim notice))))
          (insert (format "     %s\n" (string-trim notice))))
        (insert "     ")
        (kargu-confirm--note-focus (point))
        (kargu-confirm--render-action-buttons actions set-decision-fn)
        (insert "\n\n")
        (kargu-confirm--lock start (point))
        (when (boundp 'kargu-chat--output-marker)
          (setq kargu-chat--output-marker (copy-marker (point-max) t)))))))

(defun kargu-confirm--decision-message (actions decision)
  "Audit line for DECISION taken from ACTIONS."
  (let ((act (cl-find-if (lambda (a) (eq (plist-get a :key) decision)) actions)))
    (or (and act (plist-get act :message))
        (format "     -> [%s]\n\n" decision))))

(defun kargu-confirm--restore-prompt ()
  "Bring the running or idle chat prompt back after a decision."
  (when (derived-mode-p 'kargu-chat-mode)
    (if (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
        (when (fboundp 'kargu-chat--ensure-running-prompt)
          (kargu-chat--ensure-running-prompt))
      (when (fboundp 'kargu-chat--ensure-idle-prompt)
        (kargu-chat--ensure-idle-prompt)))))

(defun kargu-confirm--write-audit (chat-buf actions decision)
  "Record DECISION in CHAT-BUF and restore its prompt."
  (when (buffer-live-p chat-buf)
    (with-current-buffer chat-buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (let ((start (point)))
          (insert (propertize (kargu-confirm--decision-message actions decision)
                              'face (if (memq decision '(:stop :reject :cancel))
                                        'font-lock-warning-face
                                      'font-lock-string-face)))
          (kargu-confirm--lock start (point)))
        (when (boundp 'kargu-chat--output-marker)
          (setq kargu-chat--output-marker (copy-marker (point-max) t))))
      (kargu-confirm--restore-prompt))
    (kargu-confirm--show-end chat-buf)))

(defun kargu-confirm--settle (req decision &optional silent)
  "Answer REQ once with DECISION.  SILENT skips the callback (dismissal)."
  (unless (kargu-confirm--req-resolved req)
    (setf (kargu-confirm--req-resolved req) t)
    (setq kargu-confirm--pending (delq req kargu-confirm--pending))
    (kargu-confirm--write-audit (kargu-confirm--req-chat-buf req)
                                (kargu-confirm--req-actions req)
                                decision)
    (unless silent
      (funcall (kargu-confirm--req-on-decision req) decision))))

(defun kargu-confirm-dismiss-all ()
  "Cancel every unanswered prompt without calling its callback.
Called when a run is stopped so no button can act on a dead run."
  (dolist (req (copy-sequence kargu-confirm--pending))
    (kargu-confirm--settle req :cancel t)))

(defun kargu-confirm--reveal (chat-buf)
  "Make CHAT-BUF visible and put point on its first option button."
  (unless (or noninteractive (get-buffer-window chat-buf t))
    (when (fboundp 'kargu-chat-show)
      (kargu-chat-show)))
  (kargu-confirm--place-point chat-buf)
  (message "Action required: click an option button in the chat"))

(defun kargu-confirm--ask-in-minibuffer (fallback actions default-action)
  "Ask FALLBACK with `y-or-n-p' and return the action key."
  (if (y-or-n-p fallback)
      (or (and actions (plist-get (car actions) :key)) :ok)
    default-action))

(defun kargu-ui-confirm (&rest plist)
  "Show a confirmation prompt with action buttons and return at once.
The chosen action key is passed to the `:on-decision' function.
PLIST keys:
  `:on-decision'     - Required function of one argument (the action key)
  `:title'           - Banner title string
  `:details'         - Optional details or error message string
  `:notice'          - Explanation or question text
  `:actions'         - List of action plists (:key :label :face :help :message)
  `:chat-buffer'     - Target chat buffer
  `:fallback-prompt' - Prompt for `y-or-n-p' when no chat buffer is live
  `:default-action'  - Action key for batch Emacs (default `:stop')
  `:notify'          - Notification symbol for `kargu-notify'
Under `kargu-confirm--mock-decision' and in batch Emacs the callback runs
before this function returns; interactively it runs when a button is clicked."
  (let* ((on-decision (plist-get plist :on-decision))
         (title (plist-get plist :title))
         (actions (plist-get plist :actions))
         (default-action (or (plist-get plist :default-action) :stop))
         (chat-buf (kargu-confirm--resolve-chat-buffer (plist-get plist :chat-buffer)))
         (fallback (or (plist-get plist :fallback-prompt)
                       (format "%s Proceed? " (or title "Notice:")))))
    (unless (functionp on-decision)
      (error "kargu-ui-confirm needs an :on-decision function"))
    (cond
     (kargu-confirm--mock-decision
      (when chat-buf
        (kargu-confirm--render-prompt
         chat-buf title (plist-get plist :details) (plist-get plist :notice)
         actions #'ignore))
      (funcall on-decision kargu-confirm--mock-decision))
     (noninteractive
      (funcall on-decision default-action))
     (t
      (when (and (plist-get plist :notify) (fboundp 'kargu-notify))
        (kargu-notify (plist-get plist :notify)))
      (if (not chat-buf)
          (funcall on-decision
                   (kargu-confirm--ask-in-minibuffer fallback actions default-action))
        (let ((req (kargu-confirm--req-create
                    :chat-buf chat-buf :actions actions :on-decision on-decision)))
          (push req kargu-confirm--pending)
          (kargu-confirm--render-prompt
           chat-buf title (plist-get plist :details) (plist-get plist :notice)
           actions (lambda (d) (kargu-confirm--settle req d)))
          (kargu-confirm--reveal chat-buf)))))
    nil))

(provide 'kargu/ui/confirm)

;;; kargu/ui/confirm.el ends here
