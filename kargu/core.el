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
(require 'subr-x)
(require 'rx)

(require 'kargu/contract/constants)
(require 'kargu/contract)
(require 'kargu/state)
(require 'kargu/core/custom)
(require 'kargu/core/log)
(require 'kargu/core/session)

;;;; Alist helpers --------------------------------------------------------

(defun kargu-aget (alist key &optional default)
  "Return the value for string KEY in ALIST, or DEFAULT.
Safely handles malformed alists, dotted pairs, and non-list data."
  (if (and (consp alist) (listp (cdr alist)))
      (condition-case nil
          (alist-get key alist default nil #'equal)
        (error default))
    default))

(defun kargu-nonempty (value)
  "VALUE if it is a non-empty string, else nil."
  (and (stringp value) (not (string-empty-p value)) value))

(defalias 'kargu--aget #'kargu-aget)
(defalias 'kargu--nonempty #'kargu-nonempty)

(defun kargu-to-int (value &optional default)
  "Coerce VALUE to an integer, or return DEFAULT (defaults to nil).
Handles integers, floats (rounded), and integer strings."
  (cond
   ((integerp value) value)
   ((floatp value)
    (condition-case nil (round value)
      (arith-error default)))
   ((stringp value)
    (let ((trimmed (string-trim value)))
      (if (string-match-p
           (rx string-start (opt (any "+-")) (+ digit) string-end) trimmed)
          (string-to-number trimmed)
        default)))
   (t default)))

(defun kargu-cap-text (text limit &optional label)
  "TEXT cut to LIMIT characters, with a one-line note when it was cut.
The note names LABEL (default \"text\") and the original length.  A
non-natural LIMIT leaves TEXT alone.  This is the one wording for a cut
that is not the model-bound tool output (see `kargu--truncate-for-model')."
  (if (and (natnump limit) (> (length text) limit))
      (concat (substring text 0 limit)
              (format "\n... [%s truncated: %d of %d chars shown]"
                      (or label "text") limit (length text)))
    text))

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
