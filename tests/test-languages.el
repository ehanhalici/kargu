;;; tests/test-languages.el --- Tests for kargu/languages -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Ensure the package root is on `load-path` during byte/native compilation.
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

(require 'ert)
(require 'cl-lib)
(require 'kargu/languages)
(require 'kargu/tools/toolchain)
(require 'kargu/tools/deps)
(require 'kargu/chat)

(ert-deftest kargu-languages-registered-all-test ()
  "Ensure every target language is registered with a valid spec."
  (let ((expected-ids '(rust c cpp golang python java haskell ocaml javascript typescript emacs-lisp)))
    (dolist (id expected-ids)
      (let ((spec (kargu-language-get id)))
        (should (kargu-language-spec-p spec))
        (should (eq (kargu-language-spec-id spec) id))
        (should (stringp (kargu-language-spec-name spec)))
        (should (consp (kargu-language-spec-extensions spec)))
        (should (plist-get (kargu-language-toolchain spec default-directory) :build-cmd))
        (when (kargu-language-requires-lsp-p spec)
          (should (plist-get (kargu-language-spec-lsp spec) :binaries)))
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
                 ("ast.mli" . ocaml)
                 ("kargu.el" . emacs-lisp))))
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
              (should (eq (kargu-language-spec-id spec) 'ocaml))))
          ;; Emacs Lisp, and a Rust tree that also contains a .el file
          (let ((el-root (expand-file-name "el-proj" temp-dir)))
            (make-directory el-root t)
            (write-region ";;; foo.el\n" nil (expand-file-name "foo.el" el-root))
            (let ((spec (kargu-language-detect el-root)))
              (should spec)
              (should (eq (kargu-language-spec-id spec) 'emacs-lisp))))
          (let ((mixed (expand-file-name "rust-with-el" temp-dir)))
            (make-directory mixed t)
            (write-region "[package]\nname = \"test\"\n" nil (expand-file-name "Cargo.toml" mixed))
            (write-region ";;; helper.el\n" nil (expand-file-name "helper.el" mixed))
            (let ((spec (kargu-language-detect mixed)))
              (should spec)
              (should (eq (kargu-language-spec-id spec) 'rust)))))
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

(defun kargu-languages--kill-chats ()
  "Kill chat buffers created by a language test."
  (dolist (buf (buffer-list))
    (when (and (buffer-live-p buf)
               (eq (buffer-local-value 'major-mode buf) 'kargu-chat-mode))
      (kill-buffer buf))))

(ert-deftest kargu-languages-elisp-requires-eglot-and-does-not-ask ()
  "Emacs Lisp requires a language server and never asks for a project root."
  (let ((spec (kargu-language-get 'emacs-lisp)))
    (should (kargu-language-requires-lsp-p spec))
    (should (member "ellsp" (plist-get (kargu-language-spec-lsp spec) :binaries)))
    (with-temp-buffer
      (emacs-lisp-mode)
      (should (eq (kargu-language-spec-id (kargu-language-for-buffer))
                  'emacs-lisp)))
    (with-temp-buffer
      (lisp-interaction-mode)
      (should (eq (kargu-language-spec-id (kargu-language-for-buffer))
                  'emacs-lisp)))))

(ert-deftest kargu-languages-emacs-lisp-without-eglot-blocks-the-prompt ()
  "An Emacs Lisp buffer without Eglot shows the error and does not ask for a root."
  (let ((root (make-temp-file "kargu-el-noeglot-" t))
        (kargu-session-auto-restore nil)
        (kargu-context-buffer nil)
        (noninteractive nil))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory (file-name-as-directory root))
          (emacs-lisp-mode)
          (write-region ";;; a.el\n" nil (expand-file-name "a.el" root))
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                    ((symbol-function 'read-directory-name)
                     (lambda (&rest _) (error "should not ask for a directory"))))
            (should (kargu-chat--workspace-blocked-p))
            (kargu-chat-show)
            (should kargu-chat--awaiting-eglot)
            (should-not (kargu-chat--prompt-live-p))
            (should (string-match-p "Eglot is not connected" (buffer-string)))
            (should-not (string-match-p "no language server" (buffer-string)))
            (should-error (kargu-chat--send-input) :type 'user-error)))
      (kargu-languages--kill-chats)
      (delete-directory root t))))

(ert-deftest kargu-languages-without-eglot-blocks-the-prompt ()
  "A project with no Eglot connection shows the error and has no prompt."
  (let ((root (make-temp-file "kargu-noeglot-" t))
        (kargu-session-auto-restore nil)
        (kargu-context-buffer nil)
        (noninteractive nil))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory (file-name-as-directory root))
          (write-region "" nil (expand-file-name "shell.nix" root))
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                    ((symbol-function 'read-directory-name)
                     (lambda (&rest _) (error "should not ask for a directory"))))
            (should (kargu-chat--workspace-blocked-p))
            (kargu-chat-show)
            (should kargu-chat--awaiting-eglot)
            (should-not (kargu-chat--prompt-live-p))
            (should (string-match-p "Eglot is not connected" (buffer-string)))
            (should-error (kargu-chat--send-input) :type 'user-error)))
      (kargu-languages--kill-chats)
      (delete-directory root t))))

(ert-deftest kargu-languages-eglot-connection-allows-the-prompt ()
  "A live Eglot server for this project allows the prompt."
  (let ((root (make-temp-file "kargu-eglot-ok-" t))
        (kargu-session-auto-restore nil)
        (kargu-context-buffer nil)
        (noninteractive nil)
        (eglot-buf (generate-new-buffer "app.py")))
    (unwind-protect
        (progn
          (with-current-buffer eglot-buf
            (setq buffer-file-name (expand-file-name "app.py" root))
            (setq default-directory (file-name-as-directory root))
            (setq-local eglot--managed-mode t))
          (with-temp-buffer
            (setq default-directory (file-name-as-directory root))
            (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                      ((symbol-function 'eglot-current-server) (lambda () t))
                      ((symbol-function 'read-directory-name)
                       (lambda (&rest _) (error "should not ask for a directory"))))
              (should (kargu-eglot-connected-p))
              (should-not (kargu-chat--workspace-blocked-p))
              (kargu-chat-show)
              (should-not kargu-chat--awaiting-eglot)
              (should (kargu-chat--prompt-live-p)))))
      (kargu-languages--kill-chats)
      (when (buffer-live-p eglot-buf) (kill-buffer eglot-buf))
      (delete-directory root t))))

(ert-deftest kargu-languages-emacs-lisp-eglot-allows-the-prompt ()
  "A live Eglot server in an Emacs Lisp buffer allows the prompt and does not ask."
  (let ((root (make-temp-file "kargu-el-eglot-" t))
        (kargu-session-auto-restore nil)
        (kargu-context-buffer nil)
        (noninteractive nil))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory (file-name-as-directory root))
          (setq buffer-file-name (expand-file-name "a.el" root))
          (emacs-lisp-mode)
          (setq-local eglot--managed-mode t)
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                    ((symbol-function 'eglot-current-server) (lambda () t))
                    ((symbol-function 'read-directory-name)
                     (lambda (&rest _) (error "should not ask for a directory"))))
            (should (kargu-eglot-connected-p))
            (should-not (kargu-chat--workspace-blocked-p))
            (kargu-chat-show)
            (should-not kargu-chat--awaiting-eglot)
            (should (kargu-chat--prompt-live-p))))
      (kargu-languages--kill-chats)
      (delete-directory root t))))

(provide 'tests/test-languages)

;;; tests/test-languages.el ends here

(ert-deftest kargu-languages-web-and-java-toolchain-follow-the-project-test ()
  "The JavaScript, TypeScript and Java toolchains are read from the project."
  (let ((dir (make-temp-file "kargu-web-" t)))
    (unwind-protect
        (progn
          (write-region "{}" nil (expand-file-name "package.json" dir))
          (write-region "" nil (expand-file-name "pnpm-lock.yaml" dir))
          (should (eq (kargu-language-spec-id (kargu-language-detect dir)) 'javascript))
          (should (equal (plist-get (kargu-toolchain-detect dir) :test-cmd) "pnpm test"))
          (write-region "{}" nil (expand-file-name "tsconfig.json" dir))
          (should (eq (kargu-language-spec-id (kargu-language-detect dir)) 'typescript))
          (should (string-match-p "tsc --noEmit"
                                  (plist-get (kargu-toolchain-detect dir) :build-cmd))))
      (delete-directory dir t))
    (setq dir (make-temp-file "kargu-java-" t))
    (unwind-protect
        (progn
          (write-region "" nil (expand-file-name "pom.xml" dir))
          (should (equal (plist-get (kargu-toolchain-detect dir) :test-cmd) "mvn test"))
          (write-region "" nil (expand-file-name "build.gradle" dir))
          (delete-file (expand-file-name "pom.xml" dir))
          (should (equal (plist-get (kargu-toolchain-detect dir) :test-cmd) "gradle test")))
      (delete-directory dir t))))
