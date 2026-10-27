;;; tests/test-helpers.el --- Shared helpers for the Kargu ERT suites -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests may wait for an asynchronous result; the product code never does.

;;; Code:

(require 'cl-lib)
(require 'kargu/api/prepare)
(require 'kargu/tools/skill)

(defconst kargu-test-real-project-refresh (symbol-function 'kargu-project-probe-refresh)
  "Real native project preparation selected by its consumer fixtures.")
(defun kargu-test-refresh-project (callback &optional _root)
  "Supply CALLBACK an offline project prerequisite for general loop fixtures."
  (let ((task (kargu-async-start (lambda (value _error) (funcall callback value)))))
    (kargu-async-finish task (kargu-ok nil)) task))

(defconst kargu-test-real-skill-refresh (symbol-function 'kargu-skill-refresh)
  "Real skill preparation used by native consumer and lifecycle fixtures.")

(defun kargu-test-refresh-skills (callback)
  "Supply CALLBACK an empty offline catalog for general loop fixtures."
  (let ((task (kargu-async-start
               (lambda (value _error) (funcall callback value)))))
    (kargu-async-finish task (kargu-ok ""))
    task))

(defconst kargu-test-real-prepare-connection
  (symbol-function 'kargu-api-prepare-connection)
  "Real preparation entry point used explicitly by connection integration tests.")

(cl-defun kargu-test-prepare-connection (callback &key parent owner &allow-other-keys)
  "Supply CALLBACK an offline connection owned by PARENT and OWNER.
General loop tests mock this boundary; G02 tests exercise real preparation."
  (let ((task (kargu-async-start
               (lambda (value _error) (funcall callback value)) :parent parent :owner owner)))
    (condition-case err
        (let* ((provider (kargu--provider-name)) (model (kargu--model))
               (settings (kargu-api-connection-settings provider model)))
          (kargu-async-finish
           task (kargu-ok (kargu-connection-snapshot--create
                           :provider provider :model model
                           :endpoint (or (kargu--api-base) "https://example.invalid/v1")
                           :settings settings :capabilities (list :tools (plist-get settings :tools))
                           :credential-scope (kargu-credential-scope--create :raw-secret "offline")))))
      (error (kargu-async-finish task (kargu-err (error-message-string err) :connection-failed))))
    task))

(defun kargu-test-await (start &optional timeout)
  "Call START with a callback and return what the callback receives.
Waits up to TIMEOUT seconds (default 10) for the callback; signals an error
when it never arrives."
  (let ((result :kargu-test-pending)
        (deadline (+ (float-time) (or timeout 10))))
    (funcall start (lambda (value) (setq result value)))
    (while (and (eq result :kargu-test-pending)
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (when (eq result :kargu-test-pending)
      (error "Kargu test await: no result within %ss" (or timeout 10)))
    result))

(defun kargu-test-refresh-published-config (callback &rest _options)
  "Deliver already-published synthetic config to CALLBACK without file IO.
General UI workflow fixtures use this adapter explicitly; config-backed
selector integration tests keep the real worker and file publication."
  (let ((task (kargu-async-start (lambda (value _error) (funcall callback value))
                                 :owner nil :parent nil)))
    (kargu-async-finish task (kargu-ok (kargu-config-current-snapshot)))
    task))

(defun kargu-test-read-file (path &optional from to)
  "Await the real native read of PATH/FROM/TO in tests only.
Raise native failures so negative fixtures can use `should-error'."
  (let ((text (kargu-test-await
               (lambda (done)
                 (kargu-file-read-async path (kargu-file-window-create :from from :to to) done)))))
    (when (string-prefix-p "ERROR:" text) (error "%s" text))
    text))

(defvar kargu-test--model-apps nil
  "Native owners created by this test's explicit producer fixtures.")

(defun kargu-test-config-document (data)
  "Construct a synthetic normalized DTO from fixture DATA, without policy."
  (let (providers)
    (dolist (entry (plist-get data :providers))
      (let ((fields (make-hash-table :test #'equal)))
        (dolist (pair '((:api . "api") (:apikey . "apikey") (:model . "model") (:models . "models")))
          (when (plist-member (cdr entry) (car pair))
            (puthash (cdr pair) (if (eq (car pair) :models)
                                    (vconcat (plist-get (cdr entry) (car pair)))
                                  (plist-get (cdr entry) (car pair))) fields)))
        (push (kargu-bridge--object "name" (car entry) "data" fields) providers)))
    (kargu-bridge--object "provider" (or (plist-get data :provider) :json-null)
                          "model" (or (plist-get data :model) :json-null)
                          "review-mode" (or (plist-get data :review-mode) :json-null)
                          "providers" (vconcat (nreverse providers)))))

(defun kargu-test-config-publish (service data path digest)
  "Publish synthetic DATA/PATH/DIGEST through the real native owner of SERVICE."
  (should (eq service (kargu-config-service-context)))
  (let ((generation (cl-incf (kargu-config-service-generation service))) result failure)
    (cl-pushnew (kargu-application-context) kargu-test--model-apps)
    (let ((captured (kargu-bridge--object
                     "status" "ok" "generation" generation "path" path
                     "digest" (secure-hash 'sha256 digest) "config" (kargu-test-config-document data))))
      (kargu-test-await
       (lambda (done)
         (kargu-bridge-config-publish
          captured generation (lambda (view error-data) (setq result view failure error-data) (funcall done t))
          :application (kargu-application-context)))))
    (should-not failure)
    (kargu-config--observe service result)))

(defun kargu-test-config-invalidate ()
  "Advance the real native revision with another explicit synthetic publication."
  (let ((snapshot (kargu-config-current-snapshot)))
    (kargu-test-config-publish
     (kargu-config-service-context) (and snapshot (kargu-config-snapshot-data snapshot))
     (if snapshot (kargu-config-snapshot-path snapshot) "/synthetic/config")
     (format "invalidate-%d" (kargu-config-revision)))))

(defun kargu-test-await-catalog-start (function &rest args)
  "Call catalog FUNCTION with ARGS and await native policy or interop admission.
Only fixtures wait; no target, credential or URL policy engine is mocked."
  (let ((resolve (symbol-function 'kargu-connection-resolve-async))
        (interop (symbol-function 'kargu-connection--start-interop))
        settled result (deadline (+ (float-time) 10)))
    (cl-letf (((symbol-function 'kargu-connection--start-interop)
               (lambda (&rest options) (setq settled t) (apply interop options)))
              ((symbol-function 'kargu-connection-resolve-async)
               (lambda (provider model &rest options)
                 (let ((callback (plist-get options :callback)))
                   (apply resolve provider model
                          :callback (lambda (value) (setq settled t) (funcall callback value))
                          (cl-loop for (key value) on options by #'cddr
                                   unless (eq key :callback) append (list key value)))))))
      (setq result (apply function args))
      (while (and (not settled) (kargu-async-pending-p result) (< (float-time) deadline))
        (accept-process-output nil 0.01))
      (when (and (not settled) (kargu-async-pending-p result)) (error "Native catalog policy fixture timed out")))
    result))

(defun kargu-test-await-model-ticket (ticket)
  "Await real native TICKET in fixtures, never make the product API synchronous."
  (cl-pushnew (kargu-bridge-models-app (kargu-bridge-model-ticket-service ticket)) kargu-test--model-apps)
  (let ((deadline (+ (float-time) 10)))
    (while (and (eq (kargu-bridge-model-ticket-status ticket) :pending) (< (float-time) deadline))
      (accept-process-output nil 0.01)))
  (unless (eq (kargu-bridge-model-ticket-status ticket) :committed)
    (user-error "Native fixture publication failed: %S" (kargu-bridge-model-ticket-failure ticket)))
  (kargu-bridge-model-ticket-view ticket))

(defun kargu-test-set-model-metadata (&rest args)
  "Publish model metadata ARGS through the real public asynchronous setter."
  (kargu-test-await-model-ticket (apply #'kargu-model-set-metadata args)))

(defun kargu-test-set-model-prop (&rest args)
  "Publish model property ARGS through the real public asynchronous setter."
  (kargu-test-await-model-ticket (apply #'kargu-model-set-prop args)))

(defun kargu-test-mark-tools-refused (&rest args)
  "Await native refusal observation ARGS in a fixture."
  (kargu-test-await-model-ticket (apply #'kargu-model-mark-tools-refused args)))

(defun kargu-test-forget-tools-refusals ()
  "Await clearing native refusal observations in a fixture."
  (kargu-test-await-model-ticket (kargu-model-forget-tools-refusals)))

(defun kargu-test-cache-model-catalog (provider models)
  "Publish PROVIDER's MODELS as a real atomic native catalog fixture."
  (kargu-test-await-model-ticket (kargu--catalog-cache-live-models provider models)))

(defun kargu-test-publish-model-catalog (models &optional provider)
  "Publish MODELS for explicit PROVIDER or the fixture's active provider."
  (kargu-test-cache-model-catalog (or provider (kargu--provider-name)) models))

(defun kargu-test-drain-model-publishers ()
  "Wait for pending fixture publications without changing their captured intent."
  (when-let* ((ticket (kargu-bridge-models-capture (kargu-application-context))))
    (when (eq (kargu-bridge-model-ticket-status ticket) :pending)
      (kargu-test-await-model-ticket ticket))))

(defun kargu-test-efforts-from-specs (data specs)
  "Read DATA through real native publication with explicitly captured SPECS."
  (cl-letf (((symbol-function 'kargu-provider-effort-specs) (lambda (_) specs)))
    (kargu-test-set-model-metadata "effort-fixture" data "effort-fixture"))
  (kargu-model-reasoning-efforts "effort-fixture" "effort-fixture"))

;;;; Temporary repositories ----------------------------------------------------

(defvar kargu-permission--override-root)

(defmacro kargu-test-with-git-repo (files &rest body)
  "Run BODY in a fresh git repository containing FILES in one commit.
FILES is an alist of (NAME . TEXT).  `repo' is bound to the directory,
which is also the project root and `default-directory'.  The repository
is deleted afterwards, so no test depends on the working tree of Kargu."
  (declare (indent 1))
  `(let* ((repo (file-name-as-directory (file-truename (make-temp-file "kargu-repo-" t))))
          (default-directory repo)
          (kargu-permission--override-root repo)
          (process-environment
           (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@example.com"
                     "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@example.com"
                     "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null")
                   process-environment)))
     (unwind-protect
         (progn
           (dolist (f ,files)
             (let ((path (expand-file-name (car f) repo)))
               (make-directory (file-name-directory path) t)
               (write-region (cdr f) nil path nil 'silent)))
           (call-process "git" nil nil nil "init" "-q" "-b" "main")
           (call-process "git" nil nil nil "add" "-A")
           (call-process "git" nil nil nil "commit" "-q" "-m" "first commit")
           ,@body)
       (delete-directory repo t))))

;;;; Mode and state isolation ----------------------------------------------

(require 'kargu/history/store)
(require 'kargu/selection)

(cl-defun kargu-test-session-with-history
    (&key (messages (kargu-history-snapshot))
          (system-key (kargu-history-system-key)) (overlay (kargu-history-overlay))
          (provider (kargu-selection-provider)) (model (kargu-selection-model))
          (effort (kargu-selection-effort-value (kargu-selection-context))))
  "Create a session fixture from MESSAGES, SYSTEM-KEY, OVERLAY and choices.
PROVIDER, MODEL and EFFORT default to the current owner's explicit values."
  (let ((history (kargu-history-create :messages messages)))
    (setf (kargu-history-system-key history) (copy-tree system-key t)
          (kargu-history-overlay history) overlay)
    (kargu-session--create :id-value (kargu-session-id)
                           :usage-value (copy-tree (kargu-session-usage-value
                                                    (kargu-session-context)))
                           :history-value history
                           :mode-value (kargu-session-mode-value (kargu-session-context))
                           :selection-value (kargu-selection-create
                                             :provider provider :model model :effort effort))))

(declare-function kargu-state--set "kargu/state/store" (key value))
(declare-function kargu-state-mode "kargu/state/selectors" ())

(defvar kargu--loop-run)
(defvar kargu--busy)
(defvar kargu--generation)
(defvar kargu-application--context)
(defvar kargu--state-store)
(defvar kargu-session--context)
(defvar kargu--session-id)
(defvar kargu-context-buffer)
(defvar kargu-diff--changed)
(defvar kargu-diff--snapshots)
(defvar kargu-diff--run-modified-files)

(declare-function kargu-application-create "kargu/application/coordinator")
(declare-function kargu-application-context "kargu/application/coordinator")
(declare-function kargu-application-reset "kargu/application/coordinator")

;;;; Dual-application isolation fixtures ------------------------------------

(cl-defun kargu-test-make-dual-applications (&key (gen-a 0) (gen-b 100))
  "Create and return a cons cell of two distinct `kargu-application' instances.
GEN-A and GEN-B initialize the generation counters of the two instances."
  (cons (kargu-application-create :status :idle :generation gen-a)
        (kargu-application-create :status :idle :generation gen-b)))

(defmacro kargu-test-with-dual-applications (bindings &rest body)
  "Bind BINDINGS to two independent `kargu-application' instances and run BODY.
BINDINGS is a two-element list (APP-A-VAR APP-B-VAR).
Ensures neither application instance shares mutable state or affects the other."
  (declare (indent 1))
  (let ((app-a (car bindings))
        (app-b (cadr bindings)))
    `(let ((,app-a (kargu-application-create :status :idle :generation 0))
           (,app-b (kargu-application-create :status :idle :generation 100)))
       (unwind-protect
           (progn ,@body)
         (when (fboundp 'kargu-application-reset)
           (ignore-errors (kargu-application-reset ,app-a))
           (ignore-errors (kargu-application-reset ,app-b)))))))

(defun kargu-test-mode (mode)
  "Make MODE the active mode for the running test and return it.
The mode lives only in the state store.  `kargu-test--isolate' restores
the previous mode when the test ends."
  (kargu-state--set :mode mode)
  mode)

(defvar kargu-test--scratch-root nil
  "Project root every test runs in: a scratch directory, never the working tree.")

(defun kargu-test-scratch-root ()
  "The scratch project root of this test run, created on first use."
  (unless (and kargu-test--scratch-root (file-directory-p kargu-test--scratch-root))
    (setq kargu-test--scratch-root
          (file-name-as-directory (file-truename (make-temp-file "kargu-scratch-" t))))
    (add-hook 'kill-emacs-hook
              (lambda () (when (file-directory-p kargu-test--scratch-root)
                           (delete-directory kargu-test--scratch-root t)))))
  kargu-test--scratch-root)

(defun kargu-test--isolate (run-test &rest args)
  "Run RUN-TEST with ARGS in a scratch root and isolated session/state data.
Tests never see the working tree of Kargu as their project."
  (let ((default-directory (kargu-test-scratch-root))
        (process-environment (copy-sequence process-environment))
        (auth-sources nil)
        (kargu-permission--override-root (kargu-test-scratch-root))
        (kargu--state-store (copy-tree kargu--state-store))
        (kargu-session--context (kargu-test-session-with-history))
        (kargu--session-id kargu--session-id)
        (kargu-context-buffer kargu-context-buffer)
        ;; Global state a test may touch; each test starts from and leaves it as found.
        (kargu--loop-run kargu--loop-run)
        (kargu--busy kargu--busy)
        (kargu--generation (bound-and-true-p kargu--generation))
        (kargu-application--context
         (if (fboundp 'kargu-application-create)
             (kargu-application-create
              :status (or (plist-get kargu--state-store :status) :idle)
              :active-run kargu--loop-run
              :generation (or (bound-and-true-p kargu--generation) 0))
           (bound-and-true-p kargu-application--context)))
        (kargu-test--model-apps nil)
        (kargu-bridge-binary-path (or (getenv "KARGU_CORE_TEST_BINARY") kargu-bridge-binary-path))
        (kargu-diff--changed (if (and (boundp 'kargu-diff--changed)
                                      (hash-table-p kargu-diff--changed))
                                 (copy-hash-table kargu-diff--changed)
                               (make-hash-table :test #'equal)))
        (kargu-diff--snapshots (if (and (boundp 'kargu-diff--snapshots)
                                        (hash-table-p kargu-diff--snapshots))
                                   (copy-hash-table kargu-diff--snapshots)
                                 (make-hash-table :test #'equal)))
        (kargu-diff--run-modified-files (bound-and-true-p kargu-diff--run-modified-files)))
    (dolist (provider (kargu-provider-list))
      (dolist (name (kargu-provider-env provider)) (setenv name nil)))
    (unwind-protect
        (let ((submit (symbol-function 'kargu-bridge-models-submit))
              (ensure (symbol-function 'kargu-bridge-application-ensure)))
          (cl-letf (((symbol-function 'kargu-api-prepare-connection) #'kargu-test-prepare-connection)
                    ((symbol-function 'kargu-skill-refresh) #'kargu-test-refresh-skills)
                    ((symbol-function 'kargu-project-probe-refresh) #'kargu-test-refresh-project)
                    ;; Skill fixtures supply explicit temporary user grants.
                    ((symbol-function 'kargu-skill--user-dir) #'ignore)
                    ((symbol-function 'kargu-bridge-application-ensure)
                     (lambda (connection app callback)
                       (cl-pushnew app kargu-test--model-apps)
                       (funcall ensure connection app callback)))
                    ((symbol-function 'kargu-bridge-models-submit)
                     (lambda (connection app &rest options)
                       (cl-pushnew app kargu-test--model-apps)
                       (apply submit connection app options))))
            (apply run-test args)))
      (dolist (app kargu-test--model-apps)
        (when-let* ((service (gethash :native-models (kargu-application-services app))))
          (dolist (ticket (cons (kargu-bridge-models-active service) (copy-sequence (kargu-bridge-models-queue service))))
            (when ticket (kargu-bridge-models-cancel ticket))))
        (when-let* ((binding (gethash :native-core (kargu-application-services app)))
                    ((eq (kargu-bridge-status (kargu-bridge-application-connection binding)) 'ready)))
          (let (done)
            (kargu-bridge-application-close app (lambda (&rest _) (setq done t)))
            (let ((deadline (+ (float-time) 5)))
              (while (and (not done) (< (float-time) deadline)) (accept-process-output nil 0.01)))))))))

(advice-add 'ert-run-test :around #'kargu-test--isolate)

(provide 'tests/test-helpers)
;;; test-helpers.el ends here
