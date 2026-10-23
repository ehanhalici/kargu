;;; test-application-context.el --- Application coordinator and context isolation tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Verifies the Wave 0 acceptance gate and ARCH-01/ARCH-12 invariants:
;; 1. Two isolated application fixtures do not mutate or affect each other.
;; 2. A second active run or claim on the same application instance is rejected.
;; 3. Execution claims and releases are strictly scoped to the claiming handle.
;; 4. Logical requests and generation counters belong strictly to their owner instance.
;; 5. In-flight requests block claims and rejected claims preserve generations.
;; 6. File revisions resolve symlinks and reject remote Tramp paths cleanly.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'kargu/core)
(require 'kargu/files)
(require 'kargu/application/coordinator)
(require 'kargu/application/reset)
(require 'tests/test-helpers)

(ert-deftest kargu-application-dual-instance-isolation-test ()
  "Two independent application coordinator instances never share mutable state."
  (kargu-test-with-dual-applications (app-a app-b)
    ;; Initial state
    (should (eq (kargu-application-current-status app-a) :idle))
    (should (eq (kargu-application-current-status app-b) :idle))
    (should-not (kargu-application-current-run app-a))
    (should-not (kargu-application-current-run app-b))
    (should (= (kargu-application-current-generation app-a) 0))
    (should (= (kargu-application-current-generation app-b) 100))

    ;; Status isolation
    (kargu-application-set-status :busy app-a)
    (should (eq (kargu-application-current-status app-a) :busy))
    (should (eq (kargu-application-current-status app-b) :idle))

    ;; Active run isolation
    (kargu-application-set-active-run "run-alpha" app-a)
    (should (equal (kargu-application-current-run app-a) "run-alpha"))
    (should-not (kargu-application-current-run app-b))

    ;; Generation isolation
    (should (= (kargu-application-next-generation app-a) 1))
    (should (= (kargu-application-current-generation app-a) 1))
    (should (= (kargu-application-current-generation app-b) 100))

    ;; Work-active and busy predicates isolation
    (should (kargu-application-work-active-p app-a))
    (should-not (kargu-application-work-active-p app-b))
    (should (kargu-application-busy-p app-a))
    (should-not (kargu-application-busy-p app-b))

    ;; Reset isolation
    (kargu-application-set-status :waiting-model app-b)
    (kargu-application-set-active-run "run-beta" app-b)
    (should (equal (kargu-application-current-run app-b) "run-beta"))
    (should (eq (kargu-application-current-status app-b) :waiting-model))

    (kargu-application-reset app-a)
    (should (eq (kargu-application-current-status app-a) :idle))
    (should-not (kargu-application-current-run app-a))
    (should (eq (kargu-application-current-status app-b) :waiting-model))
    (should (equal (kargu-application-current-run app-b) "run-beta"))))

(ert-deftest kargu-application-logical-request-isolation-test ()
  "Logical requests and stream timers belong strictly to their owning application."
  (kargu-test-with-dual-applications (app-a app-b)
    (let ((req-a (kargu-logical-request-create :id "req-a" :generation 1 :state :in-flight)))
      (kargu-application-set-active-request req-a app-a)
      (should (eq (kargu-application-current-request app-a) req-a))
      (should-not (kargu-application-current-request app-b))
      (should (kargu-application-work-active-p app-a))
      (should-not (kargu-application-work-active-p app-b))

      ;; Cancelling request on A leaves B untouched
      (kargu-logical-request-cancel req-a)
      (should (eq (kargu-logical-request-state req-a) :cancelled))
      (should-not (kargu-application-work-active-p app-a))
      (should-not (kargu-application-work-active-p app-b)))))

(ert-deftest kargu-application-single-active-run-rejected-test ()
  "Attempting a second active run on an application instance is rejected (ARCH-01)."
  (let ((app (kargu-application-create :status :idle)))
    (kargu-application-set-active-run "run-first" app)
    (should (equal (kargu-application-current-run app) "run-first"))

    ;; Same run is idempotent
    (should (equal (kargu-application-set-active-run "run-first" app) "run-first"))

    ;; Second distinct run is rejected with an error
    (should-error (kargu-application-set-active-run "run-second" app))
    (should (equal (kargu-application-current-run app) "run-first"))

    ;; Clearing the run allows a new run to start
    (kargu-application-set-active-run nil app)
    (should-not (kargu-application-current-run app))
    (kargu-application-set-active-run "run-second" app)
    (should (equal (kargu-application-current-run app) "run-second"))))

(ert-deftest kargu-application-claim-and-release-lifecycle-test ()
  "Claims enforce single-run invariant and release requires matching claim."
  (kargu-test-with-dual-applications (app-a app-b)
    (let ((claim-a (kargu-application-claim app-a :run-id "run-a" :session-id "sess-a")))
      (should claim-a)
      (should (equal (kargu-application-current-run app-a) "run-a"))
      (should (eq (kargu-application-current-status app-a) :running))

      ;; App B remains idle
      (should (eq (kargu-application-current-status app-b) :idle))
      (should-not (kargu-application-current-run app-b))

      ;; Second claim on App A is rejected
      (should-error (kargu-application-claim app-a :run-id "run-a2" :session-id "sess-a"))
      (should (equal (kargu-application-current-run app-a) "run-a"))

      ;; App B can claim independently
      (let ((claim-b (kargu-application-claim app-b :run-id "run-b" :session-id "sess-b")))
        (should claim-b)
        (should (equal (kargu-application-current-run app-b) "run-b"))
        (should (equal (kargu-application-current-run app-a) "run-a"))

        ;; Release with mismatched claim fails
        (should-not (kargu-application-release app-a claim-b))
        (should (equal (kargu-application-current-run app-a) "run-a"))

        ;; Release with matching claim succeeds
        (should (kargu-application-release app-a claim-a))
        (should-not (kargu-application-current-run app-a))
        (should (eq (kargu-application-current-status app-a) :idle))

        ;; App B is still running
        (should (equal (kargu-application-current-run app-b) "run-b"))
        (should (kargu-application-release app-b claim-b))
        (should-not (kargu-application-current-run app-b))))))

(ert-deftest kargu-application-claim-in-flight-request-blocks-claim-test ()
  "An active in-flight logical request must block execution claims (BUG-04, ARCH-01)."
  (let ((app (kargu-application-create :status :idle :generation 1)))
    (unwind-protect
        (let ((req (kargu-logical-request-create :id "req-1" :generation 1 :state :in-flight)))
          (kargu-application-set-active-request req app)
          (should (kargu-application-work-active-p app))
          ;; Claim without explicit run-id and :no-error t must return nil
          (should-not (kargu-application-claim app :no-error t))
          (should-not (kargu-application-current-run app))
          (should (eq (kargu-application-current-status app) :idle))
          ;; Claim without :no-error must signal an error
          (should-error (kargu-application-claim app))
          (should-not (kargu-application-current-run app))
          ;; Claim with explicit run-id must also be rejected
          (should-error (kargu-application-claim app :run-id "run-explicit"))
          (should-not (kargu-application-current-run app))
          ;; Cancelling request makes application claimable again
          (kargu-logical-request-cancel req)
          (should-not (kargu-application-work-active-p app))
          (let ((claim (kargu-application-claim app)))
            (should claim)
            (should (equal (kargu-application-current-run app) "run-2"))
            (should (eq (kargu-application-current-status app) :running))
            (should (kargu-application-release app claim))))
      (kargu-application-reset app))))

(ert-deftest kargu-application-cross-instance-claim-release-rejected-test ()
  "A claim token from Application B cannot release Application A (ARCH-01/12, BUG-06)."
  (kargu-test-with-dual-applications (app-a app-b)
    ;; Force both applications to generation 0 to guarantee identical default run-ids
    (setf (kargu-application-generation app-a) 0
          (kargu-application-generation app-b) 0)
    (let ((claim-a (kargu-application-claim app-a))
          (claim-b (kargu-application-claim app-b)))
      (should claim-a)
      (should claim-b)
      ;; Invariant check: identical default run-ids
      (should (equal (kargu-application-claim-run-id claim-a) "run-1"))
      (should (equal (kargu-application-claim-run-id claim-b) "run-1"))
      (should (equal (kargu-application-current-run app-a) "run-1"))
      (should (equal (kargu-application-current-run app-b) "run-1"))
      (should (eq (kargu-application-current-status app-a) :running))
      (should (eq (kargu-application-current-status app-b) :running))

      ;; Cross-releasing App A using Claim B MUST fail and return nil
      (should-not (kargu-application-release app-a claim-b))
      (should (equal (kargu-application-current-run app-a) "run-1"))
      (should (eq (kargu-application-current-status app-a) :running))

      ;; Cross-releasing App B using Claim A MUST fail and return nil
      (should-not (kargu-application-release app-b claim-a))
      (should (equal (kargu-application-current-run app-b) "run-1"))
      (should (eq (kargu-application-current-status app-b) :running))

      ;; Legitimate releases succeed
      (should (kargu-application-release app-a claim-a))
      (should-not (kargu-application-current-run app-a))
      (should (eq (kargu-application-current-status app-a) :idle))

      (should (kargu-application-release app-b claim-b))
      (should-not (kargu-application-current-run app-b))
      (should (eq (kargu-application-current-status app-b) :idle)))))

(ert-deftest kargu-application-claim-rejected-generation-unchanged-test ()
  "Rejected claims must not advance the application generation counter (BUG-05)."
  (let ((app (kargu-application-create :status :idle :generation 5)))
    (unwind-protect
        (progn
          ;; 1. First claim succeeds and advances generation from 5 to 6
          (let ((claim-1 (kargu-application-claim app)))
            (should claim-1)
            (should (= (kargu-application-current-generation app) 6))
            (should (equal (kargu-application-current-run app) "run-6"))

            ;; 2. Second claim attempted with :no-error t is rejected; generation must stay 6
            (should-not (kargu-application-claim app :no-error t))
            (should (= (kargu-application-current-generation app) 6))

            ;; 3. Second claim attempted without :no-error signals error; generation must stay 6
            (should-error (kargu-application-claim app))
            (should (= (kargu-application-current-generation app) 6))

            ;; 4. Releasing the claim leaves generation at 6
            (should (kargu-application-release app claim-1))
            (should (= (kargu-application-current-generation app) 6)))

          ;; 5. Test with active request: in-flight request blocks claim without generation advance
          (let ((req (kargu-logical-request-create :id "req-test" :generation 6 :state :in-flight)))
            (kargu-application-set-active-request req app)
            (should (= (kargu-application-current-generation app) 6))
            ;; Claim rejected because request is active; generation must remain 6
            (should-not (kargu-application-claim app :no-error t))
            (should (= (kargu-application-current-generation app) 6))
            (should-error (kargu-application-claim app))
            (should (= (kargu-application-current-generation app) 6))
            (kargu-logical-request-cancel req)))
      (kargu-application-reset app))))

(ert-deftest kargu-file-current-revision-remote-path-returns-nil-test ()
  "Remote Tramp paths return nil without triggering network calls (BUG-01)."
  ;; Remote path strings with various Tramp syntax prefixes must return nil
  (should-not (kargu-file-current-revision "/ssh:user@nohost:/path/to/file"))
  (should-not (kargu-file-current-revision "/sudo:root@localhost:/etc/shadow"))
  (should-not (kargu-file-current-revision "/scp:remote:/var/log/syslog"))
  (should-not (kargu-file-current-revision "/sshx:deploy@example.org:/app/config.json"))

  ;; Remote file visiting buffer must also return nil without network I/O
  (let ((buf (generate-new-buffer " *kargu-remote-test*")))
    (unwind-protect
        (with-current-buffer buf
          (setq buffer-file-name "/ssh:user@nohost:/remote/file.txt")
          (should-not (kargu-file-current-revision buf)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest kargu-file-current-revision-symlink-resolution-test ()
  "Symlinks resolve to canonical targets, and dangling symlinks return nil (BUG-02, BUG-03)."
  (let* ((temp-dir (file-name-as-directory (make-temp-file "kargu-symlink-test-" t)))
         (target (expand-file-name "target.txt" temp-dir))
         (symlink (expand-file-name "symlink.txt" temp-dir))
         (dangling (expand-file-name "dangling.txt" temp-dir))
         (buf nil))
    (unwind-protect
        (progn
          ;; 1. Dangling symlink pointing to non-existent file must return nil (BUG-02)
          (make-symbolic-link (expand-file-name "does-not-exist.txt" temp-dir) dangling)
          (should-not (kargu-file-current-revision dangling))
          ;; Buffer visiting a dangling symlink must also return nil
          (setq buf (find-file-noselect dangling))
          (should-not (kargu-file-current-revision buf))
          (kill-buffer buf)
          (setq buf nil)

          ;; 2. Valid symlink pointing to existing target file (BUG-03)
          (write-region "initial content" nil target nil 'silent)
          (make-symbolic-link target symlink)

          (let ((target-rev (kargu-file-current-revision target))
                (link-rev (kargu-file-current-revision symlink)))
            (should target-rev)
            (should link-rev)
            ;; Symlink revision must match the target's canonical revision
            (should (equal target-rev link-rev))

            ;; 3. Modifying target file must produce an updated revision via symlink (BUG-03)
            ;; Sleep briefly to ensure filesystem mtime advances
            (sleep-for 0.05)
            (write-region "modified target content with different length" nil target nil 'silent)

            (let ((updated-target-rev (kargu-file-current-revision target))
                  (updated-link-rev (kargu-file-current-revision symlink)))
              (should updated-target-rev)
              (should updated-link-rev)
              ;; Revisions through target and through symlink must remain in sync
              (should (equal updated-target-rev updated-link-rev))
              ;; Updated revision must differ from initial revision
              (should-not (equal link-rev updated-link-rev)))))
      ;; Ensure cleanup of all temporary resources
      (when (and buf (buffer-live-p buf))
        (kill-buffer buf))
      (when (file-directory-p temp-dir)
        (delete-directory temp-dir t)))))

(ert-deftest kargu-application-status-transition-table-test ()
  "Transition table governs permitted and forbidden status transitions (ARCH-11)."
  (let ((app (kargu-application-create :status :idle)))
    ;; 1. Valid transitions through standard lifecycle
    (should (eq (kargu-application-transition app :starting) :starting))
    (should (eq (kargu-application-current-status app) :starting))
    (should (eq (kargu-application-transition app :running) :running))
    (should (eq (kargu-application-transition app :requesting) :requesting))
    (should (eq (kargu-application-transition app :streaming) :streaming))
    (should (eq (kargu-application-transition app :executing-tool) :executing-tool))
    (should (eq (kargu-application-transition app :done) :done))
    (should (eq (kargu-application-transition app :idle) :idle))

    ;; 2. Invalid transitions must signal an error
    (should-error (kargu-application-transition app :streaming))
    (should-error (kargu-application-transition app :executing-tool))
    (should (eq (kargu-application-current-status app) :idle))

    ;; 3. Direct set-status validates against transition table
    (should (eq (kargu-application-set-status :starting app) :starting))
    (should-error (kargu-application-set-status :done app))))

(ert-deftest kargu-application-explicit-identity-and-claim-slots-test ()
  "Applications and claims have unique IDs and explicit metadata slots (ARCH-01, Contract 1)."
  (let ((app (kargu-application-create :status :idle :generation 10)))
    (should (stringp (kargu-application-id app)))
    (should (string-prefix-p "app-" (kargu-application-id app)))
    (should-not (kargu-application-active-claim-token app))

    (let ((claim (kargu-application-claim app :run-id "run-explicit" :session-id "sess-1" :mode 'agent)))
      (should claim)
      (should (eq (kargu-application-active-claim-token app) claim))
      (should (equal (kargu-application-claim-run-id claim) "run-explicit"))
      (should (equal (kargu-application-claim-session-id claim) "sess-1"))
      (should (eq (kargu-application-claim-mode claim) 'agent))
      (should (equal (kargu-application-claim-app-id claim) (kargu-application-id app)))
      (should (equal (kargu-application-claim-token claim) (kargu-application-claim-id claim)))
      (should (numberp (kargu-application-claim-created-at claim)))

      (should (kargu-application-release app claim))
      (should-not (kargu-application-active-claim-token app))
      (should-not (kargu-application-current-run app)))))

(ert-deftest kargu-application-reset-ordering-isolation-test ()
  "Resetting a session never clears or invalidates a foreign run on the coordinator."
  (let ((app (kargu-application-context)))
    (unwind-protect
        (let ((claim-foreign (kargu-application-claim app :run-id "run-foreign" :session-id "sess-foreign")))
          (should claim-foreign)
          (should (equal (kargu-application-current-run app) "run-foreign"))

          ;; Reset in an unrelated buffer (different session) must leave foreign run untouched
          (with-temp-buffer
            (let ((owner (kargu-session-context)))
              ;; Our session is different from sess-foreign
              (should-not (equal (kargu-session-id owner) "sess-foreign"))
              (kargu-session-reset)
              ;; Foreign run and claim must remain intact
              (should (equal (kargu-application-current-run app) "run-foreign"))
              (should (eq (kargu-application-active-claim-token app) claim-foreign))))

          ;; Release foreign claim cleanly
          (should (kargu-application-release app claim-foreign)))
      (kargu-application-reset app))))

(provide 'tests/test-application-context)
;;; test-application-context.el ends here
