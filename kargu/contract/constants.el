;;; kargu/contract/constants.el --- Domain constants and enums -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Centralized domain constants: modes, roles, buffer names, and HTTP statuses.
;; Eliminates magic strings and numbers across the codebase.

;;; Code:

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

;;;; Buffer names ---------------------------------------------------------

(defconst kargu-buffer-chat "*kargu-chat*"
  "Name of the primary chat log buffer.")

(defconst kargu-buffer-log "*kargu-log*"
  "Name of the internal diagnostic log buffer.")

(defconst kargu-buffer-plan "*kargu-plan*"
  "Name of the in-memory plan review buffer.")

;;;; Interaction modes ----------------------------------------------------

(defconst kargu-mode-ask 'ask
  "Read-only query mode: answers questions without changing files.")

(defconst kargu-mode-debug 'debug
  "Debugging mode: inspects variables, call stacks, and runtime errors.")

(defconst kargu-mode-agent 'agent
  "Full autonomous mode: reads, searches, edits files, and executes tools.")

(defconst kargu-mode-plan 'plan
  "Implementation planning mode: inspects codebase without edits.")

(defconst kargu-all-modes '(ask plan debug agent)
  "List of all supported kargu interaction modes.")

;;;; Message roles --------------------------------------------------------

(defconst kargu-role-system "system"
  "OpenAI system instruction prompt role.")

(defconst kargu-role-user "user"
  "User turn prompt role.")

(defconst kargu-role-assistant "assistant"
  "Model answer turn role.")

(defconst kargu-role-tool "tool"
  "Tool execution result turn role.")

;;;; HTTP status codes ----------------------------------------------------

(defconst kargu-http-ok 200
  "HTTP 200 OK.")

(defconst kargu-http-bad-request 400
  "HTTP 400 Bad Request.")

(defconst kargu-http-unauthorized 401
  "HTTP 401 Unauthorized.")

(defconst kargu-http-forbidden 403
  "HTTP 403 Forbidden.")

(defconst kargu-http-not-found 404
  "HTTP 404 Not Found.")

(defconst kargu-http-too-many-requests 429
  "HTTP 429 Rate limited / Too Many Requests.")

(defconst kargu-http-internal-error 500
  "HTTP 500 Internal Server Error.")

(defconst kargu-http-bad-gateway 502
  "HTTP 502 Bad Gateway.")

(defconst kargu-http-unavailable 503
  "HTTP 503 Service Unavailable.")

(defconst kargu-http-gateway-timeout 504
  "HTTP 504 Gateway Timeout.")

(defconst kargu-http-overloaded 529
  "HTTP 529 Site is overloaded.")

(defconst kargu-http-retry-statuses
  (list kargu-http-too-many-requests
        kargu-http-internal-error
        kargu-http-bad-gateway
        kargu-http-unavailable
        kargu-http-gateway-timeout
        kargu-http-overloaded)
  "HTTP status codes that qualify for retry and backoff.")

(defconst kargu-default-api-timeout 90
  "Default HTTP request timeout in seconds for AI completions.")

(provide 'kargu/contract/constants)

;;; kargu/contract/constants.el ends here
