;;; tests/test-process.el --- ERT tests for non-blocking external commands -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory (expand-file-name root))))))

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)

(ert-deftest kargu-process-run-returns-before-the-command-ends-test ()
  "The starter returns at once; the result arrives by callback."
  (let ((got nil)
        (started (float-time)))
    (kargu-process-run "sleep" '("0.3") (lambda (r) (setq got r)))
    (should (< (- (float-time) started) 0.2))
    (should-not got)
    (let ((deadline (+ (float-time) 5)))
      (while (and (null got) (< (float-time) deadline))
        (accept-process-output nil 0.02)))
    (should (eql (plist-get got :code) 0))))

(ert-deftest kargu-process-run-kills-on-timeout-test ()
  "A command that outlives its timeout is killed and reported."
  (let ((r (kargu-test-await
            (lambda (cb) (kargu-process-run "sleep" '("30") cb :timeout 0.2)))))
    (should (plist-get r :timed-out))))

(ert-deftest kargu-process-run-caps-output-test ()
  "A command that writes past the cap is killed and flagged."
  (let ((r (kargu-test-await
            (lambda (cb) (kargu-process-run "yes" nil cb :max-bytes 1000 :timeout 5)))))
    (should (plist-get r :truncated))
    (should (<= (length (plist-get r :output)) 1000))))

(ert-deftest kargu-process-run-missing-program-test ()
  "A missing program is exit 127, delivered to the callback."
  (let ((r (kargu-test-await
            (lambda (cb) (kargu-process-run "kargu-no-such-program" nil cb)))))
    (should (eql (plist-get r :code) 127))))

(ert-deftest kargu-git-tool-needs-a-callback-and-answers-by-it-test ()
  "git tools never run while Emacs waits; with a callback they answer."
  (kargu-test-with-git-repo '(("a.txt" . "x\n"))
    (let ((spec (gethash "git_status" kargu--tool-registry)))
      (should (string-prefix-p "ERROR:" (funcall (kargu--aget spec "executor") nil)))
      (let ((out (kargu-test-await
                  (lambda (cb) (funcall (kargu--aget spec "executor") nil cb)))))
        (should (string-search "Head:" out))))))

(ert-deftest kargu-search-grep-runs-asynchronously-test ()
  "workspace_grep finds a known string and answers by callback."
  (kargu-test-with-git-repo '(("kargu/tools/process.el" . "(defun kargu-process-run ())\n"))
    (let ((out (kargu-test-await
                (lambda (cb) (kargu-search-grep cb "kargu-process-run" "kargu/tools/process.el")))))
      (should (string-search "kargu-process-run" out)))))

(ert-deftest kargu-diff-line-stats-test ()
  "Added and deleted line counts follow a unified diff for a single edit."
  (should (equal (kargu-diff--count-unified-changes "a\nb\nc\n" "a\nB\nc\nd\n") '(2 . 1)))
  (should (equal (kargu-diff--count-unified-changes "x\n" "x\n") '(0 . 0))))

(ert-deftest kargu-prompt-git-info-reads-head-test ()
  "The branch comes from .git/HEAD without running git."
  (let ((root (make-temp-file "kargu-git" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root))
          (with-temp-file (expand-file-name ".git/HEAD" root)
            (insert "ref: refs/heads/feature/x\n"))
          (should (equal (kargu-prompt--git-info root) '(t . "feature/x")))
          (should (equal (kargu-prompt--git-info temporary-file-directory)
                         '(nil . "(none)"))))
      (delete-directory root t))))

(provide 'tests/test-process)
;;; test-process.el ends here
