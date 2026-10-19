;;; test-lsp-project-diagnostics.el --- Project diagnostic boundaries -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Native Flymake records and open buffers must share one workspace boundary.

;;; Code:

(require 'ert)
(require 'flymake)
(require 'kargu)
(require 'tests/test-helpers)

(defmacro kargu-lsp-test--with-project-sources (&rest body)
  "Run BODY with local, foreign and symlinked files in isolated buffers."
  (declare (indent 0))
  `(kargu-test-with-git-repo '(("main.el" . "local\n"))
     (let* ((owned (expand-file-name "main.el" repo))
            (foreign (make-temp-file "kargu-lsp-foreign-" nil ".el" "foreign\n"))
            (alias (expand-file-name "alias.el" repo))
            (escape (expand-file-name "escape.el" repo))
            (neighbor (concat (directory-file-name repo) "-neighbor/main.el"))
            (remote "/ssh:unreachable.invalid:/secret.el")
            (paths (list owned foreign alias escape neighbor remote nil))
            (buffers nil))
       (ignore owned foreign alias escape neighbor remote paths)
       (unwind-protect
           (progn
             (make-symbolic-link owned alias)
             (make-symbolic-link foreign escape)
             (dolist (path paths)
               (let ((buffer (generate-new-buffer " *kargu-lsp-source*")))
                 (push buffer buffers)
                 (with-current-buffer buffer
                   (insert "source\n")
                   (setq buffer-file-name path))))
             (setq buffers (nreverse buffers))
             ,@body)
         (dolist (buffer buffers) (kill-buffer buffer))
         (delete-file foreign)))))

(ert-deftest kargu-lsp-project-native-records-are-workspace-owned-test ()
  "Foreign, escaping, remote and unfiled loci never enter a project report."
  (kargu-lsp-test--with-project-sources
    (let ((diags (mapcar (lambda (buffer)
                          (flymake-make-diagnostic buffer 1 2 :error "native")) buffers)))
      (cl-letf (((symbol-function 'flymake--project-diagnostics) (lambda (_) diags))
                ((symbol-function 'project-current) (lambda (&rest _) nil))
                ((symbol-function 'kargu-lsp--diagnostics-data) (lambda (_) nil)))
        (let ((data (kargu-lsp--collect-project-diagnostics repo)))
          (should (= (length data) 2))
          (should (seq-every-p (lambda (diag) (equal (plist-get diag :file) owned)) data)))))))

(ert-deftest kargu-lsp-project-open-buffers-are-checked-before-reading-test ()
  "An escaping buffer must not even be asked for its diagnostic observations."
  (kargu-lsp-test--with-project-sources
    (let ((read-paths nil))
      (cl-letf (((symbol-function 'flymake--project-diagnostics) (lambda (_) nil))
                ((symbol-function 'project-current) (lambda (&rest _) nil))
                ((symbol-function 'kargu-lsp--diagnostics-data)
                 (lambda (path)
                   (push path read-paths)
                   (list (list :line 1 :character 1 :severity 1 :message "open")))))
        (let ((data (kargu-lsp--collect-project-diagnostics (directory-file-name repo))))
          (should (= (length read-paths) 2))
          (should (equal (sort read-paths #'string<) (sort (list owned alias) #'string<)))
          (should (seq-every-p (lambda (diag) (equal (plist-get diag :file) owned)) data)))))))

(ert-deftest kargu-lsp-project-foreign-native-locations-are-not-inspected-test ()
  "A native record's untrusted source must be checked before reading its buffer."
  (kargu-lsp-test--with-project-sources
    (let* ((buffer (cadr buffers))
           (diag (flymake-make-diagnostic buffer 1 2 :error "foreign")))
      (cl-letf (((symbol-function 'flymake--project-diagnostics) (lambda (_) (list diag)))
                ((symbol-function 'project-current) (lambda (&rest _) nil))
                ((symbol-function 'kargu-lsp--diagnostics-data) (lambda (_) nil))
                ((symbol-function 'kargu-lsp--diagnostic-location)
                 (lambda (&rest _) (ert-fail "Foreign diagnostic source inspected"))))
        (should-not (kargu-lsp--collect-project-diagnostics repo))))))

(ert-deftest kargu-lsp-project-remote-root-is-not-contacted-test ()
  "A missing or remote root must not start implicit filesystem access."
  (cl-letf (((symbol-function 'flymake--project-diagnostics)
             (lambda (_) (ert-fail "Invalid project queried")))
            ((symbol-function 'file-truename)
             (lambda (_) (ert-fail "Remote root resolved"))))
    (dolist (root '(nil "" "/ssh:unreachable.invalid:/project/"))
      (should-not (kargu-lsp--collect-project-diagnostics root)))))

(ert-deftest kargu-lsp-project-canonical-root-preserves-editor-state-test ()
  "A symlinked project root preserves source point, narrowing and match data."
  (kargu-lsp-test--with-project-sources
    (let* ((buffer (car buffers))
           (diag (flymake-make-diagnostic buffer 1 2 :error "local"))
           (root-alias (expand-file-name "root-link" repo)))
      (make-symbolic-link repo root-alias)
      (with-current-buffer buffer
        (narrow-to-region 2 5)
        (goto-char 3)
        (string-match "state" "editor state")
        (let ((matches (match-data t)))
          (cl-letf (((symbol-function 'flymake--project-diagnostics) (lambda (_) (list diag)))
                    ((symbol-function 'project-current) (lambda (&rest _) nil))
                    ((symbol-function 'kargu-lsp--diagnostics-data) (lambda (_) nil)))
            (let ((data (kargu-lsp--collect-project-diagnostics root-alias)))
              (should (equal (plist-get (car data) :file) owned))
              (should (= (plist-get (car data) :character) 1))))
          (should (equal matches (match-data t))))
        (should (= (point) 3))
        (should (= (point-min) 2))
        (should (= (point-max) 5))))))

(ert-deftest kargu-lsp-project-path-resolution-failure-is-unavailable-test ()
  "An inaccessible candidate is skipped rather than admitted or opened."
  (kargu-lsp-test--with-project-sources
    (let ((original (symbol-function 'file-truename)))
      (cl-letf (((symbol-function 'file-truename)
                 (lambda (path &rest args)
                   (if (equal path escape) (signal 'file-error '("Unavailable source"))
                     (apply original path args)))))
        (should-not (kargu-lsp--project-diagnostic-path escape repo))
        (should (equal (kargu-lsp--project-diagnostic-path alias repo) owned))))))

(ert-deftest kargu-lsp-project-group-retains-distinct-columns-test ()
  "Two occurrences on one line remain distinct while exact repeats collapse."
  (let* ((first (list :file "/project/main.el" :line 2 :character 1
                      :severity 1 :message "same" :source "eglot"))
         (second (plist-put (copy-sequence first) :character 8))
         (grouped (kargu-lsp--group-diagnostics-by-file (list first second (copy-tree first)))))
    (should (= (car grouped) 2))
    (should (equal (sort (mapcar (lambda (diag) (plist-get diag :character))
                                 (gethash "/project/main.el" (cadr grouped))) #'<) '(1 8)))))

(ert-deftest kargu-lsp-project-group-key-is-not-a-formatted-string-test ()
  "Colons in distinct filenames and messages cannot collide across fields."
  (let* ((first (list :file "/project/file:1" :line 2 :character 1
                      :severity 3 :message "text"))
         (second (list :file "/project/file" :line 1 :character 1
                       :severity 2 :message "3:text"))
         (grouped (kargu-lsp--group-diagnostics-by-file (list first second))))
    (should (= (car grouped) 2))
    (should (= (hash-table-count (cadr grouped)) 2))))

(ert-deftest kargu-lsp-project-report-retains-distinct-columns-test ()
  "The public project report shows each diagnostic location exactly once."
  (kargu-lsp-test--with-project-sources
    (cl-letf (((symbol-function 'kargu-lsp-project-root) (lambda () repo))
              ((symbol-function 'flymake--project-diagnostics) (lambda (_) nil))
              ((symbol-function 'project-current) (lambda (&rest _) nil))
              ((symbol-function 'kargu-lsp--diagnostics-data)
               (lambda (file)
                 (when (equal file owned)
                   (let ((diag (list :line 1 :character 1 :severity 1 :message "same")))
                     (list diag (plist-put (copy-sequence diag) :character 8) (copy-tree diag)))))))
      (let ((report (kargu-lsp-get-project-diagnostics)))
        (should (string-search "2 diagnostics across 1 file" report))
        (should (string-search "L1:C1: same" report))
        (should (string-search "L1:C8: same" report))))))

(provide 'tests/test-lsp-project-diagnostics)
;;; test-lsp-project-diagnostics.el ends here
