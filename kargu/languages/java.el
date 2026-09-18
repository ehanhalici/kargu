;;; kargu/languages/java.el --- Java language profile for Kargu -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Code:

(require 'kargu/languages/core)

(defconst kargu-language-java-spec
  (kargu-make-language-spec
   :id 'java
   :name "Java"
   :priority 75
   :extensions '("java")
   :detectors '("pom.xml" "build.gradle" "build.gradle.kts")
   :toolchain
   '(:build-cmd "mvn compile || ./gradlew build -x test"
     :test-cmd "mvn test || ./gradlew test"
     :lint-cmd "mvn checkstyle:check"
     :notes "Run Maven or Gradle goals using the `bash` tool.")
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
   :lsp-notes
   "Java symbols: classes, interfaces, records, methods, fields. JDTLS handles outline and refactorings."))

(kargu-language-register kargu-language-java-spec)

(provide 'kargu/languages/java)

;;; kargu/languages/java.el ends here
