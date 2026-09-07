;;; kargu/chat.el --- Shell-like chat sidebar -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Chat buffer orchestrator, sidebar display, and commands.
;; Modular subfeatures:
;;   `kargu/chat/prompt'   -> prompt lifecycle, markers, and locking
;;   `kargu/chat/render'   -> transcript formatting, streaming deltas, thoughts
;;   `kargu/chat/header'   -> dynamic header line and mode buttons
;;   `kargu/chat/complete' -> `@' company for files and LSP symbols
;;   `kargu/chat/attach'   -> synthetic Read attachments
;; Requires: `kargu/core', `kargu/api', `kargu/loop'.
;; Public: `kargu-chat-show', `kargu-chat-send', `kargu-chat-toggle',
;; `kargu-chat-reset', `kargu-chat-stop'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'project nil t)
(require 'company nil t)
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
(require 'kargu/config)
(require 'kargu/api)
(require 'kargu/loop)
(require 'kargu/tools/diff)
(require 'kargu/tools/lsp)

;; Modular subcomponents of chat
(require 'kargu/chat/prompt)
(require 'kargu/chat/render)
(require 'kargu/chat/header)
(require 'kargu/chat/complete)
(require 'kargu/chat/attach)
(require 'kargu/chat/tune)

(defvar company-backends)
(defvar company-minimum-prefix-length)
(defvar company-idle-delay)
(declare-function company-mode "company")

(defgroup kargu-ui nil
  "Transient menu and chat sidebar for kargu."
  :group 'kargu
  :prefix "kargu-chat-")

(defcustom kargu-chat-side 'right
  "Side of the frame on which the chat sidebar appears."
  :type '(choice (const :tag "Right" right)
                 (const :tag "Left" left)
                 (const :tag "Bottom" bottom)
                 (const :tag "Top" top))
  :group 'kargu-ui)

(defcustom kargu-chat-window-width 0.38
  "Width of the chat sidebar as a fraction of the frame width.
Used when `kargu-chat-side' is `right' or `left'."
  :type 'number
  :group 'kargu-ui)

(defcustom kargu-chat-window-height 0.30
  "Height of the chat sidebar as a fraction of the frame height.
Used when `kargu-chat-side' is `bottom' or `top'."
  :type 'number
  :group 'kargu-ui)

(defcustom kargu-chat-attach-max-lines 150
  "Line count above which `@' file mentions are references, not bodies.
Files at or below this many lines are inlined as a synthetic Read
transcript.  Longer files become a `<referenced_file>' hint so
the model must call `read_file' instead of drowning the prompt."
  :type 'natnum
  :group 'kargu-ui)

(defcustom kargu-chat-max-listed-files 2000
  "Cap on files collected for `@' completion under one project root."
  :type 'natnum
  :group 'kargu-ui)

;;;; Chat major mode ------------------------------------------------------

(declare-function kargu-chat-select-mode-company "kargu/api" (&optional _event))
(declare-function kargu-chat-select-provider-company "kargu/api")
(declare-function kargu-chat-select-model-company "kargu/api")
(declare-function kargu-chat-select-effort-company "kargu/api")
(declare-function kargu-switch-provider-and-model "kargu/api")

(defvar-keymap kargu-chat-mode-map
  :doc "Keymap for `kargu-chat-mode'."
  "C-c C-c"  #'kargu-chat-send
  "C-c C-k"  #'kargu-chat-stop
  "C-c C-r"  #'kargu-chat-reset
  "C-c C-l"  #'kargu-chat-clear
  "C-c C-q"  #'kargu-chat-quit
  "C-c C-n"  #'kargu-chat-new
  "C-c C-b"  #'kargu-chat-switch
  "C-c C-x"  #'kargu-chat-select-mode-company
  "C-c C-p"  #'kargu-chat-select-provider-company
  "C-c C-m"  #'kargu-chat-select-model-company
  "C-c C-o"  #'kargu-chat-select-effort-company
  "C-c C-s"  #'kargu-switch-provider-and-model
  "C-a"      #'kargu-chat-beginning-of-line
  "<home>"   #'kargu-chat-beginning-of-line
  "RET"      #'kargu-chat-return)

(defun kargu-chat-return ()
  "Handle RET in the chat buffer.
Execute button action if on a button, stop run if on stop button,
or insert newline if editing."
  (interactive)
  (let ((action (or (get-text-property (point) 'action)
                    (and (fboundp 'button-at)
                         (button-at (point))
                         (button-get (button-at (point)) 'action)))))
    (cond
     (action
      (if (functionp action)
          (funcall action (point))
        (call-interactively action)))
     ((kargu-loop-running-p)
      (message "kargu is currently running. Click [Stop] or press C-c C-k to stop."))
     (t
      (newline)))))

(defvar kargu-chat-buffers nil
  "List of live kargu chat buffers.")

(defun kargu-chat-list-buffers ()
  "Return a list of live buffers running `kargu-chat-mode'."
  (setq kargu-chat-buffers
        (cl-remove-if-not (lambda (b)
                            (and (bufferp b)
                                 (buffer-live-p b)
                                 (with-current-buffer b (derived-mode-p 'kargu-chat-mode))))
                          (buffer-list)))
  kargu-chat-buffers)

(define-derived-mode kargu-chat-mode text-mode "kargu"
  "Major mode for the kargu chat transcript.

Past turns are read-only.  Type at the `kargu> ' prompt at the
end of the buffer; move the cursor up to select and copy.  C-c
C-c sends the prompt, RET inserts a newline, C-c C-k stops a
run, C-c C-q hides the sidebar.  `@' completes project files and
LSP symbols when company-mode is available.  C-c C-n starts a new
chat session, C-c C-b switches between open chat sessions.
The header line shows the active mode, model, and context usage.

\\{kargu-chat-mode-map}"
  (setq-local buffer-read-only nil)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local require-final-newline nil)
  (setq-local header-line-format '(:eval (kargu-chat--header-string)))
  (add-to-list 'kargu-chat-buffers (current-buffer))
  (add-hook 'kill-buffer-hook
            (lambda ()
              (setq kargu-chat-buffers (delq (current-buffer) kargu-chat-buffers)))
            nil t)
  (when (or (featurep 'company) (require 'company nil t))
    (setq-local company-backends '(kargu-chat-company))
    (setq-local company-minimum-prefix-length 1)
    (setq-local company-idle-delay 0.15)
    (unless (bound-and-true-p company-mode)
      (company-mode 1)))
  (add-hook 'post-self-insert-hook #'kargu-chat--maybe-company nil t)
  (when (fboundp 'kargu-api-prefetch-models)
    (kargu-api-prefetch-models)))

;;;; Buffer lifecycle & display -------------------------------------------

(defun kargu-chat-new (&optional name)
  "Create and display a new independent kargu chat session buffer.
If NAME is provided, creates `*kargu-chat: NAME*'.
Otherwise generates `*kargu-chat*<N>'."
  (interactive
   (list (when current-prefix-arg
           (read-string "Session name (optional): "))))
  (let* ((base-name (if (and (stringp name) (not (string-empty-p (string-trim name))))
                        (format "*kargu-chat: %s*" (string-trim name))
                      kargu-chat-buffer-name))
         (buf (generate-new-buffer base-name)))
    (with-current-buffer buf
      (kargu-chat-mode)
      (kargu-chat--insert
       (concat "kargu chat — type at the prompt; "
               "C-c C-c sends, C-c C-k stops, C-c C-n new chat, C-c C-b switch chat.\n\n"))
      (kargu-chat--ensure-prompt))
    (pop-to-buffer-same-window buf)
    (with-current-buffer buf
      (goto-char (point-max)))
    (kargu-chat-list-buffers)
    buf))

(defun kargu-chat-switch ()
  "Interactively switch between open kargu chat buffers."
  (interactive)
  (let* ((live (kargu-chat-list-buffers)))
    (cond
     ((null live)
      (kargu-chat-show))
     ((= (length live) 1)
      (pop-to-buffer-same-window (car live)))
     (t
      (let* ((names (mapcar #'buffer-name live))
             (default-name (buffer-name (if (derived-mode-p 'kargu-chat-mode)
                                            (or (cadr live) (car live))
                                          (car live))))
             (chosen (completing-read "Switch to kargu chat: " names nil t nil nil default-name))
             (target (get-buffer chosen)))
        (when (and target (buffer-live-p target))
          (pop-to-buffer-same-window target)))))))

(defun kargu-chat--buffer ()
  "Return the chat buffer, creating and initializing it if needed.
Reuses the current buffer if it is already in `kargu-chat-mode'."
  (if (derived-mode-p 'kargu-chat-mode)
      (current-buffer)
    (if-let ((buffer (get-buffer kargu-chat-buffer-name)))
        (with-current-buffer buffer
          (unless (eq major-mode 'kargu-chat-mode)
            (kargu-chat-mode)
            (let ((inhibit-read-only t)
                  (end (point-max)))
              (when (> end (point-min))
                (add-text-properties
                 (point-min) end
                 '(read-only t front-sticky t
                   rear-nonsticky (read-only face front-sticky))))))
          (kargu-chat--ensure-prompt)
          (current-buffer))
      (with-current-buffer (get-buffer-create kargu-chat-buffer-name)
        (kargu-chat-mode)
        (kargu-chat--insert
         (concat "kargu chat — type at the prompt; "
                 "C-c C-c sends, C-c C-k stops, C-c C-n new chat, C-c C-b switch chat.\n\n"))
        (kargu-chat--ensure-prompt)
        (current-buffer)))))

(defun kargu-chat-show ()
  "Display the chat buffer directly in the current window without splitting.
If the frame has 1 window, opens over that buffer.  If multiple windows exist,
opens in whichever window is currently selected (left or right)."
  (interactive)
  (let ((buffer (kargu-chat--buffer)))
    (pop-to-buffer-same-window buffer)
    (with-current-buffer buffer
      (kargu-chat--ensure-prompt)
      (goto-char (point-max)))
    buffer))

(defun kargu-chat--hide (window)
  "Hide the chat WINDOW and restore the previous buffer in that window."
  (condition-case nil
      (quit-window nil window)
    (error (bury-buffer))))

(defun kargu-chat-toggle ()
  "Toggle the kargu chat buffer in the current window."
  (interactive)
  (let* ((buffer (kargu-chat--buffer))
         (window (and buffer (get-buffer-window buffer t))))
    (if (and window (eq window (selected-window)))
        (kargu-chat--hide window)
      (kargu-chat-show))))

(defun kargu-chat-quit ()
  "Hide the chat buffer and restore the previous buffer in the window."
  (interactive)
  (kargu-chat--hide (selected-window)))

;;;; Commands & run submission --------------------------------------------

(defun kargu-chat--submit (prompt)
  "Start an agent run for PROMPT in the chat buffer."
  (when (kargu-loop-running-p)
    (user-error "kargu: a run is already in progress (stop it with C-c C-k)"))
  (unless (and (stringp prompt)
               (not (string-empty-p (string-trim prompt))))
    (user-error "kargu: empty prompt"))
  (add-to-history 'kargu-chat-input-history prompt)
  (setq kargu-chat--streamed-text nil
        kargu-chat--preamble-dropped nil
        kargu-chat--in-thought nil)
  (kargu-chat--render-user-turn prompt)
  (kargu-chat--render-agent-heading)
  (kargu-chat--ensure-running-prompt)
  (let ((buf (current-buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq kargu-chat--answer-start
              (copy-marker
               (or (and (markerp kargu-chat--output-marker)
                        (marker-position kargu-chat--output-marker))
                   (point-max))
               nil)))))
  (kargu-loop-send (kargu-chat--expand-prompt prompt)
                   #'kargu-chat--on-delta
                   #'kargu-chat--on-finish)
  (force-mode-line-update t)
  (let ((buffer (current-buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (goto-char (point-max))))))

(defun kargu-chat-send ()
  "Send the chat prompt input, or focus the prompt if it is empty.
Starts an autonomous agent run (`kargu-loop-send'): tool calls
are dispatched by the loop, edits go through the human ediff
review gate, and diagnostics feed back into self-healing.  Called
from the menu with an empty prompt, this just opens the chat."
  (interactive)
  (kargu-chat-show)
  (if (kargu-loop-running-p)
      (message "kargu is currently running. Click [Stop] or press C-c C-k to stop.")
    (let ((text (string-trim (kargu-chat--input-text))))
      (if (string-empty-p text)
          (progn
            (goto-char (point-max))
            (message "kargu: type a prompt, then C-c C-c to send"))
        (kargu-chat--consume-input)
        (kargu-chat--submit text)))))

(defun kargu-chat-prompt (&optional prompt)
  "Send PROMPT, or the chat input when called interactively."
  (interactive)
  (if (called-interactively-p 'interactive)
      (kargu-chat-send)
    (kargu-chat-show)
    (with-current-buffer (kargu-chat--buffer)
      (when (kargu-chat--prompt-live-p)
        (kargu-chat--consume-input)))
    (kargu-chat--submit prompt)))

(defun kargu-chat-reset ()
  "Reset the kargu session: stop the run, clear history and counters.
The chat log itself is kept as a record."
  (interactive)
  (when (y-or-n-p "Reset the kargu session (history + counters)? ")
    (kargu-session-reset)
    (kargu-chat--insert "\n— session reset —\n"
                        'kargu-chat-meta)
    (kargu-chat--ensure-prompt)))

(defun kargu-chat-clear ()
  "Clear all previous turns in the chat log, keeping only the prompt."
  (interactive)
  (when-let* ((buffer (get-buffer kargu-chat-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (delete-region (point-min) (point-max))
        (setq kargu-chat--output-marker nil
              kargu-chat--prompt-marker nil))
      (kargu-chat--ensure-prompt)
      (message "kargu: chat transcript cleared"))))

(defun kargu-chat-stop ()
  "Stop the agent run in progress."
  (interactive)
  (if (kargu-loop-running-p)
      (progn
        (kargu-loop-stop "stopped by user")
        (force-mode-line-update t)
        (message "kargu: stopped agent run"))
    (message "kargu: no run in progress")))

(kargu-log 'info "chat module loaded")

(provide 'kargu/chat)

;;; kargu/chat.el ends here
