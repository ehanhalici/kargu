;;; test-git-mutations-native.el --- Native Git approval consumers -*- lexical-binding: t; -*-
;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Real stdio and explicit temporary repository approvals.
;;; Code:
(require 'tests/test-helpers)
(require 'tests/test-bridge)
(require 'kargu/tools/git)

(defmacro kargu-git-mutation-test--fixture (&rest body)
  "Run BODY in an explicitly approved native temporary repository."
  (declare (indent 0))
  `(kargu-bridge-test--with-core
     (kargu-test-with-git-repo '(("a.txt" . "one\n") ("b.txt" . "two\n"))
       (kargu-test-mode 'agent)
       (cl-letf (((symbol-function 'kargu-present-confirmation)
                  (lambda (request) (funcall (plist-get (kargu-confirmation-options request) :on-decision) :approve))))
         ,@body))))

(ert-deftest kargu-git-deadline-is-independent-of-the-generic-runner-test ()
  "Git nil/finite deadlines are captured by native mutation requests."
  (kargu-test-mode 'agent)
  (let ((connection (kargu-bridge--connection-create :state 'ready)) seen)
    (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (done) (funcall done connection nil) #'ignore))
              ((symbol-function 'kargu-bridge-approval-execute)
               (lambda (_c args done &rest _) (setq seen args) (funcall done (kargu-bridge--object "text" "done") nil))))
      (dolist (timeout '(nil 12))
        (let ((kargu-git-timeout timeout))
          (kargu-git-commit #'ignore "message")
          (should (equal (gethash "timeout_ms" seen) (if timeout 12000 :json-null))))))))

(ert-deftest kargu-git-cancelled-task-kills-process-and-never-starts-fallback-test ()
  "Cancellation revokes one native request and cannot trigger unstage fallback."
  (kargu-test-mode 'agent)
  (let* ((parent (kargu-async-start #'ignore :owner nil :parent nil))
         (connection (kargu-bridge--connection-create :state 'ready)) reply cancelled delivered (starts 0))
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (done) (funcall done connection nil) #'ignore))
                  ((symbol-function 'kargu-bridge-approval-execute) (lambda (_c _args done &rest _) (cl-incf starts) (setq reply done) "write"))
                  ((symbol-function 'kargu-bridge-cancel) (lambda (_c id) (should (equal id "write")) (setq cancelled t))))
          (let ((kargu-async--current-task parent)) (kargu-git-unstage (lambda (r) (setq delivered r)) "."))
          (kargu-async-cancel parent)
          (funcall reply (kargu-bridge--object "outcome" "failed" "text" "late") nil)
          (should cancelled) (should-not delivered) (should (= starts 1)))
      (kargu-async-cancel parent))))

(ert-deftest kargu-git-unstage-before-the-first-commit-preserves-files-test ()
  "The native unborn action empties the index while retaining working files."
  (kargu-git-mutation-test--fixture
    (should (zerop (call-process "git" nil nil nil "checkout" "--orphan" "unborn")))
    (should (string-search "Unstaged:" (kargu-test-await (lambda (done) (kargu-git-unstage done ".")))))
    (should (file-exists-p (expand-file-name "a.txt" repo)))
    (with-temp-buffer (should (zerop (call-process "git" nil t nil "ls-files"))) (should (string-empty-p (buffer-string))))))

(ert-deftest kargu-git-stash-mutations-require-an-explicit-entry-test ()
  "Invalid/implicit stash selectors fail before any reverse approval."
  (kargu-git-mutation-test--fixture
    (cl-letf (((symbol-function 'kargu-present-confirmation) (lambda (&rest _) (ert-fail "Invalid action reviewed"))))
      (dolist (stash '(nil "" "HEAD" "--all" "stash@{-1}" "stash@{1} --all"))
        (should (string-prefix-p "ERROR:" (kargu-test-await (lambda (done) (kargu-git-stash done "apply" nil :stash stash)))))))))

(ert-deftest kargu-git-stash-apply-pins-approved-object-across-reordering-test ()
  "A native review uses an immutable object, keeping every stash entry."
  (kargu-git-mutation-test--fixture
    (write-region "saved\n" nil (expand-file-name "a.txt" repo))
    (should (zerop (call-process "git" nil nil nil "stash" "push" "-m" "saved")))
    (cl-letf (((symbol-function 'kargu-present-confirmation)
               (lambda (request)
                 (let ((object (string-trim (with-temp-buffer (call-process "git" nil t nil "rev-parse" "refs/stash") (buffer-string)))))
                   (should (zerop (call-process "git" nil nil nil "stash" "store" "-m" "reordered" object))))
                 (funcall (plist-get (kargu-confirmation-options request) :on-decision) :approve))))
      (should (string-search "retained" (kargu-test-await (lambda (done) (kargu-git-stash done "apply" nil :stash "stash@{0}"))))))
    (should (equal (with-temp-buffer (insert-file-contents (expand-file-name "a.txt" repo)) (buffer-string)) "saved\n"))))

(ert-deftest kargu-git-stash-apply-cancel-invalidates-late-approval-test ()
  "A stale native UI decision cannot apply a stash after request cancellation."
  (kargu-git-mutation-test--fixture
    (write-region "saved\n" nil (expand-file-name "a.txt" repo))
    (should (zerop (call-process "git" nil nil nil "stash" "push")))
    (let (decision task delivered)
      (cl-letf (((symbol-function 'kargu-present-confirmation)
                 (lambda (request) (when (eq (kargu-confirmation-operation request) :prompt)
                                     (setq decision (plist-get (kargu-confirmation-options request) :on-decision))))))
        (setq task (kargu-git-stash (lambda (r) (setq delivered r)) "apply" nil :stash "stash@{0}"))
        (kargu-bridge-test--wait (lambda () decision))
        (kargu-async-cancel task) (funcall decision :approve)
        (should-not delivered)
        (should (equal (with-temp-buffer (insert-file-contents (expand-file-name "a.txt" repo)) (buffer-string)) "one\n"))))))

(ert-deftest kargu-git-stash-apply-claims-approval-before-starting-write-test ()
  "Duplicated native UI decisions deliver one result and issue no second write."
  (kargu-git-mutation-test--fixture
    (write-region "saved\n" nil (expand-file-name "a.txt" repo))
    (should (zerop (call-process "git" nil nil nil "stash" "push")))
    (let ((deliveries 0))
      (cl-letf (((symbol-function 'kargu-present-confirmation)
                 (lambda (request)
                   (let ((decide (plist-get (kargu-confirmation-options request) :on-decision)))
                     (funcall decide :approve) (funcall decide :approve)))))
        (let ((result (kargu-test-await (lambda (done) (kargu-git-stash (lambda (r) (cl-incf deliveries) (funcall done r)) "apply" nil :stash "stash@{0}")))))
          (should-not (string-prefix-p "ERROR:" result))
          (should (= deliveries 1)))))))

(ert-deftest kargu-git-json-path-arrays-test ()
  "Real native stage accepts detached JSON arrays and literal file names."
  (kargu-git-mutation-test--fixture
    (write-region "changed\n" nil (expand-file-name "a.txt" repo))
    (write-region "changed\n" nil (expand-file-name "b.txt" repo))
    (should (string-search "Staged:" (kargu-test-await (lambda (done) (kargu-git-stage done ["a.txt" "b.txt"])))))))

(ert-deftest kargu-git-stage-outside-project-test ()
  "Native path validation rejects escapes before presenting an action."
  (kargu-git-mutation-test--fixture
    (cl-letf (((symbol-function 'kargu-present-confirmation) (lambda (&rest _) (ert-fail "Escape reviewed"))))
      (dolist (path '("/etc/passwd" "../outside.txt"))
        (should (string-prefix-p "ERROR:" (kargu-test-await (lambda (done) (kargu-git-stage done path)))))))))
(ert-deftest kargu-git-mutation-real-approval-stage-unstage-commit-test ()
  "Public mutations use one native review, with no legacy process execution."
  (kargu-bridge-test--with-core
    (kargu-test-with-git-repo '(("a.txt" . "one\n"))
      (kargu-test-mode 'agent)
      (let ((reviews 0))
        (cl-letf (((symbol-function 'kargu-present-confirmation)
                   (lambda (request)
                     (cl-incf reviews)
                     (funcall (plist-get (kargu-confirmation-options request) :on-decision) :approve)))
                  ((symbol-function 'kargu-process-run) (lambda (&rest _) (ert-fail "Elisp process ran"))))
          (write-region "changed\n" nil (expand-file-name "a.txt" repo))
          (should (string-search "Staged:" (kargu-test-await (lambda (done) (kargu-git-stage done "a.txt")))))
          (should (string-search "Unstaged:" (kargu-test-await (lambda (done) (kargu-git-unstage done "a.txt")))))
          (should (string-search "Commit successful:" (kargu-test-await (lambda (done) (kargu-git-commit done "  native commit  " t)))))
          (should (= reviews 3)))))))

(ert-deftest kargu-git-mutation-missing-capability-never-replays-in-elisp-test ()
  "Unsupported cores refuse the write before any editor runner or approval."
  (kargu-test-mode 'agent)
  (let ((connection (kargu-bridge--connection-create :state 'ready :capabilities nil)))
    (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (done) (funcall done connection nil) #'ignore))
              ((symbol-function 'kargu-process-run) (lambda (&rest _) (ert-fail "legacy replay")))
              ((symbol-function 'kargu-present-confirmation) (lambda (&rest _) (ert-fail "unsupported review"))))
      (should (string-prefix-p "ERROR:" (kargu-test-await (lambda (done) (kargu-git-stage done "."))))))))

(provide 'tests/test-git-mutations-native)
;;; test-git-mutations-native.el ends here
