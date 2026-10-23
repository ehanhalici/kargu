;;; tests/test-patch.el --- ERT unit tests for apply_patch tool -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the multi-file unified apply_patch tool, parsing,
;; file creation, updating, deletion, and mode gating.

;;; Code:

(require 'tests/test-helpers)
(require 'ert)
(require 'kargu/contract/constants)
(require 'kargu/core)
(require 'kargu/permission)
(require 'kargu/tools/diff)

(ert-deftest kargu-patch-stopped-owner-cannot-stage-later-files-test ()
  "Cancellation during an earlier proposal prevents later file side effects."
  (kargu-test-with-git-repo '(("a.txt" . "a\n") ("b.txt" . "b\n"))
    (let ((kargu--loop-run (list :state 'tools)) (staged 0))
      (cl-letf (((symbol-function 'kargu-diff-apply-proposal)
                 (lambda (file _text &optional callback)
                   (cl-incf staged)
                   (setq kargu--loop-run nil)
                   (funcall callback (list :status :applied-full :file file)))))
        (let ((result (kargu-diff-apply-patch
                       "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+new a\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-b\n+new b\n")))
          (should (= staged 1))
          (should (string-prefix-p "Patch NOT fully applied" result)))))))

(ert-deftest kargu-patch-waits-for-all-review-outcomes-test ()
  "Blocking and async patches deliver once, after every human decision."
  (dolist (mode '(blocking async))
    (kargu-test-with-git-repo '(("a.txt" . "a\n") ("b.txt" . "b\n"))
      (let ((kargu-diff-review-mode mode) held results)
        (kargu-test-mode 'agent)
        (cl-letf (((symbol-function 'kargu-diff--apply-interactive)
                   (lambda (path _buffer _original _new _exists callback)
                     (push (cons path callback) held)
                     (list :status :staged :file path))))
          (kargu-diff--apply-patch-tool
           '(("patch" . "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+new a\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-b\n+new b\n"))
           (lambda (text) (push text results)))
          (let ((deadline (+ (float-time) 3.0)))
            (while (and (< (length held) 2) (< (float-time) deadline))
              (accept-process-output nil 0.01)))
          (should-not results)
          (should (= (length held) 2))
          (dolist (path '("a.txt" "b.txt"))
            (with-temp-buffer
              (insert-file-contents (expand-file-name path repo))
              (should (equal (buffer-string) (concat (substring path 0 1) "\n")))))
          (funcall (cdar held) (list :status :rejected :file (caar held)))
          (should-not results)
          (funcall (cdadr held) (list :status :applied-partial :file (caadr held)))
          (should (= (length results) 1))
          (should (string-prefix-p "Patch NOT fully applied" (car results)))
          (should (string-search "REJECTED" (car results)))
          (should (string-search "APPLIED PARTIALLY" (car results)))
          (funcall (cdar held) (list :status :applied-full :file (caar held)))
          (should (= (length results) 1)))))))

(ert-deftest kargu-patch-synchronous-review-pending-is-not-success-test ()
  "Direct callers see STAGED and file failures never become full success."
  (kargu-test-with-git-repo '(("a.txt" . "a\n"))
    (let ((patch "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+b\n"))
      (cl-letf (((symbol-function 'kargu-diff-apply-proposal)
                 (lambda (path _content &optional _callback)
                   (list :status :staged :file path))))
        (should (string-prefix-p "STAGED:" (kargu-diff-apply-patch patch))))
      (cl-letf (((symbol-function 'kargu-diff-apply-proposal)
                 (lambda (&rest _) (error "Disk unavailable"))))
        (let ((summary (kargu-diff-apply-patch patch)))
          (should (string-prefix-p "Patch NOT fully applied" summary))
          (should (string-search "Disk unavailable" summary)))))))

(ert-deftest kargu-patch-rejects-unsupported-directives-before-writing-test ()
  "Unsupported binary, rename, mode and legacy directives never change files."
  (kargu-test-with-git-repo '(("original.txt" . "old\n"))
    (dolist (directive '("*** Move to: moved.txt"
                         "*** End of File"
                         "*** Begin Patch"
                         "GIT binary patch"
                         "Binary files a/original.txt and b/original.txt differ"
                         "rename from original.txt"
                         "rename to moved.txt"
                         "old mode 100644"
                         "new mode 100755"
                         "new file mode 100755"))
      (should-error
       (kargu-diff-apply-patch
        (format "--- /dev/null\n+++ b/created.txt\n@@ -0,0 +1 @@\n+created\n%s\n--- a/original.txt\n+++ b/original.txt\n@@ -1 +1 @@\n-old\n+new\n"
                directive)))
      (should-not (file-exists-p (expand-file-name "created.txt" repo)))
      (with-temp-buffer
        (insert-file-contents (expand-file-name "original.txt" repo))
        (should (equal (buffer-string) "old\n"))))))

(ert-deftest kargu-patch-add-and-delete-file-test ()
  "Test that `apply_patch' adds a new file and can delete a file."
  (let* ((tmp-dir (make-temp-file "kargu-patch-test" t))
         (kargu-permission--override-root tmp-dir)
         (kargu-diff-review-mode 'auto)
         (_ (kargu-test-mode 'agent))
         (new-file-rel "new_module.el")
         (patch-text
          (concat "--- /dev/null\n"
                  "+++ b/" new-file-rel "\n"
                  "@@ -0,0 +1,3 @@\n"
                  "+;;; new_module.el --- Test module\n"
                  "+(defun test-patch-fn () t)\n"
                  "+(provide 'new_module)\n")))
    (unwind-protect
        (progn
          ;; 1. Apply add patch (also works in non-Git directory tmp-dir)
          (let ((result (kargu-diff-apply-patch patch-text))
                (abs-path (expand-file-name new-file-rel tmp-dir)))
            (should (stringp result))
            (should (file-exists-p abs-path))
            (with-temp-buffer
              (insert-file-contents abs-path)
              (should (string-match-p "test-patch-fn" (buffer-string)))))
          ;; 2. Apply delete patch
          (let ((del-patch
                 (concat "--- a/" new-file-rel "\n"
                         "+++ /dev/null\n"
                         "@@ -1,3 +0,0 @@\n"
                         "-;;; new_module.el --- Test module\n"
                         "-(defun test-patch-fn () t)\n"
                         "-(provide 'new_module)\n")))
            (kargu-diff-apply-patch del-patch)
            (let ((abs-path (expand-file-name new-file-rel tmp-dir)))
              (should-not (file-exists-p abs-path)))))
      (delete-directory tmp-dir t))))

(ert-deftest kargu-patch-update-file-test ()
  "Test that `apply_patch' updates an existing file with hunks."
  (let* ((tmp-dir (make-temp-file "kargu-patch-update" t))
         (kargu-permission--override-root tmp-dir)
         (kargu-diff-review-mode 'auto)
         (_ (kargu-test-mode 'agent))
         (file-rel "main.py")
         (abs-file (expand-file-name file-rel tmp-dir))
         (initial-content "def hello():\n    print(\"Hello world\")\n")
         (patch-text
          (concat "--- a/" file-rel "\n"
                  "+++ b/" file-rel "\n"
                  "@@ -1,2 +1,2 @@\n"
                  " def hello():\n"
                  "-    print(\"Hello world\")\n"
                  "+    print(\"Hello, agentic world!\")\n")))
    (unwind-protect
        (progn
          (with-temp-file abs-file
            (insert initial-content))
          (let ((result (kargu-diff-apply-patch patch-text)))
            (should (stringp result))
            (with-temp-buffer
              (insert-file-contents abs-file)
              (should (string-match-p "Hello, agentic world!" (buffer-string)))
              (should-not (string-match-p "Hello world\"" (buffer-string))))))
      (delete-directory tmp-dir t))))

(ert-deftest kargu-patch-mode-safety-test ()
  "Test that `apply_patch' is blocked in non-agent modes."
  (let ((_ (kargu-test-mode 'ask)))
    (should (string-match-p "ERROR: apply_patch is disabled in ask mode"
                            (kargu-diff--apply-patch-tool '((patch . "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"))))))
  (let ((_ (kargu-test-mode 'plan)))
    (should (string-match-p "ERROR: apply_patch is disabled in plan mode"
                            (kargu-diff--apply-patch-tool '((patch . "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"))))))
  (let ((_ (kargu-test-mode 'debug)))
    (should (string-match-p "ERROR: apply_patch is disabled in debug mode"
                            (kargu-diff--apply-patch-tool '((patch . "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n")))))))

(ert-deftest kargu-patch-multi-hunk-update-test ()
  "Test that `apply_patch' correctly applies multiple hunks separated by @@."
  (let* ((tmp-dir (make-temp-file "kargu-patch-multihunk" t))
         (kargu-permission--override-root tmp-dir)
         (kargu-diff-review-mode 'auto)
         (_ (kargu-test-mode 'agent))
         (file-rel "multi.txt")
         (abs-file (expand-file-name file-rel tmp-dir))
         (initial-content "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\n")
         (patch-text
          (concat "--- a/" file-rel "\n"
                  "+++ b/" file-rel "\n"
                  "@@ -1,3 +1,3 @@\n"
                  " line 1\n"
                  "-line 2\n"
                  "+line two\n"
                  " line 3\n"
                  "@@ -8,3 +8,3 @@\n"
                  " line 8\n"
                  "-line 9\n"
                  "+line nine\n"
                  " line 10\n")))
    (unwind-protect
        (progn
          (with-temp-file abs-file
            (insert initial-content))
          (let ((result (kargu-diff-apply-patch patch-text)))
            (should (stringp result))
            (with-temp-buffer
              (insert-file-contents abs-file)
              (let ((text (buffer-string)))
                (should (string-match-p "line two" text))
                (should-not (string-match-p "line 2" text))
                (should (string-match-p "line 5" text))
                (should (string-match-p "line nine" text))
                (should-not (string-match-p "line 9" text))))))
      (delete-directory tmp-dir t))))

(ert-deftest kargu-patch-unmatched-hunk-is-an-error-test ()
  "A hunk that matches nothing is not reported as an update."
  (kargu-test-with-git-repo '(("file.el" . "alpha\n"))
    (should-error
     (kargu-diff-apply-patch "--- a/file.el\n+++ b/file.el\n@@ -1 +1 @@\n-missing\n+other\n")
     :type 'error)))

(ert-deftest kargu-patch-ambiguous-hunk-is-an-error-test ()
  "A zero-context hunk that matches twice is not applied by guessing."
  (kargu-test-with-git-repo '(("file.el" . "same\nsame\n"))
    (should-error
     (kargu-diff-apply-patch "--- a/file.el\n+++ b/file.el\n@@ -1 +1 @@\n-same\n+other\n")
     :type 'error)))

(ert-deftest kargu-patch-is-all-or-nothing-and-deletes-for-real-test ()
  "A bad hunk changes no file; a delete removes the file; @@ -1,0 +2,1 @@ inserts after line 1."
  (let* ((tmp (make-temp-file "kargu-patch-atomic" t))
         (kargu-permission--override-root tmp)
         (kargu-diff-review-mode 'auto)
         (_ (kargu-test-mode 'agent))
         (a (expand-file-name "a.txt" tmp))
         (b (expand-file-name "b.txt" tmp)))
    (unwind-protect
        (progn
          (write-region "one\ntwo\nthree\n" nil a)
          (write-region "x\n" nil b)
          ;; Second operation cannot match: the first must not be written either.
          (should-error
           (kargu-diff-apply-patch
            (concat "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-one\n+ONE\n"
                    "--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-nothing like this\n+y\n")))
          (should (equal (with-temp-buffer (insert-file-contents a) (buffer-string))
                         "one\ntwo\nthree\n"))
          ;; @@ -1,0 +2,1 @@ names line 1: a pure addition goes after it.
          (kargu-diff-apply-patch "--- a/a.txt\n+++ b/a.txt\n@@ -1,0 +2,1 @@\n+inserted\n")
          (should (equal (with-temp-buffer (insert-file-contents a) (buffer-string))
                         "one\ninserted\ntwo\nthree\n"))
          ;; Delete removes the file and leaves a rollback snapshot.
          (kargu-diff-apply-patch "--- a/b.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-x\n")
          (should-not (file-exists-p b))
          (should (gethash b kargu-diff--snapshots))
          (kargu-diff-rollback b)
          (should (file-exists-p b))
          ;; Adding an existing file is refused.
          (should-error (kargu-diff-apply-patch "--- /dev/null\n+++ b/a.txt\n@@ -0,0 +1 @@\n+z\n")))
      (delete-directory tmp t))))

(ert-deftest kargu-diff-dirty-and-narrowed-buffer-contract-test ()
  "Dirty buffers are rejected without side effects; narrowed buffers keep view and full snapshot."
  (kargu-test-with-git-repo '(("narrow.el" . "line 1\nline 2\nline 3\n"))
    (let* ((kargu-diff-review-mode 'auto)
           (_ (kargu-test-mode 'agent))
           (path (expand-file-name "narrow.el" repo))
           (buf (find-file-noselect path)))
      (unwind-protect
          (with-current-buffer buf
            ;; 1. Narrowed dirty buffer is rejected without touching buffer or disk.
            (goto-char (point-min))
            (forward-line 1)
            (narrow-to-region (point) (line-end-position))
            (insert "dirty ")
            (should (buffer-modified-p))
            (should-error (kargu-diff-apply-replace path "line 1" "LINE ONE"))
            (should-error (kargu-diff-apply-proposal path "overwritten\n"))
            (should-error (kargu-diff-apply-patch
                           "--- a/narrow.el\n+++ b/narrow.el\n@@ -1 +1 @@\n-line 1\n+LINE ONE\n"))
            ;; Revert dirty edit, keep buffer narrowed to line 2 ("line 2")
            (widen)
            (erase-buffer)
            (insert "line 1\nline 2\nline 3\n")
            (save-buffer)
            (goto-char (point-min))
            (forward-line 1)
            (let ((n-min (point))
                  (n-max (line-end-position)))
              (narrow-to-region n-min n-max)
              (goto-char (+ n-min 2))
              ;; 2. Edit outside narrowed region succeeds, preserves narrowing/point,
              ;; and captures the full-file snapshot.
              (kargu-diff-apply-replace path "line 1" "LINE ONE")
              (should (buffer-narrowed-p))
              (should (= (point-min) n-min))
              (should (equal (save-restriction (widen) (buffer-string))
                             "LINE ONE\nline 2\nline 3\n"))
              ;; 3. Rollback restores the full file while preserving narrowing.
              (kargu-diff-rollback path)
              (should (buffer-narrowed-p))
              (should (equal (save-restriction (widen) (buffer-string))
                             "line 1\nline 2\nline 3\n"))))
        (when (buffer-live-p buf)
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest kargu-diff-save-hook-reconciliation-and-user-edit-rollback-guard-test ()
  "Save-hook transformations are recorded; user edits after commit block rollback overwrite."
  (kargu-test-with-git-repo '(("hooked.txt" . "initial\n"))
    (let* ((kargu-diff-review-mode 'auto)
           (_ (kargu-test-mode 'agent))
           (path (expand-file-name "hooked.txt" repo))
           (buf (find-file-noselect path)))
      (unwind-protect
          (with-current-buffer buf
            (add-hook 'before-save-hook
                      (lambda ()
                        (save-excursion
                          (save-restriction
                            (widen)
                            (goto-char (point-max))
                            (unless (string-suffix-p " [hooked]\n" (buffer-string))
                              (goto-char (1- (point-max)))
                              (insert " [hooked]")))))
                      nil t)
            (let ((outcome (kargu-diff-apply-proposal path "proposed\n")))
              (should (plist-get outcome :hook-transformed))
              (should (equal (plist-get outcome :content) "proposed [hooked]\n"))
              (should (string-search "save hooks modified" (plist-get outcome :message)))
              ;; Rollback works cleanly when untouched since hook-transformed save:
              (kargu-diff-rollback path)
              (should (equal (buffer-string) "initial\n"))
              ;; Apply another agent edit, then simulate user modification on disk:
              (kargu-diff-apply-proposal path "second agent edit\n")
              (write-region "user external edit\n" nil path nil 'silent)
              (revert-buffer t t t)
              ;; Rollback must refuse to clobber user's edit:
              (should-error (kargu-diff-rollback path))
              (should (equal (buffer-string) "user external edit\n"))))
        (when (buffer-live-p buf)
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))))

(ert-deftest kargu-patch-rolls-back-earlier-files-when-last-file-commit-fails-test ()
  "When the final file fails during commit, earlier files committed by the batch roll back."
  (kargu-test-with-git-repo '(("first.txt" . "old 1\n") ("second.txt" . "old 2\n"))
    (let* ((kargu-diff-review-mode 'auto)
           (_ (kargu-test-mode 'agent))
           (first (expand-file-name "first.txt" repo))
           (second (expand-file-name "second.txt" repo))
           (buf2 (find-file-noselect second)))
      (unwind-protect
          (progn
            (with-current-buffer buf2
              (add-hook 'write-contents-functions (lambda () (error "Simulated disk full on second.txt")) nil t))
            (let ((summary (kargu-diff-apply-patch
                            (concat "--- a/first.txt\n+++ b/first.txt\n@@ -1 +1 @@\n-old 1\n+new 1\n"
                                    "--- a/second.txt\n+++ b/second.txt\n@@ -1 +1 @@\n-old 2\n+new 2\n"))))
              (should (string-prefix-p "Patch NOT fully applied" summary))
              (should (string-search "ROLLED BACK" summary))
              (should (string-search "Simulated disk full on second.txt" summary))
              ;; Both files on disk must be at their original pre-patch contents:
              (with-temp-buffer
                (insert-file-contents first)
                (should (equal (buffer-string) "old 1\n")))
              (with-temp-buffer
                (insert-file-contents second)
                (should (equal (buffer-string) "old 2\n")))
              (should-not (gethash first kargu-diff--snapshots))))
        (dolist (p (list first second))
          (when-let* ((b (find-buffer-visiting p)))
            (with-current-buffer b (set-buffer-modified-p nil))
            (kill-buffer b)))))))

(ert-deftest kargu-patch-batch-rollback-preserves-intervening-user-edit-test ()
  "If a hook or user modifies file 1 before file 2 fails, file 1's user edit is preserved."
  (kargu-test-with-git-repo '(("first.txt" . "old 1\n") ("second.txt" . "old 2\n"))
    (let* ((kargu-diff-review-mode 'auto)
           (_ (kargu-test-mode 'agent))
           (first (expand-file-name "first.txt" repo))
           (second (expand-file-name "second.txt" repo))
           (buf2 (find-file-noselect second)))
      (unwind-protect
          (progn
            (with-current-buffer buf2
              (add-hook 'write-contents-functions
                        (lambda ()
                          ;; Simulate external user edit to first.txt before second.txt fails
                          (write-region "user touched first\n" nil first nil 'silent)
                          (when-let* ((b1 (find-buffer-visiting first)))
                            (with-current-buffer b1 (revert-buffer t t t)))
                          (error "Second save failed"))
                        nil t))
            (let ((summary (kargu-diff-apply-patch
                            (concat "--- a/first.txt\n+++ b/first.txt\n@@ -1 +1 @@\n-old 1\n+new 1\n"
                                    "--- a/second.txt\n+++ b/second.txt\n@@ -1 +1 @@\n-old 2\n+new 2\n"))))
              (should (string-prefix-p "Patch NOT fully applied" summary))
              (should (string-search "CONFLICT:" summary))
              (with-temp-buffer
                (insert-file-contents first)
                (should (equal (buffer-string) "user touched first\n")))))
        (dolist (p (list first second))
          (when-let* ((b (find-buffer-visiting p)))
            (with-current-buffer b (set-buffer-modified-p nil))
            (kill-buffer b)))))))

(ert-deftest kargu-patch-preserves-crlf-and-utf8-and-leaves-git-index-clean-test ()
  "Unified Diff preserves CRLF/UTF-8 encoding and never touches the user's git index."
  (kargu-test-with-git-repo '(("crlf.txt" . "merhaba ğüşıöç\r\nikinci satır\r\n"))
    (let* ((kargu-diff-review-mode 'auto)
           (_ (kargu-test-mode 'agent))
           (path (expand-file-name "crlf.txt" repo))
           (index-before (with-temp-buffer
                           (call-process "git" nil t nil "-C" repo "diff" "--cached")
                           (buffer-string))))
      (kargu-diff-apply-patch
       "--- a/crlf.txt\n+++ b/crlf.txt\n@@ -1,2 +1,2 @@\n merhaba ğüşıöç\n-ikinci satır\n+yeni satır 🙂\n")
      (let ((raw-bytes (with-temp-buffer
                         (set-buffer-multibyte nil)
                         (insert-file-contents-literally path)
                         (buffer-string))))
        (should (string-search "\r\n" raw-bytes)))
      (with-temp-buffer
        (insert-file-contents path)
        (should (string-search "yeni satır 🙂" (buffer-string))))
      ;; User's staged git index must remain completely untouched
      (let ((index-after (with-temp-buffer
                           (call-process "git" nil t nil "-C" repo "diff" "--cached")
                           (buffer-string))))
        (should (equal index-before index-after)))
      ;; Rollback restores CRLF and original content
      (kargu-diff-rollback path)
      (with-temp-buffer
        (insert-file-contents path)
        (should (equal (buffer-string) "merhaba ğüşıöç\nikinci satır\n"))))))

(provide 'tests/test-patch)

;;; test-patch.el ends here
