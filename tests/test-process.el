;;; tests/test-process.el --- ERT tests for non-blocking external commands -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'kargu/state/store)
(require 'kargu/api/catalog)
(require 'kargu/models/store)
(require 'kargu/tools/process)
(require 'kargu/tools/bash)
(require 'kargu/tools/search)
(require 'kargu/tools/git)
(require 'kargu/tools/diff)
(require 'kargu/prompt)
(defvar kargu-context-buffer nil)
(require 'tests/test-helpers)
(require 'tests/test-bridge)

(ert-deftest kargu-process-separates-and-drains-stderr-test ()
  "A successful command's warnings never enter its structured stdout."
  (let ((deliveries 0) result)
    (setq result
          (kargu-test-await
           (lambda (callback)
             (kargu-process-run
              "sh" '("-c" "printf '{\"ok\":true}'; printf warning >&2")
              (lambda (value) (cl-incf deliveries) (funcall callback value))))))
    (should (= deliveries 1))
    (should (= (plist-get result :code) 0))
    (should (equal (plist-get result :output) "{\"ok\":true}"))
    (should (equal (plist-get result :stderr) "warning"))))

(ert-deftest kargu-process-stderr-cap-cancels-owner-once-test ()
  "An overflowing stderr pipe terminates its owner, not just the pipe."
  (let ((deliveries 0) process)
    (let ((result (kargu-test-await
                   (lambda (callback)
                     (setq process
                           (kargu-process-run
                            "sh" '("-c" "while :; do printf warning >&2; done")
                            (lambda (value)
                              (cl-incf deliveries) (funcall callback value))
                            :timeout 2 :max-bytes 128))))))
      (should (= deliveries 1))
      (should (plist-get result :truncated))
      (should-not (plist-get result :timed-out))
      (should-not (process-live-p process))
      (should (<= (string-bytes (plist-get result :stderr)) 128)))))

(ert-deftest kargu-process-merged-stderr-is-explicit-test ()
  "Shell clients can opt into the historical combined stream."
  (let ((result (kargu-test-await
                 (lambda (callback)
                   (kargu-process-run
                    "sh" '("-c" "printf out; printf err >&2") callback
                    :stderr 'merge)))))
    (should (string-search "out" (plist-get result :output)))
    (should (string-search "err" (plist-get result :output)))
    (should (equal (plist-get result :stderr) ""))))

(ert-deftest kargu-process-start-failure-releases-stderr-test ()
  "A failed main process start cannot leak the previously created pipe."
  (let ((before (process-list)) received)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (error "Cannot start main process"))))
      (kargu-process-run "sh" nil (lambda (value) (setq received value))))
    (should (= (plist-get received :code) -1))
    (should-not (seq-difference (process-list) before))
    (should-not (seq-find
                 (lambda (buffer)
                   (string-prefix-p kargu-process--stderr-name (buffer-name buffer)))
                 (buffer-list)))))

(ert-deftest kargu-process-exit-during-startup-is-delivered-once-test ()
  "A command may finish before its process handle is published."
  (dolist (stderr '(nil merge))
    (let ((create (symbol-function 'make-process)) (deliveries 0) result)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest options)
                   (let ((process (apply create options))
                         (deadline (+ (float-time) 2)))
                     (while (and (process-live-p process)
                                 (< (float-time) deadline))
                       (accept-process-output nil 0.01))
                     (should-not (process-live-p process))
                     ;; Resource setup must finish before user code runs.
                     (should-not result)
                     process))))
        (kargu-process-run
         "sh" '("-c" "printf done; printf warning >&2")
         (lambda (value) (cl-incf deliveries) (setq result value))
         :stderr stderr :timeout nil))
      (let ((deadline (+ (float-time) 1)))
        (while (and (not result) (< (float-time) deadline))
          (accept-process-output nil 0.01)))
      (should result)
      (should (= deliveries 1))
      (should (= (plist-get result :code) 0))
      (if (eq stderr 'merge)
          (should (string-search "warning" (plist-get result :output)))
        (should (equal (plist-get result :output) "done"))
        (should (equal (plist-get result :stderr) "warning"))))))

(ert-deftest kargu-process-stderr-late-close-precedes-delivery-test ()
  "The main process exiting does not discard pending stderr data."
  (let ((result (kargu-test-await
                 (lambda (callback)
                   (kargu-process-run
                    "sh" '("-c" "(sleep 0.05; printf late >&2) & printf out")
                    callback :timeout 1)))))
    (should (equal (plist-get result :output) "out"))
    (should (equal (plist-get result :stderr) "late"))
    (should-not (plist-get result :timed-out))))

(ert-deftest kargu-process-deadline-covers-stderr-drain-test ()
  "Inherited stderr cannot outlive a bounded command's deadline."
  (let ((result (kargu-test-await
                 (lambda (callback)
                   (kargu-process-run
                    "sh" '("-c" "(sleep 1; printf late >&2) & printf out")
                    callback :timeout 0.05)))))
    (should (plist-get result :timed-out))
    (should (equal (plist-get result :output) "out"))))

(ert-deftest kargu-structured-consumers-refuse-truncated-output-test ()
  "Quota-killed Git and search results cannot be parsed as complete records."
  (let ((result '(:code 0 :output "partial" :truncated t)))
    (should (= (car (kargu-git--result result)) -1))
    (let (received)
      (kargu-bridge-read--result
       (kargu-async-start (lambda (_text failure) (setq received failure)))
       (kargu-bridge--object "outcome" "failed" "capture_stop" "bytes"
                            "text" "output limit") nil)
      (should (string-search "output limit" received)))))

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

(ert-deftest kargu-process-run-closes-standard-input-test ()
  "Programs waiting for input receive EOF without needing a deadline."
  (dolist (command '(("cat") ("sh" "-c" "read answer || printf eof")))
    (let ((result (kargu-test-await
                   (lambda (callback)
                     (kargu-process-run (car command) (cdr command) callback
                                        :timeout 1)))))
      (should (= (plist-get result :code) 0))
      (should-not (plist-get result :timed-out))
      (when (equal (car command) "sh")
        (should (equal (plist-get result :output) "eof"))))))

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
              (accept-process-output nil 0.02)))
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

(ert-deftest kargu-process-line-limit-spans-chunks-test ()
  "A line budget counts complete records across chunks, not stderr."
  (with-temp-buffer
    (let* ((state (list :lifecycle :running))
           (filter (kargu-process--filter (current-buffer) 128 state :max-lines 2))
           cancelled)
      (cl-letf (((symbol-function 'kargu-process-cancel)
                 (lambda (process) (push process cancelled))))
        (funcall filter 'owner "ağ")
        (should-not (plist-get state :line-limit-reached))
        (string-match "kept" "kept match data")
        (let ((before (match-data)))
          (funcall filter 'owner "\n🙂\nnot retained\n")
          (should (equal before (match-data))))
        (funcall filter 'owner "late\n")
        (should (equal (buffer-string) "ağ\n🙂\n"))
        (should (equal cancelled '(owner)))
        (should (plist-get state :line-limit-reached))
        (should-not (plist-get state :truncated))
        (with-temp-buffer
          (funcall (kargu-process--filter (current-buffer) 128 state) nil "warning\n")
          (should (equal (buffer-string) "warning\n")))))))

(ert-deftest kargu-process-line-limit-terminates-producer-test ()
  "An infinite producer stops at the requested stdout record budget."
  (let ((deliveries 0) process)
    (let ((result
           (kargu-test-await
            (lambda (callback)
              (setq process
                    (kargu-process-run
                     "sh" '("-c" "while :; do printf 'hit\\n'; done")
                     (lambda (value) (cl-incf deliveries) (funcall callback value))
                     :max-lines 3 :timeout 1))))))
      (should (= deliveries 1))
      (should (equal (plist-get result :output) "hit\nhit\nhit\n"))
      (should (plist-get result :line-limit-reached))
      (should-not (plist-get result :truncated))
      (should-not (plist-get result :timed-out))
      (should-not (process-live-p process)))))

(ert-deftest kargu-process-line-limit-keeps-byte-failures-test ()
  "An intentional line limit cannot hide an oversized retained record."
  (with-temp-buffer
    (let ((state (list :lifecycle :running)))
      (funcall (kargu-process--filter (current-buffer) 4 state :max-lines 1)
               nil "too long\n")
      (should (plist-get state :line-limit-reached))
      (should (plist-get state :truncated))
      (should (equal (buffer-string) "too ")))))

(ert-deftest kargu-process-invalid-line-limit-cleans-startup-test ()
  "Invalid line budgets are rejected without allocating process resources."
  (dolist (limit '(0 -1 1.5 "3"))
    (let ((before (process-list)) result)
      (should-not
       (kargu-process-run "sh" nil (lambda (value) (setq result value))
                          :max-lines limit))
      (should (= (plist-get result :code) -1))
      (should (string-search "Line limit" (plist-get result :output)))
      (should-not (seq-difference (process-list) before)))))

(ert-deftest kargu-search-line-limit-does-not-hide-hard-failures-test ()
  "Typed failure cannot be normalized by a late record-limit observation."
  (dolist (outcome '("failed" "timeout" "cancelled" "outcome_unknown"))
    (let (received)
      (kargu-bridge-read--result
       (kargu-async-start (lambda (_text failure) (setq received failure)))
       (kargu-bridge--object "outcome" outcome "capture_stop" "records"
                            "text" "partial\n") nil)
      (should received)
      (should (string-search outcome received)))))

(ert-deftest kargu-process-start-failure-cleans-resources-test ()
  "A failed stdin setup releases the process, timer and output buffer."
  (let (process timer output results)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _)
                 (setq process (start-process "kargu-start-failure" nil "sleep" "30"))))
              ((symbol-function 'kargu-process--filter)
               (lambda (buffer &rest _) (setq output buffer) #'ignore))
              ((symbol-function 'run-at-time)
               (lambda (&rest _) (setq timer (timer-create))))
              ((symbol-function 'process-send-eof)
               (lambda (&rest _) (error "EOF setup failed"))))
      (should-not (kargu-process-run "sleep" '("30")
                                     (lambda (result) (push result results)))))
    (should (= (length results) 1))
    (should (= (plist-get (car results) :code) -1))
    (should-not (process-live-p process))
    (should-not (buffer-live-p output))
    (should-not (memq timer timer-list))))

(ert-deftest kargu-git-tool-needs-a-callback-and-answers-by-it-test ()
  "Git tools never run while Emacs waits; with a callback they answer."
  (kargu-bridge-test--with-core
  (kargu-git-register-tools)
  (kargu-test-with-git-repo '(("a.txt" . "x\n"))
                            (let ((executor (kargu-tool-definition-executor
                                             (kargu-find-tool "git_status"))))
                              (should (string-prefix-p "ERROR:" (funcall executor nil)))
                              (let ((out (kargu-test-await
                                          (lambda (cb) (funcall executor nil cb)))))
                                (should (string-search "Head:" out)))))))

(ert-deftest kargu-search-grep-runs-asynchronously-test ()
  "The workspace_grep tool finds a string and answers by callback."
  (kargu-bridge-test--with-core
  (kargu-test-with-git-repo '(("kargu/tools/process.el" . "(defun kargu-process-run ())\n"))
                            (let ((out (kargu-test-await
                                        (lambda (cb) (kargu-search-grep cb "kargu-process-run" "kargu/tools/process.el")))))
                              (should (string-search "kargu-process-run" out))))))

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
