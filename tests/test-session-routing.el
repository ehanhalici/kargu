;;; test-session-routing.el --- Project-owned restore targets -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A default-named chat in another project is never a restore destination.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu/chat)
(require 'kargu/chat/session)

(defun kargu-routing-test--restore (data root interactive)
  "Restore DATA in ROOT through the direct or INTERACTIVE entry."
  (if (not interactive) (kargu-session-load data nil root)
    (let (target)
      (cl-letf (((symbol-function 'kargu-session-list) (lambda (&rest _) (list data)))
                ((symbol-function 'completing-read) (lambda (_prompt choices &rest _) (caar choices)))
                ((symbol-function 'pop-to-buffer-same-window) (lambda (buffer &rest _) (setq target buffer))))
        (kargu-chat-sessions root))
      target)))

(defun kargu-routing-test--assert-preserved (buffer owner root)
  "Assert BUFFER still has OWNER, ROOT and its private transcript."
  (with-current-buffer buffer
    (should (equal (buffer-string) "A-PRIVATE-TRANSCRIPT"))
    (should (eq owner (kargu-session-context)))
    (should (equal kargu-chat--project-root root))))

(cl-defun kargu-routing-test--exercise (&key interactive reuse)
  "Check restore from a foreign project with INTERACTIVE entry and REUSE."
  (let* ((root-a (file-name-as-directory (make-temp-file "kargu-route-a-" t)))
         (root-b (file-name-as-directory (make-temp-file "kargu-route-b-" t)))
         (kargu-chat-buffer-name (generate-new-buffer-name "*kargu-routing*"))
         (kargu-session-auto-save nil)
         (a (get-buffer-create kargu-chat-buffer-name)) b target owner
         (data '(("id" . "route-b") ("title" . "B")
                 ("transcript" . "B-PUBLIC-TRANSCRIPT") ("messages" . []))))
    (unwind-protect
        (progn
          (with-current-buffer a
            (let ((default-directory root-a) (kargu-permission--override-root root-a))
              (kargu-chat-mode) (insert "A-PRIVATE-TRANSCRIPT")
              (setq owner (kargu-session-context))))
          (when reuse
            (setq b (generate-new-buffer " *matching-project-chat*"))
            (with-current-buffer b
              (let ((default-directory root-b) (kargu-permission--override-root root-b))
                (kargu-chat-mode))))
          (with-temp-buffer
            (let ((default-directory root-b) (kargu-permission--override-root root-b))
              (setq target (kargu-routing-test--restore data root-b interactive))))
          (should (buffer-live-p target))
          (should-not (eq target a))
          (when reuse (should (eq target b)))
          (with-current-buffer target
            (should (equal kargu-chat--project-root root-b))
            (should (equal kargu-chat--session-id "route-b")))
          (kargu-routing-test--assert-preserved a owner root-a))
      (dolist (buffer (delete-dups (list a b target)))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (delete-directory root-a t) (delete-directory root-b t))))

(ert-deftest kargu-session-routing-implicit-restore-creates-only-project-target-test ()
  "Direct restore creates a project-owned chat instead of overwriting A."
  (kargu-routing-test--exercise))

(ert-deftest kargu-session-routing-picker-never-overwrites-default-foreign-chat-test ()
  "The session picker has the same project boundary as direct restore."
  (kargu-routing-test--exercise :interactive t))

(ert-deftest kargu-session-routing-reuses-only-matching-project-test ()
  "An existing project chat wins over the unrelated default-named chat."
  (kargu-routing-test--exercise :reuse t))

(ert-deftest kargu-session-routing-explicit-foreign-target-is-refused-test ()
  "An explicit target is not permission to move a conversation to another root."
  (with-temp-buffer
    (kargu-chat-mode) (insert "private draft")
    (let ((owner (kargu-session-context)))
      (should-error (kargu-session-load '(("id" . "foreign") ("messages" . []))
                                        (current-buffer) "/") :type 'user-error)
      (should (equal (buffer-string) "private draft"))
      (should (eq owner (kargu-session-context))))))

(ert-deftest kargu-session-routing-absent-record-does-not-create-a-buffer-test ()
  "A missing session has no target-allocation side effect."
  (let ((before (buffer-list)))
    (should-not (kargu-session-load "missing-record" nil default-directory))
    (should (equal before (buffer-list)))))

(provide 'tests/test-session-routing)
;;; test-session-routing.el ends here
