;;; test-dape-workspace.el --- Debugger workspace isolation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Offline adapter identities and temporary source trees exercise ownership.

;;; Code:

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)
(require 'tests/dape-fixtures)

(defvar dape--breakpoints)

(ert-deftest kargu-dape-workspace-filters-connections-test ()
  "A globally selected foreign adapter cannot enter any local accessor."
  (kargu-test-with-git-repo '(("main.el" . "(message \"test\")\n"))
    (let* ((other (make-temp-file "kargu-dape-other-" t))
           (configs `((local command-cwd ,repo :cwd ".")
                      (foreign command-cwd ,other)
                      (unknown)
                      (relative :cwd ".")
                      (escaped command-cwd ,repo :cwd ,other)))
           (dape--connection-selected 'foreign))
      (unwind-protect
          (cl-letf (((symbol-function 'dape--live-connections)
                     (lambda () '(local foreign unknown relative escaped)))
                    ((symbol-function 'dape--config)
                     (lambda (connection) (cdr (assq connection configs))))
                    ((symbol-function 'dape--parent) (lambda (_) nil))
                    ((symbol-function 'dape--stopped-threads) (lambda (_) '(stopped)))
                    ((symbol-function 'kargu-dape-inspection-thread) (lambda (_) 'stopped)))
            (should (equal (kargu-dape-project-connections) '(local)))
            (should (eq (kargu-dape--raw-connection) 'local))
            (should (eq (kargu-dape--connection) 'local))
            (setq configs (assq-delete-all 'local configs))
            (should-not (kargu-dape-live-p))
            (should-not (kargu-dape-ready-p))
            (should (string-prefix-p "ERROR:" (kargu-dape--connection))))
        (delete-directory other t)))))

(ert-deftest kargu-dape-workspace-child-inherits-known-parent-test ()
  "A child without directory metadata may inherit its owned parent."
  (let ((root (kargu-permission-project-root)))
    (cl-letf (((symbol-function 'dape--live-connections) (lambda () '(child loop)))
              ((symbol-function 'dape--config)
               (lambda (connection) (and (eq connection 'parent) (list 'command-cwd root))))
              ((symbol-function 'dape--parent)
               (lambda (connection) (pcase connection ('child 'parent) ('loop 'loop)))))
      (should (equal (kargu-dape-project-connections) '(child))))))

(ert-deftest kargu-dape-workspace-target-rejects-foreign-context-test ()
  "Neither a foreign context buffer nor a symlink becomes a local target."
  (kargu-test-with-git-repo '(("main.el" . "(message \"test\")\n"))
    (let* ((local (find-file-noselect (expand-file-name "main.el" repo)))
           (foreign (generate-new-buffer " *kargu-dape-foreign*"))
           (other (make-temp-file "kargu-dape-other-" t))
           (kargu-context-buffer foreign))
      (unwind-protect
          (progn
            (with-current-buffer foreign
              (setq buffer-file-name (expand-file-name "foreign.el" other))
              (emacs-lisp-mode))
            (should (eq (kargu-dape--target-buffer) local))
            (setq kargu-context-buffer (buffer-file-name foreign))
            (should (eq (kargu-dape--target-buffer) local))
            (make-symbolic-link other (expand-file-name "external" repo))
            (with-current-buffer foreign
              (setq buffer-file-name (expand-file-name "external/foreign.el" repo)))
            (should (eq (kargu-dape--target-buffer) local))
            (kill-buffer local)
            (should-not (kargu-dape--target-buffer)))
        (when (buffer-live-p local) (kill-buffer local))
        (kill-buffer foreign)
        (delete-directory other t)))))

(ert-deftest kargu-dape-workspace-chain-uses-origin-root-test ()
  "Another current buffer is harmless; reassignment of the origin is not."
  (dolist (reassigned '(nil t))
    (with-temp-buffer
      (setq default-directory "/tmp/kargu-origin/")
      (let ((origin (current-buffer)) held results)
        (kargu-test-with-debug-adapter ('local (list :id 1 :status 'stopped :stackFrames (list (list :id 1))) 1)
          (((symbol-function 'kargu-permission-project-root)
                   (lambda (&optional _) default-directory))
                  ((symbol-function 'kargu-dape--connection) (lambda () 'local))
                  ((symbol-function 'dape--current-stack-frame) (lambda (_) '(:id 1)))
                  ((symbol-function 'dape--evaluate-expression)
                   (lambda (_connection _id _expression _context callback)
                     (setq held callback))))
          (kargu-dape-eval-expression "value" "hover" (lambda (text) (push text results)))
          (when reassigned (setq default-directory "/tmp/kargu-reassigned/"))
          (with-temp-buffer
            (setq default-directory "/tmp/kargu-foreign/")
            (funcall held '(:result "42") nil)
            (funcall held '(:result "duplicate") nil))
          (should (buffer-live-p origin))
          (should (= (length results) 1))
          (if reassigned
              (should (string-prefix-p "ERROR:" (car results)))
            (should (equal (car results) "value => 42"))))))))

(defmacro kargu-dape-test--with-source-paths (&rest body)
  "Run BODY with owned, foreign and symlinked debugger source paths."
  (declare (indent 0))
  `(kargu-test-with-git-repo '(("source.el" . "first\nowned-source\nthird\n"))
     (let ((owned (expand-file-name "source.el" repo))
           (foreign (make-temp-file "kargu-foreign-source-" nil ".el" "foreign-secret\n"))
           (escape (expand-file-name "escaped.el" repo))
           (local-link (expand-file-name "local-link.el" repo)))
       (ignore owned foreign escape local-link)
       (unwind-protect
           (progn
             (make-symbolic-link foreign escape)
             (make-symbolic-link owned local-link)
             ,@body)
         (delete-file foreign)))))

(ert-deftest kargu-dape-workspace-source-rejects-unowned-paths-before-read-test ()
  "Foreign, escaping and remote source paths never reach file content reads."
  (kargu-dape-test--with-source-paths
    (cl-letf (((symbol-function 'insert-file-contents)
               (lambda (&rest _) (ert-fail "Unowned source read")))
              ((symbol-function 'insert-file-contents-literally)
               (lambda (&rest _) (ert-fail "Unowned literal source read"))))
      (dolist (path (list foreign escape (file-relative-name foreign repo)
                         "/ssh:unreachable.invalid:/private.el" nil ""))
        (should-not (kargu-dape--source-line path 1))
        (should-not (kargu-dape--source-snippet path 1 1))))
    (should (equal (kargu-dape--source-line local-link 2) "owned-source"))
    (should (equal (kargu-dape--source-line "source.el" 2) "owned-source"))
    (should (string-search "owned-source" (kargu-dape--source-snippet owned 2 1)))
    (should-not (kargu-dape--source-line owned 0))
    (should-not (kargu-dape--source-snippet owned 2 -1))))

(ert-deftest kargu-dape-workspace-breakpoint-list-is-project-scoped-test ()
  "Global breakpoint objects survive unchanged while foreign entries are hidden."
  (kargu-dape-test--with-source-paths
    (let* ((missing (expand-file-name "deleted.el" repo))
           (breakpoints (list (list owned 2) (list foreign 1) (list escape 1)
                              (list missing 1) (list nil 1)))
           (snapshot (copy-tree breakpoints))
           (dape--breakpoints breakpoints))
      (cl-letf (((symbol-function 'dape--breakpoint-file-name) #'car)
                ((symbol-function 'dape--breakpoint-line) #'cadr))
        (let ((text (kargu-dape-list-breakpoints)))
          (should (string-search "ACTIVE BREAKPOINTS: 2" text))
          (should (string-search "owned-source" text))
          (should (string-search "deleted.el" text))
          (should-not (string-search foreign text))
          (should-not (string-search "escaped.el" text))
          (should-not (string-search "foreign-secret" text)))
        (should (eq dape--breakpoints breakpoints))
        (should (equal dape--breakpoints snapshot))))))

(ert-deftest kargu-dape-workspace-source-reads-preserve-editor-state-test ()
  "Owned source reads preserve caller point, narrowing and match data."
  (kargu-dape-test--with-source-paths
    (with-temp-buffer
      (insert "caller state\n")
      (narrow-to-region 2 9)
      (goto-char 5)
      (string-match "state" "caller state")
      (let ((matches (match-data t)))
        (kargu-dape--source-line owned 2)
        (kargu-dape--source-snippet owned 2 1)
        (should (equal matches (match-data t))))
      (should (= (point) 5))
      (should (= (point-min) 2))
      (should (= (point-max) 9)))))

(ert-deftest kargu-dape-workspace-foreign-frame-keeps-location-only-test ()
  "A library frame may show its location without implicitly reading its source."
  (kargu-dape-test--with-source-paths
    (let ((frame (list :id 1 :name "library" :line 1 :source (list :path foreign)))
          report)
      (kargu-test-with-debug-adapter ('local (list :id 1 :status 'stopped :stackFrames (list frame)) 1)
        (((symbol-function 'kargu-dape-get-context)
                 (lambda (callback &optional _connection selection)
                   (setf (plist-get (kargu-dape-selection-thread selection) :stackFrames) (list frame))
                   (funcall callback "adapter-context")))
                ((symbol-function 'kargu-dape--raw-connection) (lambda () 'local))
                ((symbol-function 'dape--current-thread) (lambda (_) (list :id 1 :stackFrames (vector frame))))
                ((symbol-function 'dape--current-stack-frame) (lambda (_) frame))
                ((symbol-function 'dape--file-name-local) (lambda (_connection path) path)))
        (kargu-dape--format-stopped-report "continue" (lambda (text) (setq report text)))
        (should (string-search foreign report))
        (should (string-search "adapter-context" report))
        (should-not (string-search "Source Context" report))
        (should-not (string-search "foreign-secret" report))))))

(ert-deftest kargu-dape-workspace-source-prefers-unsaved-full-buffer-test ()
  "Quotes use full unsaved text without moving or widening the source view."
  (kargu-dape-test--with-source-paths
    (let ((buffer (find-file-noselect owned)))
      (unwind-protect
          (with-current-buffer buffer
            (erase-buffer)
            (insert "unsaved-first\nunsaved-target\nlast\n")
            (narrow-to-region 2 8)
            (goto-char 4)
            (let ((matches (progn (string-match "saved" "unsaved") (match-data t))))
              (should (equal (kargu-dape--source-line local-link 2) "unsaved-target"))
              (should (string-search "=>    2: unsaved-target"
                                     (kargu-dape--source-snippet owned 2 1)))
              (should (equal matches (match-data t))))
            (should (= (point) 4))
            (should (= (point-min) 2))
            (should (= (point-max) 8))
            (should (buffer-modified-p)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest kargu-dape-workspace-source-budget-rejects-before-disk-read-test ()
  "Oversized disk files never reach even a bounded content read."
  (kargu-dape-test--with-source-paths
    (let ((kargu-dape--source-budget 8))
      (cl-letf (((symbol-function 'insert-file-contents-literally)
                 (lambda (&rest _) (ert-fail "Oversized source read"))))
        (should-not (kargu-dape--source-line owned 1))
        (should-not (kargu-dape--source-snippet owned 1))))))

(ert-deftest kargu-dape-workspace-source-budget-rejects-live-buffer-test ()
  "Narrowing cannot hide an oversized unsaved buffer or trigger disk fallback."
  (kargu-dape-test--with-source-paths
    (let ((buffer (find-file-noselect owned))
          (kargu-dape--source-budget 8))
      (unwind-protect
          (with-current-buffer buffer
            (narrow-to-region 1 3)
            (cl-letf (((symbol-function 'insert-file-contents-literally)
                       (lambda (&rest _) (ert-fail "Live source fell back to disk"))))
              (should-not (kargu-dape--source-line owned 1))
              (should-not (kargu-dape--source-snippet owned 1))))
        (kill-buffer buffer)))))

(ert-deftest kargu-dape-workspace-source-growth-sentinel-test ()
  "A size-check race cannot serve a partial source, including multibyte text."
  (kargu-dape-test--with-source-paths
    (let ((kargu-dape--source-budget 32)
          (original (symbol-function 'insert-file-contents-literally)))
      (cl-letf (((symbol-function 'insert-file-contents-literally)
                 (lambda (path visit begin end &rest rest)
                   (should (= begin 0))
                   (should (= end 33))
                   (with-temp-file path (insert (make-string 40 ?é)))
                   (apply original path visit begin end rest))))
        (should-not (kargu-dape--source-line owned 1))))))

(ert-deftest kargu-dape-workspace-source-line-boundaries-test ()
  "EOF is not a blank line and missing target lines do not yield snippets."
  (kargu-dape-test--with-source-paths
    (should (equal (kargu-dape--source-line owned 3) "third"))
    (dolist (line '(4 5 1000000000))
      (should-not (kargu-dape--source-line owned line))
      (should-not (kargu-dape--source-snippet owned line 4)))))

(ert-deftest kargu-dape-workspace-source-exact-budget-and-decoding-test ()
  "An exact byte budget accepts complete UTF-8 source, including a long line."
  (kargu-dape-test--with-source-paths
    (let* ((text (concat (make-string 64 ?é) "\n"))
           (coding-system-for-write 'utf-8-unix)
           (kargu-dape--source-budget (string-bytes text)))
      (with-temp-file owned (insert text))
      (should (equal (kargu-dape--source-line owned 1) (string-trim text)))
      (should (string-search (string-trim text) (kargu-dape--source-snippet owned 1))))))

(provide 'tests/test-dape-workspace)
;;; test-dape-workspace.el ends here
