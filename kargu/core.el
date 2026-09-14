;;; kargu/core.el --- Slim core: helpers, mode, env -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Package root on `load-path' (walk up to `kargu.el'), shared
;; settings, session counters, and the log buffer.  Every other
;; kargu file requires this, not `kargu' itself.
;;
;; Sub-modules:
;; - `kargu/core/custom': all `defcustom' declarations
;; - `kargu/core/log': logging engine and wire-log
;; - `kargu/core/session': session state and counters
;;
;; Public: `kargu-set-mode', `kargu-session-usage',
;; `kargu-session-reset', `kargu-log', `kargu-show-log',
;; `kargu-toggle-wire-log', `kargu-notify'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

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

(require 'kargu/constants)
(require 'kargu/contract)
(require 'kargu/state)
(require 'kargu/core/custom)
(require 'kargu/core/log)
(require 'kargu/core/session)

;;;; Alist helpers --------------------------------------------------------

(defun kargu--aget (alist key &optional default)
  "Return the value for string KEY in ALIST, or DEFAULT.
Safely handles malformed alists, dotted pairs, and non-list data."
  (if (and (consp alist) (listp (cdr alist)))
      (condition-case nil
          (alist-get key alist default nil #'equal)
        (error default))
    default))

(defun kargu--nonempty (value)
  "VALUE if it is a non-empty string, else nil."
  (and (stringp value) (not (string-empty-p value)) value))

;;;; Mode state -----------------------------------------------------------

(defvar kargu-active-mode 'ask
  "Current operating mode: one of `ask', `plan', `debug', `agent'.")

(defun kargu-set-mode (mode)
  "Set the active mode to MODE (`ask', `plan', `debug' or `agent')."
  (interactive
   (list (intern (completing-read "kargu mode: "
                                  '("ask" "plan" "debug" "agent")
                                  nil t))))
  (kargu-contract-assert #'kargu-contract-mode-p mode
                         "Unknown kargu mode: %s (expected one of %s)"
                         mode kargu-all-modes)
  (when (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
    (user-error "kargu: cannot change mode while an agent run is in progress (M-x kargu-loop-stop)"))
  (kargu-state-set-mode mode)
  (kargu-log 'info "mode set to `%s'" mode)
  (dolist (buf (buffer-list))
    (when (and (buffer-live-p buf)
               (with-current-buffer buf (derived-mode-p 'kargu-chat-mode)))
      (with-current-buffer buf
        (when (fboundp 'kargu-chat-refresh-footer)
          (kargu-chat-refresh-footer)))))
  (force-mode-line-update t)
  (message "kargu mode: %s" mode)
  mode)

(defun kargu-mode-ask ()
  "Switch kargu to ask mode (read-only answers)."
  (interactive)
  (kargu-set-mode 'ask))

(defun kargu-mode-debug ()
  "Switch kargu to debug mode (live DAP evidence, no edits)."
  (interactive)
  (kargu-set-mode 'debug))

(defun kargu-mode-agent ()
  "Switch kargu to agent mode (autonomous edits)."
  (interactive)
  (kargu-set-mode 'agent))

(defun kargu-mode-plan ()
  "Switch kargu to plan mode (read-only plan)."
  (interactive)
  (kargu-set-mode 'plan))

(defvar kargu-context-buffer)

(defun kargu--context-file-name ()
  "File name of `kargu-context-buffer', or nil."
  (cond
   ((and (boundp 'kargu-context-buffer)
         (bufferp kargu-context-buffer)
         (buffer-live-p kargu-context-buffer))
    (or (buffer-file-name kargu-context-buffer)
        (buffer-name kargu-context-buffer)))
   ((and (boundp 'kargu-context-buffer)
         (stringp kargu-context-buffer)
         (not (string-empty-p kargu-context-buffer)))
    kargu-context-buffer)
   (t nil)))

(defun kargu--os-description ()
  "Short OS / CPU string for the environment block."
  (format "%s (%s)"
          (pcase system-type
            ('gnu/linux "linux")
            ('darwin "darwin")
            ('windows-nt "windows")
            (sym (symbol-name sym)))
          (car (split-string system-configuration "-"))))

(defun kargu--shell-description ()
  "Login shell path for the environment block."
  (or (getenv "SHELL")
      (and (boundp 'shell-file-name) shell-file-name)
      "unknown"))

(defun kargu-notify (&optional _event)
  "Play an audio alert for _EVENT (`permission', `pause', `finish', `error')."
  (when (and (boundp 'kargu-sound-notifications) kargu-sound-notifications)
    (ignore-errors
      (ding t))))

(provide 'kargu/core)

;;; kargu/core.el ends here

