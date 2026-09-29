;;; kargu/languages/typescript.el --- TypeScript profile for Kargu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; A project with a `tsconfig.json' is TypeScript.  It is tried before the
;; JavaScript profile, which claims any other `package.json' project.

;;; Code:

(require 'kargu/languages/javascript)

(defconst kargu-language-typescript-spec
  (kargu-make-language-spec
   :id 'typescript
   :name "TypeScript"
   :priority 86
   :extensions '("ts" "tsx" "mts" "cts")
   :modes '(typescript-mode typescript-ts-mode tsx-ts-mode)
   :detectors '("tsconfig.json")
   :toolchain (lambda (root) (kargu-language-js-toolchain root t))
   :debugger
   '(:adapter "js-debug"
     :supports-eval t
     :supports-method-calls t
     :eval-guidance
     "Any expression valid in the paused frame can be evaluated. Types are erased at runtime, so do not use type annotations or `as` casts in expressions."
     :variable-inspection-advice
     "Inspect locals via `debug_get_context` or `debug_scope`. Breakpoints map to the source through source maps."
     :common-eval-pitfalls
     '(("SyntaxError:" .
        "Expressions run as JavaScript. Remove type annotations, generics and `as` casts.")
       ("ReferenceError:" .
        "The name is not defined in this frame. Check `debug_scope` for the variables that are in scope.")))
   :lsp
   '(:name "typescript-language-server"
     :binaries ("typescript-language-server" "vtsls")
     :purpose "Language Server for TypeScript"
     :hint "npm install -g typescript-language-server typescript")
   :lsp-notes
   "TypeScript symbols: functions, classes, interfaces, type aliases, enums. Prefer `edit_by_lsp` to replace a whole function body."))

(kargu-language-register kargu-language-typescript-spec)

(provide 'kargu/languages/typescript)

;;; kargu/languages/typescript.el ends here
