;;; kargu/languages/golang.el --- Go language profile for Kargu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Code:

(require 'kargu/languages/core)

(defconst kargu-language-golang-spec
  (kargu-make-language-spec
   :id 'golang
   :name "Go"
   :priority 90
   :extensions '("go")
   :detectors
   (list "go.mod" "go.sum"
         (lambda (root)
           (ignore-errors
             (cl-some (lambda (f) (string-match-p "\\.go\\'" f))
                      (directory-files root nil "\\.go$" t)))))
   :toolchain
   '(:build-cmd "go build ./..."
     :test-cmd "go test -v ./..."
     :lint-cmd "golangci-lint run"
     :notes "Run `go vet ./...` for analysis and `go test -v ./...` to execute test suites.")
   :debugger
   '(:adapter "dlv"
     :supports-eval t
     :supports-method-calls nil
     :eval-guidance
     "In Go (Delve), function calls inside expressions are generally unsupported. Evaluate variable names, struct fields (`s.Field`), slice indexing (`s[0]`), and map keys (`m[\"key\"]`). Slices and maps display length and capacity natively."
     :variable-inspection-advice
     "Inspect goroutines and local frame variables using `debug_get_context` or `debug_scope`. Delve provides clean formatting for channels, slices, interfaces, and structs."
     :common-eval-pitfalls
     '(("function calls are not supported" .
        "Delve does not support function execution in expressions. Access struct fields or inspect variable values directly.")
       ("could not find symbol" .
        "Symbol not found in the current scope. Check local variable names via `debug_scope`.")))
   :lsp-notes
   "Go symbols: functions, methods, structs, interfaces, types. Use gopls with `read_file_symbols` and `edit_by_lsp` for refactoring."))

(kargu-language-register kargu-language-golang-spec)

(provide 'kargu/languages/golang)

;;; kargu/languages/golang.el ends here
