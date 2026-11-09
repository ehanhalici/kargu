;;; constants.el --- Domain constants and enums -*- lexical-binding: t; -*-

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

(defconst kargu-eglot-required-message
  "Kargu: Eglot bu projede aktif değil. LSP araçları modele verilmeyecek; dosya/arama araçları ve agent kipinde Bash kullanılabilir."
  "Notice shown when this project has no live Eglot connection.")

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

(provide 'kargu/contract/constants)

;;; constants.el ends here
