;;; haskell.el --- Haskell language profile for Kargu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Register Haskell modes, project detection and toolchain metadata.

;;; Code:

(require 'kargu/languages/core)

(defconst kargu-language-haskell-spec
  (kargu-make-language-spec
   :id 'haskell
   :name "Haskell"
   :priority 70
   :extensions '("hs" "lhs")
   :modes '(haskell-mode literate-haskell-mode haskell-ts-mode)
   :detectors '("stack.yaml" (:root-extension "cabal"))
   :toolchain
   '(:build-cmd "cabal build || stack build"
     :test-cmd "cabal test || stack test"
     :lint-cmd "hlint ."
     :notes "Build and test using `cabal` or `stack`. Use `hlint` for lint suggestions.")
   :debugger
   '(:adapter "haskell-debug-adapter"
     :supports-eval t
     :supports-method-calls nil
     :eval-guidance
     "Haskell is lazily evaluated. Values in scope may appear as unevaluated thunks (`_`). Evaluating an expression in `debug_eval` forces evaluation. Prefer inspecting local bindings."
     :variable-inspection-advice
     "Inspect bound names in the current scope using `debug_get_context` or `debug_scope`. Note that pattern matches and let-bindings only materialize when evaluated."
     :common-eval-pitfalls
     '(("Variable not in scope:" .
        "The identifier is not in the current lexical environment. Check local bindings via `debug_scope`.")
       ("Unevaluated" .
        "The expression is currently an unevaluated lazy thunk. Forcing evaluation may cause side effects or termination.")))
   :lsp
   '(:name "haskell-language-server"
     :binaries ("haskell-language-server-wrapper" "haskell-language-server")
     :purpose "Language Server for Haskell"
     :hint "ghcup install hls")
   :lsp-notes
   "Haskell symbols: functions, data types, typeclasses, type synonyms. HLS (Haskell Language Server) provides type signatures and code actions.")
  "Language profile for Haskell buffers and projects.")

(kargu-language-register kargu-language-haskell-spec)

(provide 'kargu/languages/haskell)

;;; haskell.el ends here
