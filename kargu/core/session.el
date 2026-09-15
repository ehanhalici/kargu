;;; kargu/core/session.el --- Session state and usage counters -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Session state plist, usage counters, and session-reset.
;; Separated from `kargu/core' for single-responsibility.
;; Public: `kargu-session-id', `kargu-session-context-info',
;; `kargu-session-usage', `kargu-session-reset'.

;;; Code:

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

(require 'kargu/core/log)

(declare-function kargu-history-reset "kargu/history/protocol" ())
(declare-function kargu-circuit-reset "kargu/api/circuit" ())
(declare-function kargu-state-reset "kargu/state/transitions" ())

;;;; Session state --------------------------------------------------------

(defun kargu--generate-session-id ()
  "Generate a unique session identifier string."
  (format "kargu-%s-%06x"
          (format-time-string "%Y%m%d%H%M%S")
          (random #xffffff)))

(defvar-local kargu--session-id nil
  "Buffer-local session identifier.")

(defvar kargu--session
  (list :active nil
        :id (kargu--generate-session-id)
        :requests 0
        :tokens-in 0
        :tokens-out 0
        :last-prompt-tokens 0
        :started (format-time-string "%Y-%m-%d %H:%M"))
  "Session counters, updated by the API module.")

(defun kargu-session-id ()
  "Return the active session identifier, generating one if absent."
  (or (and (bound-and-true-p kargu--session-id) kargu--session-id)
      (let ((sid (plist-get kargu--session :id)))
        (or sid
            (let ((new-id (kargu--generate-session-id)))
              (plist-put kargu--session :id new-id)
              (setq kargu--session-id new-id)
              new-id)))))

(defun kargu-session-record-usage (tokens-in tokens-out)
  "Record TOKENS-IN and TOKENS-OUT in `kargu--session', incrementing request count.
Return the updated `kargu--session' plist."
  (plist-put kargu--session :requests
             (1+ (or (plist-get kargu--session :requests) 0)))
  (when (numberp tokens-in)
    (plist-put kargu--session :last-prompt-tokens tokens-in)
    (plist-put kargu--session :tokens-in
               (+ (or (plist-get kargu--session :tokens-in) 0) tokens-in)))
  (when (numberp tokens-out)
    (plist-put kargu--session :tokens-out
               (+ (or (plist-get kargu--session :tokens-out) 0) tokens-out)))
  kargu--session)

(defun kargu-session-context-info ()
  "Return a plist (:used TOKENS :capacity CAP :percent PCT :formatted STR)."
  (let* ((in (or (plist-get kargu--session :last-prompt-tokens)
                 (plist-get kargu--session :tokens-in)
                 0))
         (cap (if (fboundp 'kargu-model-context-window)
                  (kargu-model-context-window)
                128000))
         (pct (if (> cap 0) (/ (* 100 in) cap) 0))
         (in-str (if (>= in 1000)
                     (format "%.1fk" (/ (float in) 1000))
                   (format "%d" in)))
         (cap-str (if (>= cap 1000000)
                      (format "%dm" (/ cap 1000000))
                    (format "%dk" (/ cap 1000)))))
    (list :used in
          :capacity cap
          :percent pct
          :formatted (format "%s/%s (%d%%)" in-str cap-str pct))))

(defvar kargu--session-provider nil
  "Session override for the active TOML provider name, or nil.")

(defvar kargu--session-model nil
  "Session override for the model id, or nil.")

(defun kargu-session-usage ()
  "Return a short usage report string for the current session."
  (interactive)
  (let* ((ctx-info (kargu-session-context-info))
         (report (format "requests: %d  tokens-in: %d  tokens-out: %d  ctx: %s"
                         (or (plist-get kargu--session :requests) 0)
                         (or (plist-get kargu--session :tokens-in) 0)
                         (or (plist-get kargu--session :tokens-out) 0)
                         (plist-get ctx-info :formatted))))
    (when (called-interactively-p 'any)
      (message "kargu %s" report))
    report))

(defun kargu-session-reset ()
  "Reset session counters, conversation history and agent state."
  (interactive)
  (setq kargu--session-id (kargu--generate-session-id))
  (setq kargu--session
        (list :active nil
              :id kargu--session-id
              :requests 0
              :tokens-in 0
              :tokens-out 0
              :last-prompt-tokens 0
              :started (format-time-string "%Y-%m-%d %H:%M")))
  (when (fboundp 'kargu-history-reset)
    (kargu-history-reset))
  (when (fboundp 'kargu-circuit-reset)
    (kargu-circuit-reset))
  (when (fboundp 'kargu-state-reset)
    (kargu-state-reset))
  (setq kargu--session-provider nil
        kargu--session-model nil)
  (message "kargu session reset"))

(provide 'kargu/core/session)

;;; kargu/core/session.el ends here
