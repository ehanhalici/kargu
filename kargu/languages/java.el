;;; java.el --- Java language profile for Kargu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Register Java modes, project detection and toolchain metadata.

;;; Code:

(require 'kargu/languages/core)

(defun kargu-language-java-toolchain (root)
  "Return ROOT's completed native Java command metadata."
  (kargu-project-probe-toolchain 'java root))

(defconst kargu-language-java-spec
  (kargu-make-language-spec
   :id 'java
   :name "Java"
   :priority 75
   :extensions '("java")
   :modes '(java-mode java-ts-mode)
   :detectors '("pom.xml" "build.gradle" "build.gradle.kts")
   :toolchain '(:native "java")
   :debugger
   '(:adapter "java"
     :supports-eval t
     :supports-method-calls t
     :eval-guidance
     "Full Java expression evaluation: variable reads, field access, object method calls, collection operations, and arithmetic in current frame."
     :variable-inspection-advice
     "Inspect fields, `this` context, and method arguments via `debug_get_context` or `debug_scope`. Collections and arrays show element counts and items."
     :common-eval-pitfalls
     '(("cannot find symbol" .
        "Variable or method is not accessible in this frame's scope. Check local variable names in `debug_scope`.")
       ("NullPointerException" .
        "Attempted to invoke a method on a null object reference. Inspect the object with `debug_eval` first.")))
   :lsp
   '(:name "jdtls"
     :binaries ("jdtls")
     :purpose "Language Server for Java (code completion and definitions)"
     :hint "brew install jdtls (or your system package manager)")
   :lsp-notes
   "Java symbols: classes, interfaces, records, methods, fields. JDTLS handles outline and refactorings.")
  "Language profile for Java buffers and projects.")

(kargu-language-register kargu-language-java-spec)

(provide 'kargu/languages/java)

;;; java.el ends here
