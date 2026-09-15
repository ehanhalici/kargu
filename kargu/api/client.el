;;; kargu/api/client.el --- Chat send, cancel, connection test -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; High-level API transport: `kargu-api-send', `kargu-api-cancel', `kargu-test-connection'.

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
(require 'kargu/contract)
(require 'kargu/state)
(require 'kargu/history)
(require 'kargu/api/tools)
(require 'kargu/api/response)
(require 'kargu/api/stream)
(require 'kargu/api/circuit)
(require 'kargu/api/http)

(declare-function kargu-busy-p "kargu/api/http" ())
(declare-function kargu-api-cancel "kargu/api/http" ())
(declare-function kargu-api-clear-busy "kargu/api/http" ())
(declare-function kargu-loop-running-p "kargu/loop" ())

(defun kargu--api-cancel-busy ()
  "Clear the busy flag when a request completes or fails."
  (if (fboundp 'kargu-api-clear-busy)
      (kargu-api-clear-busy)
    (setq kargu--busy nil)
    (unless (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
      (when (fboundp 'kargu-state-transition-status)
        (kargu-state-transition-status :idle)))))

(defun kargu-api-send (prompt callback &optional on-delta)
  "Send the next conversation turn to OpenRouter, asynchronously.
PROMPT is the new user message (a string), or nil to continue from history.
CALLBACK is called with one argument: the decoded response alist.
ON-DELTA is called with each streaming SSE delta event."
  (kargu-contract-assert #'kargu-contract-prompt-p prompt
                         "PROMPT must be a string or nil: %S" prompt)
  (kargu-contract-assert #'functionp callback
                         "CALLBACK must be callable: %S" callback)
  (kargu-contract-assert #'kargu-contract-callback-p on-delta
                         "ON-DELTA must be callable or nil: %S" on-delta)
  (cl-block kargu-api-send
    ;; Guard Clause 1: Request already in flight
    (when kargu--busy
      (funcall callback
               `(("error" .
                  (("message" . "request already in flight; cancel first")))))
      (cl-return-from kargu-api-send nil))

    ;; Guard Clause 2: API key resolution
    (let ((key (kargu--resolve-api-key)))
      (unless key
        (funcall callback
                 `(("error" .
                    (("message" . "no API key: M-x kargu-edit-config, or set `kargu-api-key', or a host env/auth-source entry")))))
        (cl-return-from kargu-api-send nil))

      ;; Happy path execution
      (let ((added-prompt-p nil))
        (when (and prompt (not (string-empty-p prompt)))
          (kargu--history-add "user" prompt)
          (setq added-prompt-p t))
        (condition-case-unless-debug err
            (progn
              ;; Guard Clause 3: Completed assistant turn cannot continue without prompt
              (when (and (or (null prompt) (string-empty-p prompt))
                         (kargu--history-completed-assistant-tail-p))
                (user-error "nothing to continue; send a user message"))
              (kargu--validate-history)
              ;; Guard Clause 4: History must contain at least one user message
              (unless (cl-some (lambda (m)
                                 (equal (kargu--aget m "role") "user"))
                               kargu--message-history)
                (user-error "nothing to send: history has no user message"))
              ;; Guard Clause 5: History must not end on model turn
              (when (kargu--assistant-role-p (kargu--history-last-role))
                (user-error "refusing to send: history still ends on a model turn"))
              (let ((gen (cl-incf kargu--generation)))
                (setq kargu--busy t)
                (kargu-state-transition-status :requesting)
                (kargu--api-post
                 (concat (kargu--api-base) "/chat/completions")
                 (kargu--api-headers key)
                 (kargu--build-payload)
                 gen
                 (lambda (resp)
                   (kargu--api-cancel-busy)
                   (funcall callback resp))
                 on-delta)))
          (error
           (kargu--api-cancel-busy)
           (when (and added-prompt-p
                      kargu--message-history
                      (equal (kargu--aget (car (last kargu--message-history)) "role") "user")
                      (equal (kargu--aget (car (last kargu--message-history)) "content") prompt))
             (setq kargu--message-history (butlast kargu--message-history)))
           (funcall callback
                    (kargu--api-error-alist (error-message-string err)))))))))

(defun kargu-test-connection ()
  "Ping the active provider with a minimal request and report the result.
The conversation history is untouched: the ping uses a scratch
history which is restored afterwards."
  (interactive)
  ;; Guard Clause 1: Loop active
  (when (and (fboundp 'kargu-loop-running-p)
             (kargu-loop-running-p))
    (user-error
     "An agent run is in progress; stop it first (M-x kargu-loop-stop)"))
  ;; Guard Clause 2: Circuit breaker status
  (unless (kargu-circuit-allow-request-p)
    (user-error "Circuit breaker is %s; cannot ping until cooldown"
                (kargu-circuit-status-string)))
  (let ((kargu--message-history nil)
        (kargu-temperature nil)
        (kargu-max-tokens 32))
    (kargu--history-add "user" "Reply with the single word: pong")
    (message "kargu: pinging %s (%s)..." (kargu--provider-name) (kargu--model))
    (kargu-api-send
     nil
     (lambda (response)
       (let ((err (kargu-response-error-message response)))
         (if err
             (progn
               (kargu-log 'error "test-connection: %s" err)
               (message "kargu: FAILED — %s" err))
           (message "kargu: OK — model replied: %s"
                    (truncate-string-to-width
                     (or (kargu-response-text response) "") 60))))))))

(provide 'kargu/api/client)

;;; kargu/api/client.el ends here
