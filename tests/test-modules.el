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
     (when (bound-and-true-p kargu-session--context) (error "Session was initialized"))
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

(ert-deftest kargu-module-plan-domain-is-independent-test ()
  "Owned plan records and commands load without a chat or engine runtime."
  (kargu-module-test--load-foundation
   'kargu/plan
   '(cl-assert (not (featurep 'kargu/chat/session)))))

(ert-deftest kargu-module-plan-dispatch-without-chat-sources-test ()
  "An explicit headless dispatcher preserves revision, retry and single claim."
  (kargu-module-test--without-sources
   '("kargu/chat.el" "kargu/chat/" "kargu/ui.el" "kargu/ui/")
   '((require 'kargu/plan)
     (with-temp-buffer
       (let* ((attempts 0) text
              (context (kargu-plan-context-create
                        :root default-directory :session "headless"
                        :current-p (lambda (_) t)
                        :dispatch (lambda (_record revision)
                                    (setq text revision)
                                    (> (cl-incf attempts) 1))
                        :publish (lambda (&rest _) (error "Broken view"))))
              (view (kargu-plan-setup-buffer "draft" context))
              (record (kargu-plan-current)))
         (unwind-protect
             (progn
               (cl-assert (condition-case nil (progn (kargu-plan-approve record) nil)
                            (user-error t)))
               (cl-assert (kargu-plan-pending-p record))
               (with-current-buffer view (erase-buffer) (insert "approved revision"))
               (kargu-plan-approve record)
               (kargu-plan-approve record)
               (cl-assert (= attempts 2))
               (cl-assert (equal text "approved revision"))
               (cl-assert (eq (kargu-plan-record-state record) :approved)))
           (kill-buffer view)))))))

(ert-deftest kargu-module-file-service-without-editing-sources-test ()
  "File context does not load the optional mutation or review adapter."
  (kargu-module-test--without-sources
   '("kargu/tools/diff.el" "kargu/tools/diff/")
   '((require 'kargu/files)
     (cl-assert (not (featurep 'kargu/tools/diff)))
     (cl-assert (not (featurep 'ediff)))
     (with-temp-file "read-only.txt" (insert "Read-only service"))
     (let ((kargu-permission--override-root default-directory))
       (cl-assert (equal (kargu-file-text "read-only.txt") "Read-only service"))
       (cl-assert (string-search "1 | Read-only service"
                                 (kargu-file-read "read-only.txt")))))))

(ert-deftest kargu-module-plan-invalidated-dispatch-does-not-announce-approval-test ()
  "An invalidated owner cannot receive a false approval presentation."
  (kargu-module-test--evaluate
   '((require 'kargu/plan)
     (with-temp-buffer
       (let* ((valid t) events
              (context (kargu-plan-context-create
                        :root default-directory :current-p (lambda (_) valid)
                        :dispatch (lambda (&rest _) (setq valid nil) t)
                        :publish (lambda (_record event) (push event events))))
              (view (kargu-plan-setup-buffer "captured revision" context))
              (record (kargu-plan-current)))
         (unwind-protect
             (progn (kargu-plan-approve record)
                    (cl-assert (eq (kargu-plan-record-state record) :cancelled))
                    (cl-assert (null events)))
           (kill-buffer view)))))))

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

(ert-deftest kargu-module-edit-port-is-independent-test ()
  "The editing contract neither loads providers nor grants a mutation."
  (kargu-module-test--load-foundation
   'kargu/edit
   '(cl-assert (not (kargu-edit-changes :available)))
   '(cl-assert (not (kargu-edit-changes :pending)))
   '(let (results)
      (kargu-edit-propose "untouched.txt" "not written"
                          :callback (lambda (value) (push value results)))
      (cl-assert (= (length results) 1))
      (cl-assert (string-prefix-p "ERROR:" (car results)))
      (cl-assert (not (file-exists-p "untouched.txt"))))))

(ert-deftest kargu-module-chat-and-symbol-reading-without-diff-test ()
  "No diff sources means no mutation, not loss of chat or symbol reading."
  (kargu-module-test--without-sources
   '("kargu/tools/diff.el" "kargu/tools/diff/")
   '((require 'kargu)
     (cl-assert (not (featurep 'kargu/tools/diff)))
     (cl-assert (kargu-find-tool "read_file"))
     (cl-assert (kargu-find-tool "git_status"))
     (cl-assert (not (kargu-find-tool "edit_file")))
     (cl-assert (not (kargu-find-tool "apply_patch")))
     (kargu-state-set-mode 'agent)
     (let ((tool "edit_by_lsp")) (cl-assert (kargu-tool-policy-error tool)))
     (with-temp-file "symbol.el" (insert "(defun kept () t)\n"))
     (let ((kargu-permission--override-root default-directory))
       (cl-letf (((symbol-function 'kargu-lsp-get-file-symbols)
                  (lambda (_) '((:name "kept" :kind "Function"
                                 :start-line 1 :end-line 1)))))
         (cl-assert (string-search "defun kept"
                                   (kargu-lsp-read-symbol "symbol.el" "kept"))))
       (cl-assert (string-prefix-p "ERROR:"
                                  (kargu-lsp-edit-symbol "symbol.el" "kept" "")))
       (cl-assert (equal (kargu-file-text "symbol.el") "(defun kept () t)\n")))
     (with-temp-buffer (kargu-chat-mode) (kargu-chat-stop)))))

(ert-deftest kargu-module-edit-port-single-delivery-test ()
  "An optional provider cannot deliver one edit result twice."
  (kargu-module-test--load-foundation
   'kargu/edit
   '(let (results)
      (cl-letf (((symbol-function 'kargu-edit-submit)
                 (lambda (request)
                   (funcall (kargu-edit-request-callback request) "first")
                   (funcall (kargu-edit-request-callback request) "late"))))
        (kargu-edit-propose "file.txt" "content"
                            :callback (lambda (value) (push value results))))
      (cl-assert (equal results '("first"))))))

(ert-deftest kargu-module-edit-port-validates-provider-output-test ()
  "Malformed provider evidence and descriptions fail at the port boundary."
  (kargu-module-test--load-foundation
   'kargu/edit
   '(cl-letf (((symbol-function 'kargu-query-changes) (lambda (_) '(42)))
              ((symbol-function 'kargu-edit-submit) (lambda (_) 42)))
      (dolist (thunk (list (lambda () (kargu-edit-changes :pending))
                           (lambda () (kargu-edit-changes :available))
                           (lambda () (kargu-edit-propose "file.txt" "no"))))
        (cl-assert (condition-case nil (progn (funcall thunk) nil) (error t)))))))

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

(ert-deftest kargu-module-permission-execution-without-runtime-or-ui-sources-test ()
  "Owned permission continuations need neither chat nor a concrete engine."
  (kargu-module-test--without-sources
   '("kargu/chat" "kargu/loop" "kargu/api" "kargu/ui")
   '((require 'kargu/permission/execute)
     (let ((kargu-permission--override-root default-directory) result effect)
       (kargu-permission-execute
        :command "git status" :directory default-directory
        :start (lambda (_) (setq effect t))
        :callback (lambda (value) (setq result value)))
       (cl-assert (not effect))
       (cl-assert (string-prefix-p "ERROR:" result)))
     (dolist (feature '(kargu/core kargu/state kargu/chat kargu/loop kargu/api kargu/ui))
       (cl-assert (not (featurep feature)))))))

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

(ert-deftest kargu-module-edit-provider-unload-test ()
  "An idle unregistered provider detaches without leaving unsafe callbacks."
  (kargu-module-test--evaluate
   '((require 'kargu/tools/diff)
     (kargu-diff-install)
     (kargu-diff-install)
     (cl-assert (kargu-edit-changes :available))
     (kargu-diff-register-tools)
     (cl-assert (condition-case nil
                    (progn (unload-feature 'kargu/tools/diff t) nil)
                  (user-error t)))
     (dolist (name '("edit_file" "write_file" "apply_patch"))
       (kargu-unregister-tool name))
     (unload-feature 'kargu/tools/diff t)
     (cl-assert (not (kargu-edit-changes :available)))
     (cl-assert (string-prefix-p "ERROR:" (kargu-edit-propose "new.txt" "no")))) t))

(ert-deftest kargu-module-headless-run-without-ui-sources-test ()
  "A fake model run completes with chat, plan, UI and diff sources absent."
  (kargu-module-test--without-sources
   '("kargu/chat.el" "kargu/chat/" "kargu/ui.el" "kargu/ui/"
     "kargu/plan.el" "kargu/plan/" "kargu/tools/diff.el" "kargu/tools/diff/")
   '((setq kargu-ui-enabled nil)
     (require 'kargu)
     (dolist (feature '(kargu/chat kargu/ui/confirm kargu/ui/transient kargu/plan))
       (cl-assert (not (featurep feature))))
     (cl-assert (null (locate-library "kargu/chat")))
     (cl-assert (null (locate-library "kargu/tools/diff")))
     (cl-assert (kargu-find-tool "read_file"))
     (let (report approved)
       (cl-letf (((symbol-function 'kargu-deps-package-installed-p)
                  (lambda (package) (eq package 'plz)))
                 ((symbol-function 'kargu-deps-executable-installed-p)
                  (lambda (executable) (equal executable "curl")))
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

(ert-deftest kargu-module-dependency-policy-respects-explicit-requirements-test ()
  "Optional UI/Git dependencies do not block, but user requirements still do."
  (kargu-module-test--evaluate
   '((require 'kargu/tools/deps)
     (cl-letf (((symbol-function 'kargu-deps-package-installed-p)
                (lambda (package) (eq package 'plz)))
               ((symbol-function 'kargu-deps-executable-installed-p)
                (lambda (executable) (equal executable "curl"))))
       (cl-assert (null (kargu-deps-missing)))
       (let ((kargu-deps-mandatory-packages '(plz magit))
             (kargu-deps-mandatory-executables '("curl" "git")))
         (cl-assert (equal (mapcar (lambda (item) (plist-get item :id))
                                   (kargu-deps-missing)) '(magit "git"))))))))

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

(ert-deftest kargu-module-http-cleanup-without-client-or-loop-sources-test ()
  "Raw transport cleanup cannot change app status or require loop/UI code."
  (kargu-module-test--without-sources
   '("kargu/api/client.el" "kargu/loop.el" "kargu/loop/"
     "kargu/chat.el" "kargu/chat/" "kargu/ui.el" "kargu/ui/")
   '((require 'kargu/api/http)
     (cl-assert (not (featurep 'kargu/api/client)))
     (cl-assert (not (featurep 'kargu/loop)))
     (kargu-state-transition-status :verifying)
     (let ((generation kargu--generation))
       (kargu-http-clear-busy)
       (cl-assert (eq (kargu-state-status) :verifying))
       (kargu-http-cancel)
       (cl-assert (= kargu--generation (1+ generation)))
       (cl-assert (eq (kargu-state-status) :verifying))))))

(ert-deftest kargu-module-reset-orders-cancellation-and-passive-notices-test ()
  "Reset coordinates critical services before isolated optional notices."
  (kargu-module-test--evaluate
   '((require 'kargu/core/session)
     (let* ((active t) trace
           (old-id (kargu-session-id))
           (kargu-session-reset-hook
            (list (lambda () (error "Broken view"))
                  (lambda () (push :view trace)))))
       (cl-letf (((symbol-function 'kargu-loop-running-p) (lambda () active))
                  ((symbol-function 'kargu-loop-stop)
                   (lambda (_)
                     (cl-assert (equal old-id (kargu-session-id)))
                     (setq active nil) (push :cancel trace)))
                  ((symbol-function 'kargu-history-reset) (lambda () (push :history trace)))
                  ((symbol-function 'kargu-circuit-reset) (lambda () (push :circuit trace)))
                  ((symbol-function 'kargu-state-reset) (lambda () (push :state trace))))
         (kargu-session-reset))
       (cl-assert (equal (nreverse trace) '(:cancel :history :circuit :state :view)))
       (cl-assert (not (equal old-id (kargu-session-id)))))
     (cl-assert (not (featurep 'kargu/chat)))
     (cl-assert (not (featurep 'kargu/state))))))

(ert-deftest kargu-module-reset-retains-data-on-reentrant-work-test ()
  "Reset cannot clear a session after cancellation starts replacement work."
  (kargu-module-test--evaluate
   '((require 'kargu/core/session)
     (let ((old-id (kargu-session-id)))
       (cl-letf (((symbol-function 'kargu-loop-running-p) (lambda () t))
                  ((symbol-function 'kargu-loop-stop) #'ignore))
         (cl-assert (condition-case nil (progn (kargu-session-reset) nil)
                      (user-error t))))
       (cl-assert (equal old-id (kargu-session-id)))))))

(ert-deftest kargu-module-headless-reset-invalidates-standalone-api-delivery-test ()
  "A request without an agent loop cannot write into a reset conversation."
  (kargu-module-test--without-sources
   '("kargu/chat.el" "kargu/chat/" "kargu/ui.el" "kargu/ui/")
   '((setq kargu-ui-enabled nil)
     (require 'kargu)
     (let* (called
            (delivery (kargu-api--make-delivery
                       :generation kargu--generation
                       :callback (lambda (_) (setq called t)))))
       (setq kargu--busy t)
       (kargu-session-reset)
       (kargu-api--deliver delivery '(("usage" . (("prompt_tokens" . 5)))))
       (cl-assert (not called))
       (cl-assert (not (kargu-history-messages)))
       (cl-assert (zerop (plist-get (kargu-session-snapshot) :requests)))))))

(ert-deftest kargu-module-api-delivery-owns-usage-once-test ()
  "The delivery facade owns usage and never calls a concrete chat footer."
  (kargu-module-test--evaluate
   '((require 'kargu/api/client)
     (let* ((kargu-session--context
             (kargu-session-create :id-value (kargu-session-id)
                                   :usage-value (list :requests 0)))
           (footer-calls 0)
           (delivery (kargu-api--make-delivery
                      :callback #'ignore :generation kargu--generation :record-turn nil))
           (response '(("usage" . (("prompt_tokens" . 5) ("completion_tokens" . 2))))))
       (cl-letf (((symbol-function 'kargu-chat-refresh-footer)
                  (lambda () (cl-incf footer-calls))))
         (kargu-api--deliver delivery response)
         (kargu-api--deliver delivery response))
       (cl-assert (zerop footer-calls))
       (cl-assert (= (plist-get (kargu-session-snapshot) :requests) 1))
       (cl-assert (= (plist-get (kargu-session-snapshot) :tokens-in) 5)))) t))

(ert-deftest kargu-module-session-counters-belong-to-delivery-origin-test ()
  "A response delivered while B is current updates only captured owner A."
  (kargu-module-test--evaluate
   '((require 'kargu/api/client)
     (let ((a (generate-new-buffer " *owner-a*"))
           (b (generate-new-buffer " *owner-b*")) delivery callback-buffer)
       (unwind-protect
           (progn
             (with-current-buffer a
               (kargu-session-record-usage 10 1)
               (setq delivery (kargu-api--make-delivery
                               :generation kargu--generation
                               :callback (lambda (_) (setq callback-buffer (current-buffer))))))
             (with-current-buffer b
               (kargu-session-record-usage 3 1)
               (kargu-api--deliver delivery
                                   '(("usage" . (("prompt_tokens" . 5)
                                                 ("completion_tokens" . 2)))))
               (cl-assert (= (plist-get (kargu-session-snapshot) :tokens-in) 3)))
             (cl-assert (eq callback-buffer a))
             (cl-assert (= (plist-get (kargu-session-snapshot (kargu-session-context a))
                                      :tokens-in) 15))
             (cl-assert (not (equal (kargu-session-id (kargu-session-context a))
                                    (kargu-session-id (kargu-session-context b))))))
         (kill-buffer a) (kill-buffer b)))) t))

(ert-deftest kargu-module-session-replacement-discards-old-delivery-test ()
  "A closed or replaced session cannot receive an old response or usage."
  (kargu-module-test--evaluate
   '((require 'kargu/api/client)
     (dolist (case '(replaced closed))
       (let ((origin (generate-new-buffer " *old-owner*")) delivery called)
         (unwind-protect
             (progn
               (with-current-buffer origin
                 (setq delivery (kargu-api--make-delivery
                                 :generation kargu--generation
                                 :callback (lambda (_) (setq called t))))
                 (if (eq case 'closed) (kill-buffer origin)
                   (kargu-session-replace-usage '(:active nil :requests 0))))
               (setq kargu--busy t)
               (kargu-api--deliver delivery '(("usage" . (("prompt_tokens" . 5)))))
               (kargu-api--deliver delivery '(("usage" . (("prompt_tokens" . 5)))))
               (cl-assert (not called))
               (cl-assert (not kargu--busy))
               (when (buffer-live-p origin)
                 (cl-assert (zerop (plist-get (kargu-session-snapshot
                                               (kargu-session-context origin)) :requests)))))
           (when (buffer-live-p origin) (kill-buffer origin)))))) t))

(ert-deftest kargu-module-session-input-validation-is-atomic-test ()
  "Invalid usage counts fail before mutating any owned counter."
  (kargu-module-test--evaluate
   '((require 'kargu/core/session)
     (cl-assert (not (bound-and-true-p kargu-session--context)))
     (let ((before (kargu-session-snapshot)))
       (dolist (counts '((-1 2) (1 -1) (1.5 2) ("5" 2)))
         (cl-assert (condition-case nil
                        (progn (apply #'kargu-session-record-usage counts) nil)
                      (error t)))
         (cl-assert (equal before (kargu-session-snapshot))))))))

(ert-deftest kargu-module-closing-run-owner-cancels-and-rejects-reentry-test ()
  "Owner closure cancels the run, rejects reentry and ignores late model data."
  (kargu-module-test--evaluate
   '((setq kargu-ui-enabled nil)
     (require 'kargu)
     (dolist (case '(close mode-change))
       (let ((origin (generate-new-buffer " *run-owner*")) session callback report rejected)
         (unwind-protect
             (cl-letf (((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
                       ((symbol-function 'kargu-model-supports-tools-p) (lambda (&rest _) nil))
                       ((symbol-function 'kargu--provider-name) (lambda (&rest _) "openai"))
                       ((symbol-function 'kargu--model) (lambda (&rest _) "fake-model"))
                       ((symbol-function 'kargu--resolve-api-key) (lambda (&rest _) "fake-key"))
                       ((symbol-function 'kargu--api-base) (lambda (&rest _) "https://example.invalid"))
                       ((symbol-function 'kargu--api-post)
                        (lambda (_url _headers _payload _gen done &rest _) (setq callback done))))
               (with-current-buffer origin
                 (setq session (kargu-session-context))
                 (kargu-loop-send
                  "offline" nil
                  (lambda (value)
                    (setq report value rejected
                          (condition-case nil (progn (kargu-loop-send "reentry") nil)
                            (user-error t)))))
                 (if (eq case 'close) (kill-buffer origin) (fundamental-mode)))
               (cl-assert callback)
               (cl-assert rejected)
               (cl-assert (eq (plist-get report :status) :stopped))
               (cl-assert (not (kargu-loop-running-p)))
               (cl-assert (not (plist-get (kargu-session-snapshot session) :active)))
               (funcall callback '(("error" . (("message" . "Late reply")))))
               (cl-assert (not (kargu-loop-running-p))))
           (when (buffer-live-p origin) (kill-buffer origin)))))) t))

(ert-deftest kargu-module-closing-owner-during-request-start-never-posts-test ()
  "A reentrant close at request publication cannot launch a late HTTP effect."
  (kargu-module-test--evaluate
   '((setq kargu-ui-enabled nil)
     (require 'kargu)
     (let* ((origin (generate-new-buffer " *starting-owner*")) (posted 0) report
            (kargu-state-status-hook
             (list (lambda (status _detail)
                     (when (and (eq status :requesting) (kargu-busy-p)
                                (buffer-live-p origin))
                       (kill-buffer origin))))))
       (unwind-protect
           (cl-letf (((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
                     ((symbol-function 'kargu-model-supports-tools-p) (lambda (&rest _) nil))
                     ((symbol-function 'kargu--provider-name) (lambda (&rest _) "openai"))
                     ((symbol-function 'kargu--model) (lambda (&rest _) "fake-model"))
                     ((symbol-function 'kargu--resolve-api-key) (lambda (&rest _) "fake-key"))
                     ((symbol-function 'kargu--api-base) (lambda (&rest _) "https://example.invalid"))
                     ((symbol-function 'kargu--api-post) (lambda (&rest _) (cl-incf posted))))
             (with-current-buffer origin
               (kargu-loop-send "offline" nil (lambda (value) (setq report value))))
             (cl-assert (eq (plist-get report :status) :stopped))
             (cl-assert (zerop posted))
             (cl-assert (not (kargu-busy-p)))
             (cl-assert (not (kargu-loop-running-p))))
         (when (buffer-live-p origin) (kill-buffer origin))))) t))

(ert-deftest kargu-module-reset-retains-captured-counter-owner-test ()
  "Cancellation cannot redirect reset or clear a newly replaced owner."
  (kargu-module-test--evaluate
   '((require 'kargu/core/session)
     (dolist (case '(redirected replaced))
       (let ((a (generate-new-buffer " *reset-a*"))
             (b (generate-new-buffer " *reset-b*")) (active t))
         (unwind-protect
             (let ((b-id (kargu-session-id (kargu-session-context b))))
               (cl-letf (((symbol-function 'kargu-loop-running-p) (lambda () active))
                          ((symbol-function 'kargu-loop-stop)
                           (lambda (_)
                             (setq active nil)
                             (if (eq case 'redirected) (set-buffer b)
                               (kargu-session-replace-usage '(:requests 9))))))
                 (with-current-buffer a
                   (if (eq case 'replaced)
                       (cl-assert (condition-case nil (progn (kargu-session-reset) nil)
                                    (user-error t)))
                     (kargu-session-reset))
                   (cl-assert (eq (current-buffer) a))
                   (cl-assert (= (plist-get (kargu-session-snapshot) :requests)
                                  (if (eq case 'replaced) 9 0)))))
               (cl-assert (equal b-id (kargu-session-id (kargu-session-context b)))))
           (kill-buffer a) (kill-buffer b))))) t))

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

(ert-deftest kargu-module-mode-view-subscription-belongs-to-composition-test ()
  "Core mode commands work alone; optional composition owns view lifetime."
  (kargu-module-test--evaluate
   '((require 'kargu/core)
     (kargu-set-mode 'plan)
     (cl-assert (eq (kargu-state-mode) 'plan))
     (cl-assert (not (featurep 'kargu/chat)))
     (require 'kargu)
     (cl-assert (= (cl-count #'kargu-chat-refresh-mode kargu-state-mode-hook) 1))
     (kargu/chat-unload-function)
     (cl-assert (not (memq #'kargu-chat-refresh-mode kargu-state-mode-hook)))
     (cl-assert (not (memq #'kargu-chat-session-reset kargu-session-reset-hook))))
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
                 "kargu/core/log.el" "kargu/core/session.el"
                 "kargu/contract/history.el"
                 "kargu/contract/selection.el"
                 "kargu/json.el" "kargu/fs.el" "kargu/async.el"
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
           '((dolist (feature '(kargu/core/session kargu/json kargu/fs kargu/async
                               kargu/permission/guards kargu/tools/process
                               kargu/tools/registry))
               (require feature))
             (cl-assert (null (locate-library "kargu/chat")))
             (cl-assert (null (locate-library "kargu/api")))
             (cl-assert (null (locate-library "kargu/state")))
             (cl-assert (null (locate-library "kargu/history")))
             (cl-assert (kargu-history-p
                         (kargu-session-history-value (kargu-session-context)))))
           nil root))
      (delete-directory root t))))

(provide 'tests/test-modules)
;;; test-modules.el ends here
