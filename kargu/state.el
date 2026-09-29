;;; kargu/state.el --- Centralized state management facade -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Facade for Kargu central state management.
;; Re-exports selectors, transitions, hooks, and store operations.
;; Ensures backward compatibility with global variables while providing
;; a structured, observable single-source-of-truth.

;;; Code:

(require 'kargu/state/store)
(require 'kargu/state/hooks)
(require 'kargu/state/selectors)
(require 'kargu/state/transitions)

(provide 'kargu/state)

;;; kargu/state.el ends here
