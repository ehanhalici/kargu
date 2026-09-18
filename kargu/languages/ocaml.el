;;; kargu/languages/ocaml.el --- OCaml language profile for Kargu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Code:

(require 'kargu/languages/core)

(defconst kargu-language-ocaml-spec
  (kargu-make-language-spec
   :id 'ocaml
   :name "OCaml"
   :priority 70
   :extensions '("ml" "mli")
   :detectors '("dune-project" "dune" "_oasis" "opam")
   :toolchain
   '(:build-cmd "dune build"
     :test-cmd "dune runtest"
     :lint-cmd "dune build @check"
     :notes "Build, test, and type-check using Dune (`dune runtest`).")
   :debugger
   '(:adapter "ocamlearlybird"
     :supports-eval t
     :supports-method-calls nil
     :eval-guidance
     "In OCaml (ocamlearlybird), evaluate identifiers, record fields (`record.field`), variants, and tuples. Complex function applications inside expressions are limited. Inspect values in scope."
     :variable-inspection-advice
     "Inspect pattern-matched variant constructors, record contents, and local `let` bindings via `debug_get_context` or `debug_scope`."
     :common-eval-pitfalls
     '(("Unbound value" .
        "Value is not bound in the current frame or requires module qualification (`Module.value`). Check `debug_scope`.")
       ("Cannot evaluate" .
        "The debug adapter cannot evaluate complex functional expressions at runtime. Inspect bound values directly.")))
   :lsp-notes
   "OCaml symbols: let bindings, modules, module types, variants, records. OCaml-LSP provides precise types on hover and document outlines."))

(kargu-language-register kargu-language-ocaml-spec)

(provide 'kargu/languages/ocaml)

;;; kargu/languages/ocaml.el ends here
