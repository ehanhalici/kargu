;;; kargu/contract/constants.el --- Domain constants and enums -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Centralized domain constants: modes, roles, buffer names, and HTTP statuses.
;; Eliminates magic strings and numbers across the codebase.

;;; Code:

;;;; Buffer names ---------------------------------------------------------

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

(provide 'kargu/contract/constants)

;;; kargu/contract/constants.el ends here
