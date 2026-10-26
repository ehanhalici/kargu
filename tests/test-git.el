;;; tests/test-git.el --- ERT test suite for kargu/tools/git -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Offline Git fixtures exercise native status and the remaining legacy consumers.

;;; Code:

(require 'ert)
(require 'kargu/permission)
(require 'kargu/tools/git)
(require 'kargu/loop)
(require 'tests/test-helpers)
(require 'tests/test-bridge)

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
                                               (setq process
						     (apply runner "sleep" '("30")
                                                            (lambda (value) (setq settled t) (funcall callback value)) opts)))))
				    (funcall (kargu-async-wrap
					      task (lambda ()
                                                     (kargu-git-unstage
                                                      (lambda (text) (setq result text)) "a.txt"))))
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

(ert-deftest kargu-git-status-legacy-engine-is-removed-test ()
  "NUL parsing fixtures live in Rust; no second status engine remains in Elisp."
  (dolist (function '(kargu-git--parse-porcelain-status kargu-git--display-path
							kargu-git--status-entry-text kargu-git--insert-status-section
							kargu-git--first-line-branch kargu-git--format-status
							kargu-git--make-file-status))
    (should-not (fboundp function))))

(ert-deftest kargu-git-status-reads-actual-unicode-and-newline-paths-test ()
  "Real Git status never splits a filename at a newline or quotes Unicode away."
  (kargu-bridge-test--with-core
   (kargu-test-with-git-repo kargu-git-test--files
			     (dolist (name '("a space.txt" "ünicode.txt" "line\nbreak.txt"))
			       (with-temp-file (expand-file-name name repo) (insert "new")))
			     (should (zerop (call-process "git" nil nil nil "mv" "--" "a.txt" "renamed ü.txt")))
			     (let ((status (kargu-test-await #'kargu-git-status)))
			       (should (string-search "a space.txt" status))
			       (should (string-search "ünicode.txt" status))
			       (should (string-search "line\\nbreak.txt" status))
			       (should (string-search "a.txt -> renamed ü.txt" status))
			       (should (string-search "Untracked files (3)" status))))))

(ert-deftest kargu-git-status-reports-real-merge-conflicts-separately-test ()
  "An actual unmerged path is not misrepresented as ordinary staged changes."
  (kargu-bridge-test--with-core
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
			       (should (string-search "Unstaged changes (0)" status))))))

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
    (dolist (action '("apply" "pop" "drop"))
      (dolist (stash '(nil "" "HEAD" "--all" "stash@{-1}" "stash@{1} --all"))
        (should-error (kargu-git-stash #'ignore action nil :stash stash))))))

(ert-deftest kargu-git-stash-apply-pins-approved-object-across-reordering-test ()
  "Approval binds an immutable stash object without deleting any reflog entry."
  (kargu-test-with-git-repo kargu-git-test--files
			    (with-temp-file (expand-file-name "a.txt" repo) (insert "older stash\n"))
			    (should (zerop (call-process "git" nil nil nil "stash" "push" "-m" "older")))
			    (with-temp-file (expand-file-name "a.txt" repo) (insert "newer stash\n"))
			    (should (zerop (call-process "git" nil nil nil "stash" "push" "-m" "newer")))
			    (cl-letf (((symbol-function 'kargu-permission-request-approval-async)
				       (lambda (command directory _risks decision)
					 (should (string-search "git stash apply " command))
					 (should (equal directory repo))
					 (with-temp-file (expand-file-name "a.txt" repo) (insert "racing stash\n"))
					 (should (zerop (call-process "git" nil nil nil "stash" "push" "-m" "racing")))
					 (funcall decision t))))
			      (let ((result (kargu-test-await
					     (lambda (callback)
					       (kargu-git-stash callback "apply" nil :stash "stash@{1}")))))
				(should-not (string-prefix-p "ERROR:" result))
				(should (string-search "retained" result)))
			      (let ((entries (kargu-test-await (lambda (callback) (kargu-git-stash callback "list")))))
				(should (string-search "newer" entries))
				(should (string-search "older" entries))
				(should (string-search "racing" entries)))
			      (with-temp-buffer
				(insert-file-contents (expand-file-name "a.txt" repo))
				(should (equal (buffer-string) "older stash\n"))))))

(ert-deftest kargu-git-stash-destructive-actions-are-explicitly-refused-test ()
  "Pop/drop are unavailable even when a selector and approval are supplied."
  (let ((kargu-permission--mock-decision :approve))
    (dolist (action '("pop" "drop"))
      (should-error (kargu-git-stash #'ignore action nil :stash "stash@{0}")))))

(ert-deftest kargu-git-stash-apply-cancel-invalidates-late-approval-test ()
  "An approval after cancellation cannot apply the captured stash object."
  (let* ((run (list :state 'tools)) (kargu--loop-run run)
         (kargu-async--pending nil) approval commands)
    (cl-letf (((symbol-function 'kargu-git--run)
               (lambda (args _root callback)
                 (push args commands)
                 (funcall callback (cons 0 (make-string 40 ?a)))))
              ((symbol-function 'kargu-permission-request-approval-async)
               (lambda (_command _root _risks callback) (setq approval callback))))
      (kargu-git-stash (lambda (_) (ert-fail "Cancelled stash delivered a result"))
                       "apply" nil :stash "stash@{0}")
      (should approval)
      (kargu-async-cancel-owner run)
      (setq kargu--loop-run nil)
      (funcall approval t)
      (should (= (length commands) 1))
      (should-not kargu-async--pending))))

(ert-deftest kargu-git-stash-apply-claims-approval-before-starting-write-test ()
  "A duplicated approval cannot start a second apply while the first is live."
  (let ((kargu-async--pending nil) (writes 0) completion response)
    (cl-letf (((symbol-function 'kargu-git--run)
               (lambda (_args _root callback)
                 (funcall callback (cons 0 (make-string 40 ?a)))
                 (funcall callback (cons 0 (make-string 40 ?a)))))
              ((symbol-function 'kargu-permission-request-approval-async)
               (lambda (_command _root _risks callback)
                 (funcall callback t) (funcall callback t)))
              ((symbol-function 'kargu-git--change)
               (lambda (_args _root callback _formatter _label)
                 (cl-incf writes) (setq completion callback))))
      (kargu-git-stash (lambda (value) (setq response value)) "apply" nil :stash "stash@{0}")
      (should (= writes 1))
      (funcall completion "done")
      (should (equal response "done"))
      (should-not kargu-async--pending))))

(ert-deftest kargu-git-status-test ()
  "Ensure kargu-git-status returns formatted Magit-style sections."
  (kargu-bridge-test--with-core
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
			       (should (string-search "fresh.txt" out))))))

(ert-deftest kargu-git-json-path-arrays-test ()
  "Decoded JSON path arrays are accepted without converting them to text."
  (kargu-test-with-git-repo kargu-git-test--files
			    (should (equal (kargu-git--relative-paths
					    (kargu--json-decode "[\"a.txt\",\"b.txt\"]") "stage" repo)
					   '("a.txt" "b.txt")))))

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

(ert-deftest kargu-git-blame-honors-single-ended-ranges-test ()
  "Either blame endpoint restricts output; invalid ranges fail before launch."
  (kargu-test-with-git-repo '(("range.txt" . "blame-first\nblame-second\nblame-third\n"))
			    (let ((from (kargu-test-await
					 (lambda (callback) (kargu-git-blame callback "range.txt" 2))))
				  (to (kargu-test-await
				       (lambda (callback) (kargu-git-blame callback "range.txt" nil 2)))))
			      (should-not (string-search "blame-first" from))
			      (should (string-search "blame-second" from))
			      (should (string-search "blame-third" from))
			      (should (string-search "blame-first" to))
			      (should (string-search "blame-second" to))
			      (should-not (string-search "blame-third" to)))
			    (dolist (range '((0 nil) (nil -1) (3 2) ("bad" nil)))
			      (should (string-prefix-p "ERROR:"
                                                       (kargu-test-await (lambda (done)
                                                                           (kargu-git-blame done "range.txt" (car range) (cadr range)))))))))

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

(ert-deftest kargu-git-native-status-captures-settings-without-legacy-execution-test ()
  "Status uses the owned native read port with immutable timeout/output settings."
  (let ((connection (kargu-bridge--connection-create :state 'ready)) seen result
        (kargu-git-timeout nil) (kargu-process-max-bytes 2345))
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (funcall callback connection nil) #'ignore))
              ((symbol-function 'kargu-bridge-git-status)
               (lambda (_connection arguments callback &rest _options)
                 (setq seen arguments)
                 (funcall callback (kargu-bridge--object "outcome" "ok" "text" "native status") nil)
                 nil))
              ((symbol-function 'kargu-git--run)
               (lambda (&rest _) (ert-fail "Legacy status ran"))))
      (kargu-git-status (lambda (text) (setq result text)) default-directory)
      (should (equal result "native status"))
      (should (equal (gethash "root" seen) default-directory))
      (should (eq (gethash "timeout_ms" seen) :json-null))
      (should (= (gethash "output_bytes" seen) 2345)))))

(ert-deftest kargu-git-native-status-parent-cancel-suppresses-late-result-test ()
  "Cancelling status revokes only its RPC and a late callback cannot publish."
  (let* ((kargu--loop-run nil) (kargu-execution--current nil)
         (kargu-async--current-task nil)
         (parent (kargu-async-start #'ignore :owner nil :parent nil))
         (connection (kargu-bridge--connection-create :state 'ready))
         reply cancelled delivered)
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-bridge-ensure)
                   (lambda (callback) (funcall callback connection nil) #'ignore))
                  ((symbol-function 'kargu-bridge-git-status)
                   (lambda (_connection _arguments callback &rest _options)
                     (setq reply callback) "owned-status"))
                  ((symbol-function 'kargu-bridge-cancel)
                   (lambda (actual id)
                     (should (eq actual connection))
                     (should (equal id "owned-status"))
                     (setq cancelled t))))
          (let ((kargu-async--current-task parent))
            (kargu-git-status (lambda (_text) (setq delivered t)) default-directory))
          (kargu-async-cancel parent)
          (should cancelled)
          (funcall reply (kargu-bridge--object "outcome" "ok" "text" "stale") nil)
          (should-not delivered))
      (when (kargu-async-pending-p parent) (kargu-async-cancel parent)))))

(ert-deftest kargu-git-native-queries-freeze-inputs-before-startup-test ()
  "Raw query inputs cannot be changed while native startup yields."
  (let* ((connection (kargu-bridge--connection-create :state 'ready))
         (path (copy-sequence "tracked.txt")) ready seen result task)
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (callback) (setq ready callback) #'ignore))
                  ((symbol-function 'kargu-bridge-git-read)
                   (lambda (_connection arguments callback &rest _options)
                     (setq seen arguments)
                     (funcall callback (kargu-bridge--object "outcome" "ok" "text" "native log") nil) nil))
                  ((symbol-function 'kargu-git--run) (lambda (&rest _) (ert-fail "Legacy Git read executed"))))
          (setq task (kargu-git-log (lambda (value) (setq result value)) 7 path))
          (clear-string path)
          (funcall ready connection nil)
          (should (equal (gethash "path" (gethash "query" seen)) "tracked.txt"))
          (should (= (gethash "max_count" (gethash "query" seen)) 7))
          (should (equal result "native log")))
      (when task (kargu-async-cancel task)))))

(ert-deftest kargu-git-native-query-callback-retains-initiating-application-test ()
  "A foreign active application cannot receive another owner's callback."
  (let ((first (kargu-application-create)) (second (kargu-application-create))
        (connection (kargu-bridge--connection-create :state 'ready)) reply observed task)
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (callback) (funcall callback connection nil) #'ignore))
                  ((symbol-function 'kargu-bridge-git-read) (lambda (_connection _arguments callback &rest _) (setq reply callback) nil)))
          (let ((kargu-application--bound first))
            (setq task (kargu-git-log (lambda (_text) (setq observed (kargu-application-context))))))
          (let ((kargu-application--bound second))
            (funcall reply (kargu-bridge--object "outcome" "ok" "text" "owned") nil))
          (should (eq first observed)))
      (when task (kargu-async-cancel task)))))

(ert-deftest kargu-git-native-query-dead-parent-never-starts-core-test ()
  "Closed and elapsed parents cannot create startup waiters or forward RPCs."
  (dolist (ending '(cancel expired))
    (let* ((kargu--loop-run nil) (kargu-execution--current nil) (kargu-async--current-task nil)
           (parent (kargu-async-start #'ignore :owner nil)) task)
      (unwind-protect
          (progn
            (if (eq ending 'cancel) (kargu-async-cancel parent)
              (setf (kargu-async-task-deadline parent) (1- (float-time))))
            (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (&rest _) (ert-fail "Dead parent started core"))))
              (let ((kargu-async--current-task parent)) (setq task (kargu-git-log #'ignore))))
            (should-not (kargu-async-pending-p task))
            (should-not (kargu-async-task-timer task)))
        (kargu-async-cancel parent)))))

(ert-deftest kargu-git-native-query-origin-close-revokes-rpc-and-late-delivery-test ()
  "Origin closure cancels its exact RPC, without publishing a late result."
  (let ((origin (generate-new-buffer " *native Git owner*"))
        (connection (kargu-bridge--connection-create :state 'ready)) reply delivered cancelled task)
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (callback) (funcall callback connection nil) #'ignore))
                  ((symbol-function 'kargu-bridge-git-read) (lambda (_connection _arguments callback &rest _) (setq reply callback) "owned-query"))
                  ((symbol-function 'kargu-bridge-cancel)
                   (lambda (actual id) (should (eq connection actual)) (should (equal id "owned-query")) (setq cancelled t))))
          (with-current-buffer origin (setq task (kargu-git-log (lambda (_text) (setq delivered t)))))
          (kill-buffer origin)
          (should cancelled)
          (funcall reply (kargu-bridge--object "outcome" "ok" "text" "late") nil)
          (should-not delivered)
          (should-not (kargu-async-pending-p task)))
      (when task (kargu-async-cancel task))
      (when (buffer-live-p origin) (kill-buffer origin)))))

(ert-deftest kargu-git-native-query-old-core-and-missing-binary-have-no-fallback-test ()
  "Missing Git capability or binary never replays the legacy OS runner."
  (let ((connection (kargu-bridge--connection-create :state 'ready :capabilities [])) result)
    (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (callback) (funcall callback connection nil) #'ignore))
              ((symbol-function 'kargu-git--run) (lambda (&rest _) (ert-fail "Legacy read fallback ran"))))
      (kargu-git-log (lambda (value) (setq result value)))
      (should (string-prefix-p "ERROR:" result)))
    (setq result nil)
    (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (callback) (funcall callback nil (kargu-bridge--fault "missing_binary")) #'ignore))
              ((symbol-function 'kargu-git--run) (lambda (&rest _) (ert-fail "Legacy read fallback ran"))))
      (kargu-git-log (lambda (value) (setq result value)))
      (should (string-prefix-p "ERROR:" result)))))

(ert-deftest kargu-git-native-query-delayed-timer-cannot-admit-or-publish-test ()
  "Elapsed task deadlines win over delayed startup and successful replies."
  (dolist (phase '(startup result))
    (let ((connection (kargu-bridge--connection-create :state 'ready)) ready reply task result)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (callback) (setq ready callback) #'ignore))
                    ((symbol-function 'kargu-bridge-git-read)
                     (lambda (_connection _arguments callback &rest _)
                       (when (eq phase 'startup) (ert-fail "Expired startup sent RPC"))
                       (setq reply callback) nil)))
            (setq task (kargu-git-log (lambda (text) (setq result text))))
            (when (eq phase 'result) (funcall ready connection nil))
            (setf (kargu-async-task-deadline task) (1- (float-time)))
            (if (eq phase 'startup) (funcall ready connection nil)
              (funcall reply (kargu-bridge--object "outcome" "ok" "text" "late success") nil))
            (should (string-prefix-p "ERROR:" result))
            (should-not (kargu-async-pending-p task)))
        (when task (kargu-async-cancel task))))))

(ert-deftest kargu-git-worktree-read-requires-the-isolated-profile-capability-test ()
  "Older cores cannot execute status/diff/blame through their weaker read capability."
  (let ((connection (kargu-bridge--connection-create
                     :state 'ready :capabilities ["git_read" "git_status"]
                     :read-scope (kargu-bridge--object "application_id" "old" "session_id" "old"))))
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (funcall callback connection nil) #'ignore))
              ((symbol-function 'kargu-bridge-call) (lambda (&rest _) (ert-fail "Old unsafe RPC was sent")))
              ((symbol-function 'kargu-git--run) (lambda (&rest _) (ert-fail "Legacy Git fallback"))))
      (dolist (start (list #'kargu-git-status #'kargu-git-diff
                          (lambda (done) (kargu-git-blame done "tracked.txt"))))
        (let (result)
          (funcall start (lambda (value) (setq result value)))
          (should (string-prefix-p "ERROR:" result)))))))

(ert-deftest kargu-git-readonly-argv-and-range-engines-are-removed-test ()
  "Elisp only captures intents for the native read-only Git family."
  (dolist (function '(kargu-git--path-args kargu-git--blame-range))
    (should-not (fboundp function))))

(provide 'tests/test-git)
;;; test-git.el ends here
