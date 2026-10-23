;;; observers.el --- Isolated event listener delivery -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Deliver notifications without allowing one observer to break its publisher.

;;; Code:

(require 'kargu/core/log)

(defun kargu-run-observers (hook &rest arguments)
  "Notify every listener on HOOK with ARGUMENTS, isolating failures."
  (apply #'run-hook-wrapped
         hook
         (lambda (function &rest args)
           (condition-case err
               (save-match-data
                 (save-current-buffer (apply function args)))
             (error
              (kargu-log 'warn "Observer %S on %s failed: %s"
                         function hook (error-message-string err))))
           nil)
         arguments))

(provide 'kargu/core/observers)
;;; observers.el ends here
