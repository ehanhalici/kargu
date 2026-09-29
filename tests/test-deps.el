;;; tests/test-deps.el --- Unit tests for mandatory tool validation -*- lexical-binding: t; -*-

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
(require 'kargu)
(require 'kargu/tools/deps)
(require 'kargu/chat)

(ert-deftest kargu-deps-package-check-test ()
  "Ensure kargu-deps correctly identifies installed and missing packages."
  (let ((kargu-deps-mandatory-packages '(plz transient non-existent-dummy-package))
        (kargu-deps-mandatory-executables nil)
        (kargu-deps-check-lsp-server nil))
    (let ((missing (kargu-deps-missing)))
      (should (= (length missing) 1))
      (should (eq (plist-get (car missing) :id) 'non-existent-dummy-package))
      (should (eq (plist-get (car missing) :type) 'package)))))

(ert-deftest kargu-deps-executable-check-test ()
  "Ensure kargu-deps correctly identifies missing CLI executables."
  (let ((kargu-deps-mandatory-packages nil)
        (kargu-deps-mandatory-executables '("git" "non-existent-dummy-tool-12345"))
        (kargu-deps-check-lsp-server nil))
    (let ((missing (kargu-deps-missing)))
      (should (= (length missing) 1))
      (should (equal (plist-get (car missing) :id) "non-existent-dummy-tool-12345"))
      (should (eq (plist-get (car missing) :type) 'executable)))))

(ert-deftest kargu-deps-lsp-server-check-test ()
  "Ensure kargu-deps detects missing LSP server for detected project language."
  (let* ((temp-dir (make-temp-file "kargu-test-rust-" t))
         (cargo-file (expand-file-name "Cargo.toml" temp-dir)))
    (unwind-protect
        (progn
          (write-region "[package]\nname = \"dummy\"\nversion = \"0.1.0\"\n" nil cargo-file)
          ;; Mock executable-find so rust-analyzer is not found
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (exe)
                       (if (equal exe "rust-analyzer") nil "/bin/mock-found")))
                    ((symbol-function 'kargu-deps--active-eglot-server-p)
                     (lambda (&rest _) nil)))
            (let ((kargu-deps-mandatory-packages nil)
                  (kargu-deps-mandatory-executables nil)
                  (kargu-deps-check-lsp-server t))
              (let ((missing (kargu-deps-missing temp-dir)))
                (should (= (length missing) 1))
                (should (eq (plist-get (car missing) :type) 'lsp-server))
                (should (string-match-p "rust-analyzer" (plist-get (car missing) :name)))
                (should (string-match-p "rustup component add" (plist-get (car missing) :install-hint)))))))
      (delete-directory temp-dir t))))

(ert-deftest kargu-deps-lsp-server-satisfied-when-executable-found-test ()
  "Ensure LSP server requirement is satisfied when executable is in PATH."
  (let* ((temp-dir (make-temp-file "kargu-test-rust-" t))
         (cargo-file (expand-file-name "Cargo.toml" temp-dir)))
    (unwind-protect
        (progn
          (write-region "[package]\nname = \"dummy\"\n" nil cargo-file)
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (exe)
                       (when (equal exe "rust-analyzer") "/usr/bin/rust-analyzer")))
                    ((symbol-function 'kargu-deps--active-eglot-server-p)
                     (lambda (&rest _) nil)))
            (let ((kargu-deps-mandatory-packages nil)
                  (kargu-deps-mandatory-executables nil)
                  (kargu-deps-check-lsp-server t))
              (should (null (kargu-deps-missing temp-dir))))))
      (delete-directory temp-dir t))))

(ert-deftest kargu-deps-format-missing-report-test ()
  "Ensure kargu-deps-format-missing-report builds sensible multi-line error banner."
  (let ((missing '((:id magit :name "magit" :type package :purpose "Git integration interface" :install-hint "M-x package-install RET magit")
                   (:id "curl" :name "curl" :type executable :purpose "HTTP client" :install-hint "apt install curl"))))
    (let ((report (kargu-deps-format-missing-report missing)))
      (should (stringp report))
      (should (string-match-p "MANDATORY TOOLS MISSING" report))
      (should (string-match-p "magit (Emacs Package)" report))
      (should (string-match-p "Git integration interface" report))
      (should (string-match-p "M-x package-install RET magit" report))
      (should (string-match-p "curl (System CLI)" report))
      (should (string-match-p "apt install curl" report))
      (should (string-match-p "Prompt submission is BLOCKED" report)))))

(ert-deftest kargu-deps-chat-display-missing-tools-on-open-test ()
  "Ensure chat screen displays sensible error banner when tools are missing."
  (let ((buf (get-buffer-create "*kargu-test-missing-chat*"))
        (kargu-deps-mandatory-packages '(missing-pkg-foo))
        (kargu-deps-mandatory-executables nil)
        (kargu-deps-check-lsp-server nil))
    (unwind-protect
        (with-current-buffer buf
          (kargu-chat-mode)
          (kargu-chat--ensure-prompt)
          (kargu-chat-check-and-display-missing-tools nil t)
          (let ((content (buffer-string)))
            (should (string-match-p "MANDATORY TOOLS MISSING" content))
            (should (string-match-p "missing-pkg-foo" content))))
      (kill-buffer buf))))

(ert-deftest kargu-deps-blocks-prompt-send-test ()
  "Ensure kargu-chat-send blocks prompt submission when mandatory tools are missing."
  (let ((kargu-deps-mandatory-packages '(missing-dummy-test-pkg))
        (kargu-deps-mandatory-executables nil)
        (kargu-deps-check-lsp-server nil)
        (sent nil))
    (cl-letf (((symbol-function 'kargu-loop-running-p) (lambda () nil))
              ((symbol-function 'kargu-loop-send)
               (lambda (&rest _) (setq sent t))))
      (setq kargu--loop-run nil)
      (let ((buf (kargu-chat--buffer)))
        (unwind-protect
            (with-current-buffer buf
              (kargu-chat--ensure-prompt)
              (goto-char (point-max))
              (insert "Hello Kargu!")
              ;; Sending should signal user-error and NOT send
              (let ((err (should-error (kargu-chat-send) :type 'user-error)))
                (should (string-match-p "mandatory tools are missing" (cadr err))))
              (should-not sent)
              ;; The typed input should NOT be deleted or lost
              (should (string-match-p "Hello Kargu!" (kargu-chat--input-text))))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(ert-deftest kargu-deps-blocks-loop-send-test ()
  "Ensure kargu-loop-send blocks agent runs when mandatory tools are missing."
  (let ((kargu-deps-mandatory-packages '(missing-tool-for-loop))
        (kargu-deps-mandatory-executables nil)
        (kargu-deps-check-lsp-server nil))
    (cl-letf (((symbol-function 'kargu-loop-running-p) (lambda () nil)))
      (setq kargu--loop-run nil)
      (let ((err (should-error (kargu-loop-send "Test run") :type 'user-error)))
        (should (string-match-p "mandatory tools are missing" (cadr err)))))))

(ert-deftest kargu-deps-unblocks-when-tools-installed-test ()
  "Ensure prompt can be sent once missing tools are resolved."
  (let ((test-missing '(mock-pkg))
        (kargu-deps-mandatory-packages '(mock-pkg))
        (kargu-deps-mandatory-executables nil)
        (kargu-deps-check-lsp-server nil)
        (submitted nil))
    (cl-letf (((symbol-function 'kargu-loop-running-p) (lambda () nil))
              ((symbol-function 'kargu-deps-package-installed-p)
               (lambda (pkg) (not (memq pkg test-missing))))
              ((symbol-function 'kargu-loop-send)
               (lambda (&rest _) (setq submitted t) 'mock-run)))
      (setq kargu--loop-run nil)
      (let ((buf (kargu-chat--buffer)))
        (unwind-protect
            (with-current-buffer buf
              (setq-local kargu-chat--session-provider "opencode")
              (setq-local kargu-chat--session-model "nemotron-3-ultra-free")
              (kargu-chat--ensure-prompt)
              (goto-char (point-max))
              (insert "My prompt")
              ;; Initially missing mock-pkg -> blocked
              (should-error (kargu-chat-send) :type 'user-error)
              (should-not submitted)
              ;; Now simulate package being installed
              (setq test-missing nil)
              ;; Send again -> succeeds!
              (kargu-chat-send)
              (should submitted))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(provide 'tests/test-deps)
;;; test-deps.el ends here
