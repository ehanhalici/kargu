;;; kargu/tools/toolchain.el --- Strategy pattern for project toolchains -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Strategy Pattern implementation for multi-language detection, build commands,
;; and test toolchains.  Replaces monolithic cond checks with pluggable strategies.
;; Public: `kargu-toolchain-strategy', `kargu-toolchain-register',
;; `kargu-toolchain-detect'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory (Magit-style kargu/core features).
(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'kargu/fs)
(require 'kargu/languages)

(declare-function kargu-fs-has-file-p "kargu/fs" (root filename))

;;;; Strategy definition --------------------------------------------------

(cl-defstruct (kargu-toolchain-strategy (:constructor kargu-make-toolchain-strategy))
  "Strategy object encapsulating detection and commands for one language toolchain."
  name
  priority
  detector
  resolver)

(defvar kargu-toolchain-strategies nil
  "List of registered `kargu-toolchain-strategy' objects, ordered by priority.")

(defun kargu-toolchain-register (strategy)
  "Register a STRATEGY in `kargu-toolchain-strategies', maintaining priority order."
  (setq kargu-toolchain-strategies
        (cl-remove (kargu-toolchain-strategy-name strategy)
                   kargu-toolchain-strategies
                   :key #'kargu-toolchain-strategy-name
                   :test #'equal))
  (push strategy kargu-toolchain-strategies)
  (setq kargu-toolchain-strategies
        (sort kargu-toolchain-strategies
              (lambda (a b)
                (> (or (kargu-toolchain-strategy-priority a) 0)
                   (or (kargu-toolchain-strategy-priority b) 0)))))
  strategy)

(defun kargu-toolchain-detect (root)
  "Detect the primary toolchain for ROOT by evaluating registered strategies."
  (or (when-let* ((lang (and (fboundp 'kargu-language-detect)
                             (kargu-language-detect root)))
                  (tc (kargu-language-spec-toolchain lang)))
        (list :language (kargu-language-spec-name lang)
              :build-cmd (plist-get tc :build-cmd)
              :test-cmd (plist-get tc :test-cmd)
              :lint-cmd (plist-get tc :lint-cmd)
              :notes (plist-get tc :notes)))
      (let ((matched nil))
        (dolist (strat kargu-toolchain-strategies)
          (unless matched
            (when (funcall (kargu-toolchain-strategy-detector strat) root)
              (setq matched (funcall (kargu-toolchain-strategy-resolver strat) root)))))
        matched)))

;;;; Built-in Strategies --------------------------------------------------

(defalias 'kargu-toolchain--has-file-p #'kargu-fs-has-file-p)

;; 1. Rust Strategy
(kargu-toolchain-register
 (kargu-make-toolchain-strategy
  :name "Rust"
  :priority 100
  :detector (lambda (root) (kargu-toolchain--has-file-p root "Cargo.toml"))
  :resolver (lambda (_root)
              (list :language "Rust"
                    :build-cmd "cargo check"
                    :test-cmd "cargo test"
                    :notes "Use `cargo clippy' for linting and `cargo test' to run tests."))))

;; 2. Go Strategy
(kargu-toolchain-register
 (kargu-make-toolchain-strategy
  :name "Go"
  :priority 90
  :detector (lambda (root)
              (or (kargu-toolchain--has-file-p root "go.mod")
                  (kargu-toolchain--has-file-p root "go.sum")
                  (ignore-errors (directory-files root nil "\\.go$" t))))
  :resolver (lambda (_root)
              (list :language "Go"
                    :build-cmd "go build ./..."
                    :test-cmd "go test -v ./..."
                    :notes "Use `go vet ./...' for vetting and `go test -v ./...' to run tests."))))

;; 3. TypeScript / JavaScript Strategy
(kargu-toolchain-register
 (kargu-make-toolchain-strategy
  :name "JavaScript/TypeScript"
  :priority 85
  :detector (lambda (root) (kargu-toolchain--has-file-p root "package.json"))
  :resolver (lambda (root)
              (let* ((ts-p (kargu-toolchain--has-file-p root "tsconfig.json"))
                     (pm (cond
                          ((kargu-toolchain--has-file-p root "pnpm-lock.yaml") "pnpm")
                          ((kargu-toolchain--has-file-p root "yarn.lock") "yarn")
                          ((or (kargu-toolchain--has-file-p root "bun.lockb")
                               (kargu-toolchain--has-file-p root "bun.lock")) "bun")
                          (t "npm")))
                     (build-cmd (if ts-p
                                    (format "%s run build || npx tsc --noEmit" pm)
                                  (format "%s run build" pm)))
                     (test-cmd (format "%s test" pm)))
                (list :language (if ts-p "TypeScript" "JavaScript (Node.js)")
                      :build-cmd build-cmd
                      :test-cmd test-cmd
                      :notes (format "Package manager: %s. Use `%s' to execute tests." pm test-cmd))))))

;; 4. Python Strategy
(kargu-toolchain-register
 (kargu-make-toolchain-strategy
  :name "Python"
  :priority 80
  :detector (lambda (root)
              (or (kargu-toolchain--has-file-p root "pyproject.toml")
                  (kargu-toolchain--has-file-p root "setup.py")
                  (kargu-toolchain--has-file-p root "setup.cfg")
                  (kargu-toolchain--has-file-p root "requirements.txt")
                  (kargu-toolchain--has-file-p root "Pipfile")))
  :resolver (lambda (root)
              (let ((test-cmd (if (or (file-directory-p (expand-file-name "tests" root))
                                      (kargu-toolchain--has-file-p root "pytest.ini")
                                      (kargu-toolchain--has-file-p root "pyproject.toml"))
                                  "pytest"
                                "python -m unittest discover")))
                (list :language "Python"
                      :build-cmd "python -m py_compile <file>"
                      :test-cmd test-cmd
                      :notes "Run tests with pytest or unittest via the `bash' tool.")))))

;; 5. Java/Kotlin (Maven) Strategy
(kargu-toolchain-register
 (kargu-make-toolchain-strategy
  :name "Maven"
  :priority 75
  :detector (lambda (root) (kargu-toolchain--has-file-p root "pom.xml"))
  :resolver (lambda (_root)
              (list :language "Java (Maven)"
                    :build-cmd "mvn compile"
                    :test-cmd "mvn test"
                    :notes "Run Maven compile and test goals via `bash'."))))

;; 6. Java/Kotlin (Gradle) Strategy
(kargu-toolchain-register
 (kargu-make-toolchain-strategy
  :name "Gradle"
  :priority 70
  :detector (lambda (root)
              (or (kargu-toolchain--has-file-p root "build.gradle")
                  (kargu-toolchain--has-file-p root "build.gradle.kts")))
  :resolver (lambda (root)
              (let ((gw (if (kargu-toolchain--has-file-p root "gradlew") "./gradlew" "gradle")))
                (list :language "Java/Kotlin (Gradle)"
                      :build-cmd (format "%s build -x test" gw)
                      :test-cmd (format "%s test" gw)
                      :notes "Run Gradle build/test via `bash'.")))))

;; 7. C/C++ (CMake) Strategy
(kargu-toolchain-register
 (kargu-make-toolchain-strategy
  :name "CMake"
  :priority 65
  :detector (lambda (root) (kargu-toolchain--has-file-p root "CMakeLists.txt"))
  :resolver (lambda (_root)
              (list :language "C / C++ (CMake)"
                    :build-cmd "cmake -B build && cmake --build build"
                    :test-cmd "ctest --test-dir build"
                    :notes "Configure with cmake and run tests via ctest."))))

;; 8. C/C++ (Makefile) Strategy
(kargu-toolchain-register
 (kargu-make-toolchain-strategy
  :name "Make"
  :priority 60
  :detector (lambda (root) (kargu-toolchain--has-file-p root "Makefile"))
  :resolver (lambda (_root)
              (list :language "C / C++ (Make)"
                    :build-cmd "make"
                    :test-cmd "make test"
                    :notes "Build and test using `make' targets."))))

;; 9. Emacs Lisp Strategy
(kargu-toolchain-register
 (kargu-make-toolchain-strategy
  :name "Emacs Lisp"
  :priority 50
  :detector (lambda (root)
              (or (kargu-toolchain--has-file-p root "Cask")
                  (kargu-toolchain--has-file-p root "Eask")
                  (ignore-errors (directory-files root nil "\\.el$" t))))
  :resolver (lambda (_root)
              (list :language "Emacs Lisp"
                    :build-cmd "emacs -Q --batch -L . -f batch-byte-compile <files>"
                    :test-cmd "make test || emacs -Q --batch -L . -f ert-run-tests-batch-and-exit"
                    :notes "Use byte-compilation and ERT batch runner to verify Elisp code."))))

(provide 'kargu/tools/toolchain)

;;; kargu/tools/toolchain.el ends here
