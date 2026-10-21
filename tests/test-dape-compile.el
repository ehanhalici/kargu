;;; test-dape-compile.el --- Deferred debugger ownership -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exercise real Dape launch/compile dispatch without starting any process.

;;; Code:

(require 'tests/test-dape-startup)
(require 'tests/test-dape-readiness)

(defvar dape--compile-after-fn)
(defvar dape-default-config-functions)
(defvar dape-compile-function)
(defvar dape--connections)
(defvar dape--connection-selected)
(declare-function dape--compile "dape" (config fn))
(declare-function dape--create-connection "dape" (config &optional parent))

(defmacro kargu-dape-test--with-compile (&rest body)
  "Run BODY with real Dape dispatch and a manually released compilation."
  (declare (indent 0))
  `(let ((native-dape (symbol-function 'dape)))
     (kargu-dape-test--with-startup
      (let* ((compilation (generate-new-buffer " *kargu-owned-compile*"))
             (dape-default-config-functions nil) (dape-start-hook nil)
             (dape--connections nil) (dape--connection-selected nil)
             (dape-compile-function (lambda (_command) compilation))
             (created nil) (resume nil))
        (ignore created resume)
        (setq dape-configs `((demo command "sh" command-cwd ,repo compile "true")))
        (unwind-protect
            (cl-letf (((symbol-function 'dape) native-dape)
                      ;; This fixture substitutes connection creation, not its lifecycle.
                      ((symbol-function 'kargu-dape-adopt) #'identity)
                      ((symbol-function 'dape--config-ensure) #'ignore)
                      ((symbol-function 'dape--guess-root) (lambda (_) repo))
                      ((symbol-function 'compilation-find-buffer) (lambda (&rest _) compilation))
                      ((symbol-function 'dape--create-connection)
                       (lambda (config &optional parent)
                         (kargu-dape--create-owned
                          (lambda (clean _parent)
                            (push (cons (current-buffer) clean) created)
                            'owned-connection)
                          config parent)))
                      ((symbol-function 'dape--start-debugging) #'ignore))
              ,@body)
          (when (buffer-live-p compilation) (kill-buffer compilation)))))))

(defun kargu-dape-test--compile-continuation (buffer)
  "Return BUFFER's actual Dape continuation without running its finish hook."
  (let ((continuation (buffer-local-value 'dape--compile-after-fn buffer)))
    (should (functionp continuation))
    continuation))

(ert-deftest kargu-dape-compile-start-reports-after-adapter-only-once-test ()
  "Scheduling a compile is not success; its owned completion starts once."
  (kargu-dape-test--with-compile
   (let ((task (kargu-dape-start "demo" (lambda (text)
                                          (should (eq (current-buffer) origin))
                                          (push text results)))))
     (funcall approval t)
     (should (kargu-async-pending-p task))
     (should-not results)
     (should-not created)
     (setq resume (kargu-dape-test--compile-continuation compilation))
     (with-temp-buffer (funcall resume) (funcall resume))
     (should (= (length created) 1))
     (should (eq (caar created) source))
     (should-not (plist-member (cdar created) 'kargu--launch-operation))
     (should (= (length results) 1))
     (should (string-search "started" (car results)))
     (should-not kargu-async--pending))))

(ert-deftest kargu-dape-compile-obsolete-continuations-cannot-start-test ()
  "Cancellation or changed identities reject even duplicate compile replies."
  (dolist (change '(cancel replacement root session source edit directory mode
                           config selection environment closed-source closed-origin))
    (kargu-dape-test--with-compile
     (kargu-dape-start "demo" (lambda (text) (push text results)))
     (funcall approval t)
     (setq resume (kargu-dape-test--compile-continuation compilation))
     (pcase change
       ('cancel (kargu-async-cancel-owner kargu--loop-run))
       ('replacement (setq kargu--loop-run (list :state 'tools)))
       ('root (setq-local kargu-permission--override-root temporary-file-directory))
       ('session (setq-local kargu--session-id "another-session"))
       ('source (with-current-buffer source (setq buffer-file-name "/tmp/foreign.el")))
       ('edit (with-current-buffer source (insert "; changed\n")))
       ('directory (with-current-buffer source (setq default-directory "/tmp/")))
       ('mode (cl-letf (((symbol-function 'kargu-state-mode) (lambda () 'changed)))
                (funcall resume)))
       ('config (setq dape-configs '((demo command "sh" :program "changed"))))
       ('selection (setq kargu-dape-config 'other))
       ('environment (with-current-buffer source
                       (setq-local process-environment (cons "KARGU_COMPILE=changed" process-environment))))
       ('closed-source (kill-buffer source))
       ('closed-origin (kill-buffer origin)))
     (with-temp-buffer (funcall resume) (funcall resume))
     (should-not created)
     (should-not (seq-some (lambda (text) (string-search "started" text)) results))
     (should (<= (length results) 1)))))

(ert-deftest kargu-dape-compile-final-boundary-rechecks-start-hook-test ()
  "Reentrant Dape startup hooks cannot invalidate ownership then open a process."
  (dolist (deferred '(nil t))
    (kargu-dape-test--with-compile
     (unless deferred (cl-remf (cdar dape-configs) 'compile))
     (setq dape-start-hook (list (lambda () (setq kargu--loop-run nil))))
     (kargu-dape-start "demo" (lambda (text) (push text results)))
     (funcall approval t)
     (when deferred
       (funcall (kargu-dape-test--compile-continuation compilation)))
     (should-not created)
     (should-not results))))

(ert-deftest kargu-dape-compile-timeout-and-parent-cancel-release-resources-test ()
  "Deadline or parent cancellation closes the deferred launch and its timer."
  (dolist (end '(deadline cancel))
    (kargu-dape-test--with-compile
     (let ((parent (kargu-dape-start "demo" (lambda (text) (push text results)))))
       (funcall approval t)
       (setq resume (kargu-dape-test--compile-continuation compilation))
       (let* ((child (seq-find (lambda (task) (eq parent (kargu-async-task-parent task)))
                               kargu-async--pending))
              (timer (kargu-async-task-timer child)))
         (should (memq timer timer-list))
         (pcase end
           ('deadline (apply (timer--function timer) (timer--args timer)))
           ('cancel (kargu-async-cancel parent)))
         (funcall resume)
         (should-not created)
         (should-not (memq timer timer-list))
         (should-not kargu-async--pending)
         (if (eq end 'deadline)
             (should (string-search "timed out" (car results)))
           (should-not results)))))))

(ert-deftest kargu-dape-compile-does-not-touch-foreign-compilation-test ()
  "An owned cancellation changes no other compilation callback or hooks."
  (kargu-dape-test--with-compile
   (with-temp-buffer
     (let ((foreign (current-buffer)) (callback (lambda () :foreign))
           (hooks (list #'ignore)))
       (setq-local dape--compile-after-fn callback)
       (setq-local compilation-finish-functions hooks)
       (with-current-buffer origin
         (let ((task (kargu-dape-start "demo" (lambda (text) (push text results)))))
           (funcall approval t)
           (kargu-async-cancel task)
           (funcall (kargu-dape-test--compile-continuation compilation))))
       (should (eq (buffer-local-value 'dape--compile-after-fn foreign) callback))
       (should (eq compilation-finish-functions hooks))
       (should-not created)))))

(ert-deftest kargu-dape-compile-ownerless-stop-and-context-changes-test ()
  "A pre-run readiness wait binds its compilation to the origin, including nil."
  (dolist (change '(stop session owner))
    (kargu-dape-test--with-compile
     (setq kargu--loop-run nil)
     (kargu-dape-wait-for-session
      (lambda () (push :ready results)) :source source
      :launch (lambda (token)
                (with-current-buffer source (kargu-dape-launch-config 'demo :token token))))
     (setq resume (kargu-dape-test--compile-continuation compilation))
     (pcase change
       ('stop (kargu-chat-stop))
       ('session (setq-local kargu--session-id "changed-session"))
       ('owner (setq kargu--loop-run (list :state 'tools))))
     (funcall resume)
     (should-not created)
     (should-not results))))

(ert-deftest kargu-dape-compile-foreign-launches-pass-through-test ()
  "Unmarked Dape calls retain their own compilation and connection behavior."
  (let ((config '(command "sh")) compiled connected)
    (kargu-dape--compile-owned
     (lambda (received callback)
       (should (eq received config)) (setq compiled callback))
     config #'ignore)
    (should (eq compiled #'ignore))
    (kargu-dape--create-owned
     (lambda (received parent)
       (should (eq received config)) (should (eq parent 'foreign))
       (setq connected t))
     config 'foreign)
    (should connected)))

(ert-deftest kargu-dape-compile-source-local-config-and-editor-state-test ()
  "Continuation validators use source-local settings without moving the editor."
  (kargu-dape-test--with-compile
   (with-current-buffer source
     (setq-local dape-configs (copy-tree dape-configs))
     (setcdr (car dape-configs) (plist-put (cdar dape-configs) :program "local-program"))
     (narrow-to-region 2 9)
     (goto-char 5))
   ;; Test the public launch boundary directly, without approval discovery.
   (let ((task (kargu-async-start (lambda (_value error) (push error results)))))
     (funcall
      (kargu-async-wrap
       task (lambda ()
              (with-current-buffer source
                (kargu-dape-launch-config 'demo :on-start (lambda () (kargu-async-finish task t)))))))
     (setq resume (kargu-dape-test--compile-continuation compilation))
     (string-match "state" "editor state")
     (let ((matches (match-data t)))
       (with-temp-buffer (funcall resume))
       (should (equal matches (match-data t))))
     (should (equal results '(nil)))
     (should (= (length created) 1))
     (should (equal (plist-get (cdar created) :program) "local-program"))
     (with-current-buffer source
       (should (= (point) 5))
       (should (= (point-min) 2))
       (should (= (point-max) 9)))
     (should-not kargu-async--pending))))

(ert-deftest kargu-dape-compile-startup-error-closes-parent-once-test ()
  "A compiler setup error cannot leave a pending parent or report success."
  (kargu-dape-test--with-compile
   (let ((dape-compile-function (lambda (_) (error "Compiler unavailable"))))
     (kargu-dape-start "demo" (lambda (text) (push text results)))
     (funcall approval t)
     (funcall approval t)
     (should (equal results '("ERROR: Compiler unavailable")))
     (should-not created)
     (should-not kargu-async--pending))))

(ert-deftest kargu-dape-compile-editor-quit-closes-deferred-launch-test ()
  "Editor quit during setup or the resumed startup leaves no live continuation."
  (dolist (deferred '(nil t))
    (kargu-dape-test--with-compile
     (if deferred
         (setq dape-start-hook (list (lambda () (signal 'quit nil))))
       (setq dape-compile-function (lambda (_) (signal 'quit nil))))
     (kargu-dape-start "demo" (lambda (text) (push text results)))
     (funcall approval t)
     (when deferred
       (setq resume (kargu-dape-test--compile-continuation compilation))
       (funcall resume)
       (funcall resume))
     (should (equal results '("ERROR: Debugger startup cancelled by user")))
     (should-not created)
     (should-not kargu-async--pending))))

(provide 'tests/test-dape-compile)
;;; test-dape-compile.el ends here
