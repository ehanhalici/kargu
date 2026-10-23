;;; test-wave1-empirical-challenge.el --- Wave 1 Empirical Stress Test Suite -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Adversarial empirical challenge harness for Wave 1 (Packages A and B):
;; 1. Budget debit gate: negative tokens, zero/negative limits, budget exhaustion,
;;    debits after sealing, mid-execution deadline expiration, single compaction bound.
;; 2. Async task ownership: hierarchical recursive cancellation of nested parent/child
;;    tasks, preservation of sibling tasks under different owners and parentless siblings.
;; 3. Application reset ordering: verify `kargu-session-reset' resets only matching
;;    application claim and does not clobber foreign runs.
;; 4. Edit service isolation: concurrent instances on same/different buffers with
;;    disjoint snapshot/change/review/plan tables.
;; 5. Frozen approval identity: rejection on unsaved buffer, disk revision change,
;;    policy revision mismatch, session mismatch with typed errors.
;; 6. Closed edit service: immediate rejection of plans with :service-closed.
;; 7. Git worktree safety: verify patch workspace operations never alter or stage into
;;    the user's git index (git status --short, git diff --cached).

;;; Code:

(require 'ert)
(require 'cl-lib)

(require 'kargu/contract/assert)
(require 'kargu/contract/result)
(require 'kargu/application/budget)
(require 'kargu/application/coordinator)
(require 'kargu/application/reset)
(require 'kargu/async)
(require 'kargu/core/session)
(require 'kargu/files)
(require 'kargu/edit)
(require 'kargu/tools/diff)
(require 'kargu/tools/diff/context)
(require 'tests/test-helpers)

;;;; Suite 1: Budget Accounting & Debit Gate (Package A) -----------------------

(ert-deftest kargu-challenge-budget-negative-and-zero-limits-test ()
  "Adversarially challenge budget creation and debit against negative and zero limits."
  ;; 1. Zero/negative max-requests rejected on creation
  (should-error (kargu-budget-create :run-id "test" :max-requests 0))
  (should-error (kargu-budget-create :run-id "test" :max-requests -5))

  ;; 2. Zero/negative max-tokens rejected on creation
  (should-error (kargu-budget-create :run-id "test" :max-tokens 0))
  (should-error (kargu-budget-create :run-id "test" :max-tokens -50))

  ;; 3. Zero/negative timeout rejected on creation
  (should-error (kargu-budget-create :run-id "test" :timeout 0))
  (should-error (kargu-budget-create :run-id "test" :timeout -2.5))

  ;; 4. Negative max-compactions rejected on creation
  (should-error (kargu-budget-create :run-id "test" :max-compactions -1))

  ;; 5. Valid budget rejects zero or negative debit requests
  (let ((budget (kargu-budget-create :run-id "test" :max-requests 10)))
    (should-error (kargu-budget-debit budget :normal-request :requests 0))
    (should-error (kargu-budget-debit budget :normal-request :requests -1))

    ;; 6. Rejects negative tokens on debit
    (should-error (kargu-budget-debit budget :normal-request :tokens -10))

    ;; 7. Rejects negative prompt/completion tokens on record-tokens
    (should-error (kargu-budget-record-tokens budget -5 10))
    (should-error (kargu-budget-record-tokens budget 10 -20))))

(ert-deftest kargu-challenge-budget-exhaustion-and-sealing-test ()
  "Adversarially challenge request and token exhaustion and budget sealing."
  ;; Request exhaustion
  (let ((budget (kargu-budget-create :run-id "run-req" :max-requests 2)))
    (should (kargu-ok-p (kargu-budget-debit budget :normal-request :requests 1)))
    (should (= (kargu-run-budget-requests-spent budget) 1))
    (should (= (kargu-budget-remaining-requests budget) 1))

    ;; Debit exceeding remaining requests is rejected
    (let ((res (kargu-budget-debit budget :normal-request :requests 2)))
      (should (kargu-err-p res))
      (should (eq (kargu-result-err-code res) :budget-exhausted))
      (should (eq (plist-get (kargu-result-err-data res) :reason) :exhausted-requests))
      (should (eq (kargu-run-budget-status budget) :exhausted-requests))
      (should-not (kargu-budget-live-p budget))
      (should (kargu-budget-exhausted-p budget)))

    ;; Subsequent debits remain blocked
    (let ((res2 (kargu-budget-debit budget :normal-request :requests 1)))
      (should (kargu-err-p res2))
      (should (eq (kargu-result-err-code res2) :budget-exhausted))))

  ;; Token exhaustion
  (let ((budget (kargu-budget-create :run-id "run-tok" :max-tokens 100)))
    ;; Normal debit with tokens
    (should (kargu-ok-p (kargu-budget-debit budget :normal-request :tokens 70)))
    (should (= (kargu-run-budget-tokens-spent budget) 70))

    ;; Debit exceeding max-tokens is rejected
    (let ((res (kargu-budget-debit budget :normal-request :tokens 40)))
      (should (kargu-err-p res))
      (should (eq (kargu-result-err-code res) :budget-exhausted))
      (should (eq (plist-get (kargu-result-err-data res) :reason) :exhausted-tokens))
      (should (eq (kargu-run-budget-status budget) :exhausted-tokens)))

    ;; Further debits blocked
    (should (kargu-err-p (kargu-budget-debit budget :normal-request))))

  ;; Sealing
  (let ((budget (kargu-budget-create :run-id "run-seal" :max-requests 5)))
    (should (kargu-ok-p (kargu-budget-debit budget :normal-request)))
    (should (eq (kargu-run-budget-status budget) :ok))

    ;; Seal budget
    (kargu-budget-seal budget)
    (should (eq (kargu-run-budget-status budget) :sealed))
    (should-not (kargu-budget-live-p budget))
    (should (kargu-budget-exhausted-p budget))

    ;; Debits on sealed budget fail with reason :sealed
    (let ((res (kargu-budget-debit budget :normal-request)))
      (should (kargu-err-p res))
      (should (eq (kargu-result-err-code res) :budget-exhausted))
      (should (eq (plist-get (kargu-result-err-data res) :reason) :sealed)))

    ;; Sealing an already exhausted budget preserves the specific exhaustion reason
    (let ((exhausted (kargu-budget-create :run-id "run-exh" :max-requests 1)))
      (should (kargu-ok-p (kargu-budget-debit exhausted :normal-request)))
      (should (kargu-err-p (kargu-budget-debit exhausted :normal-request)))
      (should (eq (kargu-run-budget-status exhausted) :exhausted-requests))
      (kargu-budget-seal exhausted)
      ;; Status remains :exhausted-requests, not clobbered to :sealed
      (should (eq (kargu-run-budget-status exhausted) :exhausted-requests)))))

(ert-deftest kargu-challenge-budget-deadline-and-single-compaction-test ()
  "Adversarially challenge deadline expiry mid-execution and single compaction bound."
  ;; Deadline expiration mid-execution
  (let ((budget (kargu-budget-create :run-id "run-deadline" :timeout 0.1)))
    ;; Immediate debit succeeds
    (should (kargu-ok-p (kargu-budget-debit budget :normal-request)))
    (should (kargu-budget-live-p budget))

    ;; Sleep past deadline
    (sleep-for 0.15)

    ;; Mid-execution debit past deadline is rejected
    (let ((res (kargu-budget-debit budget :normal-request)))
      (should (kargu-err-p res))
      (should (eq (kargu-result-err-code res) :budget-exhausted))
      (should (eq (plist-get (kargu-result-err-data res) :reason) :exhausted-deadline))
      (should (eq (kargu-run-budget-status budget) :exhausted-deadline))
      (should-not (kargu-budget-live-p budget))))

  ;; Single compaction bound enforcement
  (let ((budget (kargu-budget-create :run-id "run-compact" :max-requests 10 :max-compactions 1)))
    ;; 1st compaction turn permitted
    (let ((res1 (kargu-budget-debit budget :compaction-turn)))
      (should (kargu-ok-p res1))
      (should (= (kargu-run-budget-compactions-spent budget) 1))
      (should (= (kargu-run-budget-requests-spent budget) 1))
      (should (eq (kargu-run-budget-status budget) :ok)))

    ;; 2nd compaction turn MUST be rejected
    (let ((res2 (kargu-budget-debit budget :compaction-turn)))
      (should (kargu-err-p res2))
      (should (eq (kargu-result-err-code res2) :budget-exhausted))
      (should (eq (plist-get (kargu-result-err-data res2) :reason) :exhausted-compactions))
      (should (eq (kargu-run-budget-status budget) :exhausted-compactions)))

    ;; Attempting 3rd compaction turn is also rejected
    (let ((res3 (kargu-budget-debit budget :compaction-turn)))
      (should (kargu-err-p res3))
      (should (eq (kargu-result-err-code res3) :budget-exhausted)))))

;;;; Suite 2: Async Task Ownership & Scope (Package A) -------------------------

(ert-deftest kargu-challenge-async-hierarchical-cancellation-and-isolation-test ()
  "Spawn nested parent/child tasks, cancel parent, verify recursive cancellation and sibling isolation."
  (let ((kargu-async--pending nil)
        (cleanups nil))
    (with-temp-buffer
      (let* ((orig-buf (current-buffer))
             ;; Root parent under owner-1
             (parent (kargu-async-start #'ignore :owner "owner-1" :buffer orig-buf))
             ;; Child 1 under parent
             (child1 (kargu-async-start #'ignore :owner "owner-1" :parent parent :buffer orig-buf))
             ;; Child 2 under parent
             (child2 (kargu-async-start #'ignore :owner "owner-1" :parent parent :buffer orig-buf))
             ;; Grandchild under child1
             (grandchild (kargu-async-start #'ignore :owner "owner-1" :parent child1 :buffer orig-buf))
             ;; Unrelated sibling under different owner (owner-2)
             (sibling-diff-owner (kargu-async-start #'ignore :owner "owner-2" :buffer orig-buf))
             ;; Unrelated sibling under owner-1 but without parent
             (sibling-same-owner (kargu-async-start #'ignore :owner "owner-1" :buffer orig-buf)))

        ;; Attach cleanup functions to verify teardown execution
        (kargu-async-add-cleanup parent (lambda () (push 'parent cleanups)))
        (kargu-async-add-cleanup child1 (lambda () (push 'child1 cleanups)))
        (kargu-async-add-cleanup child2 (lambda () (push 'child2 cleanups)))
        (kargu-async-add-cleanup grandchild (lambda () (push 'grandchild cleanups)))
        (kargu-async-add-cleanup sibling-diff-owner (lambda () (push 'sibling-diff-owner cleanups)))
        (kargu-async-add-cleanup sibling-same-owner (lambda () (push 'sibling-same-owner cleanups)))

        (should (= (length kargu-async--pending) 6))

        ;; Cancel parent
        (kargu-async-cancel parent)

        ;; 1. Parent, child1, child2, grandchild must all be :cancelled
        (should (eq (kargu-async-task-state parent) :cancelled))
        (should (eq (kargu-async-task-state child1) :cancelled))
        (should (eq (kargu-async-task-state child2) :cancelled))
        (should (eq (kargu-async-task-state grandchild) :cancelled))

        ;; 2. None of parent, child1, child2, grandchild remain in kargu-async--pending
        (should-not (memq parent kargu-async--pending))
        (should-not (memq child1 kargu-async--pending))
        (should-not (memq child2 kargu-async--pending))
        (should-not (memq grandchild kargu-async--pending))

        ;; 3. Cleanups were executed for all 4 cancelled tasks
        (should (memq 'parent cleanups))
        (should (memq 'child1 cleanups))
        (should (memq 'child2 cleanups))
        (should (memq 'grandchild cleanups))

        ;; 4. Unrelated sibling under different owner MUST REMAIN PENDING
        (should (eq (kargu-async-task-state sibling-diff-owner) :pending))
        (should (memq sibling-diff-owner kargu-async--pending))
        (should-not (memq 'sibling-diff-owner cleanups))

        ;; 5. Unrelated sibling under owner-1 (no parent link) MUST REMAIN PENDING
        (should (eq (kargu-async-task-state sibling-same-owner) :pending))
        (should (memq sibling-same-owner kargu-async--pending))
        (should-not (memq 'sibling-same-owner cleanups))

        ;; Cleanup remaining tasks cleanly
        (kargu-async-cancel sibling-diff-owner)
        (kargu-async-cancel sibling-same-owner)
        (should-not kargu-async--pending)))))

;;;; Suite 3: Application Reset Ordering & Isolation (Package A) ---------------

(ert-deftest kargu-challenge-application-reset-ordering-foreign-run-test ()
  "Verify `kargu-session-reset' preserves foreign runs and resets its own claim."
  (let ((app (kargu-application-context)))
    (unwind-protect
        (let ((claim-foreign (kargu-application-claim app :run-id "run-foreign-99" :session-id "sess-foreign-99")))
          (should claim-foreign)
          (should (equal (kargu-application-current-run app) "run-foreign-99"))
          (should (eq (kargu-application-current-status app) :running))

          ;; Execute reset from a different session context
          (with-temp-buffer
            (let ((local-owner (kargu-session-context)))
              ;; Verify local session is distinct from foreign session
              (should-not (equal (kargu-session-id local-owner) "sess-foreign-99"))

              ;; Run reset from local session
              (kargu-session-reset)

              ;; CRITICAL INVARIANT: foreign run and claim MUST remain completely untouched!
              (should (equal (kargu-application-current-run app) "run-foreign-99"))
              (should (eq (kargu-application-active-claim-token app) claim-foreign))
              (should (eq (kargu-application-current-status app) :running))))

          ;; Release foreign claim cleanly
          (should (kargu-application-release app claim-foreign))
          (should-not (kargu-application-current-run app))
          (should (eq (kargu-application-current-status app) :idle)))
      (kargu-application-reset app))))

;;;; Suite 4: Edit Service Isolation (Package B) -------------------------------

(ert-deftest kargu-challenge-edit-service-concurrent-isolation-test ()
  "Two kargu-edit-service instances concurrently operating on same and different files maintain isolated tables."
  (kargu-test-with-git-repo '(("fileA.txt" . "A original\n")
                              ("fileB.txt" . "B original\n")
                              ("fileC.txt" . "C original\n"))
    (let* ((fA (expand-file-name "fileA.txt" repo))
           (fB (expand-file-name "fileB.txt" repo))
           (fC (expand-file-name "fileC.txt" repo))
           (svc1 (kargu-edit-service-create :service-id "svc-iso-1" :root repo))
           (svc2 (kargu-edit-service-create :service-id "svc-iso-2" :root repo))
           (_ (kargu-test-mode 'agent)))
      (unwind-protect
          (progn
            ;; Service 1 edits fileA and fileB
            (kargu-diff-with-service svc1
              (kargu-diff-apply-proposal fA "A edited by svc1\n")
              (kargu-diff-apply-proposal fB "B edited by svc1\n"))

            ;; Service 2 edits fileB and fileC
            (kargu-diff-with-service svc2
              (kargu-diff-apply-proposal fB "B edited by svc2\n")
              (kargu-diff-apply-proposal fC "C edited by svc2\n"))

            ;; 1. Check snapshots isolation
            ;; svc1 must track fA and fB, but NEVER fC
            (should (gethash fA (kargu-edit-service-snapshots svc1)))
            (should (gethash fB (kargu-edit-service-snapshots svc1)))
            (should-not (gethash fC (kargu-edit-service-snapshots svc1)))

            ;; svc2 must track fB and fC, but NEVER fA
            (should (gethash fB (kargu-edit-service-snapshots svc2)))
            (should (gethash fC (kargu-edit-service-snapshots svc2)))
            (should-not (gethash fA (kargu-edit-service-snapshots svc2)))

            ;; 2. Check snapshot contents on shared file fB
            ;; svc1's initial snapshot recorded "B original\n"
            (let ((snap1 (car (gethash fB (kargu-edit-service-snapshots svc1)))))
              (should (equal (plist-get snap1 :content) "B original\n")))
            ;; svc2's initial snapshot recorded "B edited by svc1\n"
            (let ((snap2 (car (gethash fB (kargu-edit-service-snapshots svc2)))))
              (should (equal (plist-get snap2 :content) "B edited by svc1\n")))

            ;; 3. Check changes table isolation
            (should (gethash fA (kargu-edit-service-changes svc1)))
            (should (gethash fB (kargu-edit-service-changes svc1)))
            (should-not (gethash fC (kargu-edit-service-changes svc1)))

            (should (gethash fB (kargu-edit-service-changes svc2)))
            (should (gethash fC (kargu-edit-service-changes svc2)))
            (should-not (gethash fA (kargu-edit-service-changes svc2)))

            ;; 4. Check active plans table isolation
            (should (= (hash-table-count (kargu-edit-service-active-plans svc1)) 0))
            (should (= (hash-table-count (kargu-edit-service-active-plans svc2)) 0))

            ;; 5. Rollback on svc2 for fC does not affect svc1's files fA or fB
            (kargu-diff-rollback fC nil svc2)
            (with-temp-buffer
              (insert-file-contents fC)
              (should (equal (buffer-string) "C original\n")))
            (with-temp-buffer
              (insert-file-contents fA)
              (should (equal (buffer-string) "A edited by svc1\n"))))
        (kargu-edit-service-close svc1)
        (kargu-edit-service-close svc2)))))

;;;; Suite 5: Frozen Approval Identity & Conflict Errors (Package B) -----------

(ert-deftest kargu-challenge-frozen-approval-identity-conflicts-test ()
  "Challenge frozen approval identity against unsaved buffer, disk changes, and policy revision."
  (kargu-test-with-git-repo '(("doc.txt" . "line 1\nline 2\n"))
    (let* ((path (expand-file-name "doc.txt" repo))
           (svc (kargu-edit-service-create :service-id "svc-froz" :policy-revision 1 :root repo))
           (_ (kargu-test-mode 'agent)))
      (unwind-protect
          (progn
            ;; 1. Policy revision mismatch -> :policy-conflict
            (let ((plan-policy (kargu-edit-plan-create
                                :path path
                                :kind :block
                                :proposed-content '(:old-string "line 1\n" :new-string "line 1 mod\n")
                                :policy-revision 1)))
              (setf (kargu-edit-service-policy-revision svc) 2)
              (let ((res (kargu-diff-submit-plan svc plan-policy)))
                (should (kargu-err-p res))
                (should (eq (kargu-result-err-code res) :policy-conflict))
                (should (string-search "Policy revision mismatch" (kargu-result-err-message res))))
              ;; Reset policy revision back to 1 for next tests
              (setf (kargu-edit-service-policy-revision svc) 1))

            ;; 2. Unsaved buffer modifications -> :conflict
            (let* ((buf (find-file-noselect path))
                   (plan-buf (kargu-edit-plan-create
                              :path path
                              :kind :block
                              :proposed-content '(:old-string "line 1\n" :new-string "line 1 mod\n")
                              :policy-revision 1)))
              (with-current-buffer buf
                (insert "dirty edit\n")
                (should (buffer-modified-p)))
              (let ((res (kargu-diff-submit-plan svc plan-buf)))
                (should (kargu-err-p res))
                (should (eq (kargu-result-err-code res) :conflict))
                (should (string-search "unsaved modifications" (kargu-result-err-message res))))
              (with-current-buffer buf (set-buffer-modified-p nil))
              (kill-buffer buf))

            ;; 3. Document revision change on disk -> :conflict
            (let ((plan-disk (kargu-edit-plan-create
                              :path path
                              :kind :block
                              :proposed-content '(:old-string "line 1\n" :new-string "line 1 mod\n")
                              :policy-revision 1)))
              ;; External writer modifies file
              (write-region "external writer modified\n" nil path nil 'silent)
              (let ((res (kargu-diff-submit-plan svc plan-disk)))
                (should (kargu-err-p res))
                (should (eq (kargu-result-err-code res) :conflict))
                (should (string-search "Document revision changed" (kargu-result-err-message res)))))

            ;; 4. Session mismatch -> :session-conflict
            (write-region "line 1\nline 2\n" nil path nil 'silent)
            (let ((plan-sess (kargu-edit-plan-create
                              :path path
                              :kind :block
                              :proposed-content '(:old-string "line 1\n" :new-string "line 1 mod\n")
                              :policy-revision 1
                              :session-id "session-alpha")))
              (cl-letf (((symbol-function 'kargu-session-context)
                         (lambda () (kargu-session--create :id-value "session-beta"))))
                (let ((res (kargu-diff-submit-plan svc plan-sess)))
                  (should (kargu-err-p res))
                  (should (eq (kargu-result-err-code res) :session-conflict))
                  (should (string-search "Session mismatch" (kargu-result-err-message res)))))))
        (kargu-edit-service-close svc)))))

;;;; Suite 6: Closed Edit Service Rejection (Package B) ------------------------

(ert-deftest kargu-challenge-closed-edit-service-test ()
  "Closing an edit service causes subsequent plan submissions to fail with :service-closed."
  (kargu-test-with-git-repo '(("target.txt" . "hello world\n"))
    (let* ((path (expand-file-name "target.txt" repo))
           (svc (kargu-edit-service-create :service-id "svc-closed-test" :root repo))
           (buf (generate-new-buffer "*tracked-buf*"))
           (dir (make-temp-file "tracked-dir-" t))
           (plan (kargu-edit-plan-create
                  :path path
                  :kind :block
                  :proposed-content '(:old-string "hello world\n" :new-string "goodbye\n"))))
      (unwind-protect
          (progn
            (kargu-edit-service-register-buffer svc buf)
            (kargu-edit-service-register-temp-dir svc dir)

            ;; Close service
            (kargu-edit-service-close svc)
            (should (kargu-edit-service-closed-p svc))

            ;; Resources must be released
            (should-not (buffer-live-p buf))
            (should-not (file-directory-p dir))

            ;; Synchronous submission returns (kargu-err ... :service-closed)
            (let ((res (kargu-diff-submit-plan svc plan)))
              (should (kargu-err-p res))
              (should (eq (kargu-result-err-code res) :service-closed))
              (should (string-search "Edit service is closed" (kargu-result-err-message res))))

            ;; Asynchronous submission delivers (kargu-err ... :service-closed) to callback
            (let ((async-delivered nil))
              (kargu-diff-submit-plan
               svc plan
               (lambda (res)
                 (setq async-delivered res)))
              (should (kargu-err-p async-delivered))
              (should (eq (kargu-result-err-code async-delivered) :service-closed))))
        (when (buffer-live-p buf) (kill-buffer buf))
        (when (file-directory-p dir) (delete-directory dir t))))))

;;;; Suite 7: Git Worktree Safety (Package B) ----------------------------------

(ert-deftest kargu-challenge-git-worktree-safety-test ()
  "Verify kargu diff/patch workspace operations NEVER modify or stage into the user's actual Git index."
  (kargu-test-with-git-repo '(("staged.txt" . "user staged content\n")
                              ("working.txt" . "working tree initial\n")
                              ("file-to-patch.txt" . "patch target line 1\npatch target line 2\n"))
    (let* ((staged-file (expand-file-name "staged.txt" repo))
           (working-file (expand-file-name "working.txt" repo))
           (patch-file (expand-file-name "file-to-patch.txt" repo))
           (svc (kargu-edit-service-create :service-id "svc-git-safety" :root repo))
           (_ (kargu-test-mode 'agent)))
      (unwind-protect
          (progn
            ;; 1. User stages staged.txt into git index
            (write-region "user modified staged content\n" nil staged-file nil 'silent)
            (call-process "git" nil nil nil "add" "staged.txt")

            ;; 2. User has unstaged change in working.txt
            (write-region "user dirty unstaged content\n" nil working-file nil 'silent)

            ;; Record git status and staged diff BEFORE any kargu operations
            (let ((staged-diff-before
                   (with-temp-buffer
                     (call-process "git" nil t nil "diff" "--cached")
                     (buffer-string)))
                  (status-before
                   (with-temp-buffer
                     (call-process "git" nil t nil "status" "--short")
                     (buffer-string))))
              ;; Staged diff MUST contain the user's staged change
              (should (string-search "user modified staged content" staged-diff-before))
              ;; Staged status must show staged.txt as M or A in index, working.txt as M in tree
              (should (string-search "M  staged.txt" status-before))
              (should (string-search " M working.txt" status-before))

              ;; 3. Execute kargu-diff-apply-patch (unified diff patch)
              (let ((patch-text
                     (concat "--- a/file-to-patch.txt\n"
                             "+++ b/file-to-patch.txt\n"
                             "@@ -1,2 +1,2 @@\n"
                             "-patch target line 1\n"
                             "+patch target line 1 modified by kargu\n"
                             " patch target line 2\n"
                             "--- /dev/null\n"
                             "+++ b/kargu-created.txt\n"
                             "@@ -0,0 +1 @@\n"
                             "+new file created by kargu patch\n")))
                (let ((patch-res (kargu-diff-apply-patch patch-text)))
                  (should (string-prefix-p "Patch successfully applied" patch-res))))

              ;; 4. Execute block replacement via kargu-diff-submit-plan
              (let ((plan-block (kargu-edit-plan-create
                                 :path patch-file
                                 :kind :block
                                 :proposed-content '(:old-string "patch target line 2\n"
                                                                :new-string "patch target line 2 block-edited\n"))))
                (let ((res-block (kargu-diff-submit-plan svc plan-block)))
                  (should (kargu-ok-p res-block))))

              ;; 5. Execute write proposal via kargu-diff-submit-plan
              (let ((plan-write (kargu-edit-plan-create
                                 :path (expand-file-name "kargu-written.txt" repo)
                                 :kind :write
                                 :proposed-content "completely written by kargu\n")))
                (let ((res-write (kargu-diff-submit-plan svc plan-write)))
                  (should (kargu-ok-p res-write))))

              ;; 6. VERIFY GIT INDEX INTEGRITY:
              ;; `git diff --cached` MUST REMAIN EXACTLY IDENTICAL!
              ;; Zero changes staged into the user's git index.
              (let ((staged-diff-after
                     (with-temp-buffer
                       (call-process "git" nil t nil "diff" "--cached")
                       (buffer-string))))
                (should (equal staged-diff-before staged-diff-after)))

              ;; `git status --short` staged column (first character) for staged.txt must remain 'M'
              ;; and NO other files may have anything in the staged column!
              (let ((status-after-lines
                     (with-temp-buffer
                       (call-process "git" nil t nil "status" "--short")
                       (split-string (buffer-string) "\n" t))))
                (dolist (line status-after-lines)
                  (let ((index-char (substring line 0 1))
                        (filename (string-trim (substring line 2))))
                    (if (equal filename "staged.txt")
                        (should (equal index-char "M"))
                      ;; For all other files, the staged column MUST be space or '?' (untracked)
                      ;; NEVER 'M', 'A', 'D', 'R', 'C'
                      (should (member index-char '(" " "?")))))))

              ;; 7. Verify no temporary files leaked into the git repo
              (should-not (file-exists-p (expand-file-name ".kargu.patch" repo)))
              (should-not (file-exists-p (expand-file-name ".git/index.lock" repo)))))
        (kargu-edit-service-close svc)))))

;;;; Standalone Batch Runner ---------------------------------------------------

(defun wave1-run-empirical-challenges ()
  "Execute all Wave 1 empirical challenges and print structured empirical report."
  (interactive)
  (let ((tests '(kargu-challenge-budget-negative-and-zero-limits-test
                 kargu-challenge-budget-exhaustion-and-sealing-test
                 kargu-challenge-budget-deadline-and-single-compaction-test
                 kargu-challenge-async-hierarchical-cancellation-and-isolation-test
                 kargu-challenge-application-reset-ordering-foreign-run-test
                 kargu-challenge-edit-service-concurrent-isolation-test
                 kargu-challenge-frozen-approval-identity-conflicts-test
                 kargu-challenge-closed-edit-service-test
                 kargu-challenge-git-worktree-safety-test))
        (passed 0)
        (failed 0)
        (failures nil))
    (message "==================================================================")
    (message "STARTING WAVE 1 EMPIRICAL CHALLENGE SUITE (Packages A & B)")
    (message "==================================================================")
    (dolist (test tests)
      (message "\n>>> Running %s..." test)
      (condition-case err
          (progn
            (funcall (ert-test-body (ert-get-test test)))
            (cl-incf passed)
            (message ">>> PASS: %s" test))
        (error
         (cl-incf failed)
         (push (cons test (error-message-string err)) failures)
         (message ">>> FAIL: %s -> %s" test (error-message-string err)))))
    (message "\n==================================================================")
    (message "WAVE 1 EMPIRICAL CHALLENGE SUMMARY:")
    (message "Total: %d | Passed: %d | Failed: %d" (length tests) passed failed)
    (message "==================================================================")
    (if (zerop failed)
        (progn
          (message "ALL WAVE 1 EMPIRICAL CHALLENGES PASSED SUCCESSFULLY.")
          (kill-emacs 0))
      (progn
        (message "CHALLENGE FAILURES ENCOUNTERED:")
        (dolist (f (nreverse failures))
          (message "  - %s: %s" (car f) (cdr f)))
        (kill-emacs 1)))))

(provide 'tests/test-wave1-empirical-challenge)
;;; test-wave1-empirical-challenge.el ends here
