;;; tests/test-patch.el --- ERT unit tests for apply_patch tool -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the multi-file unified apply_patch tool, parsing,
;; file creation, updating, deletion, and mode gating.

;;; Code:

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
                       "*** Begin Patch\n*** Update File: a.txt\n@@\n-a\n+new a\n*** Update File: b.txt\n@@\n-b\n+new b\n*** End Patch")))
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
           '(("patch" . "*** Begin Patch\n*** Update File: a.txt\n@@\n-a\n+new a\n*** Update File: b.txt\n@@\n-b\n+new b\n*** End Patch"))
           (lambda (text) (push text results)))
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
    (let ((patch "*** Begin Patch\n*** Update File: a.txt\n@@\n-a\n+b\n*** End Patch"))
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
  "Unsupported move/EOF directives never silently change patch contents."
  (kargu-test-with-git-repo '(("original.txt" . "old\n"))
    (dolist (directive '("*** Move to: moved.txt" "*** End of File" "*** Unknown"))
      (should-error
       (kargu-diff-apply-patch
        (format "*** Begin Patch\n*** Add File: created.txt\n+created\n*** Update File: original.txt\n%s\n@@\n-old\n+new\n*** End Patch"
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
          (concat "*** Begin Patch\n"
                  "*** Add File: " new-file-rel "\n"
                  "+;;; new_module.el --- Test module\n"
                  "+(defun test-patch-fn () t)\n"
                  "+(provide 'new_module)\n"
                  "*** End Patch\n")))
    (unwind-protect
        (progn
          ;; 1. Apply add patch
          (let ((result (kargu-diff-apply-patch patch-text))
                (abs-path (expand-file-name new-file-rel tmp-dir)))
            (should (stringp result))
            (should (file-exists-p abs-path))
            (with-temp-buffer
              (insert-file-contents abs-path)
              (should (string-match-p "test-patch-fn" (buffer-string)))))
          ;; 2. Apply delete patch
          (let ((del-patch
                 (concat "*** Begin Patch\n"
                         "*** Delete File: " new-file-rel "\n"
                         "*** End Patch\n")))
            (kargu-diff-apply-patch del-patch)
            (let ((abs-path (expand-file-name new-file-rel tmp-dir)))
              (should (or (not (file-exists-p abs-path))
                          (with-temp-buffer
                            (insert-file-contents abs-path)
                            (string-empty-p (buffer-string))))))))
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
          (concat "*** Begin Patch\n"
                  "*** Update File: " file-rel "\n"
                  "@@\n"
                  "-    print(\"Hello world\")\n"
                  "+    print(\"Hello, agentic world!\")\n"
                  "*** End Patch\n")))
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
                            (kargu-diff--apply-patch-tool '((patch . "*** Begin Patch\n*** End Patch"))))))
  (let ((_ (kargu-test-mode 'plan)))
    (should (string-match-p "ERROR: apply_patch is disabled in plan mode"
                            (kargu-diff--apply-patch-tool '((patch . "*** Begin Patch\n*** End Patch"))))))
  (let ((_ (kargu-test-mode 'debug)))
    (should (string-match-p "ERROR: apply_patch is disabled in debug mode"
                            (kargu-diff--apply-patch-tool '((patch . "*** Begin Patch\n*** End Patch")))))))

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
          (concat "*** Begin Patch\n"
                  "*** Update File: " file-rel "\n"
                  "@@\n"
                  " line 1\n"
                  "-line 2\n"
                  "+line two\n"
                  " line 3\n"
                  "@@\n"
                  " line 8\n"
                  "-line 9\n"
                  "+line nine\n"
                  " line 10\n"
                  "*** End Patch\n")))
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
  (should-error
   (kargu-diff--apply-hunk "alpha\n" "missing\n" "other\n" "file.el")
   :type 'error))

(ert-deftest kargu-patch-ambiguous-hunk-is-an-error-test ()
  "A hunk that matches twice is not applied to the first hit."
  (should-error
   (kargu-diff--apply-hunk "same\nsame\n" "same\n" "other\n" "file.el")
   :type 'error))

(provide 'tests/test-patch)

;;; test-patch.el ends here

(ert-deftest kargu-patch-is-all-or-nothing-and-deletes-for-real-test ()
  "A bad hunk changes no file; a delete removes the file; @@ N inserts after line N."
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
            (concat "*** Update File: a.txt\n@@\n-one\n+ONE\n"
                    "*** Update File: b.txt\n@@\n-nothing like this\n+y\n")))
          (should (equal (with-temp-buffer (insert-file-contents a) (buffer-string))
                         "one\ntwo\nthree\n"))
          ;; @@ names a line: a pure addition goes after it.
          (kargu-diff-apply-patch "*** Update File: a.txt\n@@ -1,0 +2,1 @@\n+inserted\n")
          (should (equal (with-temp-buffer (insert-file-contents a) (buffer-string))
                         "one\ninserted\ntwo\nthree\n"))
          ;; Delete removes the file and leaves a rollback snapshot.
          (kargu-diff-apply-patch "*** Delete File: b.txt\n")
          (should-not (file-exists-p b))
          (should (gethash b kargu-diff--snapshots))
          (kargu-diff-rollback b)
          (should (file-exists-p b))
          ;; Adding an existing file is refused.
          (should-error (kargu-diff-apply-patch "*** Add File: a.txt\n+z\n")))
      (delete-directory tmp t))))
