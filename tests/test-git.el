;;; tests/test-git.el --- ERT test suite for kargu/tools/git -*- lexical-binding: t; -*-

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

(require 'ert)
(require 'kargu/permission)
(require 'kargu/tools/git)
(require 'kargu/loop)
(require 'tests/test-helpers)

(defconst kargu-git-test--files '(("a.txt" . "one\ntwo\nthree\n") ("src/b.el" . "(message \"b\")\n")))

(ert-deftest kargu-git-status-test ()
  "Ensure kargu-git-status returns formatted Magit-style sections."
  (kargu-test-with-git-repo kargu-git-test--files
    (write-region "changed\n" nil (expand-file-name "a.txt" repo) nil 'silent)
    (write-region "new\n" nil (expand-file-name "fresh.txt" repo) nil 'silent)
    (let ((out (kargu-test-await #'kargu-git-status)))
      (should (stringp out))
      (should (string-search "Head:" out))
      (should (string-search "Root:" out))
      (should (string-search "Staged changes" out))
      (should (string-search "Unstaged changes" out))
      (should (string-search "Untracked files" out))
      (should (string-search "a.txt" out))
      (should (string-search "fresh.txt" out)))))

(ert-deftest kargu-git-diff-test ()
  "Ensure kargu-git-diff shows the working-tree change."
  (kargu-test-with-git-repo kargu-git-test--files
    (write-region "changed\n" nil (expand-file-name "a.txt" repo) nil 'silent)
    (let ((out (kargu-test-await #'kargu-git-diff)))
      (should (stringp out))
      (should (string-search "+changed" out)))))

(ert-deftest kargu-git-log-test ()
  "Ensure kargu-git-log returns recent commit entries."
  (kargu-test-with-git-repo kargu-git-test--files
    (let ((out (kargu-test-await (lambda (cb) (kargu-git-log cb 5)))))
      (should (string-search "first commit" out)))))

(ert-deftest kargu-git-blame-test ()
  "Ensure kargu-git-blame returns line annotations for a project file."
  (kargu-test-with-git-repo kargu-git-test--files
    (let ((out (kargu-test-await (lambda (cb) (kargu-git-blame cb "a.txt" 1 2)))))
      (should (string-search "one" out))
      (should (string-search "two" out))
      (should-not (string-search "three" out)))))

(ert-deftest kargu-git-branch-list-test ()
  "Ensure kargu-git-branch lists branches."
  (kargu-test-with-git-repo kargu-git-test--files
    (let ((out (kargu-test-await (lambda (cb) (kargu-git-branch cb "list")))))
      (should (string-search "main" out)))))

(ert-deftest kargu-git-stage-outside-project-test ()
  "Ensure kargu-git-stage rejects files outside the project root."
  (kargu-test-with-git-repo kargu-git-test--files
    (should-error (kargu-git-stage #'ignore "/etc/passwd") :type 'error)
    (should-error (kargu-git-stage #'ignore "../outside.txt") :type 'error)))

(ert-deftest kargu-git-mode-gating-test ()
  "Ensure mutating git tools are rejected in read-only ask mode."
  (let ((_ (kargu-test-mode 'ask)))
    ;; Mutating tools must be gated in ask mode
    (should (kargu-loop--gate-tool "git_commit"))
    (should (kargu-loop--gate-tool "git_stage"))
    (should (kargu-loop--gate-tool "git_unstage"))
    (should (kargu-loop--gate-tool "git_branch"))
    (should (kargu-loop--gate-tool "git_stash"))
    ;; Read-only tools must NOT be gated in ask mode
    (should-not (kargu-loop--gate-tool "git_status"))
    (should-not (kargu-loop--gate-tool "git_diff"))
    (should-not (kargu-loop--gate-tool "git_log"))
    (should-not (kargu-loop--gate-tool "git_blame"))
    (should-not (kargu-loop--gate-tool "workspace_grep"))
    (should-not (kargu-loop--gate-tool "find_files"))
    (should-not (kargu-loop--gate-tool "list_files"))))

(provide 'tests/test-git)
;;; test-git.el ends here
