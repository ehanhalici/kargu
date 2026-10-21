;;; tests/test-helpers.el --- Shared helpers for the Kargu ERT suites -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests may wait for an asynchronous result; the product code never does.

;;; Code:

(defun kargu-test-await (start &optional timeout)
  "Call START with a callback and return what the callback receives.
Waits up to TIMEOUT seconds (default 10) for the callback; signals an error
when it never arrives."
  (let ((result :kargu-test-pending)
        (deadline (+ (float-time) (or timeout 10))))
    (funcall start (lambda (value) (setq result value)))
    (while (and (eq result :kargu-test-pending)
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (when (eq result :kargu-test-pending)
      (error "Kargu test await: no result within %ss" (or timeout 10)))
    result))

;;;; Temporary repositories ----------------------------------------------------

(defvar kargu-permission--override-root)

(defmacro kargu-test-with-git-repo (files &rest body)
  "Run BODY in a fresh git repository containing FILES in one commit.
FILES is an alist of (NAME . TEXT).  `repo' is bound to the directory,
which is also the project root and `default-directory'.  The repository
is deleted afterwards, so no test depends on the working tree of Kargu."
  (declare (indent 1))
  `(let* ((repo (file-name-as-directory (file-truename (make-temp-file "kargu-repo-" t))))
          (default-directory repo)
          (kargu-permission--override-root repo)
          (process-environment
           (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@example.com"
                     "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@example.com"
                     "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null")
                   process-environment)))
     (unwind-protect
         (progn
           (dolist (f ,files)
             (let ((path (expand-file-name (car f) repo)))
               (make-directory (file-name-directory path) t)
               (write-region (cdr f) nil path nil 'silent)))
           (call-process "git" nil nil nil "init" "-q" "-b" "main")
           (call-process "git" nil nil nil "add" "-A")
           (call-process "git" nil nil nil "commit" "-q" "-m" "first commit")
           ,@body)
       (delete-directory repo t))))

;;;; Mode and state isolation ----------------------------------------------

(require 'kargu/history/store)
(require 'kargu/selection)

(cl-defun kargu-test-session-with-history
    (&key (messages (kargu-history-snapshot))
          (system-key (kargu-history-system-key)) (overlay (kargu-history-overlay))
          (provider (kargu-selection-provider)) (model (kargu-selection-model))
          (effort (kargu-selection-effort-value (kargu-selection-context))))
  "Create a session fixture from MESSAGES, SYSTEM-KEY, OVERLAY and choices.
PROVIDER, MODEL and EFFORT default to the current owner's explicit values."
  (let ((history (kargu-history-create :messages messages)))
    (setf (kargu-history-system-key history) (copy-tree system-key t)
          (kargu-history-overlay history) overlay)
    (kargu-session--create :id-value (kargu-session-id)
                           :usage-value (copy-tree (kargu-session-usage-value
                                                   (kargu-session-context)))
                           :history-value history
                           :mode-value (kargu-session-mode-value (kargu-session-context))
                           :selection-value (kargu-selection-create
                                             :provider provider :model model :effort effort))))

(declare-function kargu-state--set "kargu/state/store" (key value))
(declare-function kargu-state-mode "kargu/state/selectors" ())

(defvar kargu--loop-run)
(defvar kargu--busy)
(defvar kargu--generation)
(defvar kargu-application--context)
(defvar kargu--tools-refused)
(defvar kargu--model-metadata-table)
(defvar kargu--state-store)
(defvar kargu-session--context)
(defvar kargu--session-id)
(defvar kargu-context-buffer)

(declare-function kargu-application-create "kargu/application/coordinator")
(declare-function kargu-application-context "kargu/application/coordinator")

(defun kargu-test-mode (mode)
  "Make MODE the active mode for the running test and return it.
The mode lives only in the state store.  `kargu-test--isolate' restores
the previous mode when the test ends."
  (kargu-state--set :mode mode)
  mode)

(defvar kargu-test--scratch-root nil
  "Project root every test runs in: a scratch directory, never the working tree.")

(defun kargu-test-scratch-root ()
  "The scratch project root of this test run, created on first use."
  (unless (and kargu-test--scratch-root (file-directory-p kargu-test--scratch-root))
    (setq kargu-test--scratch-root
          (file-name-as-directory (file-truename (make-temp-file "kargu-scratch-" t))))
    (add-hook 'kill-emacs-hook
              (lambda () (when (file-directory-p kargu-test--scratch-root)
                           (delete-directory kargu-test--scratch-root t)))))
  kargu-test--scratch-root)

(defun kargu-test--isolate (run-test &rest args)
  "Run RUN-TEST with ARGS in a scratch root and isolated session/state data.
Tests never see the working tree of Kargu as their project."
  (let ((default-directory (kargu-test-scratch-root))
        (kargu-permission--override-root (kargu-test-scratch-root))
        (kargu--state-store (copy-tree kargu--state-store))
        (kargu-session--context (kargu-test-session-with-history))
        (kargu--session-id kargu--session-id)
        (kargu-context-buffer kargu-context-buffer)
        ;; Global state a test may touch; each test starts from and leaves it as found.
        (kargu--loop-run kargu--loop-run)
        (kargu--busy kargu--busy)
        (kargu--generation (bound-and-true-p kargu--generation))
        (kargu-application--context
         (if (fboundp 'kargu-application-create)
             (kargu-application-create
              :status (or (plist-get kargu--state-store :status) :idle)
              :active-run kargu--loop-run
              :generation (or (bound-and-true-p kargu--generation) 0))
           (bound-and-true-p kargu-application--context)))
        (kargu--tools-refused (copy-hash-table kargu--tools-refused))
        (kargu--model-metadata-table (copy-hash-table kargu--model-metadata-table)))
    (apply run-test args)))

(advice-add 'ert-run-test :around #'kargu-test--isolate)

(provide 'tests/test-helpers)
;;; test-helpers.el ends here
