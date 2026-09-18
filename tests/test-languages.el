;;; tests/test-languages.el --- Tests for kargu/languages -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'kargu/languages)
(require 'kargu/tools/toolchain)

(ert-deftest kargu-languages-registered-all-eight-test ()
  "Ensure all 8 target languages are registered with valid specs."
  (let ((expected-ids '(rust c cpp golang python java haskell ocaml)))
    (dolist (id expected-ids)
      (let ((spec (kargu-language-get id)))
        (should (kargu-language-spec-p spec))
        (should (eq (kargu-language-spec-id spec) id))
        (should (stringp (kargu-language-spec-name spec)))
        (should (consp (kargu-language-spec-extensions spec)))
        (should (plist-get (kargu-language-spec-toolchain spec) :build-cmd))
        (should (plist-get (kargu-language-spec-debugger spec) :adapter))))))

(ert-deftest kargu-languages-extension-detection-test ()
  "Ensure all file extensions map accurately to their language spec."
  (let ((cases '(("main.rs" . rust)
                 ("src/lib.rs" . rust)
                 ("kernel.c" . c)
                 ("engine.cpp" . cpp)
                 ("solver.cc" . cpp)
                 ("matrix.cxx" . cpp)
                 ("include/header.hpp" . cpp)
                 ("server.go" . golang)
                 ("App.java" . java)
                 ("pipeline.py" . python)
                 ("parser.hs" . haskell)
                 ("syntax.lhs" . haskell)
                 ("ast.ml" . ocaml)
                 ("ast.mli" . ocaml))))
    (dolist (c cases)
      (let ((spec (kargu-language-detect-by-extension (car c))))
        (should spec)
        (should (eq (kargu-language-spec-id spec) (cdr c)))))))

(ert-deftest kargu-languages-project-root-detection-test ()
  "Ensure project root markers detect the appropriate language."
  (let ((temp-dir (make-temp-file "kargu-lang-test-" t)))
    (unwind-protect
        (progn
          ;; Rust
          (let ((rust-root (expand-file-name "rust-proj" temp-dir)))
            (make-directory rust-root t)
            (write-region "[package]\nname = \"test\"\n" nil (expand-file-name "Cargo.toml" rust-root))
            (let ((spec (kargu-language-detect rust-root)))
              (should spec)
              (should (eq (kargu-language-spec-id spec) 'rust))))
          ;; Go
          (let ((go-root (expand-file-name "go-proj" temp-dir)))
            (make-directory go-root t)
            (write-region "module example.com/test\n" nil (expand-file-name "go.mod" go-root))
            (let ((spec (kargu-language-detect go-root)))
              (should spec)
              (should (eq (kargu-language-spec-id spec) 'golang))))
          ;; Python
          (let ((py-root (expand-file-name "py-proj" temp-dir)))
            (make-directory py-root t)
            (write-region "[project]\nname = \"test\"\n" nil (expand-file-name "pyproject.toml" py-root))
            (let ((spec (kargu-language-detect py-root)))
              (should spec)
              (should (eq (kargu-language-spec-id spec) 'python))))
          ;; Haskell
          (let ((hs-root (expand-file-name "hs-proj" temp-dir)))
            (make-directory hs-root t)
            (write-region "resolver: lts-22.0\n" nil (expand-file-name "stack.yaml" hs-root))
            (let ((spec (kargu-language-detect hs-root)))
              (should spec)
              (should (eq (kargu-language-spec-id spec) 'haskell))))
          ;; OCaml
          (let ((ml-root (expand-file-name "ml-proj" temp-dir)))
            (make-directory ml-root t)
            (write-region "(lang dune 3.0)\n" nil (expand-file-name "dune-project" ml-root))
            (let ((spec (kargu-language-detect ml-root)))
              (should spec)
              (should (eq (kargu-language-spec-id spec) 'ocaml)))))
      (delete-directory temp-dir t))))

(ert-deftest kargu-languages-toolchain-bridge-test ()
  "Ensure kargu-toolchain-detect leverages kargu-languages registry."
  (let ((temp-dir (make-temp-file "kargu-tc-test-" t)))
    (unwind-protect
        (let ((rust-root (expand-file-name "rust-proj" temp-dir)))
          (make-directory rust-root t)
          (write-region "[package]\nname = \"test\"\n" nil (expand-file-name "Cargo.toml" rust-root))
          (let ((tc (kargu-toolchain-detect rust-root)))
            (should tc)
            (should (equal (plist-get tc :build-cmd) "cargo check"))
            (should (equal (plist-get tc :test-cmd) "cargo test"))
            (should (equal (plist-get tc :lint-cmd) "cargo clippy"))))
      (delete-directory temp-dir t))))

(ert-deftest kargu-languages-rust-eval-pitfall-advice-test ()
  "Ensure Rust evaluation pitfalls with method calls generate helpful guidance."
  (let* ((spec (kargu-language-get 'rust))
         (hint-len (kargu-language-eval-hint spec "frame.landmarks_2d.len()"))
         (hint-empty (kargu-language-eval-hint spec "items.is_empty()")))
    (should (string-match-p "Rust LLDB" hint-len))
    (should (string-match-p "debug_scope" hint-len))
    (should (string-match-p "Method calls with `()` cannot execute" hint-empty))
    (should (string-match-p "debug_scope" hint-empty))))

(ert-deftest kargu-languages-prompt-guidance-test ()
  "Ensure kargu-language-prompt-guidance formats markdown rules for AI injection."
  (let* ((spec (kargu-language-get 'rust))
         (md (kargu-language-prompt-guidance spec)))
    (should (string-match-p "language=\"Rust\"" md))
    (should (string-match-p "cargo check" md))
    (should (string-match-p "codelldb" md))
    (should (string-match-p "Static data access ONLY" md))))

(provide 'tests/test-languages)

;;; tests/test-languages.el ends here
