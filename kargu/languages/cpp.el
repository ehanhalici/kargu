;;; kargu/languages/cpp.el --- C++ language profile for Kargu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Code:

(require 'kargu/languages/core)

(defconst kargu-language-cpp-spec
  (kargu-make-language-spec
   :id 'cpp
   :name "C++"
   :priority 65
   :extensions '("cpp" "cc" "cxx" "hpp" "hxx" "h")
   :detectors
   (list (lambda (root)
           (and (or (kargu-languages--has-file-p root "Makefile")
                    (kargu-languages--has-file-p root "CMakeLists.txt")
                    (kargu-languages--has-file-p root "compile_commands.json"))
                (ignore-errors
                  (cl-some (lambda (f) (string-match-p "\\.\\(cpp\\|cc\\|cxx\\|hpp\\)\\'" f))
                           (directory-files root nil "\\.\\(cpp\\|cc\\|cxx\\|hpp\\)$" t))))))
   :toolchain
   '(:build-cmd "cmake -B build && cmake --build build || make"
     :test-cmd "ctest --test-dir build || make test"
     :lint-cmd "clang-tidy"
     :notes "Configure with CMake and build using Ninja/Make. Run unit tests with `ctest`.")
   :debugger
   '(:adapter "codelldb"
     :supports-eval t
     :supports-method-calls t
     :eval-guidance
     "C++ expression evaluation: member access (`obj.field`, `ptr->field`), indexing (`vec[i]`), pointer dereference, arithmetic, and non-inlined method calls. For smart pointers, use `ptr.get()` or `(*ptr).field`."
     :variable-inspection-advice
     "Inspect STL containers (`std::vector`, `std::map`, `std::string`) with `debug_get_context` or `debug_scope` to see pretty-printed sizes and elements without running complex expressions."
     :common-eval-pitfalls
     '(("member reference type .* is a pointer" .
        "Pointer variable: use `->` instead of `.`.")
       ("no matching member function" .
        "Method may be inlined, templated, or uninstantiated in the debug binary. Access fields directly.")))
   :lsp-notes
   "C++ symbols: classes, structs, namespaces, template specializations, methods. Clangd provides accurate type hierarchy and hover documentation."))

(kargu-language-register kargu-language-cpp-spec)

(provide 'kargu/languages/cpp)

;;; kargu/languages/cpp.el ends here
