;;; test-modules.el --- Isolated module boundary tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A loaded test runner must not conceal a module's missing dependencies.
;; Load each boundary in a fresh Emacs, inside the test's temporary project.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
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

(defun kargu-module-test--without-sources (prefixes forms)
  "Evaluate FORMS in a package physically missing source PREFIXES."
  (let* ((root (make-temp-file "kargu-module-matrix-" t))
         (files (cons (expand-file-name "kargu.el" kargu-module-test--root)
                      (directory-files-recursively
                       (expand-file-name "kargu" kargu-module-test--root)
                       "\\.\\(?:el\\|txt\\)\\'"))))
    (unwind-protect
        (progn
          (dolist (file files)
            (let* ((relative (file-relative-name file kargu-module-test--root))
                   (target (expand-file-name relative root)))
              (unless (seq-some (lambda (prefix) (string-prefix-p prefix relative)) prefixes)
                (make-directory (file-name-directory target) t)
                (copy-file file target))))
          (kargu-module-test--evaluate forms t root))
      (delete-directory root t))))

(ert-deftest kargu-module-chat-and-text-tools-without-debugger-or-lsp-test ()
  "Removing both editor adapters leaves chat and textual tools available."
  (kargu-module-test--without-sources
   '("kargu/tools/lsp.el" "kargu/tools/lsp/"
     "kargu/tools/dape.el" "kargu/tools/dape/")
   '((require 'kargu)
     (cl-assert (null (locate-library "kargu/tools/lsp")))
     (cl-assert (null (locate-library "kargu/tools/dape")))
     (cl-assert (kargu-find-tool "read_file"))
     (cl-assert (kargu-find-tool "workspace_grep"))
     (cl-assert (kargu-find-tool "git_status"))
     (cl-assert (not (kargu-find-tool "debug_start")))
     (cl-assert (not (kargu-find-tool "edit_by_lsp")))
     (with-temp-buffer
       (kargu-chat-mode)
       (kargu-chat--notice-without-eglot)
       (cl-assert (null (kargu-chat--symbol-candidates "missing")))
       (let (answered)
         (kargu-chat--async-candidates "@missing" (lambda (_) (setq answered t)))
         (cl-assert answered))
       (kargu-chat-stop)))))

(ert-deftest kargu-module-missing-diagnostics-is-not-clean-test ()
  "An absent diagnostic adapter reports unavailable, never clean evidence."
  (kargu-module-test--without-sources
   '("kargu/tools/lsp.el" "kargu/tools/lsp/")
   '((require 'kargu)
     (let (section)
       (kargu-loop--wait-diagnostics
        "missing.el" (lambda (path text timed-out)
                       (setq section (kargu--loop-diag-section path text timed-out))))
       (cl-assert (plist-get section :unavailable))
       (cl-assert (string-search "Verification incomplete"
                                 (kargu--loop-verify-footer (list section) 0 0)))))))

(ert-deftest kargu-module-tool-family-removal-matrix-test ()
  "Each independent tool family can be removed without disabling chat."
  (dolist (entry '((kargu/tools/search "workspace_grep" "grep")
                   (kargu/tools/bash "bash") (kargu/tools/git "git_status")
                   (kargu/tools/skill "skill") (kargu/tools/webfetch "webfetch")))
    (let ((source (symbol-name (car entry))))
      (kargu-module-test--without-sources
       (list (concat source ".el") (concat source "/"))
       `((require 'kargu)
         (cl-assert (not (featurep ',(car entry))))
         (dolist (name ',(cdr entry))
           (cl-assert (not (kargu-find-tool name))))
         (cl-assert (kargu-find-tool "read_file"))
         (cl-assert (commandp 'kargu-chat-show))
         (with-temp-buffer (kargu-chat-mode) (kargu-chat-stop)))))))

(ert-deftest kargu-module-text-editing-without-other-tool-families-test ()
  "Text reading and chat survive removal of every other tool family."
  (let ((families '("lsp" "dape" "search" "bash" "git" "skill" "webfetch")))
    (kargu-module-test--without-sources
     (cl-mapcan (lambda (name)
                  (list (concat "kargu/tools/" name ".el")
                        (concat "kargu/tools/" name "/"))) families)
     '((require 'kargu)
       (dolist (name '("debug_start" "lsp_diagnostics" "workspace_grep"
                       "bash" "git_status" "skill" "webfetch"))
         (cl-assert (not (kargu-find-tool name))))
       (cl-assert (kargu-find-tool "edit_file"))
       (with-temp-file "remaining.txt" (insert "Readable without adapters"))
       (let ((kargu-permission--override-root default-directory))
         (let ((result (kargu-execute-tool
                        "read_file" '(("file_path" . "remaining.txt")))))
           (cl-assert (string-search "Readable without adapters" result) nil
                      "Reading without adapters returned: %s" result)))
       (with-temp-buffer (kargu-chat-mode) (kargu-chat-stop))))))

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

(ert-deftest kargu-module-confirmation-port-is-independent-test ()
  "The control contract requires no UI and never invents human approval."
  (kargu-module-test--load-foundation
   'kargu/confirm
   '(cl-assert (not (featurep 'kargu/ui/confirm)))
   '(let ((kargu-confirm--mock-decision :approve) decisions)
      (kargu-confirm :default-action :reject
                     :on-decision (lambda (decision) (push decision decisions)))
      (kargu-confirm :on-decision (lambda (decision) (push decision decisions)))
      (kargu-dismiss-confirmations)
      (cl-assert (equal decisions '(:stop :reject))))))

(ert-deftest kargu-module-confirmation-rejects-unsafe-options-test ()
  "Invalid boundary input cannot reach a confirmation adapter."
  (kargu-module-test--load-foundation
   'kargu/confirm
   '(cl-letf (((symbol-function 'kargu-present-confirmation)
               (lambda (_) (error "Adapter must not be called"))))
      (dolist (options '((:default-action :approve :on-decision ignore)
                         (:on-decision nil) (:on-decision)))
        (cl-assert
         (condition-case err
             (progn (apply #'kargu-confirm options) nil)
           (error (not (equal (error-message-string err)
                              "Adapter must not be called")))))))))

(ert-deftest kargu-module-confirmation-adapter-unload-test ()
  "An adapter refuses active unloading; closed prompts remain inert."
  (kargu-module-test--evaluate
   '((require 'kargu/ui/confirm)
     (kargu-ui-confirm-install)
     (kargu-ui-confirm-install)
     (with-temp-buffer
       (let ((noninteractive nil) decisions action)
         (cl-letf (((symbol-function 'kargu-confirm--reveal) #'ignore))
           (kargu-confirm :chat-buffer (current-buffer)
                          :actions '((:key :approve :label "Approve"))
                          :on-decision (lambda (value) (push value decisions))))
         (setq action (button-get (next-button (point-min)) 'action))
         (cl-assert (condition-case nil
                        (progn (unload-feature 'kargu/ui/confirm t) nil)
                      (user-error t)))
         (cl-assert (featurep 'kargu/ui/confirm))
         (kargu-dismiss-confirmations)
         (unload-feature 'kargu/ui/confirm t)
         (cl-assert (not (featurep 'kargu/ui/confirm)))
         (funcall action nil)
         (kargu-confirm :on-decision (lambda (value) (push value decisions)))
         (cl-assert (equal decisions '(:stop :cancel)))
         (require 'kargu/ui/confirm)
         (kargu-ui-confirm-install)
         (let ((kargu-confirm--mock-decision :approve))
           (kargu-confirm :on-decision (lambda (value) (push value decisions))))
         (funcall action nil)
         (cl-assert (equal decisions '(:approve :stop :cancel)))))) t))

(ert-deftest kargu-module-headless-startup-with-ui-installed-test ()
  "A headless startup choice avoids loading even installed UI adapters."
  (kargu-module-test--evaluate
   '((setq kargu-ui-enabled nil)
     (require 'kargu)
     (dolist (feature '(kargu/chat kargu/ui kargu/ui/confirm kargu/plan))
       (cl-assert (not (featurep feature))))) t))

(ert-deftest kargu-module-headless-run-without-ui-sources-test ()
  "A fake model run completes with chat, plan and UI source trees absent."
  (kargu-module-test--without-sources
   '("kargu/chat.el" "kargu/chat/" "kargu/ui.el" "kargu/ui/"
     "kargu/plan.el" "kargu/plan/")
   '((setq kargu-ui-enabled nil)
     (require 'kargu)
     (dolist (feature '(kargu/chat kargu/ui/confirm kargu/ui/transient kargu/plan))
       (cl-assert (not (featurep feature))))
     (cl-assert (null (locate-library "kargu/chat")))
     (cl-assert (kargu-find-tool "read_file"))
     (let (report approved)
       (cl-letf (((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
                 ((symbol-function 'kargu-model-supports-tools-p) (lambda (&rest _) nil))
                 ((symbol-function 'kargu-api-send)
                  (lambda (_prompt callback &rest _)
                    (funcall callback
                             '(("choices" . [(("finish_reason" . "stop")
                                               ("message" . (("role" . "assistant")
                                                             ("content" . "Headless answer"))))]))))))
         (kargu-loop-send "Offline question" nil (lambda (value) (setq report value))))
       (cl-assert (eq (plist-get report :status) :done))
       (cl-assert (equal (plist-get report :text) "Headless answer"))
       (cl-assert (not (kargu-loop-running-p)))
       (let ((noninteractive nil))
         (kargu-permission-request-approval-async
          "dangerous command" default-directory '("risk")
          (lambda (value) (setq approved (if value :approved :rejected)))))
       (cl-assert (eq approved :rejected))))))

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
