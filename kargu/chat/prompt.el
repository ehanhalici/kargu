;;; kargu/chat/prompt.el --- Chat prompt lifecycle and input handling -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Prompt area lifecycle: idle prompt, running banner with stop control,
;; marker management, and input text consumption.
;; Requires: `kargu/core', `kargu/loop'.
;; Public: `kargu-chat--ensure-prompt', `kargu-chat--prompt-live-p',
;; `kargu-chat--input-text', `kargu-chat--consume-input',
;; `kargu-chat-beginning-of-line'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/loop)
(require 'kargu/languages)
(require 'kargu/tools/deps)

(declare-function kargu-chat--target-buffer "kargu/chat/render" ())

(declare-function kargu-chat-stop "kargu/chat")
(declare-function kargu-chat-select-mode-company "kargu/api" (&optional _event))
(declare-function kargu-chat-select-provider-company "kargu/api")
(declare-function kargu-chat-select-model-company "kargu/api")
(declare-function kargu-chat-select-effort-company "kargu/api")
(declare-function kargu--provider-name "kargu/api")
(declare-function kargu--model "kargu/api")
(declare-function kargu-model-context-window "kargu/api" (&optional model-id))
(declare-function kargu-provider-params-get-all "kargu/providers/params" (&optional provider))
(declare-function kargu-tune-provider-params-menu "kargu/chat/tune-params")
(defvar kargu-reasoning-effort)

(defcustom kargu-chat-buffer-name "*kargu-chat*"
  "Name of the default kargu chat log buffer."
  :type 'string
  :group 'kargu-ui)

(defconst kargu-chat--prompt-string "kargu> "
  "Editable prompt prefix at the end of the chat buffer.")

(defface kargu-chat-prompt
  '((t :inherit minibuffer-prompt))
  "Face for the `kargu> ' input prompt."
  :group 'kargu-ui)

(defvar kargu-chat-input-history nil
  "History of prompts sent from the chat buffer.")

(defvar-local kargu-chat--output-marker nil
  "Marker just before the prompt; agent/tool text is inserted here.
Insertion type is t so streamed output stays above the prompt.")

(defvar-local kargu-chat--prompt-marker nil
  "Marker at the start of the editable prompt input.")

(defun kargu-chat--footer-button (label face help action-fn &optional mouse-fn)
  "Create an interactive button text string for footer.
LABEL is the displayed text. FACE is the font face. HELP is tooltip text.
ACTION-FN is called on RET or click. MOUSE-FN is called with event if supplied."
  (let ((map (make-sparse-keymap)))
    (when (boundp 'kargu-chat-mode-map)
      (set-keymap-parent map kargu-chat-mode-map))
    (define-key map [mouse-1] (or mouse-fn (lambda (_) (interactive) (funcall action-fn))))
    (define-key map [mouse-2] (or mouse-fn (lambda (_) (interactive) (funcall action-fn))))
    (define-key map (kbd "RET") (lambda () (interactive) (funcall action-fn)))
    (propertize label
                'face face
                'mouse-face 'highlight
                'help-echo help
                'keymap map
                'local-map map
                'button t
                'action (lambda (_) (funcall action-fn)))))

(declare-function kargu-chat--explicit-selection "kargu/chat/session" (value))

(defun kargu-chat--shown-provider ()
  "Provider chosen for this chat buffer, or nil.
A chat shows its own choice, never the live or configured fallback, so a
fresh chat asks for a selection."
  (kargu-chat--explicit-selection (bound-and-true-p kargu-chat--session-provider)))

(defun kargu-chat--shown-model ()
  "Model chosen for this chat buffer, or nil."
  (kargu-chat--explicit-selection (bound-and-true-p kargu-chat--session-model)))

(defun kargu-chat--footer-model-label (raw-m)
  "Return cons (LABEL . FACE) for RAW-M model in footer."
  (let ((has-model (and (stringp raw-m) (not (string-empty-p raw-m)))))
    (if has-model
        (let ((cap (and (fboundp 'kargu-model-context-window)
                        (kargu-model-context-window raw-m))))
          (if (and (numberp cap) (> cap 0))
              (cons (format "[%s (%s ctx)]" raw-m
                            (if (>= cap 1000000)
                                (format "%dm" (/ cap 1000000))
                              (format "%dk" (/ cap 1000))))
                    'font-lock-string-face)
            (cons (format "[%s]" raw-m) 'font-lock-string-face)))
      (cons "[select model]" 'font-lock-warning-face))))

(defun kargu-chat--footer-mode-button ()
  "Build the mode button for the footer."
  (let ((mode-name (upcase (symbol-name (kargu-state-mode)))))
    (kargu-chat--footer-button
     (format "[%s]" mode-name) 'bold
     "mouse-1 or RET: switch mode with company list (C-c C-x)"
     #'kargu-chat-select-mode-company
     (lambda (e) (interactive "e") (kargu-chat-select-mode-company e)))))

(defun kargu-chat--footer-provider-button ()
  "Build the provider button for this chat's chosen provider."
  (let ((pname (kargu-chat--shown-provider)))
    (if pname
        (kargu-chat--footer-button
         (format "[%s]" pname) 'font-lock-type-face
         "mouse-1 or RET: switch provider (company list)"
         #'kargu-chat-select-provider-company
         (lambda (e) (interactive "e") (kargu-chat-select-provider-company e)))
      (kargu-chat--footer-button
       "[select provider]" 'font-lock-warning-face
       "mouse-1 or RET: select provider (company list)"
       #'kargu-chat-select-provider-company
       (lambda (e) (interactive "e") (kargu-chat-select-provider-company e))))))

(defun kargu-chat--footer-model-button ()
  "Build the model button for the footer."
  (let* ((raw-m (kargu-chat--shown-model))
         (m-info (kargu-chat--footer-model-label raw-m)))
    (kargu-chat--footer-button
     (car m-info) (cdr m-info)
     "mouse-1 or RET: select model (company list)"
     #'kargu-chat-select-model-company
     (lambda (e) (interactive "e") (kargu-chat-select-model-company nil nil nil e)))))

(defun kargu-chat--footer-context-button ()
  "Build the context usage indicator for the footer."
  (let* ((ctx-info (if (fboundp 'kargu-session-context-info)
                       (kargu-session-context-info)
                     (list :formatted "128k")))
         (ctx-str (plist-get ctx-info :formatted)))
    (propertize (format "[ctx: %s]" ctx-str)
                'face 'font-lock-doc-face
                'help-echo "Model context usage (used / capacity)")))

(defun kargu-chat--footer-effort-button ()
  "Build the reasoning effort button for the footer."
  (let ((effort (if (boundp 'kargu-reasoning-effort) (or kargu-reasoning-effort "off") "off")))
    (kargu-chat--footer-button
     (format "[%s]" effort) 'font-lock-keyword-face
     "mouse-1 or RET: select reasoning effort (company list)"
     #'kargu-chat-select-effort-company
     (lambda (e) (interactive "e") (kargu-chat-select-effort-company e)))))

(defun kargu-chat--footer-params-button (pname)
  "Build the provider parameters button for PNAME for the footer."
  (let* ((active-params (and pname
                             (fboundp 'kargu-provider-params-get-all)
                             (kargu-provider-params-get-all pname)))
         (params-count (length active-params))
         (params-label (if (> params-count 0) (format "[params: %d]" params-count) "[params]"))
         (params-face (if (> params-count 0) 'font-lock-keyword-face 'font-lock-comment-face)))
    (kargu-chat--footer-button
     params-label params-face
     "mouse-1 or RET: configure provider routing & parameters"
     (lambda () (interactive)
       (if (fboundp 'kargu-tune-provider-params-menu)
           (call-interactively #'kargu-tune-provider-params-menu)
         (message "kargu: provider parameters menu not available")))
     (lambda (_e) (interactive "e")
       (if (fboundp 'kargu-tune-provider-params-menu)
           (call-interactively #'kargu-tune-provider-params-menu)
         (message "kargu: provider parameters menu not available"))))))

(defvar-local kargu-chat--missing-tools-state nil
  "List of missing tool IDs currently displayed as an error banner in this buffer.")

(defun kargu-chat-check-and-display-missing-tools (&optional target-root force)
  "Check mandatory tools for TARGET-ROOT and display error banner if missing.
If FORCE is non-nil, re-displays the banner even if state hasn't changed.
Returns list of missing tools."
  (let* ((root (or target-root
                   (bound-and-true-p kargu-chat--project-root)
                   (and (fboundp 'kargu-session-project-root)
                        (kargu-session-project-root))))
         (missing (and (fboundp 'kargu-deps-missing)
                       (kargu-deps-missing root)))
         (current-ids (mapcar (lambda (m) (plist-get m :id)) missing)))
    (cond
     (missing
      (when (or force (not (equal current-ids kargu-chat--missing-tools-state)))
        (setq-local kargu-chat--missing-tools-state current-ids)
        (let ((banner (propertize (concat (kargu-deps-format-missing-report missing) "\n\n")
                                  'face 'error)))
          (if (fboundp 'kargu-chat-insert)
              (kargu-chat-insert banner)
            (let ((inhibit-read-only t))
              (save-excursion
                (goto-char (point-max))
                (insert banner)))))
        (message "kargu: Mandatory tools missing! See details in the chat buffer."))
      (when (fboundp 'kargu-chat-refresh-footer)
        (kargu-chat-refresh-footer)))
     ((and (null missing) kargu-chat--missing-tools-state)
      (setq-local kargu-chat--missing-tools-state nil)
      (let ((msg (propertize "[kargu] ✓ All mandatory tools ready! You can now send prompts.\n\n"
                             'face 'font-lock-keyword-face)))
        (if (fboundp 'kargu-chat-insert)
            (kargu-chat-insert msg)
          (let ((inhibit-read-only t))
            (save-excursion
              (goto-char (point-max))
              (insert msg)))))
      (when (fboundp 'kargu-chat-refresh-footer)
        (kargu-chat-refresh-footer))))
    missing))

(defun kargu-chat--footer-string ()
  "Build the interactive footer line shown at the bottom of the chat buffer.
Contains clickable mode, provider, model, context usage, and effort buttons."
  (let* ((pname (kargu-chat--shown-provider))
         (mode-btn (kargu-chat--footer-mode-button))
         (p-btn (kargu-chat--footer-provider-button))
         (m-btn (kargu-chat--footer-model-button))
         (ctx-btn (kargu-chat--footer-context-button))
         (e-btn (kargu-chat--footer-effort-button))
         (params-btn (kargu-chat--footer-params-button pname))
         (root (or (bound-and-true-p kargu-chat--project-root)
                   (and (fboundp 'kargu-session-project-root)
                        (kargu-session-project-root))))
         (missing (and (fboundp 'kargu-deps-missing)
                       (kargu-deps-missing root)))
         (blocked-badge
          (when missing
            (propertize (format "  [⚠️ BLOCKED: %d missing tool%s]"
                                (length missing)
                                (if (= (length missing) 1) "" "s"))
                        'face '(:foreground "red" :weight bold)
                        'help-echo "Mandatory tools are missing; prompt submission is blocked."))))
    (propertize
     (concat "\n\n"
             (propertize "mode: " 'face 'font-lock-comment-face)
             mode-btn
             "  "
             (propertize "provider: " 'face 'font-lock-comment-face)
             p-btn
             "  "
             (propertize "model: " 'face 'font-lock-comment-face)
             m-btn
             " "
             ctx-btn
             "  "
             (propertize "effort: " 'face 'font-lock-comment-face)
             e-btn
             "  "
             params-btn
             (or blocked-badge "")
             "\n")
     'field 'prompt
     'read-only t
     'front-sticky t
     'rear-nonsticky '(read-only face field front-sticky))))

(defun kargu-chat-refresh-footer ()
  "Refresh the footer line at the bottom of the chat buffer in-place."
  (let ((buf (or (and (markerp kargu-chat--output-marker)
                      (marker-position kargu-chat--output-marker)
                      (current-buffer))
                 (kargu-chat--target-buffer))))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (when (and (markerp kargu-chat--output-marker)
                   (marker-position kargu-chat--output-marker))
          (let ((inhibit-read-only t))
            (if (kargu-chat--prompt-live-p)
                (let* ((input (buffer-substring-no-properties
                               kargu-chat--prompt-marker (point-max))))
                  (delete-region kargu-chat--output-marker (point-max))
                  (goto-char (point-max))
                  (let ((start (point)))
                    (insert (kargu-chat--footer-string))
                    (insert (propertize
                             kargu-chat--prompt-string
                             'face 'kargu-chat-prompt
                             'field 'prompt
                             'read-only t
                             'front-sticky t
                             'rear-nonsticky '(read-only face field front-sticky)))
                    (setq kargu-chat--prompt-marker (point-marker))
                    (set-marker-insertion-type kargu-chat--prompt-marker nil)
                    (setq kargu-chat--output-marker (copy-marker start t))
                    (insert input)))
              (delete-region kargu-chat--output-marker (point-max))
              (kargu-chat--ensure-running-prompt))))
        (force-mode-line-update t)))))

(defun kargu-chat-goto-footer-field (field)
  "Move point to the start of FIELD button inside footer.
FIELD is \\='mode, \\='provider, \\='model, or \\='effort.
Return point if found, or nil."
  (let ((buf (or (and (markerp kargu-chat--output-marker)
                      (marker-position kargu-chat--output-marker)
                      (current-buffer))
                 (kargu-chat--target-buffer))))
    (when buf
      (with-current-buffer buf
        (let ((win (get-buffer-window buf)))
          (when win (select-window win)))
        (when (and (markerp kargu-chat--output-marker)
                   (marker-position kargu-chat--output-marker))
          (goto-char (marker-position kargu-chat--output-marker))
          (let ((pat (cl-case field
                       (mode "mode: [")
                       (provider "provider: [")
                       (model "model: [")
                       (effort "effort: [")
                       (t "mode: ["))))
            (when (search-forward pat (and (markerp kargu-chat--prompt-marker)
                                           (marker-position kargu-chat--prompt-marker))
                                  t)
              (point))))))))

(defun kargu-chat--goto-prompt ()
  "Move point to the editable prompt input.
Return that position, or nil when the prompt is not live."
  (let ((buf (or (and (derived-mode-p 'kargu-chat-mode) (current-buffer))
                 (kargu-chat--target-buffer))))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (when (and (markerp kargu-chat--prompt-marker)
                   (eq (marker-buffer kargu-chat--prompt-marker) buf)
                   (marker-position kargu-chat--prompt-marker))
          (let ((pos (marker-position kargu-chat--prompt-marker)))
            (goto-char pos)
            (dolist (win (get-buffer-window-list buf nil t))
              (set-window-point win pos))
            pos))))))

(defun kargu-chat--focus-selection (&optional open-company)
  "Move point to the next unset footer choice, or to the prompt.
When OPEN-COMPANY is non-nil, an unset provider or model opens its
Company list.  A buffer that already has both stays in the prompt.
Return nil when this buffer has no live prompt."
  (cond
   ((not (kargu-chat--prompt-live-p)) nil)
   ((not (kargu-chat--shown-provider))
    (if open-company
        (kargu-chat-select-provider-company)
      (kargu-chat-goto-footer-field 'provider)))
   ((not (kargu-chat--shown-model))
    (if open-company
        (kargu-chat-select-model-company)
      (kargu-chat-goto-footer-field 'model)))
   (t (kargu-chat--goto-prompt))))

(defun kargu-chat--propertize-log (text &optional face)
  "Return TEXT locked as transcript, optionally with FACE."
  (let ((copy (copy-sequence text)))
    (add-text-properties
     0 (length copy)
     (append (and face (list 'face face))
             '(read-only t
               front-sticky t
               rear-nonsticky (read-only face front-sticky)))
     copy)
    copy))

(defun kargu-chat--prompt-live-p ()
  "Return non-nil when this buffer ends with an editable kargu prompt."
  (and (markerp kargu-chat--output-marker)
       (eq (marker-buffer kargu-chat--output-marker) (current-buffer))
       (markerp kargu-chat--prompt-marker)
       (eq (marker-buffer kargu-chat--prompt-marker) (current-buffer))
       (< (marker-position kargu-chat--output-marker)
          (marker-position kargu-chat--prompt-marker))
       (eq (get-text-property kargu-chat--output-marker 'field) 'prompt)))

(defun kargu-chat--clear-idle-prompt ()
  "Remove the editable prompt from the current chat buffer."
  (when (kargu-chat--prompt-live-p)
    (let ((inhibit-read-only t))
      (delete-region kargu-chat--output-marker (point-max))
      (setq kargu-chat--prompt-marker nil))))

(defun kargu-chat--ensure-idle-prompt ()
  "Make sure the chat buffer ends with an editable `kargu> ' prompt.
No prompt is inserted while the language still needs a project root."
  (let ((buffer (kargu-chat--target-buffer)))
    (when buffer
      (with-current-buffer buffer
        (cond
         ((and (not noninteractive) (kargu-language-root-unresolved-p))
          (kargu-chat--clear-idle-prompt))
         (t
          (when (and (markerp kargu-chat--output-marker)
                     (eq (marker-buffer kargu-chat--output-marker) buffer)
                     (null kargu-chat--prompt-marker))
            (let ((inhibit-read-only t))
              (delete-region kargu-chat--output-marker (point-max))))
          (unless (kargu-chat--prompt-live-p)
            (let ((inhibit-read-only t))
              (goto-char (point-max))
              (unless (or (bobp) (eq (char-before) ?\n))
                (insert (kargu-chat--propertize-log "\n")))
              (let ((start (point)))
                (insert (kargu-chat--footer-string))
                (insert (propertize
                         kargu-chat--prompt-string
                         'face 'kargu-chat-prompt
                         'field 'prompt
                         'read-only t
                         'front-sticky t
                         'rear-nonsticky '(read-only face field front-sticky)))
                (setq kargu-chat--prompt-marker (point-marker))
                (set-marker-insertion-type kargu-chat--prompt-marker nil)
                (setq kargu-chat--output-marker (copy-marker start t)))))))))))

(defun kargu-chat--ensure-running-prompt ()
  "Render a read-only running banner with a clickable [Stop] button."
  (let ((buffer (kargu-chat--target-buffer)))
    (when buffer
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (when (and (markerp kargu-chat--output-marker)
                     (eq (marker-buffer kargu-chat--output-marker) buffer))
            (delete-region kargu-chat--output-marker (point-max)))
          (goto-char (point-max))
          (unless (or (bobp) (eq (char-before) ?\n))
            (insert (kargu-chat--propertize-log "\n")))
          (let* ((start (point))
                 (map (make-sparse-keymap)))
            (when (boundp 'kargu-chat-mode-map)
              (set-keymap-parent map kargu-chat-mode-map))
            (define-key map [mouse-1] (lambda () (interactive) (kargu-chat-stop)))
            (define-key map [mouse-2] (lambda () (interactive) (kargu-chat-stop)))
            (define-key map (kbd "RET") (lambda () (interactive) (kargu-chat-stop)))
            (let ((stop-btn (propertize "[Stop]"
                                        'face '(:foreground "red" :weight bold)
                                        'mouse-face 'highlight
                                        'help-echo "mouse-1 or RET: stop the agent run"
                                        'keymap map
                                        'local-map map
                                        'button t
                                        'action (lambda (_) (kargu-chat-stop)))))
              (insert (kargu-chat--footer-string))
              (insert (propertize
                       "kargu running... "
                       'face 'font-lock-comment-face
                       'field 'prompt
                       'read-only t
                       'front-sticky t
                       'rear-nonsticky '(read-only face field front-sticky)))
              (insert (propertize
                       stop-btn
                       'field 'prompt
                       'read-only t
                       'front-sticky t
                       'rear-nonsticky '(read-only face field front-sticky)))
              (insert (propertize
                       " (press C-c C-k or click to stop)\n"
                       'face 'font-lock-comment-face
                       'field 'prompt
                       'read-only t
                       'front-sticky t
                       'rear-nonsticky '(read-only face field front-sticky)))
              (setq kargu-chat--prompt-marker nil)
              (setq kargu-chat--output-marker (copy-marker start t)))))))))

(defun kargu-chat--ensure-prompt ()
  "Ensure the chat buffer ends with appropriate prompt or running status."
  (if (kargu-loop-running-p)
      (kargu-chat--ensure-running-prompt)
    (kargu-chat--ensure-idle-prompt)))

(defun kargu-chat--in-input-p (&optional pos)
  "Return non-nil if POS (default point) is in the editable prompt."
  (let ((pos (or pos (point))))
    (and (markerp kargu-chat--prompt-marker)
         (eq (marker-buffer kargu-chat--prompt-marker) (current-buffer))
         (>= pos (marker-position kargu-chat--prompt-marker)))))

(defun kargu-chat-beginning-of-line ()
  "Move to the start of input, or the beginning of the line."
  (interactive "^")
  (if (kargu-chat--in-input-p)
      (goto-char kargu-chat--prompt-marker)
    (beginning-of-line)))

(defun kargu-chat--input-text ()
  "Return the current prompt input, or the empty string."
  (let ((buffer (kargu-chat--target-buffer)))
    (cond
     ((not (buffer-live-p buffer)) "")
     (t
      (with-current-buffer buffer
        (if (kargu-chat--prompt-live-p)
            (string-trim-right
             (buffer-substring-no-properties
              kargu-chat--prompt-marker (point-max)))
          ""))))))

(defun kargu-chat--consume-input ()
  "Return the prompt input and delete the prompt block."
  (let ((buffer (kargu-chat--target-buffer)))
    (unless (buffer-live-p buffer)
      (error "kargu: no chat buffer"))
    (with-current-buffer buffer
      (unless (kargu-chat--prompt-live-p)
        (kargu-chat--ensure-prompt))
      (let* ((inhibit-read-only t)
             (text (string-trim-right
                    (buffer-substring-no-properties
                     kargu-chat--prompt-marker (point-max)))))
        (delete-region kargu-chat--output-marker (point-max))
        (set-marker kargu-chat--prompt-marker nil)
        text))))

(provide 'kargu/chat/prompt)

;;; kargu/chat/prompt.el ends here
