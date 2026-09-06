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
(require 'kargu/loop)

(declare-function kargu-chat-stop "kargu/chat")
(declare-function kargu-chat-select-provider-company "kargu/api")
(declare-function kargu-chat-select-model-company "kargu/api")
(declare-function kargu-chat-select-effort-company "kargu/api")
(declare-function kargu--provider-name "kargu/api")
(declare-function kargu--model "kargu/api")
(declare-function kargu-model-context-window "kargu/api" (&optional model-id))
(defvar kargu-reasoning-effort)

(defconst kargu-chat-buffer-name "*kargu-chat*"
  "Name of the kargu chat log buffer.")

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

(defun kargu-chat--footer-string ()
  "Build the interactive footer line shown at the bottom of the chat buffer.
Contains clickable provider, model, context, and effort buttons."
  (let* ((pname (if (fboundp 'kargu--provider-name) (kargu--provider-name) "default"))
         (mname (if (fboundp 'kargu--model) (kargu--model) "model"))
         (ctx (if (fboundp 'kargu-model-context-window) (kargu-model-context-window mname) 128000))
         (ctx-str (if (>= ctx 1000000)
                      (format "%dm" (/ ctx 1000000))
                    (format "%dk" (/ ctx 1000))))
         (effort (if (boundp 'kargu-reasoning-effort) (or kargu-reasoning-effort "off") "off"))
         (p-map (make-sparse-keymap))
         (m-map (make-sparse-keymap))
         (e-map (make-sparse-keymap)))
    (define-key p-map [mouse-1] (lambda (e) (interactive "e") (kargu-chat-select-provider-company e)))
    (define-key p-map [mouse-2] (lambda (e) (interactive "e") (kargu-chat-select-provider-company e)))
    (define-key p-map (kbd "RET") (lambda () (interactive) (kargu-chat-select-provider-company)))

    (define-key m-map [mouse-1] (lambda (e) (interactive "e") (kargu-chat-select-model-company nil nil nil e)))
    (define-key m-map [mouse-2] (lambda (e) (interactive "e") (kargu-chat-select-model-company nil nil nil e)))
    (define-key m-map (kbd "RET") (lambda () (interactive) (kargu-chat-select-model-company)))

    (define-key e-map [mouse-1] (lambda (e) (interactive "e") (kargu-chat-select-effort-company e)))
    (define-key e-map [mouse-2] (lambda (e) (interactive "e") (kargu-chat-select-effort-company e)))
    (define-key e-map (kbd "RET") (lambda () (interactive) (kargu-chat-select-effort-company)))

    (let ((p-btn (propertize (format "[%s]" pname)
                             'face 'font-lock-type-face
                             'mouse-face 'highlight
                             'help-echo "mouse-1 or RET: switch provider (company list)"
                             'keymap p-map
                             'local-map p-map
                             'button t
                             'action (lambda (_) (kargu-chat-select-provider-company))))
          (m-btn (propertize (format "[%s (%s ctx)]" mname ctx-str)
                             'face 'font-lock-string-face
                             'mouse-face 'highlight
                             'help-echo "mouse-1 or RET: select model (company list)"
                             'keymap m-map
                             'local-map m-map
                             'button t
                             'action (lambda (_) (kargu-chat-select-model-company))))
          (e-btn (propertize (format "[%s]" effort)
                             'face 'font-lock-keyword-face
                             'mouse-face 'highlight
                             'help-echo "mouse-1 or RET: select reasoning effort (company list)"
                             'keymap e-map
                             'local-map e-map
                             'button t
                             'action (lambda (_) (kargu-chat-select-effort-company)))))
      (propertize
       (concat (propertize "provider: " 'face 'font-lock-comment-face)
               p-btn
               "  "
               (propertize "model: " 'face 'font-lock-comment-face)
               m-btn
               "  "
               (propertize "effort: " 'face 'font-lock-comment-face)
               e-btn
               "\n")
       'field 'prompt
       'read-only t
       'front-sticky t
       'rear-nonsticky '(read-only face field front-sticky)))))

(defun kargu-chat-refresh-footer ()
  "Refresh the footer line at the bottom of the chat buffer in-place."
  (let ((buf (or (and (markerp kargu-chat--output-marker)
                      (marker-position kargu-chat--output-marker)
                      (current-buffer))
                 (get-buffer kargu-chat-buffer-name))))
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

(defun kargu-chat--goto-footer-field (field)
  "Move point to FIELD (\\='provider, \\='model, or \\='effort) in footer.
Return point if found, or nil."
  (let ((buf (or (and (markerp kargu-chat--output-marker)
                      (marker-position kargu-chat--output-marker)
                      (current-buffer))
                 (get-buffer kargu-chat-buffer-name))))
    (when buf
      (with-current-buffer buf
        (let ((win (get-buffer-window buf)))
          (when win (select-window win)))
        (when (and (markerp kargu-chat--output-marker)
                   (marker-position kargu-chat--output-marker))
          (goto-char (marker-position kargu-chat--output-marker))
          (let ((pat (cl-case field
                       (provider "provider: [")
                       (model "model: [")
                       (effort "effort: [")
                       (t "provider: ["))))
            (when (search-forward pat (and (markerp kargu-chat--prompt-marker)
                                           (marker-position kargu-chat--prompt-marker))
                                  t)
              (point))))))))

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

(defun kargu-chat--ensure-idle-prompt ()
  "Make sure the chat buffer ends with an editable `kargu> ' prompt."
  (let ((buffer (or (and (derived-mode-p 'kargu-chat-mode) (current-buffer))
                    (get-buffer kargu-chat-buffer-name))))
    (when buffer
      (with-current-buffer buffer
        ;; Remove leftover running indicator if present
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
              (setq kargu-chat--output-marker (copy-marker start t)))))))))

(defun kargu-chat--ensure-running-prompt ()
  "Render a read-only running banner with a clickable [Stop] button."
  (let ((buffer (get-buffer kargu-chat-buffer-name)))
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
  (let ((buffer (get-buffer kargu-chat-buffer-name)))
    (if (not buffer)
        ""
      (with-current-buffer buffer
        (if (not (kargu-chat--prompt-live-p))
            ""
          (string-trim-right
           (buffer-substring-no-properties
            kargu-chat--prompt-marker (point-max))))))))

(defun kargu-chat--consume-input ()
  "Return the prompt input and delete the prompt block."
  (with-current-buffer (get-buffer kargu-chat-buffer-name)
    (unless (kargu-chat--prompt-live-p)
      (kargu-chat--ensure-prompt))
    (let* ((inhibit-read-only t)
           (text (string-trim-right
                  (buffer-substring-no-properties
                   kargu-chat--prompt-marker (point-max)))))
      (delete-region kargu-chat--output-marker (point-max))
      (set-marker kargu-chat--prompt-marker nil)
      text)))

(provide 'kargu/chat/prompt)

;;; kargu/chat/prompt.el ends here
