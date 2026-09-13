;;; tests/run-tests.el --- Runner for all Kargu ERT test suites -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory (expand-file-name root)))
      (add-to-list 'load-path (expand-file-name "tests" root)))))

(require 'ert)
(require 'kargu)
(require 'tests/test-contract)
(require 'test-state)
(require 'tests/test-permission)
(require 'tests/test-git)
(require 'tests/test-history)
(require 'tests/test-api)
(require 'tests/test-tools)
(require 'tests/test-loop)
(require 'tests/test-integration)
(require 'tests/test-providers)
(require 'tests/test-plan)
(require 'tests/test-patch)
(require 'tests/test-metadata)
(require 'tests/test-todo-fixes)
(require 'tests/test-dynamic-models)

(defun kargu-run-all-tests ()
  "Run all Kargu ERT test suites."
  (interactive)
  (ert "^kargu-"))

(when noninteractive
  (ert-run-tests-batch-and-exit "^kargu-"))

(provide 'tests/run-tests)
;;; run-tests.el ends here
