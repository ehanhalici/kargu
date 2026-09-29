;;; tests/test-permission.el --- Permission and sandbox test suite -*- lexical-binding: t; -*-

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
(require 'kargu/permission)
(require 'kargu/tools/diff)
(require 'kargu/tools/bash)
(require 'kargu/tools/search)
(require 'kargu/loop)

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

(ert-deftest kargu-permission-call-async-asks-then-reruns-test ()
  "A tool body that needs approval is re-run once after the human approves."
  (let ((kargu-permission--mock-decision nil)
        (kargu-permission-confirm-bash t)
        (asked nil) (runs 0) (result nil))
    (cl-letf (((symbol-function 'kargu-permission-request-approval-async)
               (lambda (cmd _dir _risks cb) (push cmd asked) (funcall cb t)))
              ((symbol-function 'kargu-permission--auto-decision) (lambda (_) nil)))
      (kargu-permission-call-async
       (lambda (done)
         (cl-incf runs)
         (unless (kargu-permission-approve "git commit" "/tmp") (error "no"))
         (funcall done "committed"))
       (lambda (r) (setq result r))))
    (should (equal result "committed"))
    (should (equal asked '("git commit")))
    (should (= runs 2))))

(ert-deftest kargu-permission-call-async-rejection-is-an-error-result-test ()
  "A refused approval becomes an ERROR result and the side effect never runs."
  (let ((effect nil) (result nil))
    (cl-letf (((symbol-function 'kargu-permission-request-approval-async)
               (lambda (_c _d _r cb) (funcall cb nil)))
              ((symbol-function 'kargu-permission--auto-decision) (lambda (_) nil)))
      (kargu-permission-call-async
       (lambda (done)
         (unless (kargu-permission-approve "git commit" "/tmp") (error "no"))
         (setq effect t)
         (funcall done "ok"))
       (lambda (r) (setq result r))))
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
