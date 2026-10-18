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

(defconst kargu-language-js--metadata-max-bytes 262144
  "Maximum package.json bytes read while discovering toolchain metadata.")

(defun kargu-language-js--scripts (root)
  "Return package scripts from ROOT without reading unbounded metadata."
  (let ((file (expand-file-name "package.json" root)))
    (when (file-readable-p file)
      (condition-case err
          (with-temp-buffer
            (insert-file-contents file nil 0 kargu-language-js--metadata-max-bytes)
            (let ((package (json-parse-buffer :object-type 'hash-table)))
              (when (hash-table-p package)
                (let ((scripts (gethash "scripts" package)))
                  (and (hash-table-p scripts) scripts)))))
        (error (kargu-log 'warn "Cannot read package scripts: %s"
                          (error-message-string err)))))))

(defun kargu-language-js--script-command (scripts manager name)
  "Return MANAGER's command for NAME when present in SCRIPTS."
  (when-let* ((script (and scripts (gethash name scripts))))
    (when (and (stringp script) (not (string-empty-p (string-trim script))))
      (if (equal name "test")
          (format "%s test" manager)
        (format "%s run %s" manager name)))))

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
  "Return commands for ROOT, with optional TYPESCRIPT validation."
  (let* ((pm (kargu-language-js-package-manager root))
         (scripts (kargu-language-js--scripts root)))
    (list :build-cmd (or (kargu-language-js--script-command scripts pm "build")
                         (and typescript "npx tsc --noEmit"))
          :test-cmd (kargu-language-js--script-command scripts pm "test")
          :lint-cmd (kargu-language-js--script-command scripts pm "lint")
          :notes (format "Package manager: %s. Only use scripts defined in package.json."
                         pm))))

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
   "JavaScript symbols: functions, classes, methods, exported constants. Prefer `edit_by_lsp` to replace a whole function body.")
  "Language profile for JavaScript buffers and projects.")

(kargu-language-register kargu-language-javascript-spec)

(provide 'kargu/languages/javascript)

;;; javascript.el ends here
