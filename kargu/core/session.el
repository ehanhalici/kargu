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
(require 'kargu/contract/types)
(require 'kargu/contract/history)
(require 'kargu/contract/selection)

(autoload 'kargu-session-reset "kargu/application/reset" nil t)
(declare-function kargu-model-context-window "kargu/api/catalog" (&optional model-id provider))
(declare-function kargu-run-budget-p "kargu/application/budget" (budget))
(declare-function kargu-run-budget-requests-spent "kargu/application/budget" (budget))
(declare-function kargu-run-budget-compactions-spent "kargu/application/budget" (budget))
(declare-function kargu-run-budget-tokens-spent "kargu/application/budget" (budget))
(declare-function kargu-run-budget-tokens-unknown-p "kargu/application/budget" (budget))
(declare-function kargu-run-budget-monetary-spent "kargu/application/budget" (budget))
(declare-function kargu-run-budget-monetary-reserved "kargu/application/budget" (budget))
(declare-function kargu-run-budget-monetary-unknown-p "kargu/application/budget" (budget))

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
  (mode-value 'ask) (mode-revision 0) mode-tools mode-request
  (history-value (kargu-history-create) :read-only t)
  (native-conversations (make-hash-table :test #'eq) :read-only t)
  native-retired
  (selection-value (kargu-selection-create))
  selection-queue selection-pending)

(defvar-local kargu-session--context nil
  "The current buffer's owned session handle; callbacks capture it explicitly.")

(defvar kargu-session-before-replace-hook nil
  "Critical resource cleanup functions taking the retiring session handle.")

(defun kargu-session-retire (session)
  "Release SESSION's resources, refusing a reentrant replacement."
  (run-hook-with-args 'kargu-session-before-replace-hook session)
  (unless (eq session (kargu-session-context))
    (user-error "Kargu: session replacement was superseded"))
  (when (plist-get (kargu-session-usage-value session) :active)
    (user-error "Kargu: session retirement was superseded by active work")))

(defun kargu-session--validate-usage (usage)
  "Return validated USAGE before adopting it into a session owner."
  (unless (and (proper-list-p usage) usage (cl-evenp (length usage)))
    (error "Session usage must be a nonempty property list"))
  (dolist (key '(:requests :tokens-in :tokens-out :last-prompt-tokens
                 :cache-read :cache-write :cache-measured-read :cache-measured-input
                 :requests-spent :tokens-spent :monetary-spent :monetary-reserved :compactions-spent))
    (kargu-contract-assert
     (lambda (value) (or (null value) (natnump value))) (plist-get usage key)))
  (kargu-contract-assert #'booleanp (plist-get usage :active))
  (kargu-contract-assert (lambda (value) (or (null value) (stringp value)))
                         (plist-get usage :started))
  (kargu-contract-assert (lambda (value) (or (null value) (booleanp value)))
                         (plist-get usage :tokens-unknown))
  (kargu-contract-assert (lambda (value) (or (null value) (booleanp value)))
                         (plist-get usage :monetary-unknown))
  usage)

(cl-defun kargu-session-create (&key id-value usage-value (mode-value 'ask))
  "Create ID-VALUE's owner with USAGE-VALUE and MODE-VALUE.
Its selection starts uncommitted; only a native commit may set it."
  (kargu-contract-assert #'kargu-contract-non-empty-string-p id-value)
  (kargu-session--validate-usage usage-value)
  (kargu-contract-assert #'kargu-contract-mode-p mode-value)
  (kargu-session--create :id-value (copy-sequence id-value)
                         :usage-value (copy-tree usage-value)
                         :mode-value mode-value))

(defun kargu-session--initial-usage ()
  "Return fresh usage fields without duplicating the session identity."
  (list :active nil :requests 0 :tokens-in 0 :tokens-out 0
        :last-prompt-tokens 0 :started (format-time-string "%Y-%m-%d %H:%M")
        :requests-spent 0 :tokens-spent 0 :tokens-unknown nil
        :monetary-spent 0 :monetary-reserved 0 :monetary-unknown t :compactions-spent 0))

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
  "Replace the current owner's validated USAGE with an isolated session handle.
The replacement keeps mode and history; its selection starts uncommitted
because only the native conversation commits a selection."
  (kargu-session--validate-usage usage)
  (when (plist-get (kargu-session-usage-value (kargu-session-context)) :active)
    (user-error "Kargu: stop the session's active run before replacing its counters"))
  (kargu-session-retire (kargu-session-context))
  (setq kargu-session--context
        (kargu-session--create
         :id-value (kargu-session-id) :usage-value (copy-tree usage)
         :mode-value (kargu-session-mode-value (kargu-session-context))
         :history-value (kargu-session-history-value (kargu-session-context)))))

(defun kargu-session-project-budget (snapshot &optional session)
  "Install detached native SNAPSHOT counters into SESSION or current owner.
Monotonically advances requests, compactions, tokens and monetary spend.
An older reply or smaller counter cannot decrement session counters."
  (let* ((session (kargu-session--resolve session))
         (usage (copy-sequence (kargu-session-usage-value session)))
         (snap (cond ((hash-table-p snapshot) snapshot)
                     ((and (fboundp 'kargu-run-budget-p) (kargu-run-budget-p snapshot))
                      (let ((ht (make-hash-table :test #'equal)))
                        (puthash "requests_spent" (kargu-run-budget-requests-spent snapshot) ht)
                        (puthash "compactions_spent" (kargu-run-budget-compactions-spent snapshot) ht)
                        (puthash "tokens_spent" (kargu-run-budget-tokens-spent snapshot) ht)
                        (puthash "tokens_unknown" (if (kargu-run-budget-tokens-unknown-p snapshot) t :json-false) ht)
                        (puthash "monetary_spent" (or (kargu-run-budget-monetary-spent snapshot) 0) ht)
                        (puthash "monetary_reserved" (or (kargu-run-budget-monetary-reserved snapshot) 0) ht)
                        (puthash "monetary_unknown" (if (kargu-run-budget-monetary-unknown-p snapshot) t :json-false) ht)
                        ht))
                     ((listp snapshot)
                      (let ((ht (make-hash-table :test #'equal)))
                        (dolist (key '("requests_spent" "compactions_spent" "tokens_spent"
                                       "tokens_unknown" "monetary_spent" "monetary_reserved" "monetary_unknown" "budget_id"))
                          (let ((val (or (and (fboundp 'kargu-aget) (kargu-aget snapshot key))
                                         (plist-get snapshot (intern (concat ":" (replace-regexp-in-string "_" "-" key)))))))
                            (when val (puthash key val ht))))
                        ht))
                     (t (error "Invalid native budget projection: %S" snapshot))))
         (reqs (gethash "requests_spent" snap))
         (tokens (gethash "tokens_spent" snap))
         (compactions (gethash "compactions_spent" snap))
         (monetary (gethash "monetary_spent" snap))
         (reserved (gethash "monetary_reserved" snap))
         (tokens-unk (gethash "tokens_unknown" snap))
         (monetary-unk (gethash "monetary_unknown" snap))
         (bid (gethash "budget_id" snap)))
    (unless (or (null reqs) (natnump reqs))
      (error "Requests_spent must be a non-negative integer"))
    (unless (or (null tokens) (natnump tokens))
      (error "Tokens_spent must be a non-negative integer"))
    (unless (or (null compactions) (natnump compactions))
      (error "Compactions_spent must be a non-negative integer"))
    (unless (or (null monetary) (natnump monetary))
      (error "Monetary_spent must be a non-negative integer"))
    (unless (or (null reserved) (natnump reserved))
      (error "Monetary_reserved must be a non-negative integer"))
    (when reqs
      (let ((cur (or (plist-get usage :requests-spent) (plist-get usage :requests) 0)))
        (setq usage (plist-put usage :requests-spent (max cur reqs)))
        (setq usage (plist-put usage :requests (max cur reqs)))))
    (when compactions
      (let ((cur (or (plist-get usage :compactions-spent) 0)))
        (setq usage (plist-put usage :compactions-spent (max cur compactions)))))
    (when tokens
      (let ((cur (or (plist-get usage :tokens-spent)
                     (+ (or (plist-get usage :tokens-in) 0) (or (plist-get usage :tokens-out) 0)))))
        (setq usage (plist-put usage :tokens-spent (max cur tokens)))))
    (when monetary
      (let ((cur (or (plist-get usage :monetary-spent) 0)))
        (setq usage (plist-put usage :monetary-spent (max cur monetary)))))
    (when reserved
      (setq usage (plist-put usage :monetary-reserved reserved)))
    (when (or (eq tokens-unk t) (plist-get usage :tokens-unknown))
      (setq usage (plist-put usage :tokens-unknown t)))
    (when (or (eq monetary-unk t)
              (and (not (eq monetary-unk :json-false)) (not (null monetary-unk)))
              (plist-get usage :monetary-unknown))
      (setq usage (plist-put usage :monetary-unknown t)))
    (when bid
      (setq usage (plist-put usage :budget-id bid)))
    (setf (kargu-session-usage-value session) usage)
    (kargu-session-snapshot session)))

(defun kargu-session-record-usage (tokens-in tokens-out &optional session)
  "Add TOKENS-IN and TOKENS-OUT to SESSION, or project a native budget snapshot.
When TOKENS-IN is a native budget table or struct, install it via
`kargu-session-project-budget'.
When TOKENS-IN and TOKENS-OUT are numbers or nil, update tokens monotonically.
Missing usage (both nil) is explicitly recorded as unknown, never zero."
  (if (or (hash-table-p tokens-in)
          (and (fboundp 'kargu-run-budget-p) (kargu-run-budget-p tokens-in)))
      (kargu-session-project-budget tokens-in (or tokens-out session))
    (dolist (count (list tokens-in tokens-out))
      (kargu-contract-assert (lambda (value) (or (null value) (natnump value))) count))
    (let* ((session (kargu-session--resolve session))
           (usage (copy-sequence (kargu-session-usage-value session))))
      (setq usage (plist-put usage :requests (1+ (or (plist-get usage :requests) 0))))
      (if (and (null tokens-in) (null tokens-out))
          (progn
            (setq usage (plist-put usage :tokens-unknown t))
            (setq usage (plist-put usage :monetary-unknown t)))
        (when tokens-in
          (setq usage (plist-put usage :last-prompt-tokens tokens-in))
          (setq usage (plist-put usage :tokens-in (+ (or (plist-get usage :tokens-in) 0) tokens-in))))
        (when tokens-out
          (setq usage (plist-put usage :tokens-out (+ (or (plist-get usage :tokens-out) 0) tokens-out))))
        (setq usage (plist-put usage :tokens-spent
                               (+ (or (plist-get usage :tokens-in) 0)
                                  (or (plist-get usage :tokens-out) 0)))))
      (setf (kargu-session-usage-value session) usage)
      (kargu-session-snapshot session))))

(cl-defun kargu-session-record-cache-usage (input read write &key session)
  "Accumulate known cache INPUT, READ and WRITE counters for explicit SESSION."
  (let* ((resolved (kargu-session--resolve session))
         (usage (copy-sequence (kargu-session-usage-value resolved))))
    (dolist (entry (list (cons :cache-read read) (cons :cache-write write)))
      (when (natnump (cdr entry))
        (setq usage (plist-put usage (car entry)
                               (+ (or (plist-get usage (car entry)) 0) (cdr entry))))))
    (when (and (natnump read) (natnump input))
      (setq usage (plist-put usage :cache-measured-read
                             (+ (or (plist-get usage :cache-measured-read) 0) read)))
      (setq usage (plist-put usage :cache-measured-input
                             (+ (or (plist-get usage :cache-measured-input) 0) input))))
    (setf (kargu-session-usage-value resolved) usage)))

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
         (tokens-unk (or (plist-get usage :tokens-unknown) (plist-get usage :tokens-unknown-p)))
         (in (or (plist-get usage :last-prompt-tokens)
                 (plist-get usage :tokens-in)))
         (cap (kargu-session--capacity)))
    (if (or tokens-unk (null in))
        (list :used "unknown"
              :capacity cap
              :percent nil
              :formatted (if cap
                             (format "unknown/%s" (kargu-session--capacity-label cap))
                           "unknown"))
      (let* ((pct (if cap (/ (* 100 in) cap) nil))
             (in-str (kargu-session--count-label in)))
        (list :used in
              :capacity cap
              :percent pct
              :formatted (if cap
                             (format "%s/%s (%d%%)"
                                     in-str
                                     (kargu-session--capacity-label cap)
                                     pct)
                           in-str))))))

(defun kargu-session--monetary-report (session)
  "Return SESSION monetary counters, distinguishing unknown from zero."
  (let* ((usage (kargu-session-usage-value session))
         (monetary-unk (or (plist-get usage :monetary-unknown)
                           (plist-get usage :monetary-unknown-p)))
         (spent (plist-get usage :monetary-spent))
         (reserved (plist-get usage :monetary-reserved))
         (spent-str (if (or monetary-unk (null spent))
                        "unknown"
                      (format "$%.6f" (/ (float spent) 1000000.0))))
         (res-str (if (and (numberp reserved) (> reserved 0))
                      (format "  reserved: $%.6f" (/ (float reserved) 1000000.0))
                    "")))
    (format "  spent: %s%s" spent-str res-str)))

(defun kargu-session-usage (&optional session)
  "Return a short usage report for SESSION, defaulting to the current owner."
  (interactive)
  (let* ((session (kargu-session--resolve session))
         (usage (kargu-session-usage-value session))
         (ctx-info (kargu-session-context-info session))
         (reqs (or (plist-get usage :requests-spent) (plist-get usage :requests) 0))
         (tokens-unk (or (plist-get usage :tokens-unknown) (plist-get usage :tokens-unknown-p)))
         (in (plist-get usage :tokens-in))
         (out (plist-get usage :tokens-out))
         (in-str (if (or tokens-unk (null in)) "unknown" (format "%d" in)))
         (out-str (if (or tokens-unk (null out)) "unknown" (format "%d" out)))
         (report (format "requests: %d  tokens-in: %s  tokens-out: %s  ctx: %s"
                         reqs in-str out-str (plist-get ctx-info :formatted))))
    (setq report (concat report (kargu-session--cache-report session)
                         (kargu-session--monetary-report session)))
    (when (called-interactively-p 'any)
      (message "kargu %s" report))
    report))

(defvar kargu-session-reset-hook nil
  "Optional view notifications after the application finishes a session reset.")

(defun kargu-session-clear ()
  "Replace the current owner's counters and clear explicit selection overrides."
  (when (plist-get (kargu-session-usage-value (kargu-session-context)) :active)
    (user-error "Kargu: stop the session's active run before clearing it"))
  (kargu-session-retire (kargu-session-context))
  (setq kargu--session-id (kargu--generate-session-id)
        kargu-session--context
        (kargu-session--create :id-value kargu--session-id
                              :usage-value (kargu-session--initial-usage))))

(provide 'kargu/core/session)

;;; session.el ends here
