;;; session.el --- Session state and usage counters -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Buffer-owned session handles, usage counters, and session-reset.
;; Separated from `kargu/core' for single-responsibility.
;; Public: `kargu-session-id', `kargu-session-context-info',
;; `kargu-session-usage', `kargu-session-reset'.

;;; Code:

(require 'cl-lib)
(require 'kargu/core/log)
(require 'kargu/contract/assert)
(require 'kargu/contract/history)

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

(cl-defstruct (kargu-session (:constructor kargu-session--create))
  "One captured session ID owning its usage counters, not a runtime singleton."
  (id-value nil :read-only t) usage-value
  (history-value (kargu-history-create) :read-only t))

(defvar-local kargu-session--context nil
  "The current buffer's owned session handle; callbacks capture it explicitly.")

(defun kargu-session--validate-usage (usage)
  "Return validated USAGE before adopting it into a session owner."
  (unless (and (proper-list-p usage) usage (cl-evenp (length usage)))
    (error "Session usage must be a nonempty property list"))
  (dolist (key '(:requests :tokens-in :tokens-out :last-prompt-tokens
                 :cache-read :cache-write :cache-measured-read :cache-measured-input))
    (kargu-contract-assert
     (lambda (value) (or (null value) (natnump value))) (plist-get usage key)))
  (kargu-contract-assert #'booleanp (plist-get usage :active))
  (kargu-contract-assert (lambda (value) (or (null value) (stringp value)))
                         (plist-get usage :started))
  usage)

(cl-defun kargu-session-create (&key id-value usage-value)
  "Create an owner for ID-VALUE after validating and copying USAGE-VALUE."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p id-value)
  (kargu-session--validate-usage usage-value)
  (kargu-session--create :id-value (copy-sequence id-value)
                         :usage-value (copy-tree usage-value)))

(defun kargu-session--initial-usage ()
  "Return fresh usage fields without duplicating the session identity."
  (list :active nil :requests 0 :tokens-in 0 :tokens-out 0
        :last-prompt-tokens 0 :started (format-time-string "%Y-%m-%d %H:%M")))

(defun kargu-session-context (&optional buffer)
  "Return BUFFER's owned session, creating it lazily; default to current."
  (let ((buffer (or buffer (current-buffer))))
    (kargu-contract-assert #'buffer-live-p buffer)
    (with-current-buffer buffer
      (unless kargu--session-id
        (setq kargu--session-id
              (or (and kargu-session--context
                       (kargu-session-id-value kargu-session--context))
                  (kargu--generate-session-id))))
      (unless (and kargu-session--context
                   (equal kargu--session-id
                          (kargu-session-id-value kargu-session--context)))
        (setq kargu-session--context
              (kargu-session--create :id-value kargu--session-id
                                    :usage-value (kargu-session--initial-usage))))
      kargu-session--context)))

(defun kargu-session--resolve (session)
  "Return valid SESSION, or resolve the current boundary owner when nil."
  (let ((session (or session (kargu-session-context))))
    (kargu-contract-assert #'kargu-session-p session)
    session))

(defun kargu-session-id (&optional session)
  "Return the identity of explicit SESSION, or the current buffer's owner."
  (kargu-session-id-value (kargu-session--resolve session)))

(defun kargu-session-snapshot (&optional session)
  "Return a fresh usage/identity plist for SESSION or the current owner.
Nested scalar strings are borrowed read-only values."
  (let ((session (kargu-session--resolve session)))
    (cons :id (cons (kargu-session-id-value session)
                    (copy-tree (kargu-session-usage-value session))))))

(defun kargu-session-mark-active (active &optional session)
  "Set explicit SESSION's ACTIVE flag; default to the current boundary owner."
  (kargu-contract-assert #'booleanp active)
  (let ((session (kargu-session--resolve session)))
    (setf (kargu-session-usage-value session)
          (plist-put (kargu-session-usage-value session) :active active))))

(defun kargu-session-replace-usage (usage)
  "Replace the current owner's validated USAGE with an isolated session handle."
  (kargu-session--validate-usage usage)
  (when (plist-get (kargu-session-usage-value (kargu-session-context)) :active)
    (user-error "Kargu: stop the session's active run before replacing its counters"))
  (setq kargu-session--context
        (kargu-session--create
         :id-value (kargu-session-id) :usage-value (copy-tree usage)
         :history-value (kargu-session-history-value (kargu-session-context)))))

(defun kargu-session-record-usage (tokens-in tokens-out &optional session)
  "Add TOKENS-IN and TOKENS-OUT to SESSION, or the current boundary owner."
  (dolist (count (list tokens-in tokens-out))
    (kargu-contract-assert (lambda (value) (or (null value) (natnump value))) count))
  (let* ((session (kargu-session--resolve session))
         (usage (kargu-session-usage-value session)))
    (plist-put usage :requests (1+ (or (plist-get usage :requests) 0)))
    (when tokens-in
      (plist-put usage :last-prompt-tokens tokens-in)
      (plist-put usage :tokens-in (+ (or (plist-get usage :tokens-in) 0) tokens-in)))
    (when tokens-out
      (plist-put usage :tokens-out (+ (or (plist-get usage :tokens-out) 0) tokens-out)))
    (kargu-session-snapshot session)))

(cl-defun kargu-session-record-cache-usage (input read write &key session)
  "Accumulate known cache INPUT, READ and WRITE counters for explicit SESSION."
  (let ((usage (kargu-session-usage-value (kargu-session--resolve session))))
    (dolist (entry (list (cons :cache-read read) (cons :cache-write write)))
      (when (natnump (cdr entry))
        (plist-put usage (car entry)
                   (+ (or (plist-get usage (car entry)) 0) (cdr entry)))))
    (when (and (natnump read) (natnump input))
      (plist-put usage :cache-measured-read
                 (+ (or (plist-get usage :cache-measured-read) 0) read))
      (plist-put usage :cache-measured-input
                 (+ (or (plist-get usage :cache-measured-input) 0) input)))))

(defun kargu-session--cache-report (session)
  "Return SESSION cache counters, distinguishing missing data from zero."
  (let* ((usage (kargu-session-usage-value session))
         (input (plist-get usage :cache-measured-input)))
    (format "  cache-read: %s  cache-write: %s  measured-hit: %s"
            (or (plist-get usage :cache-read) "unknown")
            (or (plist-get usage :cache-write) "unknown")
            (if (and (numberp input) (> input 0))
                (format "%.1f%%" (/ (* 100.0 (plist-get usage :cache-measured-read)) input))
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

(defun kargu-session-context-info (&optional session)
  "Return context usage for SESSION, defaulting to the current boundary owner.
CAP is nil when the model record has no context window."
  (let* ((usage (kargu-session-usage-value (kargu-session--resolve session)))
         (in (or (plist-get usage :last-prompt-tokens)
                 (plist-get usage :tokens-in)
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

(defun kargu-session-usage (&optional session)
  "Return a short usage report for SESSION, defaulting to the current owner."
  (interactive)
  (let* ((session (kargu-session--resolve session))
         (usage (kargu-session-usage-value session))
         (ctx-info (kargu-session-context-info session))
         (report (format "requests: %d  tokens-in: %d  tokens-out: %d  ctx: %s"
                         (or (plist-get usage :requests) 0)
                         (or (plist-get usage :tokens-in) 0)
                         (or (plist-get usage :tokens-out) 0)
                         (plist-get ctx-info :formatted))))
    (setq report (concat report (kargu-session--cache-report session)))
    (when (called-interactively-p 'any)
      (message "kargu %s" report))
    report))

(defvar kargu-session-reset-hook nil
  "Optional view notifications after the application finishes a session reset.")

(defun kargu-session-clear ()
  "Replace the current owner's counters and clear explicit selection overrides."
  (when (plist-get (kargu-session-usage-value (kargu-session-context)) :active)
    (user-error "Kargu: stop the session's active run before clearing it"))
  (setq kargu--session-id (kargu--generate-session-id)
        kargu-session--context
        (kargu-session--create :id-value kargu--session-id
                              :usage-value (kargu-session--initial-usage)))
  (setq kargu--session-provider nil kargu--session-model nil))

(provide 'kargu/core/session)

;;; session.el ends here
