;;; tests/test-patch.el --- ERT unit tests for apply_patch tool -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the multi-file unified apply_patch tool, parsing,
;; file creation, updating, deletion, and mode gating.

;;; Code:

(require 'ert)
(require 'kargu/constants)
(require 'kargu/core)
(require 'kargu/permission)
(require 'kargu/tools/diff)

(ert-deftest kargu-patch-add-and-delete-file-test ()
  "Test that `apply_patch' adds a new file and can delete a file."
  (let* ((tmp-dir (make-temp-file "kargu-patch-test" t))
         (kargu-permission--override-root tmp-dir)
         (kargu-diff-review-mode 'auto)
         (kargu-active-mode 'agent)
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
         (kargu-active-mode 'agent)
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
  (let ((kargu-active-mode 'ask))
    (should (string-match-p "ERROR: apply_patch is disabled in ask mode"
                            (kargu-diff--apply-patch-tool '((patch . "*** Begin Patch\n*** End Patch"))))))
  (let ((kargu-active-mode 'plan))
    (should (string-match-p "ERROR: apply_patch is disabled in plan mode"
                            (kargu-diff--apply-patch-tool '((patch . "*** Begin Patch\n*** End Patch"))))))
  (let ((kargu-active-mode 'debug))
    (should (string-match-p "ERROR: apply_patch is disabled in debug mode"
                            (kargu-diff--apply-patch-tool '((patch . "*** Begin Patch\n*** End Patch")))))))

(provide 'tests/test-patch)

;;; test-patch.el ends here
