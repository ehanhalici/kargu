;;; kargu/languages/c.el --- C language profile for Kargu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Code:

(require 'kargu/languages/core)

(defconst kargu-language-c-spec
  (kargu-make-language-spec
   :id 'c
   :name "C"
   :priority 60
   :extensions '("c" "h")
   :detectors
   (list (lambda (root)
           (and (or (kargu-languages--has-file-p root "Makefile")
                    (kargu-languages--has-file-p root "CMakeLists.txt")
                    (kargu-languages--has-file-p root "compile_commands.json"))
                (ignore-errors
                  (cl-some (lambda (f) (string-match-p "\\.c\\'" f))
                           (directory-files root nil "\\.c$" t))))))
   :toolchain
   '(:build-cmd "cmake -B build && cmake --build build || make"
     :test-cmd "ctest --test-dir build || make test"
     :lint-cmd "clang-tidy"
     :notes "Configure with CMake or Make. Compile warnings should be treated as errors.")
   :debugger
   '(:adapter "codelldb"
     :supports-eval t
     :supports-method-calls t
     :eval-guidance
     "Standard C expression evaluation: variable reads, member access (`ptr->field` or `val.field`), array indexing (`arr[i]`), pointer dereferencing (`*ptr`), type casts (`((Type*)ptr)->field`), and arithmetic."
     :variable-inspection-advice
     "Inspect locals and arguments via `debug_get_context` or `debug_scope`. Check pointer addresses before dereferencing."
     :common-eval-pitfalls
     '(("member reference type .* is a pointer" .
        "Pointer variable: use `->` instead of `.`.")
       ("cannot access memory at address" .
        "Segmentation fault / null pointer dereference. Inspect the pointer value before dereferencing.")))
   :lsp-notes
   "C symbols: functions, structs, unions, enums, typedefs. Use clangd for accurate cross-references."))

(kargu-language-register kargu-language-c-spec)

(provide 'kargu/languages/c)

;;; kargu/languages/c.el ends here
