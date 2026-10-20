;;; test-modules.el --- Isolated module boundary tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A loaded test runner must not conceal a module's missing dependencies.
;; Load each boundary in a fresh Emacs, inside the test's temporary project.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tests/module-boundaries)

(defconst kargu-module-test--root
  (file-name-directory (locate-library "kargu"))
  "Package source directory, not the temporary project being tested.")

(defconst kargu-module-test--runtime-features
  '(kargu/core kargu/state kargu/state/store kargu/core/session
    kargu/config kargu/api kargu/loop kargu/chat kargu/ui)
  "Runtime and UI features forbidden in foundational module loads.")

(defun kargu-module-test--evaluate (forms &optional packages root)
  "Evaluate FORMS in a fresh Emacs using ROOT or the source package.
Initialize installed PACKAGES only when requested."
  (let ((program (expand-file-name invocation-name invocation-directory))
        (expression
         `(progn
            (setq load-prefer-newer t default-directory ,default-directory)
            (require 'cl-lib)
            ,@(when packages '((require 'package) (package-initialize)))
            ,@forms)))
    (with-temp-buffer
      (let ((status (call-process program nil t nil "--batch" "-Q"
                                  "-L" (or root kargu-module-test--root)
                                  "--eval" (prin1-to-string expression))))
        (unless (eql status 0)
          (ert-fail (format "Isolated module test failed (%s):\n%s"
                            status (buffer-string))))))))

(defun kargu-module-test--load-foundation (feature &rest assertions)
  "Load FEATURE without runtime dependencies, then evaluate ASSERTIONS."
  (kargu-module-test--evaluate
   `((require ',feature)
     (dolist (forbidden ',kargu-module-test--runtime-features)
       (when (featurep forbidden) (error "Unexpected dependency: %s" forbidden)))
     (when (boundp 'kargu--state-store) (error "State store was initialized"))
     (when (boundp 'kargu--session) (error "Session was initialized"))
     (when (boundp 'kargu--tool-registry) (error "Tool registry was initialized"))
     ,@assertions)))

(ert-deftest kargu-module-contract-is-independent-test ()
  "Boundary predicates and result records need no application runtime."
  (kargu-module-test--load-foundation
   'kargu/contract
   '(cl-assert (kargu-contract-mode-p 'agent))
   '(cl-assert (kargu-ok-p (kargu-ok "value")))))

(ert-deftest kargu-module-data-is-independent-test ()
  "Legacy scalar helpers retain behavior without loading application state."
  (kargu-module-test--load-foundation
   'kargu/core/data
   '(cl-assert (equal (kargu-aget '(("name" . "value")) "name") "value"))
   '(cl-assert (equal (kargu--aget '(("name" . "value")) "name") "value"))
   '(cl-assert (eq (kargu-aget "not-an-object" "name" :missing) :missing))
   '(cl-assert (= (kargu-to-int " 12 ") 12))
   '(cl-assert (eq (kargu-to-int "broken" :missing) :missing))
   '(cl-assert (string-prefix-p "abc" (kargu-cap-text "abcdef" 3)))))

(ert-deftest kargu-module-tool-registry-is-independent-test ()
  "An explicit registry operates without initializing a default runtime."
  (kargu-module-test--load-foundation
   'kargu/tools/registry
   '(let ((registry (kargu-tool-registry-create)))
      (kargu-tool-registry-register registry :name "read" :description "Read"
                                    :executor #'ignore)
      (cl-assert (kargu-tool-registry-find registry "read"))
      (cl-assert (= (kargu-tool-registry-count registry) 1))
      (cl-assert (kargu-tool-registry-remove registry "read"))
      (cl-assert (zerop (kargu-tool-registry-count registry))))))

(ert-deftest kargu-module-json-is-independent-test ()
  "The JSON codec keeps wire identities without initializing a session."
  (kargu-module-test--load-foundation
   'kargu/json
   '(let ((wire "{\"text\":\"Türkçe 🙂\",\"empty\":[],\"null\":null,\"false\":false}"))
      (cl-assert (equal (kargu--json-encode (kargu-json-decode wire)) wire)))))

(ert-deftest kargu-module-path-guards-are-independent-test ()
  "Path guards enforce their root without loading the agent or chat."
  (kargu-module-test--load-foundation
   'kargu/permission/guards
   '(let ((kargu-permission--override-root default-directory))
      (cl-assert (kargu-permission-within-project-p
                  (expand-file-name "source.el") default-directory))
      (cl-assert (not (kargu-permission-within-project-p
                       "/etc/passwd" default-directory))))))

(ert-deftest kargu-module-filesystem-is-independent-test ()
  "A bounded filesystem walk does not initialize the application."
  (kargu-module-test--load-foundation
   'kargu/fs
   '(cl-assert (listp (kargu-fs-walk default-directory 1)))))

(ert-deftest kargu-module-process-is-independent-test ()
  "Loading the process service alone starts no process or runtime."
  (kargu-module-test--evaluate
   '((let ((before (process-list)))
       (require 'kargu/tools/process)
       (cl-assert (equal before (process-list)))
       (dolist (feature '(kargu/core kargu/state/store kargu/core/session kargu/loop kargu/chat))
         (cl-assert (not (featurep feature))))))))

(ert-deftest kargu-module-async-is-independent-test ()
  "A task can finish once without loading state, history or UI."
  (kargu-module-test--load-foundation
   'kargu/async
   '(let (results)
      (let ((task (kargu-async-start (lambda (value error) (push (cons value error) results)))))
        (kargu-async-finish task "value")
        (kargu-async-finish task "duplicate")
        (cl-assert (equal results '(("value"))))
        (cl-assert (null kargu-async--pending))))))

(ert-deftest kargu-module-api-does-not-load-selection-ui-test ()
  "The API facade loads headlessly without the Company/footer adapter."
  (kargu-module-test--evaluate
   '((require 'kargu/api)
     (dolist (feature '(kargu/api/select kargu/chat/select kargu/chat kargu/chat/prompt kargu/ui))
       (cl-assert (not (featurep feature))))
     (cl-assert (null (kargu-registered-tools)))
     (cl-assert (autoloadp (symbol-function 'kargu-set-model))))
   t))

(ert-deftest kargu-module-selection-compatibility-entry-test ()
  "The legacy feature still exposes the same public selection commands."
  (kargu-module-test--evaluate
   '((require 'kargu/api/select)
     (cl-assert (featurep 'kargu/chat/select))
     (cl-assert (not (featurep 'kargu/chat)))
     (dolist (command '(kargu-set-model kargu-switch-provider-and-model
                        kargu-chat-select-provider kargu-chat-select-mode-company
                        kargu-chat-select-provider-company kargu-chat-select-model-company
                        kargu-chat-select-effort-company))
       (cl-assert (commandp command))))
   t))

(ert-deftest kargu-module-tool-loads-do-not-register-tools-test ()
  "Tool implementations load without registration, HTTP or chat adapters."
  (dolist (feature '(kargu/tools/lsp kargu/tools/search kargu/tools/dape
                     kargu/tools/diff kargu/tools/bash kargu/tools/git
                     kargu/tools/skill kargu/tools/webfetch))
    (kargu-module-test--evaluate
     `((require 'kargu/api/tools)
       (cl-assert (null (kargu-registered-tools)))
       (require ',feature)
       (cl-assert (null (kargu-registered-tools)))
       (dolist (forbidden '(kargu/api kargu/api/http kargu/api/client
                            kargu/api/catalog kargu/chat))
         (cl-assert (not (featurep forbidden)) nil
                    "Tool module loaded %s" forbidden)))
     t)))

(ert-deftest kargu-module-root-registers-compatible-tools-once-test ()
  "Composition retains core tools, aliases and repeated registration behavior."
  (kargu-module-test--evaluate
   '((require 'kargu)
     (dolist (name '("read_file" "edit_file" "write_file" "apply_patch"
                     "edit_by_lsp" "debug_start" "bash" "git_status" "skill"))
       (cl-assert (member name (kargu-registered-tools))))
     (cl-assert (equal (kargu-canonical-tool-name "edit_symbol") "edit_by_lsp"))
     (cl-assert (equal (kargu-canonical-tool-name "step_over") "debug_step_over"))
     (let ((before (sort (kargu-registered-tools) #'string<)))
       (kargu-search-register-tools)
       (kargu-lsp-register-tools)
       (kargu-dape-register-tools)
       (cl-assert (equal before (sort (kargu-registered-tools) #'string<))))
     (cl-assert (commandp 'kargu-chat-show)))
   t))

(ert-deftest kargu-module-tools-work-without-model-transport-sources-test ()
  "Tool definitions register when model HTTP/client sources are absent."
  (let* ((root (make-temp-file "kargu-tool-package-" t))
         (missing '("kargu/api.el" "kargu/api/http.el"
                    "kargu/api/client.el" "kargu/api/catalog.el"))
         (files (directory-files-recursively
                 (expand-file-name "kargu" kargu-module-test--root) "\\.el\\'")))
    (unwind-protect
        (progn
          (dolist (file files)
            (let* ((relative (file-relative-name file kargu-module-test--root))
                   (target (expand-file-name relative root)))
              (unless (member relative missing)
                (make-directory (file-name-directory target) t)
                (copy-file file target))))
          (kargu-module-test--evaluate
           '((dolist (feature '(kargu/tools/lsp kargu/tools/search kargu/tools/dape
                               kargu/tools/diff kargu/tools/bash kargu/tools/git
                               kargu/tools/skill kargu/tools/webfetch))
               (require feature))
             (cl-assert (null (locate-library "kargu/api")))
             (cl-assert (null (locate-library "kargu/api/http")))
             (cl-assert (null (kargu-registered-tools)))
             (kargu-search-register-tools)
             (kargu-lsp-register-tools)
             (kargu-dape-register-tools)
             (cl-assert (kargu-find-tool "workspace_grep"))
             (cl-assert (kargu-find-tool "read_file_symbols"))
             (cl-assert (kargu-find-tool "debug_start")))
           t root))
      (delete-directory root t))))

(defun kargu-module-test--requires (file)
  "Read FILE's literal top-level imports without executing its code."
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (goto-char (point-min))
    (let (imports)
      (while (progn (forward-comment (point-max)) (not (eobp)))
        (let ((form (read (current-buffer))))
          (when (and (consp form) (eq (car form) 'require)
                     (consp (cadr form)) (eq (caadr form) 'quote))
            (push (cadadr form) imports))))
      imports)))

(ert-deftest kargu-module-legacy-facade-debt-cannot-grow-test ()
  "Broad facade imports must match the explicit shrinking migration budget."
  (let ((files (directory-files-recursively
                (expand-file-name "kargu" kargu-module-test--root) "\\.el\\'"))
        (actual (make-hash-table :test #'eq)))
    (dolist (file files)
      (let ((feature (intern (file-name-sans-extension
                              (file-relative-name file kargu-module-test--root)))))
        (dolist (dependency (kargu-module-test--requires file))
          (when (assq dependency kargu-module-test--legacy-dependencies)
            (push feature (gethash dependency actual))))))
    (dolist (entry kargu-module-test--legacy-dependencies)
      (should (equal (sort (gethash (car entry) actual) #'string<)
                     (sort (copy-sequence (cdr entry)) #'string<))))))

(ert-deftest kargu-module-foundations-work-without-optional-source-files-test ()
  "A reduced package tree can use foundations without runtime or UI sources."
  (let ((root (make-temp-file "kargu-module-package-" t))
        (files '("kargu/core/data.el" "kargu/core/group.el" "kargu/core/custom.el"
                 "kargu/core/log.el" "kargu/json.el" "kargu/fs.el" "kargu/async.el"
                 "kargu/contract/constants.el" "kargu/contract/types.el"
                 "kargu/contract/result.el" "kargu/contract/assert.el"
                 "kargu/tools/registry.el"
                 "kargu/permission/guards.el" "kargu/tools/process.el")))
    (unwind-protect
        (progn
          (dolist (file files)
            (let ((target (expand-file-name file root)))
              (make-directory (file-name-directory target) t)
              (copy-file (expand-file-name file kargu-module-test--root) target)))
          (kargu-module-test--evaluate
           '((dolist (feature '(kargu/json kargu/fs kargu/async
                               kargu/permission/guards kargu/tools/process
                               kargu/tools/registry))
               (require feature))
             (cl-assert (null (locate-library "kargu/chat")))
             (cl-assert (null (locate-library "kargu/api")))
             (cl-assert (null (locate-library "kargu/state"))))
           nil root))
      (delete-directory root t))))

(provide 'tests/test-modules)
;;; test-modules.el ends here
