;;; java.el --- Java language profile for Kargu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Register Java modes, project detection and toolchain metadata.

;;; Code:

(require 'kargu/languages/core)

(defun kargu-language-java-toolchain (root)
  "Toolchain plist for the Java project at ROOT: Gradle when it has a build file."
  (if (or (kargu-languages--has-file-p root "build.gradle")
          (kargu-languages--has-file-p root "build.gradle.kts"))
      (let ((gw (if (kargu-languages--has-file-p root "gradlew") "./gradlew" "gradle")))
        (list :build-cmd (format "%s build -x test" gw)
              :test-cmd (format "%s test" gw)
              :lint-cmd (format "%s check" gw)
              :notes "Run Gradle build and test tasks using the `bash` tool."))
    (list :build-cmd "mvn compile"
          :test-cmd "mvn test"
          :lint-cmd "mvn checkstyle:check"
          :notes "Run Maven goals using the `bash` tool.")))

(defconst kargu-language-java-spec
  (kargu-make-language-spec
   :id 'java
   :name "Java"
   :priority 75
   :extensions '("java")
   :modes '(java-mode java-ts-mode)
   :detectors '("pom.xml" "build.gradle" "build.gradle.kts")
   :toolchain #'kargu-language-java-toolchain
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
