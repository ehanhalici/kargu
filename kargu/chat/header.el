;;; kargu/chat/header.el --- Dynamic header line for chat buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Dynamic header line showing the active mode and stop control.
;; Requires: `kargu/core', `kargu/config'.
;; Public: `kargu-chat--header-string'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/config)
(require 'kargu/state/selectors)

(declare-function kargu-loop-running-p "kargu/loop")
(declare-function kargu-chat-stop "kargu/chat")
(declare-function kargu-chat-select-mode-company "kargu/api" (&optional _event))
(declare-function kargu-deps-missing-p "kargu/tools/deps" (&optional root))

(defun kargu-chat--header-string ()
  "Build the chat buffer's dynamic header line.
Displays the kargu title, active mode, missing tools status, and stop button."
  (let* ((mode-name (upcase (symbol-name (kargu-state-mode))))
         (running (and (fboundp 'kargu-loop-running-p)
                       (kargu-loop-running-p)))
         (missing (and (fboundp 'kargu-deps-missing-p)
                       (kargu-deps-missing-p (bound-and-true-p kargu-chat--project-root))))
         (blocked-indicator
          (when missing
            (concat
             " · "
             (propertize "[TOOLS MISSING]"
                         'face '(:foreground "red" :weight bold)
                         'help-echo "Mandatory tools are missing; prompt submission is blocked."))))
         (mode-map (make-sparse-keymap))
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
    (define-key mode-map [header-line mouse-1] (lambda (e) (interactive "e") (kargu-chat-select-mode-company e)))
    (define-key mode-map [header-line mouse-2] (lambda (e) (interactive "e") (kargu-chat-select-mode-company e)))
    (define-key mode-map [mouse-1] (lambda (e) (interactive "e") (kargu-chat-select-mode-company e)))
    (define-key mode-map [mouse-2] (lambda (e) (interactive "e") (kargu-chat-select-mode-company e)))
    (concat
     (propertize "kargu" 'face 'bold)
     " · "
     (propertize (format "[%s]" mode-name)
                 'face 'bold
                 'mouse-face 'highlight
                 'help-echo "mouse-1: select mode with company (C-c C-x)"
                 'keymap mode-map
                 'local-map mode-map)
     (or blocked-indicator "")
     (or stop-btn ""))))

(provide 'kargu/chat/header)

;;; kargu/chat/header.el ends here
