;;; test-dape-startup.el --- Owned debugger approval tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Delayed approvals and probes use temporary sources and fake adapters.

;;; Code:

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)

(defmacro kargu-dape-test--with-startup (&rest body)
  "Run BODY with a captured approval, source, origin and launch results."
  (declare (indent 0))
  `(kargu-test-with-git-repo '(("main.el" . "(message \"test\")\n")
                              ("other.el" . "(message \"other\")\n"))
     (let* ((source (find-file-noselect (expand-file-name "main.el" repo)))
            (origin (generate-new-buffer " *kargu-startup-origin*"))
            (kargu-context-buffer source)
            (kargu-dape-config nil)
            (dape-configs '((demo command "sh" :program "main")))
            (kargu-dape--verified nil)
            (kargu-async--pending nil)
            (kargu--loop-run (list :state 'tools))
            (approval nil) (results nil) (launches nil) (connections nil))
       (ignore approval results launches connections)
       (unwind-protect
           (cl-letf (((symbol-function 'kargu-dape-project-connections)
                      (lambda (&optional _) connections))
                     ((symbol-function 'kargu-permission-request-approval-async)
                      (lambda (_command _root _risks callback)
                        (setq approval callback)))
                     ((symbol-function 'dape)
                      (lambda (config) (push (cons (current-buffer) config) launches))))
             (with-current-buffer origin
               (setq-local kargu--session-id "startup-session")
               (setq-local kargu-permission--override-root repo)
               ,@body))
         (dolist (task (copy-sequence kargu-async--pending))
           (kargu-async-cancel-owner (kargu-async-task-owner task)))
         (dolist (buffer (list source origin))
           (when (buffer-live-p buffer)
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer)))))))

(ert-deftest kargu-dape-startup-approval-keeps-source-and-delivers-once-test ()
  "Another current buffer and duplicate approvals do not redirect startup."
  (kargu-dape-test--with-startup
    (let ((task (kargu-dape-start "demo" (lambda (text) (push text results)))))
      (should approval)
      (should-not launches)
      (should-not kargu-dape-config)
      (with-temp-buffer
        (setq-local kargu-permission--override-root temporary-file-directory)
        (funcall approval t)
        (funcall approval t))
      (should (eq (kargu-async-task-state task) :done))
      (should (= (length results) 1))
      (should (string-search "started" (car results)))
      (should (= (length launches) 1))
      (should (eq (caar launches) source))
      (should (equal (plist-get (cdar launches) 'command) "sh"))
      (should (plist-get (cdar launches) :stopOnEntry))
      (should-not (plist-member (cdar dape-configs) :stopOnEntry))
      (should-not kargu-async--pending))))

(ert-deftest kargu-dape-startup-rejects-obsolete-approval-test ()
  "Changed project, session, source, adapter or connection cannot reuse approval."
  (dolist (change '(root session target edit directory mode selection config environment
                        verification adapter closed-source closed-origin))
    (kargu-dape-test--with-startup
      (let ((task (kargu-dape-start "demo" (lambda (text) (push text results)))))
        (should approval)
        (pcase change
          ('root (setq-local kargu-permission--override-root temporary-file-directory))
          ('session (setq-local kargu--session-id "replacement-session"))
          ('target (with-current-buffer source
                     (setq buffer-file-name (expand-file-name "other.el" repo))))
          ('edit (with-current-buffer source (insert "; changed\n")))
          ('directory (with-current-buffer source (setq default-directory "/tmp/")))
          ('mode (with-current-buffer source (fundamental-mode)))
          ('selection (setq kargu-dape-config 'replacement))
          ('config (setq dape-configs '((demo command "sh" :program "other"))))
          ('environment (with-current-buffer source
                          (setq-local process-environment
                                      (cons "KARGU_STARTUP_TEST=changed" process-environment))))
          ('verification
           (puthash repo (copy-kargu-dape--verification
                          (gethash repo kargu-dape--verified)) kargu-dape--verified))
          ('adapter (setq connections '(replacement)))
          ('closed-source (kill-buffer source))
          ('closed-origin (kill-buffer origin)))
        (with-temp-buffer (funcall approval t) (funcall approval t))
        (should-not launches)
        (should (= (length results) 1))
        (should (string-prefix-p "ERROR:" (car results)))
        (should (eq (kargu-async-task-state task) :done))
        (should-not kargu-async--pending)))))

(ert-deftest kargu-dape-startup-selection-change-rejects-other-source-test ()
  "Selecting another local source cannot silently retarget a pending approval."
  (kargu-dape-test--with-startup
    (kargu-dape-start "demo" (lambda (text) (push text results)))
    (let ((other (find-file-noselect (expand-file-name "other.el" repo))))
      (unwind-protect
          (progn
            (setq kargu-context-buffer other)
            (funcall approval t)
            (should-not launches)
            (should (string-prefix-p "ERROR:" (car results))))
        (kill-buffer other)))))

(ert-deftest kargu-dape-startup-cancelled-owner-discards-approval-test ()
  "Stopping the run releases startup and suppresses a later approval."
  (kargu-dape-test--with-startup
    (let ((task (kargu-dape-start "demo" (lambda (text) (push text results)))))
      (kargu-async-cancel-owner kargu--loop-run)
      (funcall approval t)
      (funcall approval nil)
      (should (eq (kargu-async-task-state task) :cancelled))
      (should-not launches)
      (should-not results)
      (should-not kargu-async--pending))))

(ert-deftest kargu-dape-startup-rejection-delivers-once-test ()
  "A refusal consumes the decision without starting an adapter."
  (kargu-dape-test--with-startup
    (kargu-dape-start "demo" (lambda (text) (push text results)))
    (funcall approval nil)
    (funcall approval t)
    (should-not launches)
    (should (equal results '("ERROR: Debugger startup rejected")))
    (should-not kargu-async--pending)))

(ert-deftest kargu-dape-startup-stale-probe-never-asks-approval-test ()
  "Source or owner changes during dependency verification prevent launch approval."
  (dolist (change '(session edit stopped))
    (kargu-dape-test--with-startup
      (let (probe)
        (setq dape-configs '((demo command "sh" command-args ("-m" "adapter"))))
        (cl-letf (((symbol-function 'kargu-process-run)
                   (lambda (_command _args callback &rest _) (setq probe callback))))
          (kargu-dape-start "demo" (lambda (text) (push text results)))
          (should probe)
          (should-not approval)
          (pcase change
            ('session (setq-local kargu--session-id "new-session"))
            ('edit (with-current-buffer source (insert "; changed\n")))
            ('stopped (kargu-async-cancel-owner kargu--loop-run)))
          (funcall probe '(:code 0))
          (funcall probe '(:code 0))
          (should-not approval)
          (should-not launches)
          (if (eq change 'stopped)
              (should-not results)
            (should (= (length results) 1))
            (should (string-prefix-p "ERROR:" (car results)))))))))

(ert-deftest kargu-dape-startup-requires-workspace-source-test ()
  "Missing source produces one actionable error without an approval or launch."
  (kargu-dape-test--with-startup
    (cl-letf (((symbol-function 'kargu-dape-source-buffer) (lambda (&optional _) nil)))
      (kargu-dape-start "demo" (lambda (text) (push text results))))
    (should (= (length results) 1))
    (should (string-search "Open a source file" (car results)))
    (should-not approval)
    (should-not launches)
    (should-not kargu-async--pending)))

(ert-deftest kargu-dape-startup-ignores-foreign-adapter-test ()
  "A new foreign adapter cannot cancel or redirect an owned startup approval."
  (let ((discover (symbol-function 'kargu-dape-project-connections)))
    (kargu-dape-test--with-startup
      (let (foreign)
        (cl-letf (((symbol-function 'kargu-dape-project-connections) discover)
                  ((symbol-function 'dape--live-connections)
                   (lambda () (and foreign '(foreign))))
                  ((symbol-function 'dape--config)
                   (lambda (_) (list 'command-cwd temporary-file-directory))))
          (kargu-dape-start "demo" (lambda (text) (push text results)))
          (setq foreign t)
          (let ((dape--connection-selected 'foreign)) (funcall approval t))
          (should (= (length launches) 1))
          (should (string-search "started" (car results))))))))

(ert-deftest kargu-dape-startup-preserves-editor-state-test ()
  "Narrowing, point and match data survive both probe and approval callbacks."
  (kargu-dape-test--with-startup
    (with-current-buffer source
      (narrow-to-region 2 9)
      (goto-char 5))
    (string-match "session" "startup-session")
    (let ((matches (match-data t)))
      (kargu-dape-start "demo" (lambda (text) (push text results)))
      (funcall approval t)
      (should (equal matches (match-data t))))
    (with-current-buffer source
      (should (= (point-min) 2))
      (should (= (point-max) 9))
      (should (= (point) 5)))
    (should (= (length launches) 1))))

(provide 'tests/test-dape-startup)
;;; test-dape-startup.el ends here
