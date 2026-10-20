;;; header.el --- Dynamic header line for chat buffer -*- lexical-binding: t; -*-

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
(declare-function kargu-chat-select-mode-company "kargu/api/select" (&optional _event))
(declare-function kargu-deps-missing-p "kargu/tools/deps" (&optional root))
(declare-function kargu-chat-list-buffers "kargu/chat" ())
(declare-function kargu-chat-refresh-footer "kargu/chat/prompt" ())

(defun kargu-chat-refresh-mode (_mode)
  "Refresh each chat's mode view after a committed state notification."
  (dolist (buffer (kargu-chat-list-buffers))
    (condition-case err
        (with-current-buffer buffer
          (save-excursion
            (save-restriction
              (widen)
              (kargu-chat-refresh-footer))))
      (error (kargu-log 'warn "Mode view %s failed: %s"
                        (buffer-name buffer) (error-message-string err))))))

(defun kargu/chat/header-unload-function ()
  "Remove the optional mode view subscription before unloading it."
  (remove-hook 'kargu-state-mode-hook #'kargu-chat-refresh-mode)
  nil)

(defun kargu-chat--header-action-map (command)
  "Return a header and mouse keymap invoking COMMAND."
  (let ((map (make-sparse-keymap)))
    (dolist (key '("<header-line> <mouse-1>" "<header-line> <mouse-2>"
                   "<mouse-1>" "<mouse-2>"))
      (keymap-set map key command))
    map))

(defun kargu-chat--header-stop-button ()
  "Return the stop button while an agent run is active."
  (when (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
    (let ((map (kargu-chat--header-action-map #'kargu-chat-stop)))
      (concat " " (propertize "[STOP]"
                              'face '(:foreground "red" :weight bold)
                              'mouse-face 'highlight
                              'help-echo "mouse-1: stop the agent run"
                              'keymap map 'local-map map)))))

(defun kargu-chat--header-string ()
  "Build the chat header with mode, missing tools and stop controls."
  (let ((mode-map (kargu-chat--header-action-map #'kargu-chat-select-mode-company))
        (missing (and (fboundp 'kargu-deps-missing-p)
                      (kargu-deps-missing-p
                       (bound-and-true-p kargu-chat--project-root)))))
    (concat
     (propertize "kargu" 'face 'bold) " · "
     (propertize (format "[%s]" (upcase (symbol-name (kargu-state-mode))))
                 'face 'bold 'mouse-face 'highlight
                 'help-echo "mouse-1: select mode with company (C-c C-x)"
                 'keymap mode-map 'local-map mode-map)
     (when missing
       (concat " · "
               (propertize "[TOOLS MISSING]"
                           'face '(:foreground "red" :weight bold)
                           'help-echo "Mandatory tools are missing; prompt submission is blocked.")))
     (kargu-chat--header-stop-button))))

(provide 'kargu/chat/header)

;;; header.el ends here
