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

(setq load-prefer-newer t)

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)
(require 'tests/test-modules)
(require 'tests/test-tool-registry)
(require 'tests/test-contract)
(require 'tests/test-json)
(require 'tests/test-state)
(require 'tests/test-permission)
(require 'tests/test-git)
(require 'tests/test-history)
(require 'tests/test-history-store)
(require 'tests/test-api)
(require 'tests/test-stream)
(require 'tests/test-tool-calls)
(require 'tests/test-async)
(require 'tests/test-cache)
(require 'tests/test-tools)
(require 'tests/test-loop)
(require 'tests/test-integration)
(require 'tests/test-providers)
(require 'tests/test-plan)
(require 'tests/test-patch)
(require 'tests/test-metadata)
(require 'tests/test-model-store)
(require 'tests/test-parameters)
(require 'tests/test-chat)
(require 'tests/test-chat-state)
(require 'tests/test-dynamic-models)
(require 'tests/test-lsp)
(require 'tests/test-lsp-project-diagnostics)
(require 'tests/test-lsp-settle)
(require 'tests/test-session)
(require 'tests/test-session-storage)
(require 'tests/test-session-validate)
(require 'tests/test-confirm)
(require 'tests/test-languages)
(require 'tests/test-dape-commands)
(require 'tests/test-dape-workspace)
(require 'tests/test-dape-startup)
(require 'tests/test-dape-watch)
(require 'tests/test-dape-execution)
(require 'tests/test-dape-selection)
(require 'tests/test-dape-admission)
(require 'tests/test-dape-readiness)
(require 'tests/test-dape-compile)
(require 'tests/test-deps)
(require 'tests/test-fake-agent)
(require 'tests/test-security)
(require 'tests/test-process)
(require 'tests/test-config)
(require 'tests/test-laws)
(require 'tests/test-compact)
(require 'tests/test-heal)
(require 'tests/test-attach)
(require 'tests/test-fs)
(require 'tests/test-webfetch)
(require 'tests/test-address)

(defun kargu-run-all-tests ()
  "Run all Kargu ERT test suites."
  (interactive)
  (ert "^kargu-"))

(when noninteractive
  (ert-run-tests-batch-and-exit "^kargu-"))

(provide 'tests/run-tests)
;;; run-tests.el ends here
