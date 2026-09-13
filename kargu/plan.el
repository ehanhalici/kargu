;;; kargu/plan.el --- In-memory plan buffer, review and agent execution -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Facade module for Kargu plan review workflow.
;; Requires submodules under `kargu/plan/`:
;;   * `kargu/plan/buffer'   -> major mode and in-memory buffer management
;;   * `kargu/plan/dispatch' -> approve, view/edit, reject actions
;;
;; Public API:
;;   `kargu-plan-view', `kargu-plan-approve', `kargu-plan-reject',
;;   `kargu-plan-handle-response', `kargu-plan-setup-buffer'.

;;; Code:

;; Ensure the package root is on `load-path' during compilation.
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

(require 'kargu/plan/buffer)
(require 'kargu/plan/dispatch)

(provide 'kargu/plan)

;;; kargu/plan.el ends here
