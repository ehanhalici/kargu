;;; tests/test-lsp.el --- Tests for kargu/tools/lsp Eglot support -*- lexical-binding: t; -*-

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

(require 'tests/test-helpers)
(require 'ert)

(ert-deftest kargu-lsp-skeleton-cache-is-project-scoped-test ()
  "A skeleton from another project is never reused."
  (let ((kargu-lsp--skeleton-cache
         (list :root "/project-a/" :text "cached" :time (current-time))))
    (cl-letf (((symbol-function 'kargu-lsp-project-root) (lambda () "/project-b/")))
      (should-not (kargu-lsp--cached-skeleton)))
    (cl-letf (((symbol-function 'kargu-lsp-project-root) (lambda () "/project-a/")))
      (should (equal (kargu-lsp--cached-skeleton) "cached")))))

(ert-deftest kargu-lsp-skeleton-respects-total-symbol-cap-test ()
  "The total symbol cap also limits the final file's contribution."
  (let ((root (make-temp-file "kargu-skeleton-" t))
        (kargu-lsp-skeleton-max-symbols 3)
        (kargu-lsp-skeleton-max-per-file 2))
    (unwind-protect
        (let* ((a (expand-file-name "a.el" root))
               (b (expand-file-name "b.el" root))
               (text (kargu-lsp--render-skeleton
                      root "test"
                      (list (list a 1 "first" 12) (list a 2 "second" 12)
                            (list b 1 "third" 12) (list b 2 "hidden" 12)))))
          (should (string-prefix-p "# Project skeleton" text))
          (should (string-search "third (Function)" text))
          (should-not (string-search "hidden (Function)" text))
          (should (string-search "1 more hidden" text)))
      (delete-directory root t))))
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

(ert-deftest kargu-lsp-request-is-asynchronous-and-once-test ()
  "Starting a delayed request returns immediately and delivers only once."
  (let (keys result task)
    (with-temp-buffer
      (cl-letf (((symbol-function 'eglot-current-server) (lambda () 'server))
                ((symbol-function 'jsonrpc-async-request)
                 (lambda (_server method params &rest options)
                   (should (eq method :workspace/symbol))
                   (should (equal params '(:query "foo")))
                   (setq keys options))))
        (setq task (kargu-lsp--request
                    "workspace/symbol" '(:query "foo")
                    (lambda (value error) (push (list value error) result))))
        (should (kargu-async-pending-p task))
        (should-not result)
        (funcall (plist-get keys :success-fn) 'symbols)
        (funcall (plist-get keys :error-fn) 'disconnected)
        (funcall (plist-get keys :timeout-fn))
        (should (equal result '((symbols nil))))
        (should-not (kargu-async-task-timer task))))))

(ert-deftest kargu-lsp-request-timeout-and-cancellation-test ()
  "Timeout completes once; stopped runs discard late callbacks and timers."
  (let ((kargu-lsp-request-timeout 7) keys result)
    (with-temp-buffer
      (cl-letf (((symbol-function 'eglot-current-server) (lambda () 'server))
                ((symbol-function 'jsonrpc-async-request)
                 (lambda (_srv _method _params &rest options) (setq keys options))))
        (let ((task (kargu-lsp--request
                     :textDocument/hover '(:x 1)
                     (lambda (_value error) (push error result)))))
          (should (= (plist-get keys :timeout) 7))
          (funcall (plist-get keys :timeout-fn))
          (funcall (plist-get keys :success-fn) 'late)
          (should (= (length result) 1))
          (should (string-search "timed out" (car result)))
          (should-not (kargu-async-task-timer task)))
        (setq result nil)
        (let* ((kargu--loop-run (list :state 'tools))
               (task (kargu-lsp--request
                      :textDocument/hover nil
                      (lambda (&rest _) (push 'unexpected result)))))
          (kargu-async-cancel-owner kargu--loop-run)
          (funcall (plist-get keys :success-fn) 'late)
          (should-not result)
          (should-not (kargu-async-task-timer task))
          (should-not (memq task kargu-async--pending)))))))

(ert-deftest kargu-lsp-request-rejects-stale-document-test ()
  "A result for an edited document cannot provide stale symbol boundaries."
  (let (keys result)
    (with-temp-buffer
      (cl-letf (((symbol-function 'eglot-current-server) (lambda () 'server))
                ((symbol-function 'jsonrpc-async-request)
                 (lambda (_srv _method _params &rest opts) (setq keys opts))))
        (kargu-lsp--request :textDocument/documentSymbol nil
                            (lambda (value error) (setq result (list value error))))
        (insert "changed")
        (funcall (plist-get keys :success-fn) 'stale)
        (should-not (car result))
        (should (string-search "changed" (cadr result)))))))

(ert-deftest kargu-lsp-diagnostics-preserve-real-locations-test ()
  "Character columns survive Unicode, tabs, narrowing and deduplication."
  (require 'flymake)
  (kargu-test-with-git-repo '(("columns.el" . "önce\n\t🙂wrong\n"))
    (let* ((path (expand-file-name "columns.el" repo))
           (buffer (find-file-noselect path)))
      (unwind-protect
          (with-current-buffer buffer
            (let* ((diag (flymake-make-diagnostic buffer 8 9 :error "wrong"))
                   (other (flymake-make-diagnostic buffer 9 10 :error "wrong")))
              (narrow-to-region 9 (point-max))
              (goto-char 10)
              (cl-letf (((symbol-function 'flymake-diagnostics)
                         (lambda (&rest _) (list diag other))))
                (let ((local (car (kargu-lsp--flymake-diags path)))
                      (project (kargu-lsp--extract-flymake-diag diag)))
                  (dolist (record (list local project))
                    (should (= (plist-get record :line) 2))
                    (should (= (plist-get record :character) 3)))
                  (should (= (length (kargu-lsp--diagnostics-data path)) 2))
                  (should (= (point) 10))
                  (should (= (point-min) 9))))))
        (kill-buffer buffer)))))

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
  "Test that kargu-lsp-project-root extracts root from Eglot server project."
  (with-temp-buffer
    (setq-local buffer-file-name "/tmp/repo/src/main.rs")
    (setq-local eglot--managed-mode t)
    (let ((kargu-context-buffer (current-buffer))
          (kargu-permission--override-root nil))
      (cl-letf (((symbol-function 'eglot-current-server) (lambda (&rest _) 'mock-server))
                ((symbol-function 'eglot-project) (lambda (&rest _) '(project . "/tmp/repo/")))
                ((symbol-function 'project-root) (lambda (proj) (cdr proj))))
        (should (equal (kargu-lsp-project-root) "/tmp/repo/"))))))

(ert-deftest kargu-project-root-follows-eglot-not-temp-directory ()
  "A buffer under /tmp/ does not replace the Eglot server's project."
  (let ((managed (generate-new-buffer "main.py"))
        (kargu-permission--override-root nil))
    (unwind-protect
        (progn
          (with-current-buffer managed
            (setq buffer-file-name "/home/emrehan/kod/try/dikte/main.py")
            (setq default-directory "/home/emrehan/kod/try/dikte/")
            (setq-local eglot--managed-mode t))
          (with-temp-buffer
            (setq default-directory "/tmp/")
            (setq-local kargu-chat--project-root "/home/emrehan/kod/try/dikte/")
            (cl-letf (((symbol-function 'eglot-current-server)
                       (lambda (&rest _) 'mock-server))
                      ((symbol-function 'project-current) (lambda (&rest _) nil))
                      ((symbol-function 'eglot--project)
                       (lambda (_server)
                         '(eglot--project . "/home/emrehan/kod/try/dikte/")))
                      ((symbol-function 'project-root)
                       (lambda (proj) (cdr proj))))
              (should (equal (kargu-lsp-project-root)
                             "/home/emrehan/kod/try/dikte/"))
              (should (kargu-eglot-connected-p)))))
      (when (buffer-live-p managed) (kill-buffer managed)))))

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
    (cl-letf (((symbol-function 'kargu-lsp-project-root) (lambda () mock-root))
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
            ((symbol-function 'kargu-eglot-connected-p) (lambda () t))
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
  (let ((tmp-dir (file-name-as-directory (kargu-permission-project-root))))
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
         (_ (kargu-test-mode 'agent))
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
            (should (string-search "Edit of Function `second`" res))
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
             (lambda (path &optional callback)
               (let ((text (format "SYMBOLS_OUTLINE_FOR:%s" path)))
                 (if callback (funcall callback text) text))))
            ((symbol-function 'kargu-eglot-connected-p) (lambda () t))
            ((symbol-function 'kargu-state-mode) (lambda () 'agent))
            ((symbol-function 'kargu-lsp-read-symbol)
             (lambda (path sym kind &optional callback)
               (let ((text (format "BODY_OF:%s:%s:%s" path sym kind)))
                 (if callback (funcall callback text) text))))
            ((symbol-function 'kargu-lsp-edit-symbol)
             (lambda (path sym content kind reason &optional callback)
               (let ((text (format "EDIT_OK:%s:%s:%s:%s:%s" path sym content kind reason)))
                 (if callback (funcall callback text) text)))))
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

(ert-deftest kargu-lsp-symbol-end-and-name-test ()
  "An exclusive LSP end at column 0 does not swallow the next line.
A kind filter does not select an unrelated symbol."
  (should (= (kargu-lsp--inclusive-end 10 13 0) 13))
  (should (= (kargu-lsp--inclusive-end 10 12 4) 13))
  (let ((symbols '((:name "alpha" :kind "Function")
                   (:name "beta" :kind "Function"))))
    (should-not (kargu-lsp--find-symbol-in-list symbols "missing" "Function"))
    (should (equal (plist-get
                    (car (kargu-lsp--find-symbol-in-list symbols "beta" "Function"))
                    :name)
                   "beta"))))

(ert-deftest kargu-lsp-native-elisp-navigation-needs-no-server-test ()
  "Native xref and imenu serve Lisp tools without loading project code."
  (kargu-test-with-git-repo
      '(("native.el" . "(defun kargu-test-native-only ()\n  t)\n"))
    (let* ((path (expand-file-name "native.el" repo))
           (buffer (find-file-noselect path))
           (kargu-context-buffer buffer)
           (elisp-xref-find-def-functions
            (list (lambda (symbol)
                    (when (eq symbol 'kargu-test-native-only)
                      (list (xref-make "native fixture"
                                       (xref-make-elisp-location symbol nil path))))))))
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-eglot-connected-p) #'ignore)
                    ((symbol-function 'kargu-lsp--request)
                     (lambda (&rest _) (error "No external server should be called"))))
            (kargu-test-mode 'ask)
            (dolist (name '("lsp_find_symbol" "read_file_symbols" "read_symbol" "outline"))
              (should (kargu-tool-visible-p name)))
            (should-not (kargu-tool-visible-p "edit_by_lsp"))
            (should-not (kargu-tool-visible-p "lsp_diagnostics"))
            (should-not (fboundp 'kargu-test-native-only))
            (let ((definition (kargu-execute-tool
                               "lsp_find_symbol" '(("symbol_name" . "kargu-test-native-only")))))
              (should (string-search (concat path ":1") definition)))
            (let ((outline (kargu-test-await
                            (lambda (callback)
                              (kargu-execute-tool "read_file_symbols"
                                                  '(("file_path" . "native.el")) callback)))))
              (should (string-search "kargu-test-native-only" outline)))
            (should-not (fboundp 'kargu-test-native-only))
            (kargu-test-mode 'agent)
            (should (kargu-tool-visible-p "edit_by_lsp")))
        (kill-buffer buffer)))))

(ert-deftest kargu-lsp-native-xref-filters-foreign-projects-before-opening-test ()
  "A native xref result outside the workspace is not opened or returned."
  (kargu-test-with-git-repo '(("native.el" . "(defun local-name () t)\n"))
    (let ((outside (make-temp-file "kargu-foreign-xref-" nil ".el")))
      (unwind-protect
          (cl-letf (((symbol-function 'xref-backend-definitions)
                     (lambda (_backend _name)
                       (list (xref-make "foreign" (xref-make-file-location outside 1 0))))))
            (should-not (kargu-lsp--elisp-definition-items "foreign"))
            (should-not (find-buffer-visiting outside)))
        (delete-file outside)))))

(defvar kargu-test-native-local-eval nil)

(ert-deftest kargu-lsp-native-xref-never-evaluates-file-locals-test ()
  "Opening a native xref target never evaluates project-controlled locals."
  (kargu-test-with-git-repo
      '(("target.el" . "(defun kargu-test-local-target () t)\n;; Local Variables:\n;; eval: (setq kargu-test-native-local-eval t)\n;; End:\n"))
    (let ((path (expand-file-name "target.el" repo))
          (enable-local-eval t) (kargu-test-native-local-eval nil))
      (unwind-protect
          (cl-letf (((symbol-function 'xref-backend-definitions)
                     (lambda (_backend _name)
                       (list (xref-make "target" (xref-make-file-location path 1 0))))))
            (should (kargu-lsp--elisp-definition-items "target"))
            (should-not kargu-test-native-local-eval))
        (when-let* ((buffer (find-buffer-visiting path))) (kill-buffer buffer))))))

(ert-deftest kargu-lsp-unavailable-tools-are-hidden-and-rejected-test ()
  "Unavailable LSP tools and aliases agree in prompts, schemas and execution."
  (kargu-test-mode 'agent)
  (cl-letf (((symbol-function 'kargu-eglot-connected-p) (lambda () nil)))
    (dolist (name '("lsp_project_skeleton" "lsp_diagnostics" "lsp_find_symbol"
                    "read_file_symbols" "read_symbol" "edit_by_lsp"
                    "outline" "get_symbol" "edit_symbol"))
      (should-not (kargu-tool-visible-p name))
      (should (kargu-loop--gate-tool name))
      (should (string-prefix-p "ERROR: LSP" (kargu-execute-tool name nil))))
    (let ((prompt (kargu--get-system-prompt))
          (reminder (kargu-prompt-mode-reminder)))
      (should-not (string-search "lsp_diagnostics" prompt))
      (should-not (string-search "edit_by_lsp" prompt))
      (should-not (string-search "read_file_symbols" reminder))
      (should (string-search "workspace_grep" prompt)))))

(ert-deftest kargu-lsp-edit-policy-applies-to-canonical-name-and-aliases-test ()
  "Symbol edits cannot bypass read-only modes through a canonical name."
  (cl-letf (((symbol-function 'kargu-eglot-connected-p) (lambda () t)))
    (dolist (mode '(ask plan debug))
      (kargu-test-mode mode)
      (dolist (name '("edit_by_lsp" "edit_symbol" "edit_with_lsp"))
        (should-not (kargu-tool-visible-p name))
        (should (kargu-loop--gate-tool name))
        (should (string-prefix-p "ERROR:" (kargu-execute-tool name nil)))))))

(ert-deftest kargu-lsp-unrelated-project-does-not-count-test ()
  "A managed file in another workspace cannot grant LSP access."
  (let ((kargu-context-buffer nil)
        (managed (generate-new-buffer " *kargu-other-project*")))
    (unwind-protect
        (progn
          (with-current-buffer managed
            (setq buffer-file-name "/tmp/kargu-project-a/main.py")
            (setq-local eglot--managed-mode t))
          (with-temp-buffer
            (setq-local kargu-chat--project-root "/tmp/kargu-project-b/")
            (cl-letf (((symbol-function 'eglot-current-server)
                       (lambda () 'other-server))
                      ((symbol-function 'kargu-permission-eglot-server-root)
                       (lambda (_) "/tmp/kargu-project-a/")))
              (should-not (kargu-eglot-connected-p))
              (should-not (kargu-lsp-project-root)))))
      (kill-buffer managed))))

(ert-deftest kargu-lsp-tool-waits-for-asynchronous-symbols-test ()
  "A symbol tool returns immediately and later delivers its fresh outline."
  (let* ((path (kargu-lsp-test-temp-file "kargu-async-symbols-"))
         (buffer (find-file-noselect path)) keys results)
    (unwind-protect
        (with-current-buffer buffer
          (setq-local eglot--managed-mode t)
          (cl-letf (((symbol-function 'eglot-current-server) (lambda () 'server))
                    ((symbol-function 'kargu-eglot-connected-p) (lambda () t))
                    ((symbol-function 'jsonrpc-request)
                     (lambda (&rest _) (error "Synchronous request is forbidden")))
                    ((symbol-function 'jsonrpc-async-request)
                     (lambda (_srv _method _params &rest options) (setq keys options))))
            (kargu-execute-tool "read_file_symbols" `(("file_path" . ,path))
                                (lambda (text) (push text results)))
            (should-not results)
            (funcall (plist-get keys :success-fn)
                     '((:name "fresh" :kind 12
                              :range (:start (:line 0) :end (:line 2 :character 0)))))
            (funcall (plist-get keys :success-fn) nil)
            (should (= (length results) 1))
            (should (string-search "fresh" (car results)))))
      (kill-buffer buffer)
      (delete-file path))))

(ert-deftest kargu-lsp-symbol-edit-waits-for-review-test ()
  "Finishing symbol lookup does not prematurely complete a pending review."
  (kargu-test-mode 'agent)
  (let ((path (kargu-lsp-test-temp-file "kargu-symbol-review-")) review result)
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-lsp-get-file-symbols)
                   (lambda (_path callback)
                     (funcall callback '((:name "main" :kind "Function"
                                                :start-line 1 :end-line 1)) nil)))
                  ((symbol-function 'kargu-eglot-connected-p) (lambda () t))
                  ((symbol-function 'kargu-diff-apply-proposal)
                   (lambda (_path _text callback) (setq review callback) '(:status :staged))))
          (kargu-execute-tool
           "edit_by_lsp" `(("file_path" . ,path) ("symbol" . "main")
                           ("new_content" . "replacement"))
           (lambda (text) (setq result text)))
          (should review)
          (should-not result)
          (funcall review '(:status :rejected))
          (should (stringp result))
          (should-not (string-prefix-p "ERROR:" result)))
      (delete-file path))))

(ert-deftest kargu-lsp-company-uses-asynchronous-candidates-test ()
  "Company waits by callback instead of blocking Emacs for LSP symbols."
  (let (deliver result)
    (with-temp-buffer
      (cl-letf (((symbol-function 'kargu-eglot-connected-p) (lambda () t))
                ((symbol-function 'kargu-chat--completion-roots) (lambda () nil))
                ((symbol-function 'kargu-lsp-all-symbols)
                 (lambda (_query _roots callback) (setq deliver callback)))
                ((symbol-function 'kargu-chat--file-candidates) (lambda (_) '("@a.el"))))
        (let ((candidates (kargu-chat-company 'candidates "@a")))
          (should (eq (car candidates) :async))
          (funcall (cdr candidates) (lambda (values) (setq result values)))
          (should-not result)
          (funcall deliver nil)
          (should (equal result '("@a.el"))))))))

(provide 'tests/test-lsp)
;;; test-lsp.el ends here
