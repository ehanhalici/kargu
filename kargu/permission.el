;;; kargu/permission.el --- LSP project root permission and sandboxing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Facade module for Kargu permission and sandboxing guardrails.
;; Requires submodules under `kargu/permission/`:
;;   * `kargu/permission/guards' -> project root resolution and path assertions
;;   * `kargu/permission/bash'   -> command tokenization and escape validation
;;   * `kargu/permission/policy' -> interactive approval buttons and UI policy
;;
;; Public API:
;;   `kargu-permission-project-root', `kargu-permission-within-project-p',
;;   `kargu-permission-assert-within-project', `kargu-permission-tokenize-command',
;;   `kargu-permission-validate-command', `kargu-permission-request-approval'.

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

(require 'kargu/permission/guards)
(require 'kargu/permission/bash)
(require 'kargu/permission/policy)

(provide 'kargu/permission)

;;; kargu/permission.el ends here
