;;; policy.el --- Debugger tool availability -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Share one admission policy between schemas, prompts and execution.

;;; Code:

(require 'kargu/tools/dape/session)
(require 'kargu/api/tools)

(declare-function dape--capable-p "dape" (conn thing))

(defconst kargu-dape--offline-tools
  '("debug_start" "debug_list_breakpoints" "debug_set_breakpoint"
    "debug_clear_breakpoint" "debug_toggle_breakpoint")
  "Tools usable before an adapter connection exists.")

(defconst kargu-dape--running-tools
  '("debug_pause" "debug_threads" "debug_modules" "debug_sources"
    "debug_restart" "debug_kill" "debug_disconnect" "debug_quit")
  "Tools usable while the target is running.")

(defun kargu-dape-tool-refusal (name)
  "Return a refusal for debugger tool NAME, or nil when available."
  (let ((conn (kargu-dape--raw-connection)))
    (cond
     ((not (fboundp 'dape)) "ERROR: Dape is not installed.")
     ((member name kargu-dape--offline-tools) nil)
     ((null conn) "ERROR: No live debugger; start a verified configuration first.")
     ((and (equal name "debug_restart")
           (not (dape--capable-p conn :supportsRestartRequest)))
      "ERROR: This adapter does not support restarting.")
     ((member name kargu-dape--running-tools) nil)
     ((null (dape--stopped-threads conn))
      "ERROR: Inspection requires a paused thread; pause the target first."))))

(defun kargu-dape-tool-policy (name)
  "Return the registration policy for debugger tool NAME."
  (list :modes '(debug agent)
        :available-p (lambda () (kargu-dape-tool-refusal name))))

(defun kargu-dape-tool-guide ()
  "Describe only debugger tools currently advertised to the model."
  (mapconcat
   (lambda (name) (format "- %s: %s" name (kargu-tool-description name)))
   (sort (seq-filter (lambda (name)
                       (and (string-prefix-p "debug_" name)
                            (kargu-tool-visible-p name)))
                     (kargu-advertised-tools)) #'string<)
   "\n"))

(provide 'kargu/tools/dape/policy)
;;; policy.el ends here
