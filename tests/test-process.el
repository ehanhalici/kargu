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

(ert-deftest kargu-bash-shell-selection-ignores-login-shell-test ()
  "The Bash tool never runs its commands through Fish or Nushell."
  (let ((shell-file-name "/usr/bin/nu")
        (process-environment (cons "SHELL=/usr/bin/fish" process-environment)))
    (dolist (available '(bash sh none))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (program)
                   (cond
                    ((equal program "bash")
                     (and (eq available 'bash) "/bin/bash"))
                    ((equal program "sh")
                     (and (memq available '(bash sh)) "/bin/sh"))
                    (t (ert-fail "The login shell must not be consulted"))))))
        (pcase available
          ('bash (should (equal (kargu-bash--resolve-shell) "/bin/bash")))
          ('sh (should (equal (kargu-bash--resolve-shell) "/bin/sh")))
          (_ (should-error (kargu-bash--resolve-shell))))))))

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
    (should (plist-get r :timed-out))
    (should (equal (plist-get r :timeout) 0.2))
    (should (string-search "after 0.2s" (kargu-process-failure "test" r)))))

(ert-deftest kargu-process-run-caps-output-test ()
  "A command that writes past the cap is killed and flagged."
  (let ((r (kargu-test-await
            (lambda (cb) (kargu-process-run "yes" nil cb :max-bytes 1000 :timeout 5)))))
    (should (plist-get r :truncated))
    (should (<= (length (plist-get r :output)) 1000))))

(ert-deftest kargu-process-explicit-nil-disables-default-timeout-test ()
  "An explicit nil does not silently fall back to the runner deadline."
  (let ((kargu-process-timeout 0.01))
    (let ((result (kargu-test-await
                   (lambda (callback)
                     (kargu-process-run "sleep" '("0.1") callback :timeout nil)))))
      (should-not (plist-get result :timed-out))
      (should (= (plist-get result :code) 0)))))

(ert-deftest kargu-process-tail-output-keeps-complete-unicode-test ()
  "Tail retention remains bounded across successive Unicode chunks."
  (with-temp-buffer
    (let* ((state (list :output-policy 'tail))
           (filter (kargu-process--filter (current-buffer) 5 state)))
      (funcall filter nil "ağ🙂z")
      (should (equal (buffer-string) "🙂z"))
      (funcall filter nil "end")
      (should (equal (buffer-string) "zend"))
      (should (plist-get state :truncated)))))

(ert-deftest kargu-bash-job-is-live-bounded-and-cancellable-test ()
  "Long jobs can be inspected and cancelled while their output stays bounded."
  (let ((kargu-bash-timeout nil) (kargu-process-timeout 0.01)
        (kargu-process-max-bytes 256) (kargu-permission-confirm-bash nil)
        (kargu-bash--processes (make-hash-table :test #'equal))
        result process job)
    (unwind-protect
        (progn
          (setq process (kargu-bash--run-async
                         "echo started; sleep 30" default-directory
                         (kargu-bash--resolve-shell) (lambda (value) (setq result value))))
          (maphash (lambda (_id value) (setq job value)) kargu-bash--processes)
          (accept-process-output process 0.05)
          (should (process-live-p process))
          (should-not result)
          (should (string-search "started" (kargu-bash-manage-job
                                             (concat "status " (kargu-bash--job-id job)))))
          (kargu-bash-cancel-process (kargu-bash--job-id job))
          (let ((deadline (+ (float-time) 2)))
            (while (and (not result) (< (float-time) deadline))
              (accept-process-output process 0.02)))
          (should result)
          (should-not (process-live-p process))
          (should (eq (kargu-bash--job-state job) :cancelled)))
      (when process (kargu-process-cancel process))
      (when (and job (buffer-live-p (kargu-bash--job-buffer job)))
        (kill-buffer (kargu-bash--job-buffer job))))))

(ert-deftest kargu-process-cancel-terminates-child-process-group-test ()
  "Cancelling a Unix shell also stops its long-running child."
  (skip-unless (memq system-type '(gnu/linux darwin berkeley-unix)))
  (let ((buffer (generate-new-buffer " *kargu-child-output*")) process child result)
    (unwind-protect
        (progn
          (setq process (kargu-process-run
                         "sh" '("-c" "sleep 30 & echo $!; wait")
                         (lambda (value) (setq result value))
                         :timeout nil :buffer buffer :keep-buffer t))
          (let ((deadline (+ (float-time) 2)))
            (while (and (with-current-buffer buffer (= (buffer-size) 0))
                        (< (float-time) deadline))
              (accept-process-output process 0.02)))
          (setq child (with-current-buffer buffer (string-to-number (buffer-string))))
          (should (> child 0))
          (kargu-process-cancel process)
          (let ((deadline (+ (float-time) 2)))
            (while (and (not result) (< (float-time) deadline))
              (accept-process-output process 0.02)))
          (should result)
          ;; The parent sentinel may run before the kernel reaps its child.
          (let ((deadline (+ (float-time) 2)) attributes)
            (while (and (setq attributes (process-attributes child))
                        (not (equal (alist-get 'state attributes) "Z"))
                        (< (float-time) deadline))
              (accept-process-output nil 0.01))
            (should (or (not attributes)
                        (equal (alist-get 'state attributes) "Z")))))
      (when process (kargu-process-cancel process))
      (when (and child (> child 0) (process-attributes child))
        (signal-process child 'SIGKILL))
      (kill-buffer buffer))))

(ert-deftest kargu-process-run-missing-program-test ()
  "A missing program is exit 127, delivered to the callback."
  (let ((r (kargu-test-await
            (lambda (cb) (kargu-process-run "kargu-no-such-program" nil cb)))))
    (should (eql (plist-get r :code) 127))))

(ert-deftest kargu-process-output-cap-counts-bytes-test ()
  "The output cap counts bytes and preserves whole Unicode characters."
  (with-temp-buffer
    (let ((state (list :truncated nil)))
      (funcall (kargu-process--filter (current-buffer) 5 state) nil "ağ🙂z")
      (should (plist-get state :truncated))
      (should (equal (buffer-string) "ağ"))
      (should (<= (string-bytes (buffer-string)) 5))
      (funcall (kargu-process--filter (current-buffer) 5 state) nil "more")
      (should (equal (buffer-string) "ağ")))))

(ert-deftest kargu-process-start-failure-cleans-resources-test ()
  "A failed sentinel setup releases the process, timer and output buffer."
  (let (process timer output results)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _)
                 (setq process (start-process "kargu-start-failure" nil "sleep" "30"))))
              ((symbol-function 'kargu-process--filter)
               (lambda (buffer &rest _) (setq output buffer) #'ignore))
              ((symbol-function 'run-at-time)
               (lambda (&rest _) (setq timer (timer-create))))
              ((symbol-function 'set-process-sentinel)
               (lambda (&rest _) (error "Sentinel setup failed"))))
      (should-not (kargu-process-run "sleep" '("30")
                                     (lambda (result) (push result results)))))
    (should (= (length results) 1))
    (should (= (plist-get (car results) :code) -1))
    (should-not (process-live-p process))
    (should-not (buffer-live-p output))
    (should-not (memq timer timer-list))))

(ert-deftest kargu-git-tool-needs-a-callback-and-answers-by-it-test ()
  "git tools never run while Emacs waits; with a callback they answer."
  (kargu-test-with-git-repo '(("a.txt" . "x\n"))
                            (let ((spec (gethash "git_status" kargu--tool-registry)))
                              (should (string-prefix-p "ERROR:" (funcall (kargu-aget spec "executor") nil)))
                              (let ((out (kargu-test-await
                                          (lambda (cb) (funcall (kargu-aget spec "executor") nil cb)))))
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
