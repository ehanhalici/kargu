;;; core.el --- Slim core: helpers, mode, env -*- lexical-binding: t; -*-

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
;; `kargu-toggle-wire-log'.

;;; Code:

(require 'cl-lib)
(require 'kargu/core/data)

(require 'kargu/contract/constants)
(require 'kargu/contract)
(require 'kargu/state)
(require 'kargu/core/custom)
(require 'kargu/core/log)
(require 'kargu/core/session)

;;;; Mode state -----------------------------------------------------------

(defvar kargu-mode-prepare-functions nil
  "Alist of modes to asynchronous preparation functions taking a continuation.")
(defvar kargu--mode-selection-generation 0
  "Generation used to discard an obsolete asynchronous mode selection.")

(defun kargu--publish-mode (mode)
  "Publish MODE to chat footers and the mode line."
  (kargu-log 'info "mode set to `%s'" mode)
  (dolist (buf (buffer-list))
    (when (and (buffer-live-p buf)
               (with-current-buffer buf (derived-mode-p 'kargu-chat-mode)))
      (with-current-buffer buf
        (when (fboundp 'kargu-chat-refresh-footer)
          (kargu-chat-refresh-footer)))))
  (force-mode-line-update t)
  (message "kargu mode: %s" mode))

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
    (user-error "Kargu: Stop the active run before changing mode"))
  (let* ((generation (cl-incf kargu--mode-selection-generation))
         (prepare (alist-get mode kargu-mode-prepare-functions))
         (apply-mode
          (lambda ()
            (when (= generation kargu--mode-selection-generation)
              (kargu-state-set-mode mode)
              (kargu--publish-mode mode)
              mode))))
    (if prepare (funcall prepare apply-mode) (funcall apply-mode))))

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

(provide 'kargu/core)

;;; core.el ends here
