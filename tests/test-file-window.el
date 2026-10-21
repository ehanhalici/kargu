;;; test-file-window.el --- Bounded read and line-window contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Range normalization and bounded reading are one shared service contract.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu/files)
(require 'kargu/files/async)

(ert-deftest kargu-file-window-limit-and-offset-have-consistent-starts-test ()
  "Limit alone and legacy zero/one offsets select exactly the first N lines."
  (kargu-test-with-git-repo '(("lines.txt" . "one\ntwo\nthree\nfour\n"))
                            (dolist (args '((("limit" . 3)) (("offset" . 0) ("limit" . 3))
                                            (("offset" . 1) ("limit" . 3))))
                              (let ((text (kargu-file--execute (cons '("file_path" . "lines.txt") args))))
                                (should (string-search "lines 1-3 of unknown" text))
                                (should (string-search "3 | three" text))
                                (should-not (string-search "4 | four" text))))))

(ert-deftest kargu-file-window-invalid-bounds-cannot-read-anything-test ()
  "Malformed, null and conflicting bounds are rejected before file access."
  (cl-letf (((symbol-function 'kargu-file-read-window)
             (lambda (&rest _) (ert-fail "Invalid bounds reached the reader"))))
    (dolist (entry '(("from_line" . "abc") ("to_line" . "abc")
                     ("from_line" . 0) ("from_line" . -1) ("from_line" . 1.5)
                     ("from_line" . nil) ("to_line" . 0) ("limit" . 0)
                     ("limit" . -2) ("offset" . -1)))
      (should (string-prefix-p "ERROR:" (kargu-file--execute
                                         (list '("file_path" . "any.txt") entry)))))
    (dolist (args '((("from_line" . 3) ("fromLine" . 4))
                    (("from_line" . 3) ("offset" . 1))
                    (("from_line" . 3) ("to_line" . 1))))
      (should (string-prefix-p "ERROR:" (kargu-file--execute
                                         (cons '("file_path" . "any.txt") args)))))))

(ert-deftest kargu-file-window-limit-intersects-end-and-eof-test ()
  "A limit is a maximum, while EOF determines the last actual line."
  (kargu-test-with-git-repo '(("lines.txt" . "one\ntwo\nthree\n") ("empty.txt" . ""))
                            (let ((text (kargu-file--execute '(("file_path" . "lines.txt")
                                                               ("from_line" . 2) ("to_line" . 99) ("limit" . 2)))))
                              (should (string-search "lines 2-3 of 3" text))
                              (should-not (string-search "1 | one" text)))
                            (should (string-search "lines 1-1 of 1" (kargu-file-read "empty.txt")))
                            (should-error (kargu-file-read "empty.txt" 2))
                            (should-error (kargu-file-read "lines.txt" 4))))

(ert-deftest kargu-file-window-small-range-does-not-read-the-full-disk-file-test ()
  "A narrow range reads only the initial bounded prefix, not the whole file."
  (let ((path (expand-file-name "large-read.txt" default-directory)))
    (with-temp-file path (dotimes (_ 100000) (insert "one line of padding\n")))
    (let ((reader (symbol-function 'insert-file-contents)) reads)
      (cl-letf (((symbol-function 'insert-file-contents)
                 (lambda (file &optional visit beg end replace)
                   (push (list beg end) reads)
                   (funcall reader file visit beg end replace))))
        (should (string-search "3 | one line" (kargu-file-read path 1 3)))
        (should (equal reads (list (list 0 kargu-file--read-initial-bytes))))))))

(ert-deftest kargu-file-window-live-read-never-copies-or-splits-the-full-buffer-test ()
  "Unsaved narrowed text is read in place and all editor state is retained."
  (let ((path (expand-file-name "live-read.txt" default-directory)))
    (with-temp-file path (insert "on disk\n"))
    (let ((buffer (find-file-noselect path)))
      (unwind-protect
          (with-current-buffer buffer
            (erase-buffer) (insert "α😀\nsecond\nthird\n")
            (narrow-to-region 4 10) (goto-char 6) (set-mark 8)
            (let ((limits (list (point-min) (point-max) (point) (mark))) text)
              (cl-letf (((symbol-function 'buffer-string) (lambda () (ert-fail "Whole buffer copied")))
                        ((symbol-function 'split-string) (lambda (&rest _) (ert-fail "Full line list allocated"))))
                (setq text (kargu-file-read path 1 2)))
              (should (string-search "1 | α😀\n2 | second" text))
              (should (equal limits (list (point-min) (point-max) (point) (mark))))
              (should (buffer-modified-p))))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest kargu-file-window-explicit-long-line-still-obeys-output-budget-test ()
  "An explicit range cannot bypass output limits or materialize a huge line."
  (let ((path (expand-file-name "long-line.txt" default-directory))
        (kargu-diff-read-max-chars 32) (kargu-file-read-max-bytes 1024))
    (with-temp-file path (insert (make-string 100000 ?x) "\n"))
    (let ((text (kargu-file-read path 1 1)))
      (should (string-search "truncated" text))
      (should (< (length text) 250)))
    (should-error (kargu-file-read path 2))))

(ert-deftest kargu-file-window-real-worker-uses-json-and-checks-project-boundaries-test ()
  "The real helper handles Unicode names and refuses outside or missing files."
  (let ((path (expand-file-name "quoted ' 😀.txt" default-directory)))
    (with-temp-file path (insert "α😀\nsecond\nthird\n"))
    (let ((text (kargu-test-await
                 (lambda (done) (kargu-file-read-async path (kargu-file-window-create :limit 2) done)))))
      (should (string-search "1 | α😀\n2 | second" text)))
    (dolist (target '("/etc/passwd" "does-not-exist.txt"))
      (should (string-prefix-p
               "ERROR:" (kargu-test-await
                         (lambda (done) (kargu-file-read-async
                                         target (kargu-file-window-create) done))))))))

(ert-deftest kargu-file-window-disk-worker-start-does-not-read-target-in-editor-test ()
  "Starting native reads delegates target I/O and returns before completion."
  (let ((kargu-async--pending nil) held result task)
    (cl-letf (((symbol-function 'kargu-process-run)
               (lambda (_program _args callback &rest _) (setq held callback) nil))
              ((symbol-function 'insert-file-contents)
               (lambda (&rest _) (ert-fail "Disk read on the editor thread"))))
      (setq task (kargu-file-read-async "worker-only.txt" (kargu-file-window-create)
                                        (lambda (value) (setq result value))))
      (should held) (should-not result)
      (funcall held '(:code 0 :output "{\"status\":\"ok\",\"text\":\"worker snapshot\"}"))
      (should (equal result "worker snapshot"))
      (should-not (kargu-async-pending-p task)))))

(ert-deftest kargu-file-window-new-live-buffer-wins-over-delayed-disk-test ()
  "Opening and editing a source while disk work runs cannot publish stale text."
  (let* ((path (expand-file-name "later-live.txt" default-directory))
         held result buffer)
    (with-temp-file path (insert "old disk text\n"))
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-process-run)
                   (lambda (_p _a callback &rest _) (setq held callback) nil)))
          (kargu-file-read-async path (kargu-file-window-create)
                                 (lambda (value) (setq result value)))
          (setq buffer (find-file-noselect path))
          (with-current-buffer buffer (erase-buffer) (insert "new unsaved text\n"))
          (funcall held '(:code 0 :output "{\"status\":\"ok\",\"text\":\"old disk text\"}"))
          (should (string-search "new unsaved text" result))
          (should-not (string-search "old disk text" result)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest kargu-file-window-worker-owner-replacement-or-cancel-discards-result-test ()
  "Old callbacks cannot publish into a replacement conversation or project."
  (dolist (change '(session root run strict cancel close))
    (let ((origin (generate-new-buffer " *file-read-owner*")) held result task)
      (unwind-protect
          (with-current-buffer origin
            (let ((kargu-permission--override-root (kargu-permission-project-root))
                  (kargu-permission-strict-mode t) (kargu--loop-run nil))
              (cl-letf (((symbol-function 'kargu-process-run)
                         (lambda (_p _a callback &rest _) (setq held callback) nil)))
                (setq task (kargu-file-read-async "pending.txt" (kargu-file-window-create)
                                                  (lambda (value) (setq result value)))))
              (pcase change
                ('session (kargu-session-clear))
                ('root (setq kargu-permission--override-root "/"))
                ('run (setq kargu--loop-run (list :state 'tools)))
                ('strict (setq kargu-permission-strict-mode nil))
                ('cancel (kargu-async-cancel task))
                ('close (kill-buffer origin)))
              (funcall held '(:code 0 :output "{\"status\":\"ok\",\"text\":\"obsolete\"}"))
              (should-not result)
              (should-not (memq task kargu-async--pending))))
        (when task (kargu-async-cancel task))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(ert-deftest kargu-file-window-malformed-or-truncated-worker-output-never-succeeds-test ()
  "Corrupt worker output and budget failures become one error, not an excerpt."
  (dolist (reply '((:code 0 :output "not JSON")
                   (:code 0 :output "{\"status\":\"unknown\",\"text\":\"wrong\"}")
                   (:code 0 :output "{\"status\":\"ok\",\"text\":123}")
                   (:code 0 :output "{}" :truncated t) (:code 1 :output "")))
    (let (held results)
      (cl-letf (((symbol-function 'kargu-process-run)
                 (lambda (_p _a callback &rest _) (setq held callback) nil)))
        (kargu-file-read-async "pending.txt" (kargu-file-window-create)
                               (lambda (value) (push value results))))
      (funcall held reply) (funcall held reply)
      (should (= (length results) 1))
      (should (string-prefix-p "ERROR:" (car results))))))

(ert-deftest kargu-file-window-worker-captures-limits-at-start-test ()
  "Changing settings after a request starts cannot widen its captured limits."
  (let ((kargu-diff-read-max-chars 8) held captured result)
    (cl-letf (((symbol-function 'kargu-process-run)
               (lambda (_p args callback &rest _)
                 (setq held callback captured (json-parse-string
                                               (decode-coding-string (base64-decode-string (car (last args))) 'utf-8-unix)
                                               :object-type 'plist)) nil)))
      (kargu-file-read-async "pending.txt" (kargu-file-window-create :limit 2)
                             (lambda (value) (setq result value))))
    (setq kargu-diff-read-max-chars 999999)
    (should (= (plist-get captured :output-chars) 8))
    (should (= (plist-get captured :to) 2))
    (funcall held '(:code 0 :output "{\"status\":\"ok\",\"text\":\"captured\"}"))
    (should (equal result "captured"))))

(ert-deftest kargu-file-window-owner-close-stops-the-actual-helper-process-test ()
  "Closing a standalone read owner releases its helper without a late callback."
  (let ((origin (generate-new-buffer " *file-helper-owner*"))
        (runner (symbol-function 'kargu-process-run)) process task result settled)
    (unwind-protect
        (progn
          (with-current-buffer origin
            (cl-letf (((symbol-function 'kargu-process-run)
                       (lambda (_p _a callback &rest options)
                         (setq process
                               (apply runner "sleep" '("30")
                                      (lambda (value) (setq settled t) (funcall callback value)) options)))))
              (setq task (kargu-file-read-async "slow.txt" (kargu-file-window-create)
                                                (lambda (value) (setq result value))))))
          (should (process-live-p process))
          (kill-buffer origin)
          (let ((deadline (+ (float-time) 2)))
            (while (and (not settled) (< (float-time) deadline))
              (accept-process-output process 0.02)))
          (should settled)
          (should-not (process-live-p process))
          (should-not result)
          (should-not (memq task kargu-async--pending)))
      (when task (kargu-async-cancel task))
      (when (buffer-live-p origin) (kill-buffer origin)))))

(ert-deftest kargu-file-window-prefix-growth-remains-within-cumulative-budget-test ()
  "Geometric rereads are charged to one total input budget."
  (let ((path (expand-file-name "growing-prefix.txt" default-directory))
        (kargu-file-read-max-bytes 200000)
        (reader (symbol-function 'insert-file-contents)) (requested 0))
    (with-temp-file path (dotimes (_ 20000) (insert "longer source line\n")))
    (cl-letf (((symbol-function 'insert-file-contents)
               (lambda (file &optional visit beg end replace)
                 (cl-incf requested (- end beg))
                 (funcall reader file visit beg end replace))))
      (should (string-search "6000 |" (kargu-file-read path 6000 6001)))
      (should (<= requested kargu-file-read-max-bytes)))))

(ert-deftest kargu-file-window-changing-disk-revision-is-not-published-test ()
  "A concurrent writer invalidates the excerpt rather than returning torn text."
  (let ((path (expand-file-name "racing-read.txt" default-directory))
        (reader (symbol-function 'insert-file-contents)))
    (with-temp-file path (insert "old\n"))
    (cl-letf (((symbol-function 'insert-file-contents)
               (lambda (file &optional visit beg end replace)
                 (prog1 (funcall reader file visit beg end replace)
                   (with-temp-file path (insert "new content after the read\n"))))))
      (should-error (kargu-file-read path 1 1)))))

(ert-deftest kargu-file-window-decoded-prefix-exhaustion-is-not-eof-test ()
  "A character scan cap cannot masquerade as a complete live file."
  (let ((path (expand-file-name "bounded-live.txt" default-directory))
        (kargu-file-read-max-scan-chars 12))
    (with-temp-file path (insert "first\nsecond\nthird\n"))
    (let ((buffer (find-file-noselect path)))
      (unwind-protect
          (progn
            (let ((text (kargu-file-read path)))
              (should (string-search "of unknown, truncated" text)))
            (should-error (kargu-file-read path 4)))
        (kill-buffer buffer)))))

(ert-deftest kargu-file-window-worker-spawn-failure-cleans-owner-resources-test ()
  "A synchronous spawn error is delivered once and leaves no owner hook."
  (with-temp-buffer
    (let ((hooks kill-buffer-hook) results task)
      (cl-letf (((symbol-function 'kargu-process-run)
                 (lambda (_p _a callback &rest _)
                   (funcall callback '(:code 127 :output "" :stderr "missing helper")) nil)))
        (setq task (kargu-file-read-async "pending.txt" (kargu-file-window-create)
                                          (lambda (value) (push value results)))))
      (should (= (length results) 1))
      (should (string-prefix-p "ERROR:" (car results)))
      (should (equal hooks kill-buffer-hook))
      (should-not (memq task kargu-async--pending)))))

(provide 'tests/test-file-window)
;;; test-file-window.el ends here
