;;; session.el --- Session state and usage counters -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Session state plist, usage counters, and session-reset.
;; Separated from `kargu/core' for single-responsibility.
;; Public: `kargu-session-id', `kargu-session-context-info',
;; `kargu-session-usage', `kargu-session-reset'.

;;; Code:

(require 'kargu/core/log)

(autoload 'kargu-session-reset "kargu/application/reset" nil t)
(declare-function kargu-model-context-window "kargu/api/catalog" (&optional model-id provider))

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

(defun kargu-session-record-cache-usage (input read write)
  "Accumulate reported cache INPUT, READ and WRITE counters only when known."
  (dolist (entry (list (cons :cache-read read) (cons :cache-write write)))
    (when (natnump (cdr entry))
      (plist-put kargu--session (car entry)
                 (+ (or (plist-get kargu--session (car entry)) 0) (cdr entry)))))
  (when (and (natnump read) (natnump input))
    (plist-put kargu--session :cache-measured-read
               (+ (or (plist-get kargu--session :cache-measured-read) 0) read))
    (plist-put kargu--session :cache-measured-input
               (+ (or (plist-get kargu--session :cache-measured-input) 0) input))))

(defun kargu-session--cache-report ()
  "Return observed cache counters, distinguishing missing data from zero."
  (let ((input (plist-get kargu--session :cache-measured-input)))
    (format "  cache-read: %s  cache-write: %s  measured-hit: %s"
            (or (plist-get kargu--session :cache-read) "unknown")
            (or (plist-get kargu--session :cache-write) "unknown")
            (if (and (numberp input) (> input 0))
                (format "%.1f%%" (/ (* 100.0 (plist-get kargu--session :cache-measured-read)) input))
              "unknown"))))

(defun kargu-session--count-label (n)
  "Short label for token count N."
  (if (>= n 1000)
      (format "%.1fk" (/ (float n) 1000))
    (format "%d" n)))

(defun kargu-session--capacity ()
  "Context-window size of the active model, or nil when unknown."
  (let ((cap (and (fboundp 'kargu-model-context-window)
                  (kargu-model-context-window))))
    (and (numberp cap) (> cap 0) cap)))

(defun kargu-session--capacity-label (cap)
  "Short label for context capacity CAP."
  (if (>= cap 1000000)
      (format "%dm" (/ cap 1000000))
    (format "%dk" (/ cap 1000))))

(defun kargu-session-context-info ()
  "Return a plist (:used TOKENS :capacity CAP :percent PCT :formatted STR).
CAP is nil when the model record has no context window."
  (let* ((in (or (plist-get kargu--session :last-prompt-tokens)
                 (plist-get kargu--session :tokens-in)
                 0))
         (cap (kargu-session--capacity))
         (pct (if cap (/ (* 100 in) cap) nil))
         (in-str (kargu-session--count-label in)))
    (list :used in
          :capacity cap
          :percent pct
          :formatted (if cap
                         (format "%s/%s (%d%%)"
                                 in-str
                                 (kargu-session--capacity-label cap)
                                 pct)
                       in-str))))

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
    (setq report (concat report (kargu-session--cache-report)))
    (when (called-interactively-p 'any)
      (message "kargu %s" report))
    report))

(defvar kargu-session-reset-hook nil
  "Optional view notifications after the application finishes a session reset.")

(defun kargu-session-clear ()
  "Replace only session-owned counters and explicit selection overrides."
  (setq kargu--session-id (kargu--generate-session-id))
  (setq kargu--session
        (list :active nil
              :id kargu--session-id
              :requests 0
              :tokens-in 0
              :tokens-out 0
              :last-prompt-tokens 0
              :started (format-time-string "%Y-%m-%d %H:%M")))
  (setq kargu--session-provider nil
        kargu--session-model nil))

(provide 'kargu/core/session)

;;; session.el ends here
