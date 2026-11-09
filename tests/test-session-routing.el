;;; test-session-routing.el --- Project-owned restore targets -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A default-named chat in another project is never a restore destination.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'tests/test-bridge)
(require 'kargu/chat)
(require 'kargu/chat/session)
(require 'kargu/chat/routing)
(require 'kargu/loop)

(defun kargu-routing-test--restore (data root interactive)
  "Restore DATA in ROOT through the direct or INTERACTIVE entry."
  (if (not interactive) (kargu-session-load data nil root)
    (let (target)
      (cl-letf (((symbol-function 'kargu-session-list-async)
                 (lambda (_root callback) (funcall callback (list data) nil)))
                ((symbol-function 'kargu-session--native-load)
                 (lambda (_id _root callback) (funcall callback data nil)))
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
  (let ((before (kargu-chat-list-buffers)) reply)
    (kargu-session-load "missing-record" nil default-directory
                        :callback (lambda (buffer error) (setq reply (list buffer error))))
    (kargu-bridge-test--wait (lambda () reply))
    (should-not (car reply))
    (should (cadr reply))
    (should (equal before (kargu-chat-list-buffers)))))

(ert-deftest kargu-session-routing-two-chats-same-project-distinct-handles-and-sessions-test ()
  "Two chats in the same project hold distinct handles, sessions, and run states."
  (let* ((root (file-name-as-directory (make-temp-file "kargu-two-chats-" t)))
         (kargu-session-auto-save nil)
         (a (generate-new-buffer "*kargu-chat-a*"))
         (b (generate-new-buffer "*kargu-chat-b*")))
    (unwind-protect
        (progn
          (with-current-buffer a
            (let ((default-directory root) (kargu-permission--override-root root))
              (kargu-chat-mode)))
          (with-current-buffer b
            (let ((default-directory root) (kargu-permission--override-root root))
              (kargu-chat-mode)))
          ;; Distinct buffer identities
          (should-not (eq a b))
          ;; Distinct session contexts and session IDs
          (let ((sess-a (kargu-session-context a))
                (sess-b (kargu-session-context b)))
            (should (kargu-session-p sess-a))
            (should (kargu-session-p sess-b))
            (should-not (eq sess-a sess-b))
            (should-not (equal (kargu-session-id sess-a) (kargu-session-id sess-b))))
          ;; Distinct frontend handle stores and tokens
          (let ((store-a (kargu-chat-handle-store a))
                (store-b (kargu-chat-handle-store b)))
            (should store-a)
            (should store-b)
            (should-not (eq store-a store-b))
            (should-not (eq (kargu-chat-handle-store-token store-a)
                            (kargu-chat-handle-store-token store-b)))
            (should (kargu-chat-handle-valid-p store-a a))
            (should (kargu-chat-handle-valid-p store-b b))
            (should-not (kargu-chat-handle-valid-p store-a b))
            (should-not (kargu-chat-handle-valid-p store-b a)))
          ;; Run handle isolation: run on A does not make B busy or running
          (should-not (kargu-loop-running-p a))
          (should-not (kargu-loop-running-p b))
          (let ((dummy-run (list :id "run-a" :chat-buffer a)))
            (kargu-chat-set-run-handle dummy-run a)
            (should (kargu-loop-running-p a))
            (should-not (kargu-loop-running-p b))
            (should (kargu-loop-running-p a))
            (should-not (kargu-loop-running-p b))
            (kargu-chat-set-run-handle nil a)
            (should-not (kargu-loop-running-p a))
            (should-not (kargu-loop-running-p a))))
      (when (buffer-live-p a) (kill-buffer a))
      (when (buffer-live-p b) (kill-buffer b))
      (delete-directory root t))))

(ert-deftest kargu-session-routing-closed-origin-reused-name-rejects-old-handle-delivery-test ()
  "Reincarnated buffer with the same name rejects deliveries to the old handle."
  (let* ((root (file-name-as-directory (make-temp-file "kargu-reincarnate-" t)))
         (buf-name "*kargu-chat-reincarnate-test*")
         (kargu-session-auto-save nil)
         (a (get-buffer-create buf-name))
         old-store delivered-to-new)
    (unwind-protect
        (progn
          (with-current-buffer a
            (let ((default-directory root) (kargu-permission--override-root root))
              (kargu-chat-mode)))
          (setq old-store (kargu-chat-handle-store a))
          (should (kargu-chat-handle-valid-p old-store a))
          ;; Kill the origin buffer
          (kill-buffer a)
          (should-not (buffer-live-p a))
          (should-not (kargu-chat-handle-valid-p old-store a))
          ;; Reincarnate buffer with the same name
          (let ((b (get-buffer-create buf-name)))
            (unwind-protect
                (progn
                  (with-current-buffer b
                    (let ((default-directory root) (kargu-permission--override-root root))
                      (kargu-chat-mode)))
                  ;; The old store is NOT valid for the new buffer
                  (should-not (kargu-chat-handle-valid-p old-store b))
                  (should-not (eq (kargu-chat-handle-store-token old-store)
                                  (kargu-chat-handle-store-token (kargu-chat-handle-store b))))
                  ;; Delivery to old handle must be rejected
                  (when (kargu-chat-handle-valid-p old-store b)
                    (setq delivered-to-new t))
                  (should-not delivered-to-new))
              (when (buffer-live-p b) (kill-buffer b)))))
      (when (buffer-live-p a) (kill-buffer a))
      (delete-directory root t))))

(ert-deftest kargu-session-routing-callback-draws-correct-origin-regardless-of-current-buffer-test ()
  "Delivery draws into the correct origin chat even when another buffer is current, preserving Unicode draft."
  (let* ((root (file-name-as-directory (make-temp-file "kargu-route-current-" t)))
         (kargu-session-auto-save nil)
         (a (generate-new-buffer "*kargu-chat-a*"))
         (b (generate-new-buffer "*kargu-chat-b*")))
    (unwind-protect
        (progn
          (with-current-buffer a
            (let ((default-directory root) (kargu-permission--override-root root))
              (kargu-chat-mode)
              (kargu-chat--ensure-idle-prompt)
              (goto-char (point-max))
              (insert "Türkçe taslak: ğüşıöç 🚀\nİkinci satır...")))
          (with-current-buffer b
            (let ((default-directory root) (kargu-permission--override-root root))
              (kargu-chat-mode)
              (kargu-chat--ensure-idle-prompt)
              (goto-char (point-max))
              (insert "B tamponu taslağı")))
          ;; Buffer B is current
          (with-current-buffer b
            (let ((store-a (kargu-chat-handle-store a)))
              ;; Deliver delta to buffer A while B is current
              (when (kargu-chat-handle-valid-p store-a a)
                (with-current-buffer a
                  (kargu-chat--stream-delta "Chunk from model to A: §42\n" nil)))
              ;; Deliver completion report to buffer A
              (when (kargu-chat-handle-valid-p store-a a)
                (kargu-chat--complete-submission
                 '(:status :done :text "Chunk from model to A: §42\n")
                 :buffer a :session (kargu-session-context a)))))
          ;; Verify Buffer A has the streamed text and its draft was preserved
          (with-current-buffer a
            (should (string-search "Chunk from model to A: §42" (buffer-string)))
            (should (string-search "Türkçe taslak: ğüşıöç 🚀\nİkinci satır..." (buffer-string))))
          ;; Verify Buffer B was never touched by A's delivery
          (with-current-buffer b
            (should-not (string-search "Chunk from model to A: §42" (buffer-string)))
            (should (string-search "B tamponu taslağı" (buffer-string)))))
      (when (buffer-live-p a) (kill-buffer a))
      (when (buffer-live-p b) (kill-buffer b))
      (delete-directory root t))))

(ert-deftest kargu-session-routing-buffer-rename-preserves-delivery-and-draft-test ()
  "Renaming a chat buffer preserves its handle validity, delivery, and Unicode draft."
  (let* ((root (file-name-as-directory (make-temp-file "kargu-rename-" t)))
         (kargu-session-auto-save nil)
         (buf (generate-new-buffer "*kargu-chat-to-rename*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (let ((default-directory root) (kargu-permission--override-root root))
              (kargu-chat-mode)
              (kargu-chat--ensure-idle-prompt)
              (goto-char (point-max))
              (insert "Yeniden adlandırma taslağı: 測試 ✨")))
          (let ((store (kargu-chat-handle-store buf)))
            (should (kargu-chat-handle-valid-p store buf))
            ;; Rename the buffer
            (with-current-buffer buf
              (rename-buffer "*kargu-chat-renamed*"))
            ;; Handle store is still valid for the same buffer object
            (should (kargu-chat-handle-valid-p store buf))
            ;; Deliver delta to renamed buffer
            (with-current-buffer buf
              (kargu-chat--stream-delta "Cevap metni: OK\n" nil))
            ;; Verify delivery and draft
            (with-current-buffer buf
              (should (string-search "Cevap metni: OK" (buffer-string)))
              (should (string-search "Yeniden adlandırma taslağı: 測試 ✨" (buffer-string))))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory root t))))

(ert-deftest kargu-session-routing-origin-close-does-not-abort-sibling-session-test ()
  "Closing one chat buffer in a project does not abort or stop another active chat."
  (let* ((root (file-name-as-directory (make-temp-file "kargu-sibling-" t)))
         (kargu-session-auto-save nil)
         (a (generate-new-buffer "*kargu-sibling-a*"))
         (b (generate-new-buffer "*kargu-sibling-b*"))
         b-completed)
    (unwind-protect
        (progn
          (with-current-buffer a
            (let ((default-directory root) (kargu-permission--override-root root))
              (kargu-chat-mode)))
          (with-current-buffer b
            (let ((default-directory root) (kargu-permission--override-root root))
              (kargu-chat-mode)))
          ;; Give B an active run
          (let ((run-b (list :id "run-b" :chat-buffer b)))
            (kargu-chat-set-run-handle run-b b)
            (should (kargu-loop-running-p b))
            ;; Kill buffer A
            (kill-buffer a)
            (should-not (buffer-live-p a))
            ;; Buffer B's run must still be active (never aborted by A's close!)
            (should (buffer-live-p b))
            (should (kargu-loop-running-p b))
            (should (kargu-loop-running-p b))
            ;; B completes its own run
            (kargu-chat-set-run-handle nil b)
            (setq b-completed t)
            (should-not (kargu-loop-running-p b))))
      (when (buffer-live-p a) (kill-buffer a))
      (when (buffer-live-p b) (kill-buffer b))
      (delete-directory root t))
    (should b-completed)))

(ert-deftest kargu-session-routing-foreign-stop-rejected-test ()
  "Calling stop in an idle chat buffer never stops a running sibling chat."
  (let* ((root (file-name-as-directory (make-temp-file "kargu-stop-" t)))
         (kargu-session-auto-save nil)
         (a (generate-new-buffer "*kargu-stop-a*"))
         (b (generate-new-buffer "*kargu-stop-b*")))
    (unwind-protect
        (progn
          (with-current-buffer a
            (let ((default-directory root) (kargu-permission--override-root root))
              (kargu-chat-mode)))
          (with-current-buffer b
            (let ((default-directory root) (kargu-permission--override-root root))
              (kargu-chat-mode)))
          ;; Run on buffer A
          (let ((run-a (list :id "run-a" :chat-buffer a)))
            (kargu-chat-set-run-handle run-a a)
            (should (kargu-loop-running-p a))
            (should-not (kargu-loop-running-p b))
            ;; User in buffer B attempts to stop
            (with-current-buffer b
              (kargu-loop-stop "user clicked stop in b" b))
            ;; Buffer A is STILL running (no foreign stop!)
            (should (kargu-loop-running-p a))
            ;; Now stopping from buffer A stops A
            (with-current-buffer a
              (kargu-chat-set-run-handle nil a))
            (should-not (kargu-loop-running-p a))))
      (when (buffer-live-p a) (kill-buffer a))
      (when (buffer-live-p b) (kill-buffer b))
      (delete-directory root t))))

(ert-deftest kargu-session-routing-reopen-buffer-never-receives-old-completion-test ()
  "Reopening a buffer with the same name never receives completion from previous incarnation."
  (let* ((root (file-name-as-directory (make-temp-file "kargu-reopen-" t)))
         (buf-name "*kargu-chat-reopen-test*")
         (kargu-session-auto-save nil)
         (a (get-buffer-create buf-name))
         old-store delivered-to-new)
    (unwind-protect
        (progn
          (with-current-buffer a
            (let ((default-directory root) (kargu-permission--override-root root))
              (kargu-chat-mode)
              (kargu-chat--ensure-idle-prompt)
              (goto-char (point-max))
              (insert "Old draft in A")))
          (setq old-store (kargu-chat-handle-store a))
          ;; Kill old buffer A
          (kill-buffer a)
          ;; Reopen new buffer with same name
          (let ((b (get-buffer-create buf-name)))
            (unwind-protect
                (progn
                  (with-current-buffer b
                    (let ((default-directory root) (kargu-permission--override-root root))
                      (kargu-chat-mode)
                      (kargu-chat--ensure-idle-prompt)
                      (goto-char (point-max))
                      (insert "Yeni tampon yazısı 🌟")))
                  ;; A late completion arrives targeting old-store
                  (when (kargu-chat-handle-valid-p old-store b)
                    (setq delivered-to-new t)
                    (with-current-buffer b
                      (kargu-chat--stream-delta "Old late completion" nil)))
                  (should-not delivered-to-new)
                  ;; New buffer's draft is unpolluted
                  (with-current-buffer b
                    (should-not (string-search "Old late completion" (buffer-string)))
                    (should (string-search "Yeni tampon yazısı 🌟" (buffer-string)))))
              (when (buffer-live-p b) (kill-buffer b)))))
      (when (buffer-live-p a) (kill-buffer a))
      (delete-directory root t))))

(provide 'tests/test-session-routing)
;;; test-session-routing.el ends here
