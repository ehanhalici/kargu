;;; test-dape-workspace.el --- Debugger workspace isolation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Offline adapter identities and temporary source trees exercise ownership.

;;; Code:

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)

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

(provide 'tests/test-dape-workspace)
;;; test-dape-workspace.el ends here
