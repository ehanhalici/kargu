;;; test-dape-workspace.el --- Debugger workspace isolation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Offline adapter identities and temporary source trees exercise ownership.

;;; Code:

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)

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
                    ((symbol-function 'dape--stopped-threads) (lambda (_) '(stopped))))
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
        (cl-letf (((symbol-function 'kargu-permission-project-root)
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
               (lambda (&rest _) (ert-fail "Unowned source read"))))
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
      (cl-letf (((symbol-function 'kargu-dape-get-context)
                 (lambda (callback &optional _connection) (funcall callback "adapter-context")))
                ((symbol-function 'kargu-dape--raw-connection) (lambda () 'local))
                ((symbol-function 'dape--current-thread) (lambda (_) '(:id 1)))
                ((symbol-function 'dape--current-stack-frame) (lambda (_) frame))
                ((symbol-function 'dape--file-name-local) (lambda (_connection path) path)))
        (kargu-dape--format-stopped-report "continue" (lambda (text) (setq report text)))
        (should (string-search foreign report))
        (should (string-search "adapter-context" report))
        (should-not (string-search "Source Context" report))
        (should-not (string-search "foreign-secret" report))))))

(provide 'tests/test-dape-workspace)
;;; test-dape-workspace.el ends here
