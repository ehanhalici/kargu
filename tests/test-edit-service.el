;;; test-edit-service.el --- Tests for single-owner edit service and approval identity -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests covering Contract 3 (Edit Service Contract):
;; - Single-owner edit service context isolation (snapshots, changes, reviews, active plans)
;; - Frozen approval identity and policy revision invalidation
;; - Session mismatch invalidation
;; - Document revision verification (disk, buffer modified)
;; - Resource cleanup on service close (processes, timers, buffers, temp dirs)
;; - Non-leakage across services (same path / different paths)
;; - Git working tree protection (staged index untouched, isolated git apply)
;; - Dirty / narrowed / CRLF / Unicode preservation
;; - Unified kargu-edit-outcome contract

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'kargu)

(require 'kargu/core)
(require 'kargu/core/session)
(require 'kargu/permission)
(require 'kargu/files)
(require 'kargu/contract/result)
(require 'kargu/edit)
(require 'kargu/tools/diff)
(require 'kargu/tools/diff/context)
(require 'tests/test-helpers)

(ert-deftest kargu-edit-service-two-services-different-paths-test ()
  "Two edit services operating on different files maintain isolated state and tables."
  (kargu-test-with-git-repo '(("file1.txt" . "alpha 1\n") ("file2.txt" . "beta 1\n"))
    (let* ((f1 (expand-file-name "file1.txt" repo))
           (f2 (expand-file-name "file2.txt" repo))
           (svc1 (kargu-edit-service-create :service-id "svc-1" :root repo))
           (svc2 (kargu-edit-service-create :service-id "svc-2" :root repo))
           (_ (kargu-test-mode 'agent)))
      (unwind-protect
          (progn
            ;; Service 1 edits file1
            (kargu-diff-with-service svc1
              (kargu-diff-apply-proposal f1 "alpha 2\n"))
            ;; Service 2 edits file2
            (kargu-diff-with-service svc2
              (kargu-diff-apply-proposal f2 "beta 2\n"))

            ;; Verify table isolation
            (should (gethash f1 (kargu-edit-service-snapshots svc1)))
            (should-not (gethash f2 (kargu-edit-service-snapshots svc1)))
            (should (gethash f2 (kargu-edit-service-snapshots svc2)))
            (should-not (gethash f1 (kargu-edit-service-snapshots svc2)))

            (should (gethash f1 (kargu-edit-service-changes svc1)))
            (should-not (gethash f2 (kargu-edit-service-changes svc1)))
            (should (gethash f2 (kargu-edit-service-changes svc2)))
            (should-not (gethash f1 (kargu-edit-service-changes svc2)))

            ;; Rollback on svc1 restores file1 only
            (kargu-diff-rollback f1 nil svc1)
            (with-temp-buffer
              (insert-file-contents f1)
              (should (equal (buffer-string) "alpha 1\n")))
            (with-temp-buffer
              (insert-file-contents f2)
              (should (equal (buffer-string) "beta 2\n")))

            ;; svc2 still has its snapshot and change
            (should (gethash f2 (kargu-edit-service-snapshots svc2)))
            (should (gethash f2 (kargu-edit-service-changes svc2))))
        (kargu-edit-service-close svc1)
        (kargu-edit-service-close svc2)))))

(ert-deftest kargu-edit-service-two-services-same-path-isolation-test ()
  "Two edit services modifying the same file maintain disjoint histories and tables."
  (kargu-test-with-git-repo '(("shared.txt" . "step 0\n"))
    (let* ((shared (expand-file-name "shared.txt" repo))
           (svc1 (kargu-edit-service-create :service-id "svc-1" :root repo))
           (svc2 (kargu-edit-service-create :service-id "svc-2" :root repo))
           (_ (kargu-test-mode 'agent)))
      (unwind-protect
          (progn
            ;; svc1 moves step 0 -> step 1
            (kargu-diff-with-service svc1
              (kargu-diff-apply-proposal shared "step 1\n"))
            (should (= (length (gethash shared (kargu-edit-service-snapshots svc1))) 1))
            (should-not (gethash shared (kargu-edit-service-snapshots svc2)))

            ;; svc2 moves step 1 -> step 2
            (kargu-diff-with-service svc2
              (kargu-diff-apply-proposal shared "step 2\n"))
            (should (= (length (gethash shared (kargu-edit-service-snapshots svc2))) 1))

            ;; svc1's snapshot still records step 0
            (let ((snap1 (car (gethash shared (kargu-edit-service-snapshots svc1)))))
              (should (equal (plist-get snap1 :content) "step 0\n")))
            ;; svc2's snapshot records step 1
            (let ((snap2 (car (gethash shared (kargu-edit-service-snapshots svc2)))))
              (should (equal (plist-get snap2 :content) "step 1\n")))

            ;; Rolling back on svc2 restores to step 1
            (kargu-diff-rollback shared nil svc2)
            (with-temp-buffer
              (insert-file-contents shared)
              (should (equal (buffer-string) "step 1\n")))

            ;; svc1's rollback correctly detects that intervening writer touched the file
            ;; and signals a conflict error instead of silently corrupting
            (should-error (kargu-diff-rollback shared nil svc1)))
        (kargu-edit-service-close svc1)
        (kargu-edit-service-close svc2)))))

(ert-deftest kargu-edit-service-approval-invalidated-on-policy-change-test ()
  "An edit plan captured with policy revision N is rejected if policy revision changes."
  (kargu-test-with-git-repo '(("sample.txt" . "old line\n"))
    (let* ((path (expand-file-name "sample.txt" repo))
           (svc (kargu-edit-service-create :service-id "svc-policy" :policy-revision 1 :root repo))
           (_ (kargu-test-mode 'agent))
           (plan (kargu-edit-plan-create
                  :path path
                  :kind :block
                  :proposed-content '(:old-string "old line\n" :new-string "new line\n")
                  :policy-revision 1)))
      (unwind-protect
          (progn
            ;; Invalidate approval by bumping service policy revision
            (setf (kargu-edit-service-policy-revision svc) 2)
            (let ((result (kargu-diff-submit-plan svc plan)))
              (should (kargu-err-p result))
              (should (eq (kargu-result-err-code result) :policy-conflict))
              ;; File on disk remains untouched
              (with-temp-buffer
                (insert-file-contents path)
                (should (equal (buffer-string) "old line\n")))))
        (kargu-edit-service-close svc)))))

(ert-deftest kargu-edit-service-approval-invalidated-on-session-change-test ()
  "An edit plan captured for session-A is rejected when executed under session-B."
  (kargu-test-with-git-repo '(("sample.txt" . "original\n"))
    (let* ((path (expand-file-name "sample.txt" repo))
           (svc (kargu-edit-service-create :service-id "svc-sess" :root repo))
           (_ (kargu-test-mode 'agent))
           (plan (kargu-edit-plan-create
                  :path path
                  :kind :block
                  :proposed-content '(:old-string "original\n" :new-string "updated\n")
                  :session-id "session-alpha")))
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-session-context)
                     (lambda () (kargu-session--create :id-value "session-beta"))))
            (let ((result (kargu-diff-submit-plan svc plan)))
              (should (kargu-err-p result))
              (should (eq (kargu-result-err-code result) :session-conflict))
              (with-temp-buffer
                (insert-file-contents path)
                (should (equal (buffer-string) "original\n")))))
        (kargu-edit-service-close svc)))))

(ert-deftest kargu-edit-service-approval-invalidated-on-doc-revision-change-test ()
  "An edit plan captured with revision R is rejected if the document changes before apply."
  (kargu-test-with-git-repo '(("sample.txt" . "version 1\n"))
    (let* ((path (expand-file-name "sample.txt" repo))
           (svc (kargu-edit-service-create :service-id "svc-rev" :root repo))
           (_ (kargu-test-mode 'agent))
           (plan (kargu-edit-plan-create
                  :path path
                  :kind :block
                  :proposed-content '(:old-string "version 1\n" :new-string "version 2\n"))))
      (unwind-protect
          (progn
            ;; External modification before plan is submitted
            (write-region "external edit\n" nil path nil 'silent)
            (let ((result (kargu-diff-submit-plan svc plan)))
              (should (kargu-err-p result))
              (should (eq (kargu-result-err-code result) :conflict))
              ;; External edit is preserved
              (with-temp-buffer
                (insert-file-contents path)
                (should (equal (buffer-string) "external edit\n")))))
        (kargu-edit-service-close svc)))))

(ert-deftest kargu-edit-service-active-close-cleans-own-resources-test ()
  "Service close releases only own review sessions, buffers, timers, and temp dirs."
  (let* ((svc1 (kargu-edit-service-create :service-id "svc-close-1"))
         (svc2 (kargu-edit-service-create :service-id "svc-close-2"))
         (buf1 (generate-new-buffer "*test-svc1-buf*"))
         (buf2 (generate-new-buffer "*test-svc2-buf*"))
         (dir1 (make-temp-file "test-svc1-dir-" t))
         (dir2 (make-temp-file "test-svc2-dir-" t))
         (timer1 (run-at-time 500 nil #'ignore))
         (timer2 (run-at-time 500 nil #'ignore)))
    (unwind-protect
        (progn
          ;; Register resources in respective services
          (kargu-edit-service-register-buffer svc1 buf1)
          (kargu-edit-service-register-temp-dir svc1 dir1)
          (kargu-edit-service-register-timer svc1 timer1)

          (kargu-edit-service-register-buffer svc2 buf2)
          (kargu-edit-service-register-temp-dir svc2 dir2)
          (kargu-edit-service-register-timer svc2 timer2)

          ;; Close svc1
          (kargu-edit-service-close svc1)
          (should (kargu-edit-service-closed-p svc1))

          ;; Verify svc1 resources were cleanly released
          (should-not (buffer-live-p buf1))
          (should-not (file-directory-p dir1))
          (should-not (memq timer1 timer-list))

          ;; Verify svc2 resources remain fully alive and intact
          (should (buffer-live-p buf2))
          (should (file-directory-p dir2))
          (should (memq timer2 timer-list))
          (should-not (kargu-edit-service-closed-p svc2))

          ;; Attempting to submit to closed service fails immediately
          (let ((plan (kargu-edit-plan-create
                       :path (expand-file-name "x.txt" default-directory)
                       :kind :write
                       :proposed-content "text")))
            (let ((res (kargu-diff-submit-plan svc1 plan)))
              (should (kargu-err-p res))
              (should (eq (kargu-result-err-code res) :service-closed)))))
      (kargu-edit-service-close svc2)
      (when (buffer-live-p buf1) (kill-buffer buf1))
      (when (buffer-live-p buf2) (kill-buffer buf2))
      (when (file-directory-p dir1) (delete-directory dir1 t))
      (when (file-directory-p dir2) (delete-directory dir2 t)))))

(ert-deftest kargu-edit-service-staged-git-index-unmodified-test ()
  "Applying edits never touches user staged git index."
  (kargu-test-with-git-repo '(("target.txt" . "original\n") ("staged.txt" . "init\n"))
    (let* ((staged-file (expand-file-name "staged.txt" repo))
           (target-file (expand-file-name "target.txt" repo))
           (svc (kargu-edit-service-create :service-id "svc-git" :root repo))
           (_ (kargu-test-mode 'agent)))
      (unwind-protect
          (progn
            ;; User stages a change in git index
            (write-region "user staged content\n" nil staged-file nil 'silent)
            (call-process "git" nil nil nil "add" "staged.txt")
            (let ((cached-before (with-temp-buffer
                                   (call-process "git" nil t nil "diff" "--cached")
                                   (buffer-string))))
              (should (string-search "user staged content" cached-before))

              ;; Apply edit to target.txt through edit service
              (let ((plan (kargu-edit-plan-create
                           :path target-file
                           :kind :block
                           :proposed-content '(:old-string "original\n" :new-string "modified\n"))))
                (let ((result (kargu-diff-submit-plan svc plan)))
                  (should (kargu-ok-p result))))

              ;; Staged git index must remain 100% identical
              (let ((cached-after (with-temp-buffer
                                    (call-process "git" nil t nil "diff" "--cached")
                                    (buffer-string))))
                (should (equal cached-before cached-after)))))
        (kargu-edit-service-close svc)))))

(ert-deftest kargu-edit-service-dirty-buffer-rejected-test ()
  "An edit plan is rejected when the target file buffer has unsaved changes."
  (kargu-test-with-git-repo '(("buffer.txt" . "clean content\n"))
    (let* ((path (expand-file-name "buffer.txt" repo))
           (svc (kargu-edit-service-create :service-id "svc-dirty" :root repo))
           (buf (find-file-noselect path))
           (_ (kargu-test-mode 'agent)))
      (unwind-protect
          (with-current-buffer buf
            (insert "unsaved edit\n")
            (should (buffer-modified-p))
            (let ((plan (kargu-edit-plan-create
                         :path path
                         :kind :block
                         :proposed-content '(:old-string "clean content\n" :new-string "new\n"))))
              (let ((result (kargu-diff-submit-plan svc plan)))
                (should (kargu-err-p result))
                (should (eq (kargu-result-err-code result) :conflict))
                (should (buffer-modified-p buf)))))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)
        (kargu-edit-service-close svc)))))

(ert-deftest kargu-edit-service-narrowed-buffer-preserved-test ()
  "Buffer narrowing and point are preserved across edit service plan applications."
  (kargu-test-with-git-repo '(("lines.txt" . "line 1\nline 2\nline 3\nline 4\nline 5\n"))
    (let* ((path (expand-file-name "lines.txt" repo))
           (svc (kargu-edit-service-create :service-id "svc-narrow" :root repo))
           (buf (find-file-noselect path))
           (_ (kargu-test-mode 'agent)))
      (unwind-protect
          (with-current-buffer buf
            ;; Narrow to lines 3-4
            (goto-char (point-min))
            (forward-line 2)
            (let ((beg (point)))
              (forward-line 2)
              (narrow-to-region beg (point)))
            (goto-char (point-min))
            (let ((orig-point (point))
                  (orig-min (point-min))
                  (orig-max (point-max))
                  (plan (kargu-edit-plan-create
                         :path path
                         :kind :block
                         :proposed-content '(:old-string "line 1\n" :new-string "line 1 updated\n"))))
              (let ((result (kargu-diff-submit-plan svc plan)))
                (should (kargu-ok-p result))
                ;; Narrowing restriction and point preserved
                (should (= (point) orig-point))
                (should (= (point-min) orig-min))
                (should (= (point-max) orig-max)))))
        (with-current-buffer buf (widen) (set-buffer-modified-p nil))
        (kill-buffer buf)
        (kargu-edit-service-close svc)))))

(ert-deftest kargu-edit-service-crlf-line-endings-preserved-test ()
  "Edit service preserves CRLF line endings on disk."
  (kargu-test-with-git-repo '(("dos.txt" . "first line\r\nsecond line\r\n"))
    (let* ((path (expand-file-name "dos.txt" repo))
           (svc (kargu-edit-service-create :service-id "svc-crlf" :root repo))
           (_ (kargu-test-mode 'agent)))
      (unwind-protect
          (let ((plan (kargu-edit-plan-create
                       :path path
                       :kind :block
                       :proposed-content '(:old-string "first line\n" :new-string "first edited\n"))))
            (let ((result (kargu-diff-submit-plan svc plan)))
              (should (kargu-ok-p result))
              (let ((raw (with-temp-buffer
                           (set-buffer-multibyte nil)
                           (insert-file-contents-literally path)
                           (buffer-string))))
                (should (string-search "\r\n" raw)))))
        (kargu-edit-service-close svc)))))

(ert-deftest kargu-edit-service-unicode-content-test ()
  "Edit service preserves multibyte UTF-8 characters and emoji."
  (kargu-test-with-git-repo '(("unicode.txt" . "başlık: ğüşıöç\ndetay: roket 🚀\n"))
    (let* ((path (expand-file-name "unicode.txt" repo))
           (svc (kargu-edit-service-create :service-id "svc-utf8" :root repo))
           (_ (kargu-test-mode 'agent)))
      (unwind-protect
          (let ((plan (kargu-edit-plan-create
                       :path path
                       :kind :block
                       :proposed-content '(:old-string "detay: roket 🚀\n" :new-string "detay: şahin 🦅\n"))))
            (let ((result (kargu-diff-submit-plan svc plan)))
              (should (kargu-ok-p result))
              (with-temp-buffer
                (insert-file-contents path)
                (should (string-search "başlık: ğüşıöç" (buffer-string)))
                (should (string-search "detay: şahin 🦅" (buffer-string))))))
        (kargu-edit-service-close svc)))))

(ert-deftest kargu-edit-service-unified-outcome-structure-test ()
  "Submit plan produces typed kargu-edit-outcome struct with all required slots."
  (kargu-test-with-git-repo '(("doc.txt" . "before text\n"))
    (let* ((path (expand-file-name "doc.txt" repo))
           (svc (kargu-edit-service-create :service-id "svc-outcome" :root repo))
           (_ (kargu-test-mode 'agent))
           (plan (kargu-edit-plan-create
                  :path path
                  :kind :block
                  :proposed-content '(:old-string "before text\n" :new-string "after text\n"))))
      (unwind-protect
          (let ((result (kargu-diff-submit-plan svc plan)))
            (should (kargu-ok-p result))
            (let ((outcome (kargu-result-value result)))
              (should (kargu-edit-outcome-p outcome))
              (should (eq (kargu-edit-outcome-status outcome) :applied))
              (should (equal (kargu-edit-outcome-path outcome) path))
              (should (kargu-edit-outcome-saved outcome))
              (should (kargu-file-revision-p (kargu-edit-outcome-post-revision outcome)))
              (should (= (kargu-edit-outcome-hunks-applied outcome) 1))
              (should (= (kargu-edit-outcome-hunks-total outcome) 1))
              (should (plist-get (kargu-edit-outcome-write-effects outcome) :saved))))
        (kargu-edit-service-close svc)))))

(provide 'tests/test-edit-service)
;;; test-edit-service.el ends here
