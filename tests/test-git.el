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

(ert-deftest kargu-git-deadline-is-independent-of-the-generic-runner-test ()
  "Git hooks/signing have no implicit 30-second process deadline."
  (let ((kargu-process-timeout 30) options)
    (cl-letf (((symbol-function 'kargu-process-run)
               (lambda (_program _args _callback &rest opts) (setq options opts) nil)))
      (let ((kargu-git-timeout nil))
        (kargu-git--run '("status") default-directory #'ignore)
        (should (plist-member options :timeout))
        (should-not (plist-get options :timeout)))
      (let ((kargu-git-timeout 12))
        (kargu-git--run '("status") default-directory #'ignore)
        (should (= (plist-get options :timeout) 12))))))

(ert-deftest kargu-git-cancelled-task-kills-process-and-never-starts-fallback-test ()
  "Cancelling an in-flight unstage cannot launch a second mutating Git command."
  (kargu-test-with-git-repo kargu-git-test--files
    (let* ((run (list :state 'tools)) (kargu--loop-run run)
           (task (kargu-async-start #'ignore))
           (runner (symbol-function 'kargu-process-run))
           (kargu-permission--mock-decision :approve)
           (starts 0) process result settled)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-process-run)
                     (lambda (_program _args callback &rest opts)
                       (cl-incf starts)
                       (apply runner "sleep" '("30")
                              (lambda (value) (setq settled t) (funcall callback value)) opts))))
            (funcall (kargu-async-wrap
                      task (lambda ()
                             (setq process (kargu-git-unstage
                                            (lambda (text) (setq result text)) "a.txt")))))
            (should (process-live-p process))
            (kargu-async-cancel-owner run)
            (let ((deadline (+ (float-time) 2)))
              (while (and (not settled) (< (float-time) deadline))
                (accept-process-output process 0.02)))
            (should settled)
            (should-not (process-live-p process))
            (should (= starts 1))
            (should-not result))
        (kargu-async-cancel-owner run)
        (when process (kargu-process-cancel process))))))

(ert-deftest kargu-git-unstage-before-the-first-commit-preserves-files-test ()
  "Unstaging an unborn branch clears its index without deleting working files."
  (kargu-test-with-git-repo kargu-git-test--files
    (should (zerop (call-process "git" nil nil nil "checkout" "--orphan" "unborn")))
    (let ((kargu-permission--mock-decision :approve))
      (let ((result (kargu-test-await (lambda (callback) (kargu-git-unstage callback ".")))))
        (should (string-search "Unstaged:" result)))
      (should (file-exists-p (expand-file-name "a.txt" repo)))
      (should (file-exists-p (expand-file-name "src/b.el" repo)))
      (with-temp-buffer
        (should (zerop (call-process "git" nil t nil "ls-files")))
        (should (string-empty-p (buffer-string)))))))

(ert-deftest kargu-git-status-nul-records-preserve-paths-and-conflicts-test ()
  "NUL records preserve every path byte and consume rename source records."
  (let* ((path " leading ünicode\nfile.txt ")
         (parsed (kargu-git--parse-porcelain-status
                  (list (concat "?? " path) "R  renamed.txt" "original -> file.txt"
                        "UU conflict.txt" "?? after-rename.txt"))))
    (should (equal (kargu-git--file-status-path (cadr (plist-get parsed :untracked))) path))
    (should (= (length (plist-get parsed :untracked)) 2))
    (let ((renamed (car (plist-get parsed :staged))))
      (should (equal (kargu-git--file-status-path renamed) "renamed.txt"))
      (should (equal (kargu-git--file-status-old-path renamed) "original -> file.txt")))
    (should (= (length (plist-get parsed :conflicts)) 1))
    (should-not (plist-get parsed :unstaged))
    (should (string-search "\\n" (kargu-git--display-path path)))
    (should-not (string-search "\n" (kargu-git--display-path path)))))

(ert-deftest kargu-git-status-reads-actual-unicode-and-newline-paths-test ()
  "Real Git status never splits a filename at a newline or quotes Unicode away."
  (kargu-test-with-git-repo kargu-git-test--files
    (dolist (name '("a space.txt" "ünicode.txt" "line\nbreak.txt"))
      (with-temp-file (expand-file-name name repo) (insert "new")))
    (should (zerop (call-process "git" nil nil nil "mv" "--" "a.txt" "renamed ü.txt")))
    (let ((status (kargu-test-await #'kargu-git-status)))
      (should (string-search "a space.txt" status))
      (should (string-search "ünicode.txt" status))
      (should (string-search "line\\nbreak.txt" status))
      (should (string-search "a.txt -> renamed ü.txt" status))
      (should (string-search "Untracked files (3)" status)))))

(ert-deftest kargu-git-status-reports-real-merge-conflicts-separately-test ()
  "An actual unmerged path is not misrepresented as ordinary staged changes."
  (kargu-test-with-git-repo kargu-git-test--files
    (should (zerop (call-process "git" nil nil nil "checkout" "-b" "side")))
    (with-temp-file (expand-file-name "a.txt" repo) (insert "side version\n"))
    (should (zerop (call-process "git" nil nil nil "commit" "-am" "side")))
    (should (zerop (call-process "git" nil nil nil "checkout" "main")))
    (with-temp-file (expand-file-name "a.txt" repo) (insert "main version\n"))
    (should (zerop (call-process "git" nil nil nil "commit" "-am" "main")))
    (should (= (call-process "git" nil nil nil "merge" "--no-edit" "side") 1))
    (let ((status (kargu-test-await #'kargu-git-status)))
      (should (string-search "Merge conflicts (1)" status))
      (should (string-search "UU a.txt" status))
      (should (string-search "Staged changes (0)" status))
      (should (string-search "Unstaged changes (0)" status)))))

(ert-deftest kargu-git-read-only-lists-work-in-ask-and-plan-test ()
  "List-only schemas do not expose branch or stash mutation in read-only modes."
  (kargu-test-with-git-repo kargu-git-test--files
    (dolist (mode '(ask plan))
      (kargu-test-mode mode)
      (dolist (tool '("git_branches" "git_stashes"))
        (should (kargu-tool-visible-p tool))
        (should-not (kargu-loop--gate-tool tool)))
      (dolist (tool '("git_branch" "git_stash"))
        (should-not (kargu-tool-visible-p tool))
        (should (string-prefix-p "ERROR:" (kargu-execute-tool tool nil))))
      (let ((branches (kargu-test-await
                       (lambda (callback) (kargu-execute-tool "git_branches" nil callback))))
            (stashes (kargu-test-await
                      (lambda (callback) (kargu-execute-tool "git_stashes" nil callback)))))
        (should (string-search "main" branches))
        (should (equal stashes "(no stash entries)"))))))

(ert-deftest kargu-git-stash-mutations-require-an-explicit-entry-test ()
  "No implicit top-of-stack mutation or option-shaped reference is accepted."
  (let ((kargu-permission--mock-decision :approve))
    (dolist (action '("pop" "drop"))
      (dolist (stash '(nil "" "HEAD" "--all" "stash@{-1}" "stash@{1} --all"))
        (should-error (kargu-git-stash #'ignore action nil :stash stash))))))

(ert-deftest kargu-git-stash-uses-the-selected-reflog-entry-test ()
  "Dropping an older entry preserves the newest stash; popping selects it explicitly."
  (kargu-test-with-git-repo kargu-git-test--files
    (with-temp-file (expand-file-name "a.txt" repo) (insert "older stash\n"))
    (should (zerop (call-process "git" nil nil nil "stash" "push" "-m" "older")))
    (with-temp-file (expand-file-name "a.txt" repo) (insert "newer stash\n"))
    (should (zerop (call-process "git" nil nil nil "stash" "push" "-m" "newer")))
    (let ((kargu-permission--mock-decision :approve))
      (let ((result (kargu-test-await
                     (lambda (callback)
                       (kargu-git-stash callback "drop" nil :stash "stash@{1}")))))
        (should-not (string-prefix-p "ERROR:" result)))
      (let ((entries (kargu-test-await (lambda (callback) (kargu-git-stash callback "list")))))
        (should (string-search "newer" entries))
        (should-not (string-search "older" entries)))
      (let ((result (kargu-test-await
                     (lambda (callback)
                       (kargu-git-stash callback "pop" nil :stash "stash@{0}")))))
        (should-not (string-prefix-p "ERROR:" result)))
      (with-temp-buffer
        (insert-file-contents (expand-file-name "a.txt" repo))
        (should (equal (buffer-string) "newer stash\n"))))))

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
