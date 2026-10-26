;;; test-file-window.el --- Native excerpts and live editor capture -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Real Rust disk/range tests live in file_reads.rs.  These tests exercise
;; actual consumers plus owner and live-document interop, without a disk engine.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu/files)
(require 'kargu/files/async)

(defmacro kargu-file-test--with-held (&rest body)
  "Run BODY holding a native reply in HELD and immutable input in CAPTURED."
  (declare (indent 0) (debug t))
  `(let (held captured)
     (cl-letf (((symbol-function 'kargu-bridge-ensure)
                (lambda (callback &rest _) (funcall callback :fixture nil) #'ignore))
               ((symbol-function 'kargu-bridge-read-file)
                (lambda (_connection arguments callback &rest _)
                  (setq captured arguments held callback) nil)))
       (ignore captured)
       ,@body)))

(ert-deftest kargu-file-window-limit-and-offset-have-consistent-starts-test ()
  "Actual native reads preserve inclusive alias and limit contracts."
  (kargu-test-with-git-repo '(("lines.txt" . "one\ntwo\nthree\nfour\n"))
			    (dolist (args '((("limit" . 3)) (("offset" . 0) ("limit" . 3))
					    (("offset" . 1) ("limit" . 3))))
			      (let ((text (kargu-test-await
					   (lambda (done) (kargu-file--execute (cons '("file_path" . "lines.txt") args) done)))))
				(should (string-search "lines 1-3 of unknown" text))
				(should (string-search "3 | three" text))
				(should-not (string-search "4 | four" text))))))

(ert-deftest kargu-file-window-invalid-bounds-cannot-read-anything-test ()
  "Invalid aliases never reach even native startup."
  (cl-letf (((symbol-function 'kargu-file-read-async)
             (lambda (&rest _) (ert-fail "Invalid bounds reached the reader"))))
    (dolist (args '((("from_line" . "abc")) (("to_line" . "abc"))
                    (("from_line" . 0)) (("from_line" . -1)) (("from_line" . 1.5))
                    (("from_line" . nil)) (("to_line" . 0)) (("limit" . 0))
                    (("limit" . -2)) (("offset" . -1))
                    (("from_line" . 3) ("fromLine" . 4))
                    (("from_line" . 3) ("offset" . 1))
                    (("from_line" . 3) ("to_line" . 1))))
      (should (string-prefix-p "ERROR:" (kargu-file--execute (cons '("file_path" . "any.txt") args)))))))

(ert-deftest kargu-file-window-limit-intersects-end-and-eof-test ()
  "EOF is neither a fabricated line nor an unbounded total scan."
  (kargu-test-with-git-repo '(("lines.txt" . "one\ntwo\nthree\n") ("empty.txt" . ""))
			    (let ((text (kargu-test-await
					 (lambda (done) (kargu-file--execute '(("file_path" . "lines.txt")
									       ("from_line" . 2) ("to_line" . 99) ("limit" . 2)) done)))))
			      (should (string-search "lines 2-3 of 3" text))
			      (should-not (string-search "1 | one" text)))
			    (should (string-search "lines 1-1 of 1" (kargu-test-read-file "empty.txt")))
			    (should-error (kargu-test-read-file "empty.txt" 2))
			    (should-error (kargu-test-read-file "lines.txt" 4))))

(ert-deftest kargu-file-window-live-read-never-copies-or-splits-the-full-buffer-test ()
  "Raw bounded live capture preserves narrowing, point, mark and unsaved Unicode."
  (let ((path (expand-file-name "live-read.txt" default-directory)))
    (with-temp-file path (insert "on disk\n"))
    (let ((buffer (find-file-noselect path)))
      (unwind-protect
          (with-current-buffer buffer
            (erase-buffer) (insert "α😀\nsecond\nthird\n")
            (narrow-to-region 4 10) (goto-char 6) (set-mark 8)
            (let ((limits (list (point-min) (point-max) (point) (mark)))
                  (original (symbol-function 'buffer-substring-no-properties)) text copied)
              (cl-letf (((symbol-function 'buffer-substring-no-properties)
                         (lambda (from to) (push (- to from) copied) (funcall original from to))))
                (setq text (kargu-test-read-file path 1 2)))
              (should (string-search "1 | α😀\n2 | second" text))
              (should (equal limits (list (point-min) (point-max) (point) (mark))))
              (should (cl-every (lambda (size) (<= size (1+ kargu-diff-read-max-chars))) copied))
              (should (buffer-modified-p))))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest kargu-file-window-real-native-read-checks-project-boundaries-test ()
  "Real native reads handle quoted Unicode names and reject outside/missing paths."
  (let ((path (expand-file-name "quoted ' 😀.txt" default-directory)))
    (with-temp-file path (insert "α😀\nsecond\nthird\n"))
    (should (string-search "1 | α😀\n2 | second" (kargu-test-read-file path 1 2)))
    (dolist (target '("/etc/passwd" "does-not-exist.txt" "../outside.txt"))
      (should-error (kargu-test-read-file target)))))

(ert-deftest kargu-file-window-start-never-reads-target-in-editor-test ()
  "Starting a disk read returns immediately and delegates I/O to Rust."
  (kargu-file-test--with-held
   (let (result task)
     (cl-letf (((symbol-function 'insert-file-contents)
                (lambda (&rest _) (ert-fail "Target disk read on editor thread")))
               ((symbol-function 'kargu-process-run)
                (lambda (&rest _) (ert-fail "Legacy process fallback"))))
       (setq task (kargu-file-read-async "worker-only.txt" (kargu-file-window-create)
                                         (lambda (value) (setq result value)))))
     (should held) (should-not result)
     (should (equal (gethash "kind" (gethash "source" captured)) "disk"))
     (funcall held (kargu-bridge--object "text" "native snapshot") nil)
     (should (equal result "native snapshot"))
     (should-not (kargu-async-pending-p task)))))

(ert-deftest kargu-file-window-new-live-buffer-wins-over-delayed-disk-test ()
  "A new unsaved buffer triggers a native live-snapshot request, not stale disk text."
  (let ((path (expand-file-name "later-live.txt" default-directory)) result buffer)
    (with-temp-file path (insert "old disk text\n"))
    (unwind-protect
        (kargu-file-test--with-held
         (kargu-file-read-async path (kargu-file-window-create) (lambda (value) (setq result value)))
         (setq buffer (find-file-noselect path))
         (with-current-buffer buffer (erase-buffer) (insert "new unsaved text\n"))
         (funcall held (kargu-bridge--object "text" "old disk text") nil)
         (should-not result)
         (should (equal (gethash "text" (gethash "source" captured)) "new unsaved text\n"))
         (funcall held (kargu-bridge--object "text" "1 | new unsaved text") nil)
         (should (equal result "1 | new unsaved text")))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest kargu-file-window-live-revision-change-rejects-late-result-test ()
  "Editing, replacing or closing a live snapshot cannot publish its old revision."
  (let ((path (expand-file-name "revision.txt" default-directory)) buffer result)
    (with-temp-file path (insert "disk\n"))
    (setq buffer (find-file-noselect path))
    (unwind-protect
        (kargu-file-test--with-held
         (kargu-file-read-async path (kargu-file-window-create) (lambda (value) (setq result value)))
         (with-current-buffer buffer (erase-buffer) (insert "changed\n"))
         (funcall held (kargu-bridge--object "text" "1 | obsolete") nil)
         (should (string-prefix-p "ERROR:" result))
         (should-not (string-search "obsolete" result)))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

(ert-deftest kargu-file-window-owner-replacement-or-cancel-discards-result-test ()
  "Session, root, run, strictness, cancellation and close all revoke publication."
  (dolist (change '(session root run strict cancel close))
    (let ((origin (generate-new-buffer " *file-read-owner*"))
          (kargu-permission-strict-mode t) (kargu--loop-run nil) result task)
      (unwind-protect
          (with-current-buffer origin
            (setq-local kargu-permission--override-root (kargu-permission-project-root))
            (kargu-file-test--with-held
             (setq task (kargu-file-read-async "pending.txt" (kargu-file-window-create)
                                               (lambda (value) (setq result value))))
             (pcase change
               ('session (kargu-session-clear))
               ('root (setq-local kargu-permission--override-root "/"))
               ('run (setq kargu--loop-run (list :state 'tools)))
               ('strict (setq kargu-permission-strict-mode nil))
               ('cancel (kargu-async-cancel task))
               ('close (kill-buffer origin)))
             (funcall held (kargu-bridge--object "text" "obsolete") nil)
             (should-not result)
             (should-not (kargu-async-pending-p task))))
        (when task (kargu-async-cancel task))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(ert-deftest kargu-file-window-malformed-native-output-never-succeeds-test ()
  "Invalid native replies and missing capability yield exactly one error."
  (dolist (reply (list nil (kargu-bridge--object "text" 123)
                       (kargu-bridge--object "outcome" "timeout" "text" "partial")))
    (kargu-file-test--with-held
     (let (results)
       (kargu-file-read-async "pending.txt" (kargu-file-window-create) (lambda (value) (push value results)))
       (funcall held reply nil) (funcall held reply nil)
       (should (= (length results) 1))
       (should (string-prefix-p "ERROR:" (car results)))))))

(ert-deftest kargu-file-window-captures-limits-and-cleans-owner-hooks-test ()
  "Changing settings cannot widen the captured native request or leak owner hooks."
  (with-temp-buffer
    (let ((hooks kill-buffer-hook) (kargu-diff-read-max-chars 8) result)
      (kargu-file-test--with-held
       (kargu-file-read-async "pending.txt" (kargu-file-window-create :limit 2)
                              (lambda (value) (setq result value)))
       (setq kargu-diff-read-max-chars 999999)
       (should (= (gethash "output_chars" captured) 8))
       (should (= (gethash "to" (gethash "window" captured)) 2))
       (funcall held nil (kargu-bridge--fault "unavailable" "Missing native reader"))
       (should (string-prefix-p "ERROR:" result))
       (should (equal hooks kill-buffer-hook))))))

(ert-deftest kargu-file-window-decoded-prefix-exhaustion-is-not-eof-test ()
  "A bounded live prefix cannot masquerade as complete EOF."
  (let ((path (expand-file-name "bounded-live.txt" default-directory))
        (kargu-file-read-max-scan-chars 12))
    (with-temp-file path (insert "first\nsecond\nthird\n"))
    (let ((buffer (find-file-noselect path)))
      (unwind-protect
          (progn
            (should (string-search "of unknown, truncated" (kargu-test-read-file path)))
            (should-error (kargu-test-read-file path 4)))
        (kill-buffer buffer)))))

(ert-deftest kargu-file-window-legacy-disk-and-format-engines-are-removed-test ()
  "Only explicit edit snapshots and Dape's still-live source worker remain."
  (dolist (function '(kargu-file-read kargu-file-read-window kargu-file--disk-excerpt
				      kargu-file--buffer-excerpt kargu-file--describe-excerpt
				      kargu-diff-read-file kargu-file-worker--read))
    (should-not (fboundp function)))
  (should (fboundp 'kargu-file-text))
  (should (string-prefix-p "ERROR:" (kargu-file--execute '(("file_path" . "any.txt"))))))

(ert-deftest kargu-file-window-old-core-never-starts-a-legacy-reader-test ()
  "A missing native capability fails closed, including a direct read call."
  (let ((connection (kargu-bridge--connection-create :state 'ready :capabilities [])) result)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (funcall callback connection nil) #'ignore))
              ((symbol-function 'kargu-process-run) (lambda (&rest _) (ert-fail "Legacy fallback"))))
      (kargu-file-read-async "pending.txt" (kargu-file-window-create) (lambda (text) (setq result text)))
      (should (string-prefix-p "ERROR:" result)))))

(ert-deftest kargu-file-window-read-alias-and-direct-consumer-share-native-results-test ()
  "Read-only mode and legacy alias selection cannot select another disk engine."
  (kargu-test-with-git-repo '(("source" . "native only\n"))
			    (dolist (mode '(ask plan))
			      (kargu-test-mode mode)
			      (dolist (tool '("read_file" "read"))
				(should (string-search "1 | native only"
						       (kargu-test-await (lambda (done)
									   (kargu-execute-tool tool '(("file_path" . "source")) done)))))))
			    (should (string-search "1 | native only" (kargu-test-read-file "source")))))

(provide 'tests/test-file-window)
;;; test-file-window.el ends here
