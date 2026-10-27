;;; javascript.el --- JavaScript / Node.js profile for Kargu -*- lexical-binding: t; -*-

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
(require 'json)

(defun kargu-language-js-package-manager (root)
  "Return ROOT's observed native package manager, or nil."
  (when-let* ((view (kargu-project-probe-view root))) (gethash "package_manager" view)))
(defun kargu-language-js-toolchain (root &optional typescript)
  "Return ROOT's observed native commands, optionally for TYPESCRIPT."
  (kargu-project-probe-toolchain (if typescript 'typescript 'javascript) root))

(defconst kargu-language-javascript-spec
  (kargu-make-language-spec
   :id 'javascript
   :name "JavaScript (Node.js)"
   :priority 85
   :extensions '("js" "jsx" "mjs" "cjs")
   :modes '(js-mode js-ts-mode js2-mode)
   :detectors '("package.json")
   :toolchain '(:native "javascript")
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
   "JavaScript symbols: functions, classes, methods, exported constants. Prefer `edit_by_lsp` to replace a whole function body.")
  "Language profile for JavaScript buffers and projects.")

(kargu-language-register kargu-language-javascript-spec)

(provide 'kargu/languages/javascript)

;;; javascript.el ends here
