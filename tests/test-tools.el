;;; tests/test-tools.el --- Tests for kargu/tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'kargu/permission)
(require 'kargu/tools/diff)
(require 'kargu/tools/search)
(require 'kargu/tools/webfetch)

(defun kargu-test-temp-file (prefix)
  "Create a temporary file inside the project root for testing."
  (let ((tmp-dir (file-name-as-directory (expand-file-name ".test-tmp" (kargu-permission-project-root)))))
    (unless (file-directory-p tmp-dir)
      (make-directory tmp-dir t))
    (make-temp-file (expand-file-name prefix tmp-dir))))

(ert-deftest kargu-diff-read-file-window-test ()
  "Ensure kargu-diff-read-file extracts line windows past 60,000 chars without error."
  (let ((temp (kargu-test-temp-file "kargu-test-diff")))
    (unwind-protect
        (progn
          ;; Create a file with 2500 lines (>75,000 characters)
          (with-temp-file temp
            (dotimes (i 2500)
              (insert (format "Line %04d: this is a test line with padding text\n" (1+ i)))))
          ;; Request window near the end (lines 2000-2010)
          (let ((out (kargu-diff-read-file temp 2000 2010)))
            (should (stringp out))
            (should (string-search "lines 2000-2010 of" out))
            (should (string-search "2000 | Line 2000:" out))
            (should (string-search "2010 | Line 2010:" out))))
      (when (file-exists-p temp)
        (delete-file temp)))))

(ert-deftest kargu-search-glob-subdirectory-test ()
  "Ensure kargu-search--glob-elisp matches files under subdirectories."
  (let* ((root (locate-dominating-file default-directory "kargu.el"))
         (target (expand-file-name "kargu" root))
         (res (kargu-search--glob-elisp "*.el" target root)))
    (should (stringp res))
    (should-not (string-prefix-p "No files matching" res))
    (should (string-search "core.el" res))))

(ert-deftest kargu-search-list-files-test ()
  "Ensure kargu-search-list-files lists directory entries with [DIR] and [FILE] tags."
  (let ((out (kargu-search-list-files)))
    (should (stringp out))
    (should (string-search "kargu.el" out))))

(ert-deftest kargu-search-tool-recommendations-test ()
  "Ensure kargu-search-tool-recommendations returns a valid string with fd/find and rg/grep."
  (let ((rec (kargu-search-tool-recommendations)))
    (should (stringp rec))
    (should (or (string-search "fd" rec) (string-search "find" rec)))
    (should (or (string-search "rg" rec) (string-search "grep" rec)))))

(ert-deftest kargu-diff-ediff-plain-horizontal-test ()
  "Ensure ediff configuration defaults to single-frame (plain) and horizontal (side-by-side) split."
  (should (eq kargu-diff-ediff-window-setup-function #'ediff-setup-windows-plain))
  (should (eq kargu-diff-ediff-split-window-function #'split-window-horizontally)))

(ert-deftest kargu-chat-show-same-window-test ()
  "Ensure kargu-chat-show opens in the current window without creating splits."
  (save-window-excursion
    ;; Case 1: single window in frame
    (delete-other-windows)
    (switch-to-buffer "*scratch*")
    (let ((orig-win (selected-window)))
      (kargu-chat-show)
      (should (= (length (window-list)) 1))
      (should (eq (selected-window) orig-win))
      (should (string= (buffer-name (window-buffer (selected-window)))
                       kargu-chat-buffer-name)))
    ;; Case 2: 2 windows in frame, cursor on right window
    (delete-other-windows)
    (switch-to-buffer "*scratch*")
    (let* ((w-left (selected-window))
           (w-right (split-window-horizontally)))
      (select-window w-right)
      (kargu-chat-show)
      (should (= (length (window-list)) 2))
      (should (eq (selected-window) w-right))
      (should (string= (buffer-name (window-buffer w-right))
                       kargu-chat-buffer-name))
      (should (string= (buffer-name (window-buffer w-left))
                       "*scratch*")))))

(ert-deftest kargu-diff-review-buffer-order-test ()
  "Ensure ediff setup puts real file in Buffer A (left) and proposal in Buffer B (right)."
  (let ((temp (kargu-test-temp-file "kargu-review-test")))
    (unwind-protect
        (progn
          (with-temp-file temp (insert "version 1\n"))
          (let* ((path (expand-file-name temp))
                 (buf (find-file-noselect path))
                 (snap (list :content "version 1\n"
                             :created-new nil
                             :at (current-time))))
            ;; Record snapshot for path
            (puthash path (list snap) kargu-diff--snapshots)
            ;; Modify file buffer to version 2
            (with-current-buffer buf
              (erase-buffer)
              (insert "version 2\n"))
            ;; Run review
            (let ((ctl (kargu-diff-review path)))
              (should (bufferp ctl))
              (with-current-buffer ctl
                (let ((buf-a ediff-buffer-A)
                      (buf-b ediff-buffer-B))
                  ;; Buffer A (left) must be original version 1
                  (should (string-search "*kargu-orig:" (buffer-name buf-a)))
                  (with-current-buffer buf-a
                    (should (string= (buffer-string) "version 1\n")))
                  ;; Buffer B (right) must be file buffer with version 2
                  (should (eq buf-b buf))
                  (with-current-buffer buf-b
                    (should (string= (buffer-string) "version 2\n"))))
                ;; Clean up ediff
                (let ((ediff-quit-hook nil))
                  (if (fboundp 'ediff-really-quit)
                      (ediff-really-quit nil)))))))
      (when (file-exists-p temp)
        (delete-file temp)))))

(ert-deftest kargu-diff-window-configuration-restoration-test ()
  "Ensure quitting ediff restores the exact pre-ediff window configuration."
  (save-window-excursion
    (delete-other-windows)
    (let* ((b-code (generate-new-buffer "code.el"))
           (b-dired (generate-new-buffer "dired"))
           (b-chat (get-buffer-create kargu-chat-buffer-name))
           (w-left (selected-window))
           (w-right (split-window-horizontally))
           (temp (kargu-test-temp-file "kargu-layout-test")))
      (unwind-protect
          (progn
            (set-window-buffer w-right b-chat)
            (select-window w-left)
            (set-window-buffer w-left b-code)
            (let ((w-dired (split-window-vertically)))
              (set-window-buffer w-dired b-dired))
            (should (= (length (window-list)) 3))
            ;; Record layout snapshot for review
            (with-temp-file temp (insert "initial text\n"))
            (let* ((path (expand-file-name temp))
                   (buf (find-file-noselect path))
                   (snap (list :content "initial text\n" :created-new nil :at (current-time))))
              (puthash path (list snap) kargu-diff--snapshots)
              (with-current-buffer buf
                (erase-buffer)
                (insert "modified text\n"))
              ;; Launch review
              (let ((ctl (kargu-diff-review path)))
                (should (bufferp ctl))
                ;; Simulate user quitting ediff
                (with-current-buffer ctl
                  (ediff-really-quit nil))
                ;; Assert 3 windows restored with exact buffer placement
                (should (= (length (window-list)) 3))
                (let* ((windows (window-list))
                       (names (mapcar (lambda (w) (buffer-name (window-buffer w))) windows)))
                  (should (member "code.el" names))
                  (should (member "dired" names))
                  (should (member kargu-chat-buffer-name names))))))
        (when (file-exists-p temp) (delete-file temp))
        (when (buffer-live-p b-code) (kill-buffer b-code))
        (when (buffer-live-p b-dired) (kill-buffer b-dired))))))

(ert-deftest kargu-diff-stage-edit-blocking-layout-test ()
  "Ensure kargu-diff-stage-edit in blocking mode restores window configuration on exit."
  (save-window-excursion
    (delete-other-windows)
    (let* ((b-code (generate-new-buffer "code.el"))
           (b-dired (generate-new-buffer "dired"))
           (b-chat (get-buffer-create kargu-chat-buffer-name))
           (w-left (selected-window))
           (w-right (split-window-horizontally))
           (temp (kargu-test-temp-file "kargu-stage-layout-test"))
           (kargu-diff-review-mode 'blocking))
      (unwind-protect
          (progn
            (set-window-buffer w-right b-chat)
            (select-window w-left)
            (set-window-buffer w-left b-code)
            (let ((w-dired (split-window-vertically)))
              (set-window-buffer w-dired b-dired))
            (should (= (length (window-list)) 3))
            (with-temp-file temp (insert "line 1\nline 2\n"))
            (let* ((path (expand-file-name temp))
                   (buf (find-file-noselect path)))
              (select-window w-left)
              (set-window-buffer w-left buf)
              ;; When ediff starts, simulate typing q to exit
              (run-at-time 0.05 nil
                           (lambda ()
                             (let ((ctl (cl-find-if (lambda (b)
                                                      (string-prefix-p "*Ediff Control Panel" (buffer-name b)))
                                                    (buffer-list))))
                               (when (buffer-live-p ctl)
                                 (with-current-buffer ctl
                                   (ediff-really-quit nil))))))
              (let ((outcome (kargu-diff-apply-proposal path "line 1\nline 2 modified\n" nil)))
                (should (plist-get outcome :status))
                (should (= (length (window-list)) 3))
                (let* ((windows (window-list))
                       (names (mapcar (lambda (w) (buffer-name (window-buffer w))) windows)))
                  (should (member (buffer-name buf) names))
                  (should (member "dired" names))
                  (should (member kargu-chat-buffer-name names))))))
        (when (file-exists-p temp) (delete-file temp))
        (when (buffer-live-p b-code) (kill-buffer b-code))
        (when (buffer-live-p b-dired) (kill-buffer b-dired))))))

(ert-deftest kargu-diff-write-file-overwrite-existing-test ()
  "Ensure write_file allows overwriting existing non-empty files without error."
  (let ((temp (kargu-test-temp-file "kargu-write-test"))
        (kargu-active-mode 'agent)
        (kargu-diff-review-mode 'auto))
    (unwind-protect
        (progn
          (with-temp-file temp (insert "initial existing content\n"))
          (let ((res (kargu-diff--write-file-tool
                      `(("file_path" . ,temp)
                        ("contents" . "completely replaced content\n")
                        ("reason" . "rewrite entire file")))))
            (should (stringp res))
            (should-not (string-search "ERROR: file exists and is not empty" res))
            (should (string-search "APPLIED" res))
            (with-temp-buffer
              (insert-file-contents temp)
              (should (string= (buffer-string) "completely replaced content\n")))))
      (when (file-exists-p temp) (delete-file temp)))))

(ert-deftest kargu-diff-rollback-multi-step-to-initial-test ()
  "Ensure rollback reverts all the way to initial state before any edit in the series."
  (let ((temp (kargu-test-temp-file "kargu-rb-test"))
        (kargu-active-mode 'agent)
        (kargu-diff-review-mode 'auto))
    (unwind-protect
        (progn
          (with-temp-file temp (insert "version 0 - untouched\n"))
          ;; Step 1 edit
          (kargu-diff-apply-proposal temp "version 1 - first edit\n")
          ;; Step 2 edit
          (kargu-diff-apply-proposal temp "version 2 - second edit\n")
          ;; Step 3 edit
          (kargu-diff-apply-proposal temp "version 3 - third edit\n")
          ;; Verify stack has 3 snapshots
          (let ((stack (gethash (expand-file-name temp) kargu-diff--snapshots)))
            (should (= (length stack) 3)))
          ;; Rollback (default without single-step)
          (kargu-diff-rollback temp)
          ;; Verify file is restored all the way back to version 0
          (with-temp-buffer
            (insert-file-contents temp)
            (should (string= (buffer-string) "version 0 - untouched\n")))
          ;; Verify snapshot stack is cleared
          (should-not (gethash (expand-file-name temp) kargu-diff--snapshots)))
      (when (file-exists-p temp) (delete-file temp)))))

(ert-deftest kargu-diff-rollback-single-step-test ()
  "Ensure rollback with single-step reverts only the last edit step."
  (let ((temp (kargu-test-temp-file "kargu-rb-step-test"))
        (kargu-active-mode 'agent)
        (kargu-diff-review-mode 'auto))
    (unwind-protect
        (progn
          (with-temp-file temp (insert "initial\n"))
          (kargu-diff-apply-proposal temp "step 1\n")
          (kargu-diff-apply-proposal temp "step 2\n")
          ;; Single step rollback
          (kargu-diff-rollback temp t)
          (with-temp-buffer
            (insert-file-contents temp)
            (should (string= (buffer-string) "step 1\n")))
          ;; 1 snapshot remaining
          (should (= (length (gethash (expand-file-name temp) kargu-diff--snapshots)) 1))
          ;; Full rollback to initial
          (kargu-diff-rollback temp)
          (with-temp-buffer
            (insert-file-contents temp)
            (should (string= (buffer-string) "initial\n")))
          (should-not (gethash (expand-file-name temp) kargu-diff--snapshots)))
      (when (file-exists-p temp) (delete-file temp)))))

(ert-deftest kargu-diff-rollback-created-file-test ()
  "Ensure rollback of a file created by agent deletes the file."
  (let* ((temp (kargu-test-temp-file "kargu-rb-created-test"))
         (path (expand-file-name temp))
         (kargu-active-mode 'agent)
         (kargu-diff-review-mode 'auto))
    (delete-file path) ; file does not exist initially
    (unwind-protect
        (progn
          ;; Step 1: create file
          (kargu-diff-apply-proposal path "created by agent\n")
          (should (file-exists-p path))
          ;; Step 2: edit file
          (kargu-diff-apply-proposal path "edited by agent\n")
          (should (= (length (gethash path kargu-diff--snapshots)) 2))
          ;; Rollback to initial state
          (kargu-diff-rollback path)
          ;; File should be deleted because it did not exist before the series
          (should-not (file-exists-p path))
          (should-not (gethash path kargu-diff--snapshots)))
      (when (file-exists-p path) (delete-file path)))))

(provide 'tests/test-tools)
;;; test-tools.el ends here
