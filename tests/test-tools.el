;;; tests/test-tools.el --- Tests for kargu/tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exercise tool contracts inside isolated scratch projects.

;;; Code:

(require 'tests/test-helpers)
(require 'ert)
(require 'kargu/permission)
(require 'kargu/chat)
(require 'kargu/chat/prompt)
(require 'kargu/tools/diff)
(require 'kargu/tools/search)
(require 'tests/test-bridge)
(require 'kargu/tools/webfetch)
(require 'kargu/tools/bash)
(declare-function rust-mode "rust-mode" ())

(defun kargu-test-temp-file (prefix)
  "Create a temporary file with PREFIX inside the scratch project."
  (make-temp-file (expand-file-name prefix (kargu-permission-project-root))))

(ert-deftest kargu-diff-read-file-counts-logical-lines-test ()
  "A terminal newline ends the last line instead of inventing another line."
  (kargu-test-with-git-repo '(("one.txt" . "one\n") ("two.txt" . "one\n\n"))
    (should (string-search "lines 1-1 of 1" (kargu-test-read-file "one.txt")))
    (should-not (string-search "2 |" (kargu-test-read-file "one.txt")))
    (should (string-search "lines 1-2 of 2" (kargu-test-read-file "two.txt")))
    (should-error (kargu-test-read-file "one.txt" 2 2))))

(ert-deftest kargu-tool-output-buffer-is-owned-and-collision-safe-test ()
  "A buffer name alone grants neither overwrite authority nor read access."
  (let* ((kargu--truncated-counter 81000) (kargu-tool-output-limit 3)
         (fake (generate-new-buffer "*kargu-output-81001*"))
         (other-root (make-temp-file "kargu-output-other-" t)) output)
    (unwind-protect
        (progn
          (with-current-buffer fake (insert "user draft"))
          (should-error (kargu-test-read-file (buffer-name fake)))
          (let ((text (kargu--truncate-for-model "complete tool output")))
            (should (string-match "buffer '\\([^']+\\)'" text))
            (setq output (get-buffer (match-string 1 text))))
          (should-not (eq output fake))
          (should (equal (with-current-buffer fake (buffer-string)) "user draft"))
          (should (with-current-buffer fake (buffer-modified-p)))
          (should (eq (kargu-tool-output-buffer (buffer-name output)) output))
          (should (string-search "complete tool output"
                                 (kargu-test-read-file (buffer-name output))))
          (let ((kargu-permission--override-root other-root))
            (should-not (kargu-tool-output-buffer (buffer-name output)))
            (should-error (kargu-test-read-file (buffer-name output))))
          (with-current-buffer output
            (setq-local buffer-file-name (expand-file-name "converted.txt" other-root)))
          (should-not (kargu-tool-output-buffer (buffer-name output))))
      (dolist (buffer (list fake output))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory other-root))))

(ert-deftest kargu-tool-output-archive-enforces-count-and-size-test ()
  "The oldest generated buffers are evicted to satisfy both quotas."
  (let ((kargu--tool-output-archive nil)
        (kargu-tool-output-archive-max-buffers 2)
        (kargu-tool-output-archive-max-chars 8) buffers)
    (unwind-protect
        (progn
          (dotimes (_ 3)
            (push (get-buffer (kargu--preserve-tool-output "abcd")) buffers))
          (should-not (buffer-live-p (nth 2 buffers)))
          (should (buffer-live-p (nth 1 buffers)))
          (should (buffer-live-p (car buffers)))
          (let ((kargu-tool-output-archive-max-chars 4))
            (push (get-buffer (kargu--preserve-tool-output "x")) buffers)
            (should-not (buffer-live-p (nth 2 buffers)))
            (should-not (buffer-live-p (nth 1 buffers)))))
      (dolist (buffer buffers) (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest kargu-tool-output-archive-protects-user-changes-test ()
  "Edited, saved-as and externally converted archive buffers are not killed."
  (let ((kargu--tool-output-archive nil)
        (kargu-tool-output-archive-max-buffers 1)
        (kargu-tool-output-archive-max-chars 8) buffers)
    (unwind-protect
        (progn
          (dolist (kind '(edited converted reset-modified))
            (let ((buffer (get-buffer (kargu--preserve-tool-output "old"))))
              (push buffer buffers)
              (with-current-buffer buffer
                (pcase kind
                  ('converted (setq-local buffer-file-name "/not-written/output.txt"))
                  (_ (let ((inhibit-read-only t)) (insert "user"))
                     (when (eq kind 'reset-modified) (set-buffer-modified-p nil)))))
              (push (get-buffer (kargu--preserve-tool-output "new")) buffers)
              (should (buffer-live-p buffer)))))
      (dolist (buffer buffers)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest kargu-tool-output-archive-reports-partial-or-disabled-storage-test ()
  "Model notices never claim that a quota-cut archive contains the full result."
  (let ((kargu--tool-output-archive nil)
        (kargu-tool-output-limit 2)
        (kargu-tool-output-archive-max-buffers 1)
        (kargu-tool-output-archive-max-chars 4) buffer)
    (unwind-protect
        (let ((notice (kargu--truncate-for-model "0123456789")))
          (should (string-search "first 4 of 10 chars" notice))
          (should-not (string-search "Complete output" notice))
          (setq buffer (car kargu--tool-output-archive))
          (should (= (with-current-buffer buffer (buffer-size)) 4))
          (let ((kargu-tool-output-archive-max-chars 0))
            (should (string-search "not archived" (kargu--truncate-for-model "abcdef")))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest kargu-diff-shadow-buffers-never-clobber-existing-content-test ()
  "Same-basename proposals never erase each other or user-owned buffers."
  (let* ((path (expand-file-name "src/shared.el" default-directory))
         (existing (generate-new-buffer (kargu-diff--shadow-name path)))
         first second)
    (unwind-protect
        (progn
          (with-current-buffer existing (insert "user draft"))
          (setq first (kargu-diff--make-shadow path "first proposal")
                second (kargu-diff--make-shadow
                        (expand-file-name "tests/shared.el" default-directory)
                        "second proposal"))
          (should (buffer-live-p existing))
          (should (with-current-buffer existing (buffer-modified-p)))
          (should (equal (with-current-buffer existing (buffer-string)) "user draft"))
          (should (equal (with-current-buffer first (buffer-string)) "first proposal"))
          (should (equal (with-current-buffer second (buffer-string)) "second proposal"))
          (should-not (eq first second)))
      (dolist (buffer (list existing first second))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest kargu-diff-read-file-prefers-full-live-buffer-test ()
  "Unsaved text is visible without changing the source buffer's narrowing or point."
  (kargu-test-with-git-repo '(("live.el" . "disk version\n"))
    (let* ((path (expand-file-name "live.el" repo))
           (buffer (find-file-noselect path)))
      (unwind-protect
          (with-current-buffer buffer
            (erase-buffer)
            (insert "first\nunsaved\nlast\n")
            (narrow-to-region 7 14)
            (goto-char 9)
            (let ((text (kargu-test-read-file path)))
              (should (string-search "lines 1-3 of 3" text))
              (should (string-search "1 | first" text))
              (should (string-search "2 | unsaved" text))
              (should (string-search "3 | last" text))
              (should (= (point) 9))
              (should (= (point-min) 7))
              (should (= (point-max) 14))
              (should (buffer-modified-p))))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest kargu-diff-read-file-window-test ()
  "Read numbered windows beyond the default character cap."
  (let ((temp (kargu-test-temp-file "kargu-test-diff")))
    (unwind-protect
        (progn
          ;; Create a file with 2500 lines (>75,000 characters)
          (with-temp-file temp
            (dotimes (i 2500)
              (insert (format "Line %04d: this is a test line with padding text\n" (1+ i)))))
          ;; Request window near the end (lines 2000-2010)
          (let ((out (kargu-test-read-file temp 2000 2010)))
            (should (stringp out))
            (should (string-search "lines 2000-2010 of" out))
            (should (string-search "2000 | Line 2000:" out))
            (should (string-search "2010 | Line 2010:" out))))
      (when (file-exists-p temp)
        (delete-file temp)))))

(ert-deftest kargu-search-glob-subdirectory-test ()
  "The native adapter matches files under subdirectories."
  (kargu-bridge-test--with-core
  (kargu-test-with-git-repo '(("kargu/core.el" . "x") ("kargu/tools/a.el" . "y") ("readme.md" . "z"))
    (let* ((target (expand-file-name "kargu" repo))
           (res (kargu-test-await (lambda (done) (kargu-search-glob done "*.el" target)))))
      (should (stringp res))
      (should-not (string-prefix-p "No files matching" res))
      (should (string-search "core.el" res))
      (should-not (string-search "readme.md" res))))))

(ert-deftest kargu-search-list-files-test ()
  "Directory listing returns GNU ls output without native display tags."
  (kargu-bridge-test--with-core
    (kargu-test-with-git-repo '(("top.el" . "x") ("sub/inner.el" . "y"))
      (let ((out (kargu-test-await (lambda (done) (kargu-search-list-files nil done)))))
        (should (string-search "sub" out))
        (should (string-search "top.el" out))
        (should-not (string-search "[FILE]" out))))))

(ert-deftest kargu-search-tool-recommendations-test ()
  "Search recommendations describe available discovery commands."
  (let ((rec (kargu-search-tool-recommendations)))
    (should (stringp rec))
    (should (or (string-search "fd" rec) (string-search "find" rec)))
    (should (or (string-search "rg" rec) (string-search "grep" rec)))))

(ert-deftest kargu-diff-ediff-plain-horizontal-test ()
  "Ensure ediff configuration defaults to single-frame (plain) and horizontal (side-by-side) split."
  (should (eq kargu-diff-ediff-window-setup-function #'ediff-setup-windows-plain))
  (should (eq kargu-diff-ediff-split-window-function #'split-window-horizontally)))

(ert-deftest kargu-chat-show-same-window-test ()
  "Showing the chat uses the current window without creating splits."
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
  "In blocking review mode the staged proposal answers by callback and the layout returns after ediff quits."
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
              (let* ((final nil)
                     (outcome (kargu-diff-apply-proposal
                               path "line 1\nline 2 modified\n"
                               (lambda (o) (setq final o)))))
                (should (eq (plist-get outcome :status) :staged))
                (let ((deadline (+ (float-time) 3)))
                  (while (and (null final) (< (float-time) deadline))
                    (accept-process-output nil 0.05)))
                (accept-process-output nil 0.1)
                (should final)
                (should (plist-get final :status))
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
        (_ (kargu-test-mode 'agent))
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
        (_ (kargu-test-mode 'agent))
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
        (_ (kargu-test-mode 'agent))
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
         (_ (kargu-test-mode 'agent))
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

(ert-deftest kargu-tool-missing-file-path-pattern-guidance-test ()
  "A pattern in place of a missing file path produces helpful guidance."
  (let ((res (kargu-execute-tool "read_file" '(("pattern" . "my_search_term")))))
    (should (stringp res))
    (should (string-prefix-p "ERROR: missing file_path" res))
    (should (string-search "workspace_grep" res))
    (should (string-search "find_files" res))))

(ert-deftest kargu-dape-breakpoint-set-clear-test ()
  "Setting and clearing breakpoints yields deterministic, rich output."
  (let ((temp (kargu-test-temp-file "kargu-bp-test")))
    (unwind-protect
        (progn
          (with-temp-file temp
            (insert "fn main() {\n    let x = 42;\n    println!(\"{}\", x);\n}\n"))
          ;; Mock dape internals
          (let* ((full-temp (expand-file-name temp))
                 (dape--breakpoints nil)
                 (toggled-calls nil))
            (cl-letf (((symbol-function 'dape-breakpoint-toggle)
                       (lambda ()
                         (let ((cur-line (line-number-at-pos)))
                           (push (list full-temp cur-line) toggled-calls)
                           (if (cl-some (lambda (bp) (and (equal (nth 0 bp) full-temp) (= (nth 1 bp) cur-line)))
                                        dape--breakpoints)
                               (setq dape--breakpoints
                                     (cl-remove-if (lambda (bp) (and (equal (nth 0 bp) full-temp) (= (nth 1 bp) cur-line)))
                                                   dape--breakpoints))
                             (push (list full-temp cur-line) dape--breakpoints)))))
                      ((symbol-function 'dape--breakpoint-file-name)
                       (lambda (bp) (nth 0 bp)))
                      ((symbol-function 'dape--breakpoint-line)
                       (lambda (bp) (nth 1 bp))))
              ;; 1. Set breakpoint on line 2
              (let ((res (kargu-dape-set-breakpoint temp 2)))
                (should (stringp res))
                (should (string-search "[BREAKPOINT SET]" res))
                (should (string-search "let x = 42;" res))
                (should (cl-some (lambda (bp) (and (equal (nth 0 bp) full-temp) (= (nth 1 bp) 2))) dape--breakpoints)))
              ;; 2. Set breakpoint on line 2 again (already set)
              (let ((res2 (kargu-dape-set-breakpoint temp 2)))
                (should (string-search "[BREAKPOINT ALREADY SET]" res2)))
              ;; 3. Clear breakpoint on line 2
              (let ((res3 (kargu-dape-clear-breakpoint temp 2)))
                (should (string-search "[BREAKPOINT REMOVED]" res3))
                (should-not (cl-some (lambda (bp) (and (equal (nth 0 bp) full-temp) (= (nth 1 bp) 2))) dape--breakpoints)))
              ;; 4. Clear breakpoint on line 2 again (none exists)
              (let ((res4 (kargu-dape-clear-breakpoint temp 2)))
                (should (string-search "[BREAKPOINT NOT FOUND]" res4))))))
      (when (file-exists-p temp) (delete-file temp)))))

(ert-deftest kargu-dape-source-snippet-and-line-test ()
  "Source line and snippet helpers return their documented formats."
  (let ((temp (kargu-test-temp-file "kargu-snippet-test")))
    (unwind-protect
        (progn
          (with-temp-file temp
            (insert "line 1\nline 2 target\nline 3\nline 4\n"))
          (should (string= (kargu-dape--source-line temp 2) "line 2 target"))
          (let ((snippet (kargu-dape--source-snippet temp 2 1)))
            (should (stringp snippet))
            (should (string-search "=>    2: line 2 target" snippet))
            (should (string-search "      1: line 1" snippet))
            (should (string-search "      3: line 3" snippet))))
      (when (file-exists-p temp) (delete-file temp)))))

(ert-deftest kargu-dape-target-buffer-and-stop-on-entry-test ()
  "The launch target skips chat buffers and enables stop-on-entry."
  (let ((src-buf (generate-new-buffer "my-code.rs"))
        (chat-buf (generate-new-buffer "*kargu-chat*")))
    (unwind-protect
        (progn
          (with-current-buffer src-buf
            (if (fboundp 'rust-mode)
                (rust-mode)
              (prog-mode))
            (setq-local buffer-file-name
                        (expand-file-name "my-code.rs" (kargu-test-scratch-root))))
          (with-current-buffer chat-buf
            (kargu-chat-mode))
          ;; When kargu-context-buffer is set to src-buf
          (let ((kargu-context-buffer src-buf))
            (should (eq (kargu-dape-source-buffer) src-buf)))
          ;; Test ensure-stop-on-entry
          (let ((cfg1 '(:program "test"))
                (cfg2 '(:program "test" :stopOnEntry nil)))
            (should (equal (plist-get (kargu-dape--ensure-stop-on-entry cfg1) :stopOnEntry) t))
            (should (equal (plist-get (kargu-dape--ensure-stop-on-entry cfg2) :stopOnEntry) t))
            (should (equal cfg1 '(:program "test")))
            (should (equal cfg2 '(:program "test" :stopOnEntry nil)))))
      (when (buffer-live-p src-buf) (kill-buffer src-buf))
      (when (buffer-live-p chat-buf) (kill-buffer chat-buf)))))

(ert-deftest kargu-dape-tools-registration-and-execution-test ()
  "Ensure all new dape debug tools are registered and return clean errors when disconnected."
  ;; Tools should be registered
  (should (member "debug_step_over" (kargu-registered-tools)))
  (should (member "debug_step_in" (kargu-registered-tools)))
  (should (member "debug_step_out" (kargu-registered-tools)))
  (should (member "debug_continue" (kargu-registered-tools)))
  (should (member "debug_pause" (kargu-registered-tools)))
  (should (member "debug_restart" (kargu-registered-tools)))
  (should (member "debug_set_breakpoint" (kargu-registered-tools)))
  (should (member "debug_clear_breakpoint" (kargu-registered-tools)))
  ;; Without a live session, tools return descriptive error strings
  (let ((res-step (kargu-execute-tool "debug_step_over" nil))
        (res-cont (kargu-execute-tool "debug_continue" nil))
        (res-pause (kargu-execute-tool "debug_pause" nil)))
    (should (string-prefix-p "ERROR:" res-step))
    (should (string-prefix-p "ERROR:" res-cont))
    (should (string-prefix-p "ERROR:" res-pause))))

(ert-deftest kargu-loop-debug-mode-tool-visibility-test ()
  "Ensure debug tools are visible in debug mode, while mutating tools are hidden."
  (let ((_ (kargu-test-mode 'debug)))
    (cl-letf (((symbol-function 'kargu-state-mode) (lambda () 'debug))
              ((symbol-function 'kargu-dape--raw-connection) (lambda () 'conn))
              ((symbol-function 'dape--stopped-threads) (lambda (_) '(thread)))
              ((symbol-function 'kargu-dape-inspection-thread) (lambda (_) 'thread)))
      ;; Debug tools should be visible in debug mode
      (should (kargu-loop-tool-visible-p "debug_get_context"))
      (should (kargu-loop-tool-visible-p "debug_step_in"))
      (should (kargu-loop-tool-visible-p "debug_step_over"))
      (should (kargu-loop-tool-visible-p "debug_set_breakpoint"))
      (should (kargu-loop-tool-visible-p "read_file"))
      (should (kargu-loop-tool-visible-p "workspace_grep"))
      ;; File mutating tools must be hidden in debug mode
      (should-not (kargu-loop-tool-visible-p "edit_file"))
      (should-not (kargu-loop-tool-visible-p "write_file"))
      (should-not (kargu-loop-tool-visible-p "bash"))
      ;; Debug tools should not be blocked by gate in debug mode
      (should-not (kargu-loop--gate-tool "debug_step_over"))
      (should-not (kargu-loop--gate-tool "debug_set_breakpoint"))
      ;; Mutating tools should be gated
      (should (stringp (kargu-loop--gate-tool "edit_file"))))))

(ert-deftest kargu-prompt-debug-message-content-test ()
  "Explain the debugger without inventing a paused session or hidden tools."
  (let ((_ (kargu-test-mode 'debug)))
    (cl-letf (((symbol-function 'kargu-state-mode) (lambda () 'debug))
              ((symbol-function 'kargu-dape-tool-guide) (lambda () "debug_set_breakpoint"))
              ((symbol-function 'kargu-dape-context-snapshot) (lambda () "Paused at src/main.rs:10\nStack: main()")))
      (let ((msg (kargu-prompt-debug-message)))
        (should (stringp msg))
        (should (string-search "debug_set_breakpoint" msg))
        (should (string-search "DEBUG mode" msg))
        (should-not (string-search "paused at entry" msg))
        (should-not (string-search "debug_continue" msg))
        (should (string-search "execute sequentially" msg))
        (should (string-search "Observed debugger state:" msg))
        (should (string-search "Paused at src/main.rs:10" msg))))))

(ert-deftest kargu-prompt-tools-guidance-multi-tool-test ()
  "Tool guidance explains sequential multi-tool execution."
  (kargu-test-mode 'agent)
  (let ((block (kargu-prompt--tools-guidance-block)))
    (should (stringp block))
    (should (string-search "MULTIPLE tools in one turn" block))
    (should (string-search "execution is sequential" block))
    (should (string-search "debug_set_breakpoint" block))
    (should-not (string-search "debug_continue" block))))

(ert-deftest kargu-prompt-omits-tools-when-model-cannot-call-them ()
  "A model that cannot call tools is not told about tools in the messages."
  (cl-letf (((symbol-function 'kargu-model-supports-tools-p) (lambda (&optional _id) nil)))
    (should-not (kargu-prompt--tools-guidance-block))
    (should (string-search "cannot call tools" (kargu-prompt-mode-reminder)))
    (should-not (string-search "read_file" (kargu-prompt-mode-reminder)))))

(ert-deftest kargu-chat-agent-without-tools-keeps-the-prompt ()
  "Refusing a tool-less model in agent mode does not leave a running banner."
  (let ((b (get-buffer-create kargu-chat-buffer-name))
        (kargu--loop-run nil))
    (unwind-protect
        (with-current-buffer b
          (kargu-chat-mode)
          (setf (kargu-selection-provider) "nvidia")
          (setf (kargu-selection-model) "nvidia/nemotron-3.5-content-safety:free")
          (kargu-chat--ensure-prompt)
          (cl-letf (((symbol-function 'kargu-state-mode) (lambda () 'agent))
                    ((symbol-function 'kargu-model-supports-tools-p) (lambda (&optional _id) nil))
                    ((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
                    ((symbol-function 'kargu--model) (lambda () "nvidia/nemotron-3.5-content-safety:free")))
            (let ((err (should-error (kargu-chat--submit "look at install.sh") :type 'user-error)))
              (should (string-match-p "does not support tool calling" (error-message-string err))))
            (should (kargu-chat--prompt-live-p))
            (should-not (kargu-loop-running-p))
            (kargu-chat--ensure-running-prompt)
            (should-not (kargu-chat--prompt-live-p))
            (kargu-chat-stop)
            (should (kargu-chat--prompt-live-p))))
      (when (buffer-live-p b) (kill-buffer b)))))

(ert-deftest kargu-chat-send-empty-prompt-debug-mode-test ()
  "Sending an empty debug prompt initiates a debug session."
  (let ((_ (kargu-test-mode 'debug))
        (ensure-called nil)
        (submitted-text nil)
        (b (get-buffer-create kargu-chat-buffer-name)))
    (unwind-protect
        (with-current-buffer b
          (kargu-chat-mode)
          (kargu-chat--ensure-prompt)
          (cl-letf (((symbol-function 'kargu-state-mode) (lambda () 'debug))
                    ((symbol-function 'kargu-dape-ready-p) (lambda () nil))
                    ((symbol-function 'kargu-dape-ensure-session)
                     (lambda (on-ready _on-cancel)
                       (setq ensure-called t)
                       (funcall on-ready)))
                    ((symbol-function 'kargu-chat--preflight) #'ignore)
                    ((symbol-function 'kargu-chat--submit)
                     (lambda (text &rest _options)
                       (setq submitted-text text))))
            (kargu-chat-send)
            (should ensure-called)
            (should (string-search "Debug oturumu başlatıldı" submitted-text))))
      (when (buffer-live-p b) (kill-buffer b)))))

(ert-deftest kargu-chat-refused-send-keeps-typed-input-test ()
  "A send refused by a preflight check leaves the typed prompt in place."
  (let ((b (get-buffer-create kargu-chat-buffer-name))
        (kargu--loop-run nil))
    (unwind-protect
        (with-current-buffer b
          (kargu-chat-mode)
          (setf (kargu-selection-provider) "p")
          (setf (kargu-selection-model) "m")
          (kargu-chat--ensure-prompt)
          (goto-char (point-max))
          (let ((inhibit-read-only t)) (insert "my precious prompt"))
          (cl-letf (((symbol-function 'kargu-state-mode) (lambda () 'agent))
                    ((symbol-function 'kargu-model-supports-tools-p) (lambda (&optional _) nil))
                    ((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
                    ((symbol-function 'kargu--model) (lambda () "m")))
            (should-error (kargu-chat--send-input) :type 'user-error)
            (should (kargu-chat--prompt-live-p))
            (should (string-match-p "my precious prompt" (kargu-chat--input-text)))))
      (when (buffer-live-p b) (kill-buffer b)))))

(ert-deftest kargu-chat-stream-flags-are-buffer-local-test ()
  "Deltas of one chat never flip the stream flags of another chat."
  (let ((a (generate-new-buffer "*kargu-a*"))
        (b (generate-new-buffer "*kargu-b*")))
    (unwind-protect
        (progn
          (dolist (buf (list a b))
            (with-current-buffer buf (kargu-chat-mode) (kargu-chat--ensure-prompt)))
          (let ((kargu--loop-run (list :chat-buffer a)))
            (kargu-chat--on-delta "hello"))
          (should (buffer-local-value 'kargu-chat--streamed-text a))
          (should-not (buffer-local-value 'kargu-chat--streamed-text b))
          (with-current-buffer a
            (should (string-match-p "hello" (buffer-string)))))
      (kill-buffer a) (kill-buffer b))))

(ert-deftest kargu-test-connection-leaves-history-alone-test ()
  "Pending, cancelled and completed pings never modify real conversation turns."
  (dolist (outcome '(success error cancel))
    (let* ((original (list '(("role" . "user") ("content" . "real"))))
           (kargu-session--context
            (kargu-test-session-with-history
             :messages original))
           (stored-original (kargu-history-messages))
           (kargu--loop-run nil) (kargu--busy nil)
           held payload)
      (cl-letf (((symbol-function 'kargu--resolve-direct-api-key) (lambda (&rest _) "test-key"))
                ((symbol-function 'kargu--api-base) (lambda (&rest _) "https://example.invalid"))
                ((symbol-function 'kargu-transport-request)
                 (lambda (_method _url &rest options)
                   (setq held (plist-get options :then)
                         payload (kargu--json-decode (plist-get options :body))) nil)))
        (kargu-test-connection)
        (should (eq (kargu-history-messages) stored-original))
        (should-not (kargu-aget payload "tools"))
        (should (= (length (kargu-aget payload "messages")) 2))
        (should (< (length (kargu--json-encode payload)) 1000))
        (setf (kargu-history-messages) (append original '( (("role" . "user") ("content" . "new")))))
        (let ((new-history (kargu-history-messages)))
          (when (eq outcome 'cancel) (kargu-api-cancel))
          (funcall held (if (eq outcome 'error) "{\"error\":{\"message\":\"Rejected\"}}"
                          "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"pong\"},\"finish_reason\":\"stop\"}]}"))
          (should (eq (kargu-history-messages) new-history)))))))

(ert-deftest kargu-loop-refused-start-leaves-run-state-alone-test ()
  "A start refused by the preflight does not reset the run's diff files."
  (let ((kargu--loop-run nil)
        (reset nil))
    (cl-letf (((symbol-function 'kargu-state-mode) (lambda () 'agent))
              ((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
              ((symbol-function 'kargu-model-supports-tools-p) (lambda (&optional _) nil))
              ((symbol-function 'kargu-diff-reset-run-files) (lambda () (setq reset t))))
      (should-error (kargu-loop-send "hi") :type 'user-error)
      (should-not reset)
      (should-not kargu--loop-run))))

(ert-deftest kargu-bad-tool-arguments-go-back-to-the-model-test ()
  "Text that is not a JSON object is an error result; `{}' is no arguments."
  (kargu-register-tool "kargu_arg_probe" "probe"
                       '(("type" . "object") ("properties" . :json-empty-object))
                       (lambda (_args) "ran"))
  (should (equal (kargu-execute-tool "kargu_arg_probe" "{}") "ran"))
  (should (equal (kargu-execute-tool "kargu_arg_probe" "") "ran"))
  (should (string-prefix-p "ERROR: the arguments of tool kargu_arg_probe"
                           (kargu-execute-tool "kargu_arg_probe" "{not json"))))

(provide 'tests/test-tools)
;;; test-tools.el ends here
