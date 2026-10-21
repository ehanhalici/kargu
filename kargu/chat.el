;;; chat.el --- Shell-like chat sidebar -*- lexical-binding: t; -*-

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
(require 'kargu/core)
(require 'kargu/ui/notify)
(require 'kargu/config)
(require 'kargu/api)
(require 'kargu/chat/select)
(require 'kargu/loop)
(require 'kargu/tools/deps)

;; Modular subcomponents of chat
(require 'kargu/chat/prompt)
(require 'kargu/chat/render)
(require 'kargu/chat/header)
(require 'kargu/chat/complete)
(require 'kargu/chat/attach)
(require 'kargu/chat/tune)
(require 'kargu/chat/session)

(declare-function kargu-chat--shown-provider "kargu/chat/prompt" ())
(declare-function kargu-chat--shown-model "kargu/chat/prompt" ())
(declare-function kargu-chat--focus-selection "kargu/chat/prompt" (&optional open-company))
(declare-function kargu-eglot-connected-p "kargu/tools/lsp/context" ())
(declare-function kargu-dape-ready-p "kargu/tools/dape/session" ())
(declare-function kargu-dape-ensure-session "kargu/tools/dape/session"
                  (on-ready &optional on-cancel))
(declare-function kargu-dape-cancel-session-wait "kargu/tools/dape/readiness" ())
(defvar kargu-eglot-required-message)

(defvar-local kargu-chat--eglot-notice-p nil
  "Non-nil when this chat has shown its missing-Eglot notice.")

(defun kargu-chat--notice-without-eglot ()
  "Warn once about unavailable LSP without withholding the prompt."
  (if (and (fboundp 'kargu-eglot-connected-p) (kargu-eglot-connected-p))
      (setq-local kargu-chat--eglot-notice-p nil)
    (unless kargu-chat--eglot-notice-p
      (setq-local kargu-chat--eglot-notice-p t)
      (kargu-chat-insert (concat kargu-eglot-required-message "\n\n")
                         'font-lock-warning-face))))

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

(declare-function kargu-chat-select-mode-company "kargu/api/select" (&optional _event))
(declare-function kargu-chat-select-provider-company "kargu/api/select")
(declare-function kargu-chat-select-model-company "kargu/api/select")
(declare-function kargu-chat-select-effort-company "kargu/api/select")
(declare-function kargu-switch-provider-and-model "kargu/api/select")

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

(defun kargu-chat-list-buffers ()
  "Return a list of live buffers running `kargu-chat-mode'."
  (cl-remove-if-not
   (lambda (buffer)
     (with-current-buffer buffer (derived-mode-p 'kargu-chat-mode)))
   (buffer-list)))

(defun kargu/chat-unload-function ()
  "Refuse live views and detach composition subscriptions before unloading."
  (when (kargu-chat-list-buffers)
    (user-error "Kargu: close chat buffers before unloading their UI"))
  (remove-hook 'kargu-state-mode-hook #'kargu-chat-refresh-mode)
  (remove-hook 'kargu-session-reset-hook #'kargu-chat-session-reset)
  nil)

(define-derived-mode kargu-chat-mode text-mode "kargu"
  "Major mode for the kargu chat transcript.

Past turns are read-only.  Type at the prompt and use the command
`kargu-chat-send' to submit or `kargu-chat-stop' to stop a run.
Move up to select and copy transcript text.  Mentions beginning with
`@' complete project files and LSP symbols when Company is available.
The header line shows the active mode, model, and context usage.

\\{kargu-chat-mode-map}"
  (setq-local buffer-read-only nil)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local require-final-newline nil)
  (setq-local header-line-format '(:eval (kargu-chat--header-string)))
  (unless kargu-chat--project-root
    (setq-local kargu-chat--project-root (kargu-session-project-root)))
  (unless kargu-chat--session-id
    (setq-local kargu-chat--session-id (kargu-session-id)))
  (add-hook 'kill-buffer-hook
            (lambda ()
              (when (bound-and-true-p kargu-session-auto-save)
                (ignore-errors (kargu-session-save (current-buffer)))))
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
  (let* ((proj (kargu-session-project-root))
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
      (kargu-chat-insert
       (concat "kargu chat — type at the prompt; "
               "C-c C-c sends, C-c C-k stops, C-c C-n new chat, C-c C-h switch session.\n\n"))
      (kargu-chat--notice-without-eglot)
      (kargu-chat--ensure-prompt)
      (when (fboundp 'kargu-chat-check-and-display-missing-tools)
        (kargu-chat-check-and-display-missing-tools proj)))
    (pop-to-buffer-same-window buf)
    (with-current-buffer buf
      (kargu-chat--focus-selection (called-interactively-p 'any)))
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

(defun kargu-chat--buffer (&optional target-root)
  "Return the chat buffer for TARGET-ROOT, creating or restoring it.
Reuse the current buffer when it already belongs to the project."
  (let ((root (kargu-session-project-root
               (or target-root (kargu-session-project-root)))))
    (or (and (derived-mode-p 'kargu-chat-mode)
             (or (null kargu-chat--project-root)
                 (equal kargu-chat--project-root root))
             (current-buffer))
        (cl-find-if
         (lambda (buffer)
           (equal (buffer-local-value 'kargu-chat--project-root buffer) root))
         (kargu-chat-list-buffers))
        (kargu-chat--create-project-buffer root))))

(defun kargu-chat--create-project-buffer (root)
  "Create or restore a chat buffer for project ROOT."
  (let* ((sessions (and kargu-session-auto-restore (kargu-session-list root)))
         (existing (get-buffer kargu-chat-buffer-name))
         (other-root (and existing
                          (buffer-local-value 'kargu-chat--project-root existing)))
         (buffer (if (and other-root (not (equal other-root root)))
                     (generate-new-buffer kargu-chat-buffer-name)
                   (get-buffer-create kargu-chat-buffer-name))))
    (with-current-buffer buffer
      (if sessions
          (kargu-session-load (car sessions) buffer root)
        (kargu-chat--initialize-project-buffer root))
      (kargu-chat-check-and-display-missing-tools root))
    buffer))

(defun kargu-chat--initialize-project-buffer (root)
  "Initialize the current chat buffer for project ROOT."
  (unless (eq major-mode 'kargu-chat-mode) (kargu-chat-mode))
  (setq-local kargu-chat--project-root root)
  (setq-local kargu-chat--session-id (kargu-session-id))
  (let ((inhibit-read-only t))
    (add-text-properties
     (point-min) (point-max)
     '(read-only t front-sticky t
                 rear-nonsticky (read-only face front-sticky))))
  (unless (kargu-chat--prompt-live-p)
    (kargu-chat-insert
     (concat "kargu chat — type at the prompt; "
             "C-c C-c sends, C-c C-k stops, C-c C-n new chat, C-c C-h switch session.\n\n"))
    (kargu-chat--ensure-prompt)))

(defun kargu-chat-show ()
  "Display the chat buffer directly in the current window without splitting.
If the frame has 1 window, opens over that buffer.  If multiple windows exist,
opens in whichever window is currently selected (left or right).
LSP is optional; a missing connection is reported without blocking chat."
  (interactive)
  (let* ((open-company (called-interactively-p 'any))
         (proj (kargu-session-project-root))
         (buffer (kargu-chat--buffer proj)))
    (pop-to-buffer-same-window buffer)
    (with-current-buffer buffer
      (kargu-chat--notice-without-eglot)
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
    (user-error "Kargu: select a provider and model before sending")))

(declare-function kargu-loop-require-tools-for-agent "kargu/loop" ())
(declare-function kargu-model-forget-tools-refusals "kargu/api/catalog" ())

(defun kargu-chat--refuse-agent-without-tools ()
  "Signal when agent mode is on and the model cannot call tools.
The request is not sent.  Call this before the prompt is consumed
so the typed text stays in the input."
  (kargu-loop-require-tools-for-agent))

(defun kargu-chat--preflight (prompt)
  "Signal `user-error' when PROMPT cannot be sent now.
Nothing is consumed or rendered, so a refusal keeps the typed input."
  (unless (and (stringp prompt)
               (not (string-empty-p (string-trim prompt))))
    (user-error "Kargu: empty prompt"))
  (kargu-chat--require-selection)
  (kargu-chat--refuse-agent-without-tools)
  (kargu-loop-preflight))

(defun kargu-chat--reset-stream-state ()
  "Forget the stream flags of the previous run in this chat buffer."
  (setq kargu-chat--streamed-text nil
        kargu-chat--preamble-dropped nil
        kargu-chat--in-thought nil))

(defun kargu-chat--mark-answer-start ()
  "Remember where the assistant answer of this turn begins."
  (setq kargu-chat--answer-start
        (copy-marker
         (or (and (markerp kargu-chat--output-marker)
                  (marker-position kargu-chat--output-marker))
             (point-max))
         nil)))

(defun kargu-chat--follow-end (buffer)
  "Move point and every window showing BUFFER to its end."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (goto-char (point-max)))
    (dolist (win (get-buffer-window-list buffer nil t))
      (set-window-point win (point-max)))))

(cl-defstruct (kargu-chat--submission
               (:constructor kargu-chat--make-submission))
  "Prompt region and cursor positions before publishing a user turn."
  start footer prompt-offset point mark windows)

(defun kargu-chat--capture-submission ()
  "Capture the live prompt and cursors for a rejected submission."
  (let ((start (marker-position kargu-chat--output-marker)))
    (kargu-chat--make-submission
     :start start :footer (buffer-substring start (point-max))
     :prompt-offset (- kargu-chat--prompt-marker start)
     :point (point) :mark (mark t)
     :windows (mapcar (lambda (win) (cons win (window-point win)))
                      (get-buffer-window-list (current-buffer) nil t)))))

(defun kargu-chat--rollback-submission (saved)
  "Restore prompt and cursors from SAVED after startup rejection."
  (let ((inhibit-read-only t)
        (start (kargu-chat--submission-start saved)))
    (delete-region start (point-max))
    (goto-char start)
    (insert (kargu-chat--submission-footer saved))
    (setq kargu-chat--output-marker (copy-marker start t)
          kargu-chat--prompt-marker
          (copy-marker (+ start (kargu-chat--submission-prompt-offset saved)))
          kargu-chat--answer-start nil)
    (goto-char (kargu-chat--submission-point saved))
    (set-marker (mark-marker) (kargu-chat--submission-mark saved))
    (dolist (pair (kargu-chat--submission-windows saved))
      (when (and (window-live-p (car pair))
                 (eq (window-buffer (car pair)) (current-buffer)))
        (set-window-point (car pair) (cdr pair))))))

(defun kargu-chat--publish-submission (prompt)
  "Render PROMPT and its running banner before callbacks can arrive."
  (kargu-chat--consume-input)
  (kargu-chat--reset-stream-state)
  (kargu-chat--render-user-turn prompt)
  (kargu-chat--render-agent-heading)
  (kargu-chat--ensure-running-prompt)
  (kargu-chat--mark-answer-start))

(defun kargu-chat--restore-draft (saved)
  "Restore the unsent draft from SAVED without removing the new transcript."
  (kargu-chat--ensure-idle-prompt)
  (let* ((offset (kargu-chat--submission-prompt-offset saved))
         (old-start (+ (kargu-chat--submission-start saved) offset))
         (text (substring (kargu-chat--submission-footer saved) offset))
         (start (marker-position kargu-chat--prompt-marker))
         (inhibit-read-only t))
    (save-excursion
      (goto-char start)
      (insert text)
      (when (and (not (string-empty-p text)) (< (point) (point-max)))
        (insert "\n")))
    (when (>= (kargu-chat--submission-point saved) old-start)
      (goto-char (+ start (- (kargu-chat--submission-point saved) old-start))))
    (when-let* ((mark (kargu-chat--submission-mark saved)))
      (when (>= mark old-start)
        (set-mark (+ start (- mark old-start)))))
    (dolist (pair (kargu-chat--submission-windows saved))
      (when (and (window-live-p (car pair))
                 (eq (window-buffer (car pair)) (current-buffer))
                 (>= (cdr pair) old-start))
        (set-window-point (car pair) (+ start (- (cdr pair) old-start)))))))

(cl-defun kargu-chat--complete-submission (report &key buffer draft)
  "Render REPORT in BUFFER and restore an optional unsent DRAFT."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unwind-protect
          (kargu-chat--on-finish report)
        (when draft (kargu-chat--restore-draft draft))))))

(cl-defun kargu-chat--submit (prompt &key preserve-draft)
  "Start a run for PROMPT, restoring the draft if startup is rejected.
When PRESERVE-DRAFT is non-nil, keep unsent input after completion too."
  (kargu-chat--preflight prompt)
  (let ((expanded (kargu-chat--expand-prompt prompt))
        (saved (kargu-chat--capture-submission))
        (buffer (current-buffer)))
    (condition-case err
        (progn
          (kargu-chat--publish-submission prompt)
          (kargu-chat--follow-end buffer)
          (kargu-loop-send
           expanded #'kargu-chat--on-delta
           (lambda (report)
             (kargu-chat--complete-submission
              report :buffer buffer :draft (and preserve-draft saved)))))
      (error
       (unless (kargu-loop-running-p)
         (kargu-chat--rollback-submission saved))
       (signal (car err) (cdr err)))))
  (add-to-history 'kargu-chat-input-history prompt)
  (force-mode-line-update t))

(defun kargu-chat--project ()
  "Project root of the current chat, or the session root."
  (or (bound-and-true-p kargu-chat--project-root)
      (and (fboundp 'kargu-session-project-root)
           (kargu-session-project-root))))

(defun kargu-chat--missing-tools (proj)
  "Missing mandatory tools for PROJ, or nil."
  (and (fboundp 'kargu-deps-missing)
       (kargu-deps-missing proj)))

(defun kargu-chat--signal-missing-tools (proj missing)
  "Show MISSING tools for PROJ and signal `user-error'."
  (when (fboundp 'kargu-chat-check-and-display-missing-tools)
    (kargu-chat-check-and-display-missing-tools proj t))
  (user-error "Kargu: cannot send prompt: mandatory tools are missing: %s (please install them first)"
              (string-join (mapcar (lambda (m) (format "%s" (plist-get m :name))) missing) ", ")))

(defun kargu-chat--debug-fallback-text ()
  "Prompt used when debug mode is asked to start with an empty input."
  "Debug oturumu başlatıldı. Kodu incele, breakpoint koy ve çalıştır.")

(defun kargu-chat--debug-session-needed-p ()
  "Non-nil when debug mode has no ready debugger session."
  (and (eq (kargu-state-mode) 'debug)
       (not (and (fboundp 'kargu-dape-ready-p) (kargu-dape-ready-p)))))

(defun kargu-chat--after-debug-session (continue cancel)
  "Start a debug session, then call CONTINUE.  CANCEL reports failure."
  (if (fboundp 'kargu-dape-ensure-session)
      (kargu-dape-ensure-session
       continue (lambda (&optional reason)
                  (funcall cancel (or reason "user abort"))))
    (funcall cancel "debugger module unavailable")))

(cl-defstruct (kargu-chat--debug-prompt (:constructor kargu-chat--make-debug-prompt))
  "Captured chat and input awaiting debugger readiness."
  buffer session root text input preserve-draft (state :pending))

(defun kargu-chat--resume-debug-prompt (pending)
  "Submit PENDING only in its unchanged originating chat."
  (when (eq (kargu-chat--debug-prompt-state pending) :pending)
    (setf (kargu-chat--debug-prompt-state pending) :done)
    (let ((buffer (kargu-chat--debug-prompt-buffer pending)))
      (if (not (buffer-live-p buffer))
          (message "kargu: debug prompt not sent: its chat was closed")
        (with-current-buffer buffer
          (cond
           ((or (not (derived-mode-p 'kargu-chat-mode))
                (not (equal kargu-chat--session-id (kargu-chat--debug-prompt-session pending)))
                (not (equal kargu-chat--project-root (kargu-chat--debug-prompt-root pending)))
                (not (eq (kargu-state-mode) 'debug)))
            (message "kargu: debug prompt not sent: chat, session or mode changed; send it again"))
           ((and (not (kargu-chat--debug-prompt-preserve-draft pending))
                 (not (equal (kargu-chat--input-text) (kargu-chat--debug-prompt-input pending))))
            (message "kargu: input changed while starting the debugger; nothing was sent, review and send again"))
           (t
            (condition-case err
                (let ((kargu-permission--override-root (kargu-chat--debug-prompt-root pending)))
                  (kargu-loop-preflight)
                  (kargu-chat--submit
                   (kargu-chat--debug-prompt-text pending)
                   :preserve-draft (kargu-chat--debug-prompt-preserve-draft pending)))
              (error (message "kargu: debug prompt not sent: %s" (error-message-string err)))))))))))

(defun kargu-chat--await-debug-prompt (text preserve-draft)
  "Wait for debug startup before submitting TEXT with PRESERVE-DRAFT policy."
  (let ((pending (kargu-chat--make-debug-prompt
                  :buffer (current-buffer) :session kargu-chat--session-id
                  :root kargu-chat--project-root :text (copy-sequence text)
                  :input (kargu-chat--input-text) :preserve-draft preserve-draft)))
    (kargu-chat--after-debug-session
     (lambda () (kargu-chat--resume-debug-prompt pending))
     (lambda (reason)
       (when (eq (kargu-chat--debug-prompt-state pending) :pending)
         (setf (kargu-chat--debug-prompt-state pending) :done)
         (message "kargu: debug session cancelled or failed: %s" reason))))))

(cl-defun kargu-chat--send-prepared (text &key preserve-draft)
  "Submit TEXT, keeping an unrelated input when PRESERVE-DRAFT is non-nil.
A debug session that is not ready is started before the submit.
Every refusal happens before the input is consumed."
  (kargu-chat--preflight text)
  (cond
   ((kargu-chat--debug-session-needed-p)
    (kargu-chat--await-debug-prompt text preserve-draft))
   (t
    (kargu-chat--submit text :preserve-draft preserve-draft))))

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
      (kargu-chat--send-prepared text)))))

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
  "Send PROMPT from the chat buffer after startup validation."
  (let ((missing (kargu-chat--missing-tools (kargu-chat--project))))
    (when missing
      (kargu-chat-show)
      (kargu-chat--signal-missing-tools (kargu-chat--project) missing)))
  (kargu-chat-show)
  (let ((text (kargu-chat--prompt-text prompt)))
    (with-current-buffer (kargu-chat--buffer)
      (kargu-chat--send-prepared text :preserve-draft t))))

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
    (kargu-model-forget-tools-refusals)
    (kargu-chat-insert "\n— session reset —\n"
                       'kargu-chat-meta)
    (kargu-chat--ensure-prompt)))

(defun kargu-chat-clear ()
  "Clear the chat transcript while keeping the prompt."
  (interactive)
  (when-let* ((buffer (kargu-chat-output-buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (delete-region (point-min) (point-max))
        (setq kargu-chat--output-marker nil
              kargu-chat--prompt-marker nil))
      (kargu-chat--ensure-prompt)
      (message "kargu: chat transcript cleared"))))

(defun kargu-chat-stop ()
  "Stop the agent run in progress.
Also cancel this chat's debugger readiness wait before a run starts.
A running banner left behind by a failed start is cleared too, so
the editable prompt comes back."
  (interactive)
  (let ((cancelled (and (fboundp 'kargu-dape-cancel-session-wait)
                        (kargu-dape-cancel-session-wait))))
    (if (kargu-loop-running-p)
        (progn
          (kargu-loop-stop "stopped by user")
          (force-mode-line-update t)
          (message "kargu: stopped agent run"))
      (when (and (markerp kargu-chat--output-marker)
                 (null kargu-chat--prompt-marker))
        (kargu-chat--ensure-idle-prompt))
      (message (if cancelled "kargu: debugger wait cancelled" "kargu: no run in progress")))))

(kargu-log 'info "chat module loaded")

(provide 'kargu/chat)

;;; chat.el ends here
