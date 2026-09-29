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
(require 'kargu/ui/notify)
(require 'kargu/config)
(require 'kargu/api)
(require 'kargu/loop)
(require 'kargu/tools/diff)
(require 'kargu/tools/lsp)
(require 'kargu/tools/dape nil t)
(require 'kargu/tools/deps)

;; Modular subcomponents of chat
(require 'kargu/chat/prompt)
(require 'kargu/chat/render)
(require 'kargu/chat/header)
(require 'kargu/chat/complete)
(require 'kargu/chat/attach)
(require 'kargu/chat/tune)
(require 'kargu/chat/session)

(declare-function kargu-chat-note-selection "kargu/chat/session" (&optional buffer))
(declare-function kargu-chat-activate-selection "kargu/chat/session" (&optional buffer))
(declare-function kargu-chat--shown-provider "kargu/chat/prompt" ())
(declare-function kargu-chat--shown-model "kargu/chat/prompt" ())
(declare-function kargu-chat--focus-selection "kargu/chat/prompt" (&optional open-company))

(defvar company-backends)
(defvar company-minimum-prefix-length)
(defvar company-idle-delay)
(declare-function company-mode "company")

(defgroup kargu-ui nil
  "Transient menu and chat sidebar for kargu."
  :group 'kargu
  :prefix "kargu-chat-")

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
  "C-c C-h"  #'kargu-chat-sessions
  "C-c C-x"  #'kargu-chat-select-mode-company
  "C-c C-p"  #'kargu-chat-select-provider-company
  "C-c C-m"  #'kargu-chat-select-model-company
  "C-c C-o"  #'kargu-chat-select-effort-company
  "C-c C-s"  #'kargu-switch-provider-and-model
  "C-a"      #'kargu-chat-beginning-of-line
  "<home>"   #'kargu-chat-beginning-of-line
  "RET"      #'kargu-chat-return)

(defvar kargu-chat--prompt-marker)

(defun kargu-chat-return ()
  "Handle RET in the chat buffer.
Execute button action if on a button, stop run if on stop button,
or insert newline if editing prompt."
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
     ((and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
      (message "kargu is currently running. Click [Stop] or press C-c C-k to stop."))
     ;; If point is in the footer or transcript area (before prompt marker), never insert newline!
     ((and (boundp 'kargu-chat--prompt-marker)
           (markerp kargu-chat--prompt-marker)
           (marker-position kargu-chat--prompt-marker)
           (< (point) (marker-position kargu-chat--prompt-marker)))
      (goto-char (point-max)))
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
chat session, C-c C-b switches between open chat sessions,
C-c C-h switches between saved past project sessions.
The header line shows the active mode, model, and context usage.

\\{kargu-chat-mode-map}"
  (setq-local buffer-read-only nil)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local require-final-newline nil)
  (setq-local header-line-format '(:eval (kargu-chat--header-string)))
  (unless kargu-chat--project-root
    (setq-local kargu-chat--project-root (kargu-session--project-root)))
  (unless kargu-chat--session-id
    (setq-local kargu-chat--session-id (kargu-session-id)))
  (add-to-list 'kargu-chat-buffers (current-buffer))
  (add-hook 'kill-buffer-hook
            (lambda ()
              (when (bound-and-true-p kargu-session-auto-save)
                (ignore-errors (kargu-session-save (current-buffer))))
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
  (when (and (derived-mode-p 'kargu-chat-mode) (bound-and-true-p kargu-session-auto-save))
    (ignore-errors (kargu-session-save (current-buffer))))
  (let* ((proj (kargu-session--project-root))
         (base-name (if (and (stringp name) (not (string-empty-p (string-trim name))))
                        (format "*kargu-chat: %s*" (string-trim name))
                      kargu-chat-buffer-name))
         (buf (generate-new-buffer base-name)))
    (with-current-buffer buf
      (kargu-chat-mode)
      (setq-local kargu-chat--project-root proj)
      (setq-local kargu-chat--session-id (and (fboundp 'kargu-session-id) (kargu-session-id)))
      (when (and (stringp name) (not (string-empty-p (string-trim name))))
        (setq-local kargu-chat--session-title (string-trim name)))
      (kargu-chat--insert
       (concat "kargu chat — type at the prompt; "
               "C-c C-c sends, C-c C-k stops, C-c C-n new chat, C-c C-h switch session.\n\n"))
      (kargu-chat--ensure-prompt)
      (when (fboundp 'kargu-chat-check-and-display-missing-tools)
        (kargu-chat-check-and-display-missing-tools proj)))
    (pop-to-buffer-same-window buf)
    (kargu-chat-activate-selection buf)
    (with-current-buffer buf
      (kargu-chat--focus-selection (called-interactively-p 'any)))
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
      (pop-to-buffer-same-window (car live))
      (kargu-chat-activate-selection (car live)))
     (t
      (let* ((names (mapcar #'buffer-name live))
             (default-name (buffer-name (if (derived-mode-p 'kargu-chat-mode)
                                            (or (cadr live) (car live))
                                          (car live))))
             (chosen (completing-read "Switch to kargu chat: " names nil t nil nil default-name))
             (target (get-buffer chosen)))
        (when (and target (buffer-live-p target))
          (pop-to-buffer-same-window target)
          (kargu-chat-activate-selection target)))))))

(defun kargu-chat--buffer (&optional target-root)
  "Return the chat buffer for TARGET-ROOT, creating or restoring it if needed.
Reuses the current buffer if it is already in `kargu-chat-mode'."
  (let ((root (or target-root (kargu-session--project-root))))
    (cond
     ;; Current buffer is already a matching chat buffer
     ((and (derived-mode-p 'kargu-chat-mode)
           (or (null kargu-chat--project-root)
               (equal kargu-chat--project-root root)))
      (current-buffer))
     ;; Look for an already live chat buffer matching this project
     ((cl-find-if (lambda (b)
                    (and (buffer-live-p b)
                         (equal (buffer-local-value 'kargu-chat--project-root b) root)))
                  (kargu-chat-list-buffers)))
     ;; If existing default buffer matches or is empty, use it; otherwise create or restore
     (t
      (let* ((sessions (and (bound-and-true-p kargu-session-auto-restore)
                            (fboundp 'kargu-session-list)
                            (kargu-session-list root)))
             (buf (get-buffer-create kargu-chat-buffer-name)))
        (if (and sessions (> (length sessions) 0))
            (progn
              (kargu-session-load (car sessions) buf root)
              (with-current-buffer buf
                (when (fboundp 'kargu-chat-check-and-display-missing-tools)
                  (kargu-chat-check-and-display-missing-tools root)))
              buf)
          (with-current-buffer buf
            (unless (eq major-mode 'kargu-chat-mode)
              (kargu-chat-mode))
            (setq-local kargu-chat--project-root root)
            (setq-local kargu-chat--session-id (and (fboundp 'kargu-session-id) (kargu-session-id)))
            (let ((inhibit-read-only t)
                  (end (point-max)))
              (when (> end (point-min))
                (add-text-properties
                 (point-min) end
                 '(read-only t front-sticky t
                   rear-nonsticky (read-only face front-sticky)))))
            (unless (kargu-chat--prompt-live-p)
              (kargu-chat--insert
               (concat "kargu chat — type at the prompt; "
                       "C-c C-c sends, C-c C-k stops, C-c C-n new chat, C-c C-h switch session.\n\n"))
              (kargu-chat--ensure-prompt))
            (when (fboundp 'kargu-chat-check-and-display-missing-tools)
              (kargu-chat-check-and-display-missing-tools root))
            (current-buffer))))))))

(defun kargu-chat--withhold-prompt-until-root ()
  "Drop every chat prompt when this language still has no project root."
  (when (and (not noninteractive) (kargu-language-root-unresolved-p))
    (dolist (buf (kargu-chat-list-buffers))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (kargu-chat--clear-idle-prompt))))))

(defun kargu-chat-show ()
  "Display the chat buffer directly in the current window without splitting.
If the frame has 1 window, opens over that buffer.  If multiple windows exist,
opens in whichever window is currently selected (left or right).
A language that names its own project root, such as Emacs Lisp, asks
for that directory before the prompt exists."
  (interactive)
  (kargu-chat--withhold-prompt-until-root)
  (let* ((open-company (called-interactively-p 'any))
         (owned (kargu-language-claim-root))
         (proj (or owned (kargu-session--project-root)))
         (buffer (kargu-chat--buffer proj)))
    (pop-to-buffer-same-window buffer)
    (kargu-chat-activate-selection buffer)
    (with-current-buffer buffer
      (kargu-chat--ensure-prompt)
      (when (fboundp 'kargu-chat-check-and-display-missing-tools)
        (kargu-chat-check-and-display-missing-tools proj))
      (kargu-chat--focus-selection open-company))
    buffer))

(defun kargu-chat--hide (window)
  "Hide the chat WINDOW and restore the previous buffer in that window."
  (condition-case nil
      (quit-window nil window)
    (error (bury-buffer))))

(defun kargu-chat-toggle ()
  "Toggle the kargu chat buffer in the current window."
  (interactive)
  (if (derived-mode-p 'kargu-chat-mode)
      (kargu-chat--hide (selected-window))
    (kargu-chat-show)))

(defun kargu-chat-quit ()
  "Hide the chat buffer and restore the previous buffer in the window."
  (interactive)
  (kargu-chat--hide (selected-window)))

;;;; Commands & run submission --------------------------------------------

(defun kargu-chat--require-selection ()
  "Signal when this chat has not chosen a provider and a model."
  (unless (and (kargu-chat--shown-provider) (kargu-chat--shown-model))
    (user-error "kargu: select a provider and model before sending")))

(defun kargu-chat--refuse-agent-without-tools ()
  "Signal when agent mode is on and the model cannot call tools.
The request is not sent.  Call this before the prompt is consumed
so the typed text stays in the input."
  (when (and (eq (kargu-state-mode) 'agent)
             (fboundp 'kargu-model-supports-tools-p)
             (not (kargu-model-supports-tools-p)))
    (user-error "Model '%s' does not support tool calling; switch to a tool-capable model or ask mode"
                (or (kargu--model) "unknown"))))

(defun kargu-chat--submit (prompt)
  "Start an agent run for PROMPT in the chat buffer."
  (when (kargu-loop-running-p)
    (user-error "kargu: a run is already in progress (stop it with C-c C-k)"))
  (let* ((proj (or (bound-and-true-p kargu-chat--project-root)
                   (and (fboundp 'kargu-session--project-root)
                        (kargu-session--project-root))))
         (missing (and (fboundp 'kargu-deps-missing)
                       (kargu-deps-missing proj))))
    (when missing
      (user-error "kargu: cannot send prompt: mandatory tools are missing: %s (please install them first)"
                  (string-join (mapcar (lambda (m) (format "%s" (plist-get m :name))) missing) ", "))))
  (unless (and (stringp prompt)
               (not (string-empty-p (string-trim prompt))))
    (user-error "kargu: empty prompt"))
  (kargu-chat--require-selection)
  (kargu-chat--refuse-agent-without-tools)
  (add-to-history 'kargu-chat-input-history prompt)
  (setq kargu-chat--streamed-text nil
        kargu-chat--preamble-dropped nil
        kargu-chat--in-thought nil)
  (kargu-chat-note-selection)
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
  (condition-case err
      (kargu-loop-send (kargu-chat--expand-prompt prompt)
                       #'kargu-chat--on-delta
                       #'kargu-chat--on-finish)
    (error
     (kargu-chat--ensure-idle-prompt)
     (signal (car err) (cdr err))))
  (force-mode-line-update t)
  (let ((buffer (current-buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (goto-char (point-max)))
      (dolist (win (get-buffer-window-list buffer nil t))
        (set-window-point win (point-max))
        (with-selected-window win
          (goto-char (point-max)))))))

(defun kargu-chat--project ()
  "Project root of the current chat, or the session root."
  (or (bound-and-true-p kargu-chat--project-root)
      (and (fboundp 'kargu-session--project-root)
           (kargu-session--project-root))))

(defun kargu-chat--missing-tools (proj)
  "Missing mandatory tools for PROJ, or nil."
  (and (fboundp 'kargu-deps-missing)
       (kargu-deps-missing proj)))

(defun kargu-chat--signal-missing-tools (proj missing)
  "Show MISSING tools for PROJ and signal `user-error'."
  (when (fboundp 'kargu-chat-check-and-display-missing-tools)
    (kargu-chat-check-and-display-missing-tools proj t))
  (user-error "kargu: cannot send prompt: mandatory tools are missing: %s (please install them first)"
              (string-join (mapcar (lambda (m) (format "%s" (plist-get m :name))) missing) ", ")))

(defun kargu-chat--debug-fallback-text ()
  "Prompt used when debug mode is asked to start with an empty input."
  "Debug oturumu başlatıldı. Kodu incele, breakpoint koy ve çalıştır.")

(defun kargu-chat--debug-session-needed-p ()
  "Non-nil when debug mode has no ready debugger session."
  (and (eq (kargu-state-mode) 'debug)
       (fboundp 'kargu-dape-ready-p)
       (not (kargu-dape-ready-p))))

(defun kargu-chat--after-debug-session (continue cancel)
  "Start a debug session, then call CONTINUE.  CANCEL reports failure."
  (kargu-dape-ensure-session
   continue
   (lambda (&optional reason)
     (funcall cancel (or reason "user abort")))))

(defun kargu-chat--send-prepared (text consume)
  "Submit TEXT.  CONSUME non-nil deletes the matching prompt first.
A debug session that is not ready is started before the submit."
  (cond
   ((kargu-chat--debug-session-needed-p)
    (kargu-chat--after-debug-session
     (lambda ()
       (let ((chat-buf (kargu-chat--buffer)))
         (kargu-chat-show)
         (with-current-buffer chat-buf
           (when (and consume
                      (string= (string-trim (kargu-chat--input-text)) text))
             (kargu-chat--consume-input))
           (kargu-chat--submit text))))
     (lambda (reason)
       (message "kargu: debug session cancelled or failed: %s" reason))))
   (t
    (when consume
      (kargu-chat--consume-input))
    (kargu-chat--submit text))))

(defun kargu-chat--send-input ()
  "Read, check, and send the current chat prompt."
  (let ((missing (kargu-chat--missing-tools (kargu-chat--project))))
    (when missing
      (kargu-chat--signal-missing-tools (kargu-chat--project) missing)))
  (let ((text (string-trim (kargu-chat--input-text))))
    (when (and (string-empty-p text) (eq (kargu-state-mode) 'debug))
      (setq text (kargu-chat--debug-fallback-text)))
    (unless (string-empty-p text)
      (kargu-chat--refuse-agent-without-tools))
    (cond
     ((string-empty-p text)
      (goto-char (point-max))
      (message "kargu: type a prompt, then C-c C-c to send"))
     (t
      (kargu-chat--send-prepared text t)))))

(defun kargu-chat-send ()
  "Send the chat prompt input, or focus the prompt if it is empty.
Starts an autonomous agent run (`kargu-loop-send'): tool calls
are dispatched by the loop, edits go through the human ediff
review gate, and diagnostics feed back into self-healing.  Called
from the menu with an empty prompt, this just opens the chat."
  (interactive)
  (kargu-chat-show)
  (cond
   ((kargu-loop-running-p)
    (message "kargu is currently running. Click [Stop] or press C-c C-k to stop."))
   (t
    (kargu-chat--send-input))))

(defun kargu-chat--prompt-text (prompt)
  "PROMPT, or the debug fallback when PROMPT is empty in debug mode."
  (cond
   ((and (stringp prompt) (not (string-empty-p (string-trim prompt))))
    prompt)
   ((eq (kargu-state-mode) 'debug)
    (kargu-chat--debug-fallback-text))
   (t nil)))

(defun kargu-chat--send-given (prompt)
  "Send PROMPT from the chat buffer, discarding a live input first."
  (let ((missing (kargu-chat--missing-tools (kargu-chat--project))))
    (when missing
      (kargu-chat-show)
      (kargu-chat--signal-missing-tools (kargu-chat--project) missing)))
  (kargu-chat-show)
  (with-current-buffer (kargu-chat--buffer)
    (kargu-chat--refuse-agent-without-tools)
    (when (kargu-chat--prompt-live-p)
      (kargu-chat--consume-input)))
  (let ((text (kargu-chat--prompt-text prompt)))
    (cond
     ((kargu-chat--debug-session-needed-p)
      (kargu-chat--after-debug-session
       (lambda ()
         (let ((chat-buf (kargu-chat--buffer)))
           (kargu-chat-show)
           (with-current-buffer chat-buf
             (kargu-chat--submit text))))
       (lambda (reason)
         (message "kargu: debug session cancelled or failed: %s" reason))))
     (t
      (kargu-chat--submit text)))))

(defun kargu-chat-prompt (&optional prompt)
  "Send PROMPT, or the chat input when called interactively."
  (interactive)
  (if (called-interactively-p 'interactive)
      (kargu-chat-send)
    (kargu-chat--send-given prompt)))

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
  (when-let* ((buffer (kargu-chat--target-buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (delete-region (point-min) (point-max))
        (setq kargu-chat--output-marker nil
              kargu-chat--prompt-marker nil))
      (kargu-chat--ensure-prompt)
      (message "kargu: chat transcript cleared"))))

(defun kargu-chat-stop ()
  "Stop the agent run in progress.
A running banner left behind by a failed start is cleared too, so
the editable prompt comes back."
  (interactive)
  (if (kargu-loop-running-p)
      (progn
        (kargu-loop-stop "stopped by user")
        (force-mode-line-update t)
        (message "kargu: stopped agent run"))
    (when (and (markerp kargu-chat--output-marker)
               (null kargu-chat--prompt-marker))
      (kargu-chat--ensure-idle-prompt))
    (message "kargu: no run in progress")))

(kargu-log 'info "chat module loaded")

(provide 'kargu/chat)

;;; kargu/chat.el ends here
