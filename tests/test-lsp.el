;;; tests/test-lsp.el --- Tests for kargu/tools/lsp Eglot support -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'kargu/tools/lsp)
(require 'kargu/config/schema)
(require 'kargu/permission)

(ert-deftest kargu-lsp-backend-detection-test ()
  "Test LSP backend detection defaults to Eglot."
  (should (eq (kargu-lsp-backend) 'eglot))
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/test-eglot.el")
    (setq-local eglot--managed-mode t)
    (cl-letf (((symbol-function 'eglot-current-server) (lambda (&rest _) 'mock-eglot-server)))
      (should (eq (kargu-lsp-backend (current-buffer)) 'eglot)))))

(ert-deftest kargu-lsp-buffer-managed-p-test ()
  "Test buffer managed predicate for Eglot."
  ;; File-less buffer should return nil
  (with-temp-buffer
    (setq-local eglot--managed-mode t)
    (cl-letf (((symbol-function 'eglot-current-server) (lambda (&rest _) 'mock-server)))
      (should-not (kargu-lsp--buffer-managed-p (current-buffer)))))
  ;; Eglot managed buffer with file
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/test.el")
    (setq-local eglot--managed-mode t)
    (cl-letf (((symbol-function 'eglot-current-server) (lambda (&rest _) 'mock-server)))
      (should (kargu-lsp--buffer-managed-p (current-buffer))))))

(ert-deftest kargu-lsp-uri-and-path-test ()
  "Test LSP URI to path conversion and buffer URI generation."
  (should (equal (kargu-lsp--uri-to-path "file:///home/user/project/test.el")
                 "/home/user/project/test.el"))
  (should (equal (kargu-lsp--uri-to-path "file:///home/user/my%20file.el")
                 "/home/user/my file.el"))
  (with-temp-buffer
    (setq-local buffer-file-name "/home/user/foo.el")
    (let ((uri (kargu-lsp--buffer-uri (current-buffer))))
      (should (string-prefix-p "file://" uri))
      (should (string-suffix-p "foo.el" uri)))))

(ert-deftest kargu-lsp-symbol-information-item-test ()
  "Test converting SymbolInformation, WorkspaceSymbol and hash-tables."
  ;; Plist with location: range
  (let* ((item '(:name "my-function"
                 :kind 12
                 :location (:uri "file:///tmp/test.el"
                            :range (:start (:line 41 :character 0)))))
         (res (kargu-lsp--symbol-information-item item)))
    (should (equal res (list "/tmp/test.el" 42 "my-function" 12))))
  ;; Plist with targetUri and targetRange (WorkspaceSymbol / LocationLink)
  (let* ((item '(:name "MyClass"
                 :kind 5
                 :location (:targetUri "file:///tmp/class.el"
                            :targetSelectionRange (:start (:line 9 :character 4)))))
         (res (kargu-lsp--symbol-information-item item)))
    (should (equal res (list "/tmp/class.el" 10 "MyClass" 5))))
  ;; Hash table representation
  (let ((ht (make-hash-table :test 'equal))
        (loc (make-hash-table :test 'equal))
        (rng (make-hash-table :test 'equal))
        (start (make-hash-table :test 'equal)))
    (puthash "line" 19 start)
    (puthash "character" 2 start)
    (puthash "start" start rng)
    (puthash "uri" "file:///tmp/ht.el" loc)
    (puthash "range" rng loc)
    (puthash "name" "ht-symbol" ht)
    (puthash "kind" 13 ht)
    (puthash "location" loc ht)
    (let ((res (kargu-lsp--symbol-information-item ht)))
      (should (equal res (list "/tmp/ht.el" 20 "ht-symbol" 13))))))

(ert-deftest kargu-lsp-request-dispatch-eglot-test ()
  "Test that kargu-lsp--request dispatches keywords and strings to Eglot server."
  (let (called-method called-params)
    (with-temp-buffer
      (setq-local buffer-file-name "/tmp/mock.el")
      (cl-letf (((symbol-function 'eglot-current-server) (lambda (&rest _) 'mock-server))
                ((symbol-function 'eglot--request)
                 (lambda (_srv method params &rest _keys)
                   (setq called-method method)
                   (setq called-params params)
                   'mock-response)))
        (let ((res (kargu-lsp--request "workspace/symbol" '(:query "foo"))))
          (should (eq called-method :workspace/symbol))
          (should (equal called-params '(:query "foo")))
          (should (eq res 'mock-response)))
        (let ((res (kargu-lsp--request :textDocument/documentSymbol '(:query "bar"))))
          (should (eq called-method :textDocument/documentSymbol))
          (should (equal called-params '(:query "bar")))
          (should (eq res 'mock-response)))))))

(ert-deftest kargu-lsp-flymake-diags-source-tag-test ()
  "Test flymake diagnostics source tagging for Eglot."
  (let* ((temp (make-temp-file "kargu-test-diag" nil ".el"))
         (buf (find-file-noselect temp)))
    (unwind-protect
        (with-current-buffer buf
          (insert "(defun foo ()\n  (+ 1 2))\n")
          (setq-local eglot--managed-mode t)
          (cl-letf (((symbol-function 'eglot-current-server) (lambda (&rest _) 'mock-server))
                    ((symbol-function 'flymake-diagnostics)
                     (lambda (&rest _)
                       (list 'dummy-diag)))
                    ((symbol-function 'flymake-diagnostic-beg) (lambda (&rest _) 1))
                    ((symbol-function 'flymake-diagnostic-type) (lambda (&rest _) :error))
                    ((symbol-function 'flymake-diagnostic-text) (lambda (&rest _) "syntax error")))
            (let ((diags (kargu-lsp--flymake-diags temp)))
              (should (consp diags))
              (let ((d (car diags)))
                (should (equal (plist-get d :source) "eglot"))
                (should (= (plist-get d :severity) 1))
                (should (equal (plist-get d :message) "syntax error"))))))
      (when (buffer-live-p buf)
        (kill-buffer buf))
      (when (file-exists-p temp)
        (delete-file temp)))))

(ert-deftest kargu-project-root-eglot-resolution-test ()
  "Test that kargu--project-root extracts root from Eglot server project."
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/repo/src/main.rs")
    (setq-local eglot--managed-mode t)
    (let ((kargu-context-buffer (current-buffer)))
      (cl-letf (((symbol-function 'eglot-current-server) (lambda (&rest _) 'mock-server))
                ((symbol-function 'eglot-project) (lambda (&rest _) '(project . "/tmp/repo/")))
                ((symbol-function 'project-root) (lambda (proj) (cdr proj))))
        (should (equal (kargu--project-root) "/tmp/repo/"))))))

(ert-deftest kargu-missing-dependencies-with-eglot-test ()
  "Test that kargu--missing-dependencies checks eglot availability."
  (cl-letf (((symbol-function 'locate-library)
             (lambda (lib)
               (cond
                ((equal lib "eglot") "/mock/eglot.el")
                (t (symbol-name (intern lib)))))))
    (let ((missing (kargu--missing-dependencies)))
      (should-not (assq 'eglot missing)))))

(ert-deftest kargu-lsp-get-project-diagnostics-clean-test ()
  "Test that kargu-lsp-get-project-diagnostics reports [Project Clean] when no errors exist."
  (cl-letf (((symbol-function 'flymake--project-diagnostics) (lambda (&rest _) nil)))
    (let ((report (kargu-lsp-get-project-diagnostics)))
      (should (stringp report))
      (should (string-search "[Project Clean]" report))
      (should (string-search "No compile or linter diagnostics found across the project" report)))))

(ert-deftest kargu-lsp-get-project-diagnostics-with-diags-test ()
  "Test that kargu-lsp-get-project-diagnostics formats and groups diagnostics by file."
  (let* ((mock-root (file-name-as-directory (expand-file-name "/tmp/mock-project")))
         (mock-file-1 (expand-file-name "src/lib.rs" mock-root))
         (mock-file-2 (expand-file-name "src/main.rs" mock-root)))
    (cl-letf (((symbol-function 'kargu--project-root) (lambda () mock-root))
              ((symbol-function 'flymake--project-diagnostics)
               (lambda (&rest _)
                 (list 'diag-1 'diag-2 'diag-3)))
              ((symbol-function 'kargu-lsp--extract-flymake-diag)
               (lambda (d)
                 (cond
                  ((eq d 'diag-1)
                   (list :file mock-file-1
                         :severity 1
                         :line 42
                         :character 10
                         :source "rustc"
                         :message "cannot find value `foo`"))
                  ((eq d 'diag-2)
                   (list :file mock-file-1
                         :severity 2
                         :line 15
                         :character 5
                         :source "rustc"
                         :message "unused variable `bar`"))
                  ((eq d 'diag-3)
                   (list :file mock-file-2
                         :severity 1
                         :line 102
                         :character 14
                         :source "rustc"
                         :message "mismatched types"))))))
      (let ((report (kargu-lsp-get-project-diagnostics)))
        (should (stringp report))
        (should (string-search "Project diagnostics" report))
        (should (string-search "3 diagnostics across 2 files" report))
        (should (string-search "src/lib.rs (2 diagnostics: 1 error, 1 warning)" report))
        (should (string-search "src/main.rs (1 diagnostic: 1 error)" report))
        (should (string-search "[error] L42:C10: cannot find value `foo`" report))
        (should (string-search "[warning] L15:C5: unused variable `bar`" report))
        (should (string-search "[error] L102:C14: mismatched types" report))))))

(ert-deftest kargu-lsp-tool-diagnostics-dispatch-test ()
  "Test that lsp_diagnostics tool dispatches to project diagnostics when file_path is omitted."
  (cl-letf (((symbol-function 'kargu-lsp-get-project-diagnostics)
             (lambda () "MOCK_PROJECT_DIAGNOSTICS_REPORT"))
            ((symbol-function 'kargu-lsp-get-diagnostics)
             (lambda (path) (format "MOCK_FILE_DIAGS: %s" path))))
    ;; 1. Empty args ({})
    (let ((res (kargu-execute-tool "lsp_diagnostics" nil)))
      (should (equal res "MOCK_PROJECT_DIAGNOSTICS_REPORT")))
    ;; 2. Empty file_path string
    (let ((res (kargu-execute-tool "lsp_diagnostics" '(("file_path" . "")))))
      (should (equal res "MOCK_PROJECT_DIAGNOSTICS_REPORT")))
    ;; 3. Whitespace file_path
    (let ((res (kargu-execute-tool "lsp_diagnostics" '(("file_path" . "   ")))))
      (should (equal res "MOCK_PROJECT_DIAGNOSTICS_REPORT")))
    ;; 4. Explicit file path
    (let ((res (kargu-execute-tool "lsp_diagnostics" '(("file_path" . "src/lib.rs")))))
      (should (string-prefix-p "MOCK_FILE_DIAGS:" res)))))

(ert-deftest kargu-lsp-imenu-document-symbols-test ()
  "Test that kargu-lsp--imenu-document-symbols extracts symbol plists."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defvar my-test-var 42\n  \"Doc.\")\n\n(defun my-test-fun (x)\n  \"Double.\"\n  (* x 2))\n")
    (let ((syms (kargu-lsp--imenu-document-symbols (current-buffer))))
      (should (listp syms))
      (should (cl-some (lambda (s) (equal (plist-get s :name) "my-test-fun")) syms))
      (let ((fun (cl-find-if (lambda (s) (equal (plist-get s :name) "my-test-fun")) syms)))
        (should (equal (plist-get fun :kind) "Function"))
        (should (>= (plist-get fun :start-line) 4))
        (should (>= (plist-get fun :end-line) 4))))))

(ert-deftest kargu-lsp-read-file-symbols-format-test ()
  "Test that kargu-lsp-read-file-symbols formats outline with line numbers and kinds."
  (cl-letf (((symbol-function 'kargu-lsp-get-file-symbols)
             (lambda (_path)
               (list (list :name "calculate_total"
                           :kind "Function"
                           :start-line 10
                           :end-line 25
                           :detail "(items) -> int"
                           :children nil)
                     (list :name "Order"
                           :kind "Struct"
                           :start-line 30
                           :end-line 50
                           :detail nil
                           :children nil)))))
    (let ((res (kargu-lsp-read-file-symbols "src/order.py")))
      (should (string-search "2 symbol(s) found" res))
      (should (string-search "Function calculate_total [lines 10-25] ((items) -> int)" res))
      (should (string-search "Struct Order [lines 30-50]" res)))))

(defun kargu-lsp-test-temp-file (prefix)
  "Create a temporary file inside project root for testing."
  (let ((tmp-dir (file-name-as-directory (expand-file-name ".test-tmp" (kargu-permission-project-root)))))
    (unless (file-directory-p tmp-dir)
      (make-directory tmp-dir t))
    (make-temp-file (expand-file-name prefix tmp-dir))))

(ert-deftest kargu-lsp-read-symbol-test ()
  "Test that kargu-lsp-read-symbol extracts body or lists available symbols on error."
  (let* ((tmp (kargu-lsp-test-temp-file "kargu-sym-test.py")))
    (with-temp-file tmp
      (insert "def add(a, b):\n    return a + b\n\ndef sub(a, b):\n    return a - b\n"))
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-lsp-get-file-symbols)
                   (lambda (_path)
                     (list (list :name "add" :kind "Function" :start-line 1 :end-line 2 :detail nil :children nil)
                           (list :name "sub" :kind "Function" :start-line 4 :end-line 5 :detail nil :children nil)))))
          ;; 1. Found symbol
          (let ((res (kargu-lsp-read-symbol tmp "add")))
            (should (string-search "1 | def add(a, b):" res))
            (should (string-search "2 |     return a + b" res))
            (should-not (string-search "sub" res)))
          ;; 2. Missing symbol
          (let ((err-res (kargu-lsp-read-symbol tmp "multiply")))
            (should (string-search "ERROR: Symbol 'multiply' not found" err-res))
            (should (string-search "• Function add [lines 1-2]" err-res))
            (should (string-search "• Function sub [lines 4-5]" err-res))))
      (when (file-exists-p tmp)
        (delete-file tmp)))))

(ert-deftest kargu-lsp-edit-by-lsp-test ()
  "Test that kargu-lsp-edit-symbol replaces symbol body cleanly."
  (let* ((orig "def first():\n    return 1\n\ndef second():\n    return 2\n")
         (kargu-active-mode 'agent)
         (tmp (kargu-lsp-test-temp-file "kargu-edit-test.py")))
    (with-temp-file tmp (insert orig))
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-lsp-get-file-symbols)
                   (lambda (_path)
                     (list (list :name "first" :kind "Function" :start-line 1 :end-line 2 :detail nil :children nil)
                           (list :name "second" :kind "Function" :start-line 4 :end-line 5 :detail nil :children nil))))
                  ((symbol-function 'kargu-diff-apply-proposal)
                   (lambda (path content)
                     (with-temp-file path (insert content))
                     "PROPOSAL_OK"))
                  ((symbol-function 'kargu-diff--describe)
                   (lambda (_p) "Applied edit.")))
          (let ((res (kargu-lsp-edit-symbol tmp "second" "def second():\n    return 200\n    # updated")))
            (should (string-search "Successfully replaced Function `second`" res))
            (with-temp-buffer
              (insert-file-contents tmp)
              (let ((text (buffer-string)))
                (should (string-search "def first():\n    return 1" text))
                (should (string-search "def second():\n    return 200\n    # updated" text))
                (should-not (string-search "return 2\n" text))))))
      (when (file-exists-p tmp)
        (delete-file tmp)))))

(ert-deftest kargu-lsp-tool-dispatch-and-aliases-test ()
  "Test execution of read_file_symbols, read_symbol, edit_by_lsp and their aliases."
  (cl-letf (((symbol-function 'kargu-lsp-read-file-symbols)
             (lambda (path) (format "SYMBOLS_OUTLINE_FOR:%s" path)))
            ((symbol-function 'kargu-lsp-read-symbol)
             (lambda (path sym kind) (format "BODY_OF:%s:%s:%s" path sym kind)))
            ((symbol-function 'kargu-lsp-edit-symbol)
             (lambda (path sym content kind reason)
               (format "EDIT_OK:%s:%s:%s:%s:%s" path sym content kind reason))))
    ;; read_file_symbols & aliases
    (should (equal (kargu-execute-tool "read_file_symbols" '(("file_path" . "a.rs")))
                   "SYMBOLS_OUTLINE_FOR:a.rs"))
    (should (equal (kargu-execute-tool "read_file_outline" '(("file_path" . "a.rs")))
                   "SYMBOLS_OUTLINE_FOR:a.rs"))
    (should (equal (kargu-execute-tool "outline" '(("file_path" . "a.rs")))
                   "SYMBOLS_OUTLINE_FOR:a.rs"))
    ;; read_symbol & aliases
    (should (equal (kargu-execute-tool "read_symbol" '(("file_path" . "a.rs") ("symbol" . "foo") ("kind" . "Function")))
                   "BODY_OF:a.rs:foo:Function"))
    (should (equal (kargu-execute-tool "get_symbol" '(("file_path" . "a.rs") ("symbol" . "foo") ("kind" . "Function")))
                   "BODY_OF:a.rs:foo:Function"))
    ;; edit_by_lsp & aliases
    (should (equal (kargu-execute-tool "edit_by_lsp" '(("file_path" . "a.rs") ("symbol" . "bar") ("new_content" . "code") ("kind" . "Method")))
                   "EDIT_OK:a.rs:bar:code:Method:nil"))
    (should (equal (kargu-execute-tool "edit_symbol" '(("file_path" . "a.rs") ("symbol" . "bar") ("new_content" . "code") ("kind" . "Method")))
                   "EDIT_OK:a.rs:bar:code:Method:nil"))
    (should (equal (kargu-execute-tool "edit_with_lsp" '(("file_path" . "a.rs") ("symbol" . "bar") ("new_content" . "code") ("kind" . "Method")))
                   "EDIT_OK:a.rs:bar:code:Method:nil"))))

(provide 'tests/test-lsp)
;;; test-lsp.el ends here
