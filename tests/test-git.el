;;; tests/test-git.el --- ERT test suite for kargu/tools/git -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'kargu/permission)
(require 'kargu/tools/git)
(require 'kargu/loop)

(ert-deftest kargu-git-status-test ()
  "Ensure kargu-git-status returns formatted Magit-style sections."
  (let ((out (kargu-git-status)))
    (should (stringp out))
    (should (string-search "Head:" out))
    (should (string-search "Root:" out))
    (should (string-search "Staged changes" out))
    (should (string-search "Unstaged changes" out))
    (should (string-search "Untracked files" out))))

(ert-deftest kargu-git-diff-test ()
  "Ensure kargu-git-diff runs without error in the repository."
  (let ((out (kargu-git-diff)))
    (should (stringp out))))

(ert-deftest kargu-git-log-test ()
  "Ensure kargu-git-log returns recent commit entries."
  (let ((out (kargu-git-log 5)))
    (should (stringp out))
    (should-not (string-empty-p out))))

(ert-deftest kargu-git-blame-test ()
  "Ensure kargu-git-blame returns line annotations for a project file."
  (let ((out (kargu-git-blame "kargu.el" 1 5)))
    (should (stringp out))
    (should (string-search "kargu.el" out))))

(ert-deftest kargu-git-branch-list-test ()
  "Ensure kargu-git-branch lists branches."
  (let ((out (kargu-git-branch "list")))
    (should (stringp out))
    (should-not (string-empty-p out))))

(ert-deftest kargu-git-stage-outside-project-test ()
  "Ensure kargu-git-stage rejects files outside the project root."
  (should-error (kargu-git-stage "/etc/passwd") :type 'error)
  (should-error (kargu-git-stage "../outside.txt") :type 'error))

(ert-deftest kargu-git-mode-gating-test ()
  "Ensure mutating git tools are rejected in read-only ask mode."
  (let ((kargu-active-mode 'ask))
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
