;;; tests/test-permission.el --- Permission and sandbox test suite -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'kargu/permission)
(require 'kargu/tools/diff)
(require 'kargu/tools/bash)
(require 'kargu/tools/search)

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
  (let ((kargu-active-mode 'agent)
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
  (should-error (kargu-search-grep "pattern" "/etc") :type 'error)
  (should-error (kargu-search-glob "*.txt" "/tmp") :type 'error)
  (should-error (kargu-search-grep "pattern" "../") :type 'error))

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

(provide 'tests/test-permission)
;;; test-permission.el ends here
