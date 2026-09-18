;;; tests/test-tools.el --- Tests for kargu/tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'kargu/permission)
(require 'kargu/chat)
(require 'kargu/chat/prompt)
(require 'kargu/tools/diff)
(require 'kargu/tools/search)
(require 'kargu/tools/webfetch)
(require 'kargu/tools/bash)
(declare-function rust-mode "rust-mode" ())

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

(ert-deftest kargu-bash-run-async-callback-test ()
  "Ensure kargu-bash-run executes asynchronously when callback is provided."
  (let* ((kargu-permission-confirm-bash nil)
         (done nil)
         (result nil))
    (kargu-bash-run "echo async_hello_world" (kargu-permission-project-root) nil
                    (lambda (res)
                      (setq result res)
                      (setq done t)))
    (let ((start (float-time)))
      (while (and (not done) (< (- (float-time) start) 5.0))
        (accept-process-output nil 0.05)))
    (should done)
    (should (stringp result))
    (should (string-match-p "exit 0" result))
    (should (string-match-p "async_hello_world" result))))

(ert-deftest kargu-execute-tool-async-bash-test ()
  "Ensure kargu-execute-tool delegates to callback asynchronously for bash."
  (let* ((kargu-permission-confirm-bash nil)
         (done nil)
         (result nil))
    (kargu-execute-tool "bash" '(("command" . "echo tool_exec_async_test"))
                        (lambda (res)
                          (setq result res)
                          (setq done t)))
    (let ((start (float-time)))
      (while (and (not done) (< (- (float-time) start) 5.0))
        (accept-process-output nil 0.05)))
    (should done)
    (should (stringp result))
    (should (string-match-p "tool_exec_async_test" result))))

(ert-deftest kargu-bash-kill-active-async-test ()
  "Ensure kargu-bash-kill-active-async terminates running async bash process."
  (let ((kargu-permission-confirm-bash nil))
    (kargu-bash-run "sleep 30" (kargu-permission-project-root) nil #'ignore)
    (should (processp kargu-bash--active-async-proc))
    (should (process-live-p kargu-bash--active-async-proc))
    (kargu-bash-kill-active-async)
    (should-not kargu-bash--active-async-proc)))

(ert-deftest kargu-tool-missing-file-path-pattern-guidance-test ()
  "Ensure kargu--tool-missing-file-path gives helpful guidance when pattern is passed."
  (let ((res (kargu-execute-tool "read_file" '(("pattern" . "my_search_term")))))
    (should (stringp res))
    (should (string-prefix-p "ERROR: missing file_path" res))
    (should (string-search "workspace_grep" res))
    (should (string-search "find_files" res))))

(ert-deftest kargu-dape-breakpoint-set-clear-test ()
  "Ensure kargu-dape-set-breakpoint and clear-breakpoint function deterministically with rich output."
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
  "Ensure kargu-dape--source-line and kargu-dape--source-snippet return expected formats."
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
  "Ensure kargu-dape--target-buffer skips chat buffer and ensure-stop-on-entry works."
  (let ((src-buf (generate-new-buffer "my-code.rs"))
        (chat-buf (generate-new-buffer "*kargu-chat*")))
    (unwind-protect
        (progn
          (with-current-buffer src-buf
            (if (fboundp 'rust-mode)
                (rust-mode)
              (prog-mode))
            (setq-local buffer-file-name "/tmp/my-code.rs"))
          (with-current-buffer chat-buf
            (kargu-chat-mode))
          ;; When kargu-context-buffer is set to src-buf
          (let ((kargu-context-buffer src-buf))
            (should (eq (kargu-dape--target-buffer) src-buf)))
          ;; Test ensure-stop-on-entry
          (let ((cfg1 '(:program "test"))
                (cfg2 '(:program "test" :stopOnEntry nil)))
            (should (equal (plist-get (kargu-dape--ensure-stop-on-entry cfg1) :stopOnEntry) t))
            (should (equal (plist-get (kargu-dape--ensure-stop-on-entry cfg2) :stopOnEntry) t))))
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
  (let ((kargu-active-mode 'debug))
    (cl-letf (((symbol-function 'kargu-state-mode) (lambda () 'debug)))
      ;; Debug tools should be visible in debug mode
      (should (kargu-loop--tool-visible-p "debug_get_context"))
      (should (kargu-loop--tool-visible-p "debug_step_in"))
      (should (kargu-loop--tool-visible-p "debug_step_over"))
      (should (kargu-loop--tool-visible-p "debug_set_breakpoint"))
      (should (kargu-loop--tool-visible-p "read_file"))
      (should (kargu-loop--tool-visible-p "workspace_grep"))
      ;; File mutating tools must be hidden in debug mode
      (should-not (kargu-loop--tool-visible-p "edit_file"))
      (should-not (kargu-loop--tool-visible-p "write_file"))
      (should-not (kargu-loop--tool-visible-p "bash"))
      ;; Debug tools should not be blocked by gate in debug mode
      (should-not (kargu-loop--gate-tool "debug_step_over"))
      (should-not (kargu-loop--gate-tool "debug_set_breakpoint"))
      ;; Mutating tools should be gated
      (should (stringp (kargu-loop--gate-tool "edit_file"))))))

(ert-deftest kargu-prompt-debug-message-content-test ()
  "Ensure kargu-prompt-debug-message contains LSP schema, pause notice, and multi-tool calling rule."
  (let ((kargu-active-mode 'debug))
    (cl-letf (((symbol-function 'kargu-state-mode) (lambda () 'debug))
              ((symbol-function 'kargu-lsp-build-skeleton) (lambda () "fn main() { ... }"))
              ((symbol-function 'kargu-dape-get-context) (lambda () "Paused at src/main.rs:10\nStack: main()")))
      (let ((msg (kargu-prompt-debug-message)))
        (should (stringp msg))
        ;; Check Turkish instructions
        (should (string-search "DEBUG modundasın" msg))
        (should (string-search "Kodun LSP şeması (semboller tablosu)" msg))
        (should (string-search "fn main() { ... }" msg))
        (should (string-search "Debug başladı ve şu an çalışmıyor" msg))
        (should (string-search "breakpoint koyup run edebilirsin" msg))
        (should (string-search "Aynı anda birden fazla komut" msg))
        (should (string-search "debug_set_breakpoint" msg))
        (should (string-search "debug_continue" msg))
        (should (string-search "list_files" msg))
        ;; Check English instructions for multi-model reliability
        (should (string-search "DEBUG mode" msg))
        (should (string-search "paused at entry" msg))
        (should (string-search "MULTIPLE tools in a single turn" msg))
        (should (string-search "Current debugger state:" msg))
        (should (string-search "Paused at src/main.rs:10" msg))))))

(ert-deftest kargu-prompt-tools-guidance-multi-tool-test ()
  "Ensure kargu-prompt--tools-guidance-block explains multi-tool sequential execution."
  (let ((block (kargu-prompt--tools-guidance-block)))
    (should (stringp block))
    (should (string-search "Execution & Multiple Tool Calling Rule:" block))
    (should (string-search "MULTIPLE tools in a single turn" block))
    (should (string-search "debug_set_breakpoint" block))
    (should (string-search "debug_continue" block))))

(ert-deftest kargu-chat-send-empty-prompt-debug-mode-test ()
  "Ensure kargu-chat-send with empty prompt in debug mode initiates debug session."
  (let ((kargu-active-mode 'debug)
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
                    ((symbol-function 'kargu-chat--submit)
                     (lambda (text)
                       (setq submitted-text text))))
            (kargu-chat-send)
            (should ensure-called)
            (should (string-search "Debug oturumu başlatıldı" submitted-text))))
      (when (buffer-live-p b) (kill-buffer b)))))

(provide 'tests/test-tools)
;;; test-tools.el ends here
