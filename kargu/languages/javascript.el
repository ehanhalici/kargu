;;; kargu/languages/javascript.el --- JavaScript / Node.js profile for Kargu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; A project with a `package.json' is JavaScript unless it also has a
;; `tsconfig.json', which the TypeScript profile claims first.  The
;; toolchain depends on the package manager the lock file names, so it is
;; a function of the project root.

;;; Code:

(require 'kargu/languages/core)

(defun kargu-language-js-package-manager (root)
  "Package manager for the JavaScript project at ROOT, from its lock file."
  (cond
   ((kargu-languages--has-file-p root "pnpm-lock.yaml") "pnpm")
   ((kargu-languages--has-file-p root "yarn.lock") "yarn")
   ((or (kargu-languages--has-file-p root "bun.lockb")
        (kargu-languages--has-file-p root "bun.lock"))
    "bun")
   (t "npm")))

(defun kargu-language-js-toolchain (root &optional typescript)
  "Toolchain plist for the project at ROOT; TYPESCRIPT adds a type check."
  (let* ((pm (kargu-language-js-package-manager root))
         (test-cmd (format "%s test" pm)))
    (list :build-cmd (if typescript
                         (format "%s run build || npx tsc --noEmit" pm)
                       (format "%s run build" pm))
          :test-cmd test-cmd
          :lint-cmd (format "%s run lint" pm)
          :notes (format "Package manager: %s. Use `%s' to execute tests."
                         pm test-cmd))))

(defconst kargu-language-javascript-spec
  (kargu-make-language-spec
   :id 'javascript
   :name "JavaScript (Node.js)"
   :priority 85
   :extensions '("js" "jsx" "mjs" "cjs")
   :modes '(js-mode js-ts-mode js2-mode)
   :detectors '("package.json")
   :toolchain #'kargu-language-js-toolchain
   :debugger
   '(:adapter "js-debug"
     :supports-eval t
     :supports-method-calls t
     :eval-guidance
     "Any JavaScript expression valid in the paused frame can be evaluated, including property access and function calls."
     :variable-inspection-advice
     "Inspect locals and closures via `debug_get_context` or `debug_scope` before evaluating expressions."
     :common-eval-pitfalls
     '(("ReferenceError:" .
        "The name is not defined in this frame. Check `debug_scope` for the variables that are in scope.")
       ("TypeError:.*undefined" .
        "A value in the expression is undefined. Inspect its parent object with `debug_scope`.")))
   :lsp
   '(:name "typescript-language-server"
     :binaries ("typescript-language-server" "vtsls")
     :purpose "Language Server for JavaScript"
     :hint "npm install -g typescript-language-server typescript")
   :lsp-notes
   "JavaScript symbols: functions, classes, methods, exported constants. Prefer `edit_by_lsp` to replace a whole function body."))

(kargu-language-register kargu-language-javascript-spec)

(provide 'kargu/languages/javascript)

;;; kargu/languages/javascript.el ends here
