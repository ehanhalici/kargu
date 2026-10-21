;;; tests/test-permission.el --- Permission and sandbox test suite -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'tests/test-helpers)
(require 'ert)
(require 'cl-lib)

(ert-deftest kargu-permission-async-result-is-delivered-once-test ()
  "A tool completing twice can deliver only its first asynchronous result."
  (let ((kargu-permission--mock-decision :approve) done results)
    (kargu-permission-execute
     :command "git status" :directory default-directory
     :start (lambda (callback) (setq done callback))
     :callback (lambda (result) (push result results)))
    (funcall done "first")
    (funcall done "second")
    (should (equal results '("first")))))
(require 'kargu/permission)
(require 'kargu/tools/diff)
(require 'kargu/tools/bash)
(require 'kargu/tools/search)
(require 'kargu/loop)

(ert-deftest kargu-permission-command-expansion-preserves-prefix-test ()
  "Double slashes and tilde text must not discard an earlier forbidden path."
  (let* ((root (kargu-test-scratch-root))
         (process-environment (cons (concat "KARGU_VALIDATION_ROOT=" root) process-environment)))
    (dolist (command (list (concat "cat /etc/passwd /" root "allowed")
                          (concat "cat /etc/passwd " root "/allowed")
                          (concat "cat /etc/passwd " root "/~literal")
                          "cat /etc/passwd $KARGU_VALIDATION_ROOT/allowed"
                          "cat /etc/passwd ${KARGU_VALIDATION_ROOT}/allowed"))
      (should (string-prefix-p "cat /etc/passwd " (kargu-permission--expand-environment command)))
      (should-error (kargu-permission-validate-command command root)))
    (should (equal (kargu-permission--expand-environment "cat a//b a/~c") "cat a//b a/~c"))))

(ert-deftest kargu-permission-within-project-test ()
  "Ensure kargu-permission-within-project-p correctly classifies in-tree and out-of-tree paths."
  (let ((root (kargu-permission-project-root)))
    ;; Within project
    (should (kargu-permission-within-project-p (expand-file-name "kargu.el" root) root))
    (should (kargu-permission-within-project-p "kargu.el" root))
    (should (kargu-permission-within-project-p "kargu/permission.el" root))
    (should (kargu-permission-within-project-p "./kargu/tools/bash.el" root))
    (should (kargu-permission-within-project-p root root))
    ;; Outside project
    (should-not (kargu-permission-within-project-p "/etc/passwd" root))
    (should-not (kargu-permission-within-project-p "/tmp" root))
    (should-not (kargu-permission-within-project-p "../outside.txt" root))
    (should-not (kargu-permission-within-project-p (expand-file-name ".." root) root))))

(ert-deftest kargu-permission-assert-within-project-test ()
  "Ensure kargu-permission-assert-within-project raises permission-denied for out-of-tree paths."
  (let ((root (kargu-permission-project-root)))
    ;; In-tree passes
    (should (stringp (kargu-permission-assert-within-project "kargu.el" root "file")))
    ;; Out-of-tree signals error
    (should-error (kargu-permission-assert-within-project "/etc/passwd" root "file")
                  :type 'error)
    (should-error (kargu-permission-assert-within-project "../escape.txt" root "file")
                  :type 'error)
    (should-error (kargu-permission-assert-within-project "/tmp/test" root "file")
                  :type 'error)))

(ert-deftest kargu-permission-file-tools-rejection-test ()
  "Ensure read_file, write_file, and edit_file reject paths outside the project root."
  (let ((_ (kargu-test-mode 'agent))
        (kargu-diff-review-mode 'auto))
    ;; read_file on /etc/passwd
    (should-error (kargu-diff-read-file "/etc/passwd") :type 'error)
    (should-error (kargu-diff-read-file "../outside.txt") :type 'error)
    ;; write_file outside project
    (let ((res (kargu-diff--write-file-tool
                '(("file_path" . "/tmp/should-never-be-written.txt")
                  ("contents" . "malicious content")))))
      (should (stringp res))
      (should (string-match-p "Permission denied" res)))
    ;; edit_file outside project
    (should-error (kargu-diff-apply-replace "/etc/hosts" "127.0.0.1" "0.0.0.0")
                  :type 'error)))

(ert-deftest kargu-permission-search-tools-rejection-test ()
  "Ensure workspace search tools reject searches outside project root."
  (should-error (kargu-search-grep #'ignore "pattern" "/etc") :type 'error)
  (should-error (kargu-search-glob #'ignore "*.txt" "/tmp") :type 'error)
  (should-error (kargu-search-grep #'ignore "pattern" "../") :type 'error))

(ert-deftest kargu-permission-bash-cwd-rejection-test ()
  "Ensure bash tool rejects working directory outside project root."
  (should-error (kargu-bash-run "ls" "/tmp") :type 'error)
  (should-error (kargu-bash-run "pwd" "/etc") :type 'error)
  (should-error (kargu-bash-run "pwd" "../") :type 'error))

(ert-deftest kargu-permission-bash-command-traversal-rejection-test ()
  "Ensure bash command validator blocks path traversal escaping root."
  (let ((root (kargu-permission-project-root)))
    (should-error (kargu-permission-validate-command "cd .." root) :type 'error)
    (should-error (kargu-permission-validate-command "cd ../.. ; pwd" root) :type 'error)
    (should-error (kargu-permission-validate-command "cat ../outside.txt" root) :type 'error)
    (should-error (kargu-permission-validate-command "cd .. && ls" root) :type 'error)
    (should-error (kargu-permission-validate-command "ls ../" root) :type 'error)))

(ert-deftest kargu-permission-bash-command-external-paths-rejection-test ()
  "Ensure bash command validator blocks access to external absolute and home paths."
  (let ((root (kargu-permission-project-root)))
    (should-error (kargu-permission-validate-command "cat /etc/passwd" root) :type 'error)
    (should-error (kargu-permission-validate-command "cat /etc/shadow" root) :type 'error)
    (should-error (kargu-permission-validate-command "cat ~/.ssh/id_rsa" root) :type 'error)
    (should-error (kargu-permission-validate-command "rm -rf /" root) :type 'error)
    (should-error (kargu-permission-validate-command "ls /tmp" root) :type 'error)
    (should-error (kargu-permission-validate-command "python3 /etc/passwd" root) :type 'error)
    (should-error (kargu-permission-validate-command "/bin/cat /etc/passwd" root) :type 'error)
    (should-error (kargu-permission-validate-command "VAR=/tmp/leak make" root) :type 'error)))

(ert-deftest kargu-permission-bash-command-redirection-rejection-test ()
  "Ensure bash command validator blocks redirections to paths outside root."
  (let ((root (kargu-permission-project-root)))
    (should-error (kargu-permission-validate-command "echo evil > /tmp/evil" root) :type 'error)
    (should-error (kargu-permission-validate-command "echo evil >> /tmp/evil" root) :type 'error)
    (should-error (kargu-permission-validate-command "echo evil > ../outside.txt" root) :type 'error)
    (should-error (kargu-permission-validate-command "cat < /etc/hosts" root) :type 'error)))

(ert-deftest kargu-permission-bash-legitimate-commands-test ()
  "Ensure legitimate project-bound commands pass validation without error."
  (let ((root (kargu-permission-project-root)))
    (should (null (kargu-permission-validate-command "git status" root)))
    (should (null (kargu-permission-validate-command "git log -n 5" root)))
    (should (null (kargu-permission-validate-command "cargo test -- --nocapture" root)))
    (should (null (kargu-permission-validate-command "pytest tests/" root)))
    (should (null (kargu-permission-validate-command "python -m pytest" root)))
    (should (null (kargu-permission-validate-command "sed -i 's/foo/bar/g' test.txt" root)))
    (should (null (kargu-permission-validate-command "echo 'hello world' > out.txt" root)))
    (should (null (kargu-permission-validate-command "echo 'test' > /dev/null 2>&1" root)))
    (should (null (kargu-permission-validate-command "find . -name '*.el'" root)))
    (should (null (kargu-permission-validate-command "grep -r 'kargu' ." root)))
    (should (null (kargu-permission-validate-command "make -j4" root)))
    (should (null (kargu-permission-validate-command "git commit -m 'feat: add <foo> & <bar>'" root)))))

(ert-deftest kargu-permission-bash-approval-decision-test ()
  "Ensure kargu-permission-request-approval respects user decisions."
  (let ((kargu-permission--mock-decision :approve))
    (should (eq (kargu-permission-request-approval "echo ok" (kargu-permission-project-root)) t)))
  (let ((kargu-permission--mock-decision :reject))
    (should (eq (kargu-permission-request-approval "echo ok" (kargu-permission-project-root)) nil))))

(ert-deftest kargu-permission-bash-rejection-aborts-execution-test ()
  "Ensure kargu-bash-run signals error when user rejects execution."
  (let ((kargu-permission--mock-decision :reject))
    (should-error (kargu-bash-run "git status") :type 'error)))

(defun kargu-test-permission-click (label)
  "Click the button named LABEL in the current buffer."
  (goto-char (point-min))
  (search-forward label)
  (backward-char 2)
  (push-button))

(ert-deftest kargu-permission-interactive-prompt-and-decision-flow-test ()
  "The approval prompt shows buttons and answers by callback, without waiting."
  (dolist (case '(("[✓ Approve]" . t) ("[✗ Reject]" . nil)))
    (with-temp-buffer
      (let ((kargu-permission--mock-decision nil)
            (kargu-confirm--mock-decision nil)
            (kargu-confirm--pending nil)
            (kargu-permission-confirm-bash t)
            (noninteractive nil)
            (verdict :unanswered)
            (kargu--loop-run (list :chat-buffer (current-buffer))))
        (cl-letf (((symbol-function 'kargu-chat-show) #'ignore)
                  ((symbol-function 'recenter) #'ignore))
          (kargu-permission-request-approval-async
           "make test" "/tmp/proj" nil (lambda (v) (setq verdict v))))
        (let ((content (buffer-string)))
          (should (string-match-p "Bash Permission Approval" content))
          (should (string-match-p "make test" content))
          (should (string-match-p "\\[✓ Approve\\]" content))
          (should (string-match-p "\\[✗ Reject\\]" content)))
        (should (eq verdict :unanswered))
        (kargu-test-permission-click (car case))
        (should (eq verdict (cdr case)))))))

(ert-deftest kargu-permission-approval-is-scoped-to-directory-and-risks-test ()
  "The same command needs its own approval for every prepared context."
  (let* ((root (kargu-permission-project-root))
         (a (make-temp-file (expand-file-name "approval-a-" root) t))
         (b (make-temp-file (expand-file-name "approval-b-" root) t))
         asked (delivered 0))
    (cl-letf (((symbol-function 'kargu-permission-request-approval-async)
               (lambda (command directory risks callback)
                 (push (list command directory risks) asked)
                 (funcall callback t) (funcall callback t))))
      (dolist (entry (list (list a '("first risk")) (list b '("first risk"))
                           (list b '("second risk"))))
        (kargu-permission-execute
         :command "same command" :directory (car entry) :risks (cadr entry)
         :start (lambda (done) (funcall done "done"))
         :callback (lambda (_) (cl-incf delivered)))))
    (should (= (length asked) 3))
    (should (= delivered 3))
    (should-not (equal (car asked) (cadr asked)))))

(ert-deftest kargu-permission-callback-failure-never-redelivers-test ()
  "A failing sync or delayed continuation is logged without another delivery."
  (dolist (delayed '(nil t))
    (let ((kargu-permission--mock-decision :approve) (delivered 0) held)
      (kargu-permission-execute
       :command "git status" :directory default-directory
       :start (lambda (done) (setq held done) (unless delayed (funcall done "ok")))
       :callback (lambda (_) (cl-incf delivered) (error "Bad continuation")))
      (funcall held "ok")
      (funcall held "duplicate")
      (should (= delivered 1)))))

(ert-deftest kargu-permission-execute-asks-then-starts-once-test ()
  "A prepared tool starts only once after the human approves, without replay."
  (let ((asked nil) (runs 0) result)
    (cl-letf (((symbol-function 'kargu-permission-request-approval-async)
               (lambda (cmd _dir _risks cb)
                 (push cmd asked) (funcall cb t) (funcall cb t))))
      (kargu-permission-execute
       :command "git commit" :directory default-directory
       :start (lambda (done) (cl-incf runs) (funcall done "committed"))
       :callback (lambda (value) (setq result value))))
    (should (equal result "committed"))
    (should (equal asked '("git commit")))
    (should (= runs 1))))

(ert-deftest kargu-permission-execute-rejection-is-an-error-result-test ()
  "A refused approval becomes an ERROR result and the side effect never runs."
  (let ((effect nil) result)
    (cl-letf (((symbol-function 'kargu-permission-request-approval-async)
               (lambda (_c _d _r callback) (funcall callback nil))))
      (kargu-permission-execute
       :command "git commit" :directory default-directory
       :start (lambda (done) (setq effect t) (funcall done "ok"))
       :callback (lambda (value) (setq result value))))
    (should-not effect)
    (should (string-prefix-p "ERROR:" result))))

(ert-deftest kargu-permission-detailed-error-message-test ()
  "Ensure kargu-permission-assert-within-project provides structured, detailed error messages."
  (let ((root (kargu-permission-project-root)))
    (condition-case err
        (kargu-permission-assert-within-project "/etc/shadow" root "file")
      (error
       (let ((msg (error-message-string err)))
         (should (string-match-p "Permission denied" msg))
         (should (string-match-p "Attempted target:" msg))
         (should (string-match-p "Allowed project root:" msg))
         (should (string-match-p "Reason:" msg))
         (should (string-match-p "Guidance:" msg))
         (should (string-search root msg)))))))

(ert-deftest kargu-permission-detailed-bash-validation-error-test ()
  "Ensure kargu-permission-validate-command returns detailed error messages for all violations."
  (let ((root (kargu-permission-project-root)))
    ;; 1. Working directory
    (condition-case err
        (kargu-permission-validate-command "ls" root "/tmp")
      (error
       (let ((msg (error-message-string err)))
         (should (string-match-p "working directory" msg))
         (should (string-match-p "Allowed project root:" msg))
         (should (string-match-p "Guidance:" msg)))))
    ;; 2. Traversal
    (condition-case err
        (kargu-permission-validate-command "cat ../outside.txt" root)
      (error
       (let ((msg (error-message-string err)))
         (should (string-match-p "path traversal" msg))
         (should (string-match-p "Allowed project root:" msg))
         (should (string-match-p "Guidance:" msg)))))
    ;; 3. External path
    (condition-case err
        (kargu-permission-validate-command "cat /etc/passwd" root)
      (error
       (let ((msg (error-message-string err)))
         (should (string-match-p "external system path" msg))
         (should (string-match-p "Allowed project root:" msg))
         (should (string-match-p "Guidance:" msg)))))))

(ert-deftest kargu-permission-detailed-bash-rejection-test ()
  "Ensure kargu-bash-run user rejection returns detailed context and guidance."
  (let ((kargu-permission--mock-decision :reject))
    (condition-case err
        (kargu-bash-run "python3 script.py")
      (error
       (let ((msg (error-message-string err)))
         (should (string-match-p "Command execution was rejected by the user" msg))
         (should (string-match-p "Rejected command:.*python3 script.py" msg))
         (should (string-match-p "Allowed project root:" msg))
         (should (string-match-p "Guidance:" msg)))))))

(ert-deftest kargu-permission-detailed-mode-gating-test ()
  "Ensure kargu-loop--gate-tool returns detailed error messages for blocked mutating tools."
  (let ((_ (kargu-test-mode 'plan)))
    (let ((msg (kargu-loop--gate-tool "bash")))
      (should (stringp msg))
      (should (string-match-p "Tool `bash' is blocked in plan mode" msg))
      (should (string-match-p "Allowed tools in this mode:" msg))
      (should (string-match-p "Guidance:" msg)))))

(provide 'tests/test-permission)
;;; test-permission.el ends here
