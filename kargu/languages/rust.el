;;; kargu/languages/rust.el --- Rust language profile for Kargu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Code:

(require 'kargu/languages/core)

(defconst kargu-language-rust-spec
  (kargu-make-language-spec
   :id 'rust
   :name "Rust"
   :priority 100
   :extensions '("rs")
   :detectors '("Cargo.toml")
   :toolchain
   '(:build-cmd "cargo check"
     :test-cmd "cargo test"
     :lint-cmd "cargo clippy"
     :notes "Use `cargo check` for fast compilation checks, `cargo clippy` for lints, and `cargo test` to run tests.")
   :debugger
   '(:adapter "codelldb"
     :supports-eval t
     :supports-method-calls nil
     :eval-guidance
     "In Rust LLDB, `debug_eval` only evaluates static data structures without function execution:
- Allowed: bare variables (`var`), direct struct fields (`var.field`), pointer dereference (`(*ptr).field`), indexing (`arr[0]`), arithmetic.
- Prohibited: Any expression with parentheses `()` (functions, methods, trait calls). To inspect collection lengths, Option/Result, or struct internals, inspect the variable via `debug_scope` or `debug_get_context`."
     :variable-inspection-advice
     "ALWAYS inspect variables from the `in-scope variables` list in `debug_get_context` or use `debug_scope` instead of guessing expressions in `debug_eval`. The debug adapter automatically formats Vec (showing size and items), String, Option, and Result."
     :common-eval-pitfalls
     '(("\\.[a-zA-Z0-9_]+[ \t]*(" .
        "Rust LLDB: Method calls with `()` cannot execute at runtime. Use direct field access (`var.field`), indexing (`var[0]`), or `debug_scope`.")
       ("(" .
        "Rust LLDB: Function/method calls are not supported in eval. Inspect variables directly using `debug_scope`.")
       ("called object type 'unsigned long' is not" .
        "Rust LLDB: Cannot invoke methods in eval. Inspect variables via `debug_scope` or read direct fields without parentheses.")
       ("no member named 'len' in 'alloc::raw_vec" .
        "RawVec does not store `len`. The enclosing `Vec` holds the length. Inspect the parent struct with `debug_scope`.")
       ("member reference type .* is a pointer" .
        "The variable is a pointer or reference in LLDB. Use arrow `->` or dereference with `(*ptr).field`.")
       ("no member named" .
        "Field not found in debug symbol table. Inspect all fields of the struct using `debug_scope` or check the source with `read_symbol`.")))
   :lsp-notes
   "Rust symbol outline: functions (fn), structs (struct), enums (enum), traits (trait), impl blocks. Prefer `edit_by_lsp` to replace target function bodies without fragile string matching."))

(kargu-language-register kargu-language-rust-spec)

(provide 'kargu/languages/rust)

;;; kargu/languages/rust.el ends here
