;;; test-modules.el --- Isolated module boundary tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A loaded test runner must not conceal a module's missing dependencies.
;; Load each boundary in a fresh Emacs, inside the test's temporary project.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst kargu-module-test--root
  (file-name-directory (locate-library "kargu"))
  "Package source directory, not the temporary project being tested.")

(defconst kargu-module-test--runtime-features
  '(kargu/core kargu/state kargu/state/store kargu/core/session
    kargu/config kargu/api kargu/loop kargu/chat kargu/ui)
  "Runtime and UI features forbidden in foundational module loads.")

(defun kargu-module-test--evaluate (forms &optional packages)
  "Evaluate FORMS in a fresh Emacs, optionally initializing PACKAGES."
  (let ((program (expand-file-name invocation-name invocation-directory))
        (expression
         `(progn
            (setq load-prefer-newer t default-directory ,default-directory)
            (require 'cl-lib)
            ,@(when packages '((require 'package) (package-initialize)))
            ,@forms)))
    (with-temp-buffer
      (let ((status (call-process program nil t nil "--batch" "-Q"
                                  "-L" kargu-module-test--root
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

(provide 'tests/test-modules)
;;; test-modules.el ends here
