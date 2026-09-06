;;; kargu/chat/header.el --- Dynamic header line for chat buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Dynamic header line with clickable mode selection buttons and stop control.
;; Requires: `kargu/core', `kargu/config'.
;; Public: `kargu-chat--make-mode-button', `kargu-chat--header-string'.

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
(require 'kargu/config)

(defvar kargu--loop-run)
(defvar kargu-max-iterations)
(declare-function kargu-loop-running-p "kargu/loop")
(declare-function kargu-busy-p "kargu/core")
(declare-function kargu-chat-stop "kargu/chat")

(defun kargu-chat--make-mode-button (mode)
  "Create a clickable header-line mode button for MODE."
  (let* ((active (eq kargu-active-mode mode))
         (label (if active
                    (format "[%s]" (upcase (symbol-name mode)))
                  (format "[%s]" mode)))
         (map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] (lambda () (interactive) (kargu-set-mode mode)))
    (define-key map [header-line mouse-2] (lambda () (interactive) (kargu-set-mode mode)))
    (define-key map [mouse-1] (lambda () (interactive) (kargu-set-mode mode)))
    (define-key map [mouse-2] (lambda () (interactive) (kargu-set-mode mode)))
    (propertize label
                'face (if active 'bold 'font-lock-keyword-face)
                'mouse-face 'highlight
                'help-echo (format "mouse-1: switch to %s mode" mode)
                'keymap map
                'local-map map
                'kargu-mode mode)))

(declare-function kargu-chat-select-provider-company "kargu/api")
(declare-function kargu-chat-select-model-company "kargu/api")
(declare-function kargu-chat-select-effort-company "kargu/api")
(declare-function kargu-chat-select-provider "kargu/api")
(declare-function kargu-set-model "kargu/api")
(declare-function kargu-tune-menu "kargu/chat/tune")

(defun kargu-chat--make-provider-button ()
  "Create a clickable header-line button for active provider."
  (let* ((pname (if (fboundp 'kargu--provider-name) (kargu--provider-name) "default"))
         (label (format "[%s]" pname))
         (map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] (lambda (e) (interactive "e") (kargu-chat-select-provider-company e)))
    (define-key map [header-line mouse-2] (lambda (e) (interactive "e") (kargu-chat-select-provider-company e)))
    (define-key map [mouse-1] (lambda (e) (interactive "e") (kargu-chat-select-provider-company e)))
    (define-key map [mouse-2] (lambda (e) (interactive "e") (kargu-chat-select-provider-company e)))
    (propertize label
                'face 'font-lock-type-face
                'mouse-face 'highlight
                'help-echo "mouse-1: select provider with company list (C-c C-p)"
                'keymap map
                'local-map map)))

(defun kargu-chat--make-model-button ()
  "Create a clickable header-line button for active model."
  (let* ((mname (if (fboundp 'kargu--model) (kargu--model) "model"))
         (label (format "[%s]" mname))
         (map (make-sparse-keymap)))
    (define-key map [header-line mouse-1] (lambda (e) (interactive "e") (kargu-chat-select-model-company nil nil nil e)))
    (define-key map [header-line mouse-2] (lambda (e) (interactive "e") (kargu-chat-select-model-company nil nil nil e)))
    (define-key map [mouse-1] (lambda (e) (interactive "e") (kargu-chat-select-model-company nil nil nil e)))
    (define-key map [mouse-2] (lambda (e) (interactive "e") (kargu-chat-select-model-company nil nil nil e)))
    (propertize label
                'face 'font-lock-string-face
                'mouse-face 'highlight
                'help-echo "mouse-1: select model with company list (C-c C-m)"
                'keymap map
                'local-map map)))

(defun kargu-chat--make-tune-button ()
  "Create a clickable header-line button for model parameter tuning."
  (let* ((parts nil))
    (when (and (boundp 'kargu-reasoning-effort) kargu-reasoning-effort)
      (push (format "eff:%s" kargu-reasoning-effort) parts))
    (when (and (boundp 'kargu-max-tokens) (integerp kargu-max-tokens) (> kargu-max-tokens 0))
      (push (format "%dk" (/ kargu-max-tokens 1024)) parts))
    (let* ((summary (if parts (string-join (nreverse parts) ",") "effort"))
           (label (format "[%s]" summary))
           (map (make-sparse-keymap)))
      (define-key map [header-line mouse-1] (lambda (e) (interactive "e") (kargu-chat-select-effort-company e)))
      (define-key map [header-line mouse-2] (lambda (e) (interactive "e") (kargu-chat-select-effort-company e)))
      (define-key map [mouse-1] (lambda (e) (interactive "e") (kargu-chat-select-effort-company e)))
      (define-key map [mouse-2] (lambda (e) (interactive "e") (kargu-chat-select-effort-company e)))
      (propertize label
                  'face (if parts 'font-lock-keyword-face 'font-lock-comment-face)
                  'mouse-face 'highlight
                  'help-echo "mouse-1: select reasoning effort (C-c C-o)"
                  'keymap map
                  'local-map map))))

(defun kargu-chat--header-string ()
  "Build the chat buffer's dynamic header line.
Shows clickable mode buttons, provider, model, tune options, run state,
and stop button."
  (let* ((run (and (boundp 'kargu--loop-run)
                   kargu--loop-run))
         (running (and (fboundp 'kargu-loop-running-p)
                       (kargu-loop-running-p)))
         (iterations (and run (or (plist-get run :iterations) 0)))
         (state (cond
                 ((and (fboundp 'kargu-busy-p) (kargu-busy-p)) "thinking")
                 (run "working (tools)")
                 (t "idle")))
         (modes '(ask plan debug agent))
         (mode-buttons (mapconcat #'kargu-chat--make-mode-button modes " "))
         (stop-btn
          (when running
            (let ((map (make-sparse-keymap)))
              (define-key map [header-line mouse-1] (lambda () (interactive) (kargu-chat-stop)))
              (define-key map [header-line mouse-2] (lambda () (interactive) (kargu-chat-stop)))
              (define-key map [mouse-1] (lambda () (interactive) (kargu-chat-stop)))
              (define-key map [mouse-2] (lambda () (interactive) (kargu-chat-stop)))
              (concat
               " "
               (propertize "[STOP]"
                           'face '(:foreground "red" :weight bold)
                           'mouse-face 'highlight
                           'help-echo "mouse-1: stop the agent run"
                           'keymap map
                           'local-map map))))))
    (concat
     (propertize "kargu" 'face 'bold)
     "  "
     mode-buttons
     (or stop-btn "")
     "  · "
     (kargu-chat--make-provider-button)
     " "
     (kargu-chat--make-model-button)
     " "
     (kargu-chat--make-tune-button)
     (propertize (format "  · %s" state)
                 'face (if running 'font-lock-warning-face 'font-lock-comment-face))
     (and run
          (propertize
           (format "  · turn %d/%d"
                   iterations
                   (if (boundp 'kargu-max-iterations) kargu-max-iterations 25))
           'face 'font-lock-comment-face)))))

(provide 'kargu/chat/header)

;;; kargu/chat/header.el ends here
