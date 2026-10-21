;;; test-permission-operation.el --- Captured approval contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Runtime expansion and delayed approval must not change execution authority.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu/permission)
(require 'kargu/permission/execute)

(ert-deftest kargu-permission-unknown-environment-requires-explicit-approval-test ()
  "Unresolved references cannot use the no-confirmation shortcut."
  (let ((process-environment (copy-sequence process-environment))
        (kargu-permission--mock-decision nil))
    (setenv "KARGU_MISSING_VARIABLE" nil)
    (dolist (command '("cat $KARGU_MISSING_VARIABLE/etc/passwd"
                       "cat \"$KARGU_MISSING_VARIABLE/etc/passwd\""
                       "cat $KARGU_MISSING_VARIABLE$KARGU_OTHER_MISSING/etc/passwd"))
      (dolist (confirm '(nil t))
        (let ((kargu-permission-confirm-bash confirm)
              (risks (kargu-permission-command-risks command)))
          (should risks)
          (should (string-search "WARNING:"
                                 (kargu-permission--shown-command command risks)))
          (should-not (kargu-permission-request-approval command default-directory risks)))))))

(ert-deftest kargu-permission-shell-local-directories-are-not-trusted-test ()
  "The shell may replace PWD and OLDPWD even when Emacs has values."
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "PWD" default-directory)
    (setenv "OLDPWD" default-directory)
    (dolist (command '("cat $PWD/file" "cat $OLDPWD/file"))
      (should (kargu-permission-command-risks command)))))

(ert-deftest kargu-permission-known-environment-preserves-path-validation-test ()
  "Known simple references retain path checking and do not become unknown."
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "KARGU_KNOWN_DIRECTORY" (kargu-permission-project-root))
    (should-not (kargu-permission-command-risks "cat $KARGU_KNOWN_DIRECTORY/file"))
    (should-not (kargu-permission-validate-command "cat $KARGU_KNOWN_DIRECTORY/file"))
    (setenv "KARGU_KNOWN_DIRECTORY" "/etc")
    (should-error (kargu-permission-validate-command "cat $KARGU_KNOWN_DIRECTORY/passwd"))
    (should (kargu-permission-command-risks "cat ${KARGU_KNOWN_DIRECTORY}/file"))))

(ert-deftest kargu-permission-owned-operation-invalidates-obsolete-authority-test ()
  "A delayed decision cannot use a changed session, root or environment."
  (dolist (change '(session root environment path strict run))
    (with-temp-buffer
      (let ((process-environment (copy-sequence process-environment))
            (exec-path (copy-sequence exec-path))
            (kargu-permission-strict-mode t)
            (kargu-permission--override-root (kargu-permission-project-root))
            (kargu--loop-run nil) held result effect)
        (cl-letf (((symbol-function 'kargu-permission-request-approval-async)
                   (lambda (_command _directory _risks callback) (setq held callback))))
          (kargu-permission-execute
           :command "git status" :directory default-directory
           :start (lambda (done) (setq effect t) (funcall done "done"))
           :callback (lambda (value) (setq result value)))
          (pcase change
            ('session (kargu-session-clear))
            ('root (setq kargu-permission--override-root "/"))
            ('environment (setenv "KARGU_APPROVAL_TEST" "changed"))
            ('path (push "/untrusted" exec-path))
            ('strict (setq kargu-permission-strict-mode nil))
            ('run (setq kargu--loop-run (list :state 'tools))))
          (funcall held t)
          (funcall held t)
          (should-not effect)
          (when result (should (string-prefix-p "ERROR:" result))))))))

(ert-deftest kargu-permission-operation-cancelled-or-closed-never-starts-test ()
  "Cancellation and a killed owner suppress even duplicated late decisions."
  (dolist (action '(cancel close))
    (let ((origin (generate-new-buffer " *approval-owner*")) held task effect result)
      (unwind-protect
          (progn
            (with-current-buffer origin
              (cl-letf (((symbol-function 'kargu-permission-request-approval-async)
                         (lambda (_c _d _r callback) (setq held callback))))
                (setq task (kargu-permission-execute
                            :command "git status" :directory default-directory
                            :start (lambda (_) (setq effect t))
                            :callback (lambda (value) (setq result value))))))
            (if (eq action 'close) (kill-buffer origin) (kargu-async-cancel task))
            (funcall held t)
            (funcall held t)
            (should-not effect)
            (when result (should (string-prefix-p "ERROR:" result)))
            (should-not (memq task kargu-async--pending)))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(ert-deftest kargu-permission-operation-reentrant-decisions-cannot-reenter-start-test ()
  "The approval is consumed before a starter can invoke the decision again."
  (let (held done results (starts 0))
    (cl-letf (((symbol-function 'kargu-permission-request-approval-async)
               (lambda (_c _d _r callback) (setq held callback))))
      (kargu-permission-execute
       :command "git status" :directory default-directory
       :start (lambda (callback) (cl-incf starts) (setq done callback) (funcall held t))
       :callback (lambda (value) (push value results)))
      (funcall held t)
      (funcall held nil)
      (funcall done "done")
      (funcall done "duplicate")
      (should (= starts 1))
      (should (equal results '("done"))))))

(ert-deftest kargu-permission-operation-checks-domain-freshness-before-execution-test ()
  "A formerly valid domain request cannot execute after its revision changes."
  (let ((fresh t) held effect result)
    (cl-letf (((symbol-function 'kargu-permission-request-approval-async)
               (lambda (_c _d _r callback) (setq held callback))))
      (kargu-permission-execute
       :command "git status" :directory default-directory
       :valid-p (lambda () fresh) :start (lambda (_) (setq effect t))
       :callback (lambda (value) (setq result value)))
      (setq fresh nil)
      (funcall held t)
      (should-not effect)
      (should (string-prefix-p "ERROR:" result)))))

(ert-deftest kargu-permission-operation-cancellation-dismisses-only-owned-prompt-test ()
  "Closing one permission task cannot settle another task's UI request."
  (require 'kargu/ui/confirm)
  (with-temp-buffer
    (kargu-chat-mode)
    (kargu-chat--ensure-idle-prompt)
    (let* ((origin (current-buffer)) (noninteractive nil)
           (kargu-permission--mock-decision nil) (kargu-confirm--mock-decision nil)
           (kargu-confirm--pending nil) first second)
      (cl-letf (((symbol-function 'kargu-confirm--resolve-chat-buffer) (lambda (_) origin))
                ((symbol-function 'kargu-confirm--reveal) #'ignore)
                ((symbol-function 'kargu-notify) #'ignore))
        (unwind-protect
            (progn
              (setq first (kargu-permission-execute
                           :command "first" :directory default-directory
                           :start #'ignore :callback #'ignore)
                    second (kargu-permission-execute
                            :command "second" :directory default-directory
                            :start #'ignore :callback #'ignore))
              (should (= (length kargu-confirm--pending) 2))
              (kargu-async-cancel first)
              (should (= (length kargu-confirm--pending) 1))
              (should (kargu-async-pending-p second)))
          (when first (kargu-async-cancel first))
          (when second (kargu-async-cancel second)))
        (should-not kargu-confirm--pending)))))

(ert-deftest kargu-permission-operation-refuses-replaced-directory-test ()
  "Recreating a directory at the same pathname cannot inherit its approval."
  (let* ((directory (make-temp-file (expand-file-name "approval-dir-" default-directory) t))
         held effect result)
    (cl-letf (((symbol-function 'kargu-permission-request-approval-async)
               (lambda (_c _d _r callback) (setq held callback))))
      (kargu-permission-execute
       :command "git status" :directory directory
       :start (lambda (_) (setq effect t))
       :callback (lambda (value) (setq result value)))
      (rename-file directory (concat directory "-old"))
      (make-directory directory)
      (funcall held t)
      (should-not effect)
      (should (string-prefix-p "ERROR:" result)))))

(ert-deftest kargu-permission-operation-rejects-invalid-adapter-decisions-test ()
  "A truthy non-boolean adapter response cannot grant execution authority."
  (dolist (decision '(1 "approve" :approve))
    (let (effect result)
      (cl-letf (((symbol-function 'kargu-permission-request-approval-async)
                 (lambda (_c _d _r callback) (funcall callback decision))))
        (kargu-permission-execute
         :command "git status" :directory default-directory
         :start (lambda (_) (setq effect t))
         :callback (lambda (value) (setq result value)))
        (should-not effect)
        (should (string-prefix-p "ERROR:" result))))))

(provide 'tests/test-permission-operation)
;;; test-permission-operation.el ends here
