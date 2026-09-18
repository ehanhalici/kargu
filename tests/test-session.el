;;; tests/test-session.el --- Tests for kargu/chat/session -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'kargu)
(require 'kargu/chat/session)
(require 'kargu/chat)

(ert-deftest kargu-session-project-key-test ()
  "Ensure kargu-session--project-key produces deterministic and valid slugs."
  (let ((slug1 (kargu-session--project-key "/home/user/project-foo/"))
        (slug2 (kargu-session--project-key "/home/user/project-foo"))
        (slug3 (kargu-session--project-key "/home/user/project-bar/")))
    ;; Slashes should not affect canonical slug
    (should (equal slug1 slug2))
    (should (string-prefix-p "project-foo-" slug1))
    (should (string-prefix-p "project-bar-" slug3))
    (should-not (equal slug1 slug3))))

(ert-deftest kargu-session-save-and-load-test ()
  "Ensure saving and restoring chat session preserves messages, transcript, and metadata."
  (let* ((temp-dir (make-temp-file "kargu-test-sessions-" t))
         (kargu-sessions-directory temp-dir)
         (proj-dir (make-temp-file "kargu-test-project-" t))
         (buf1 (get-buffer-create "*kargu-test-chat-1*"))
         (buf2 (get-buffer-create "*kargu-test-chat-2*"))
         (test-msgs '((("role" . "user") ("content" . "Hello Kargu"))
                      (("role" . "assistant") ("content" . "Hello! How can I help?")))))
    (unwind-protect
        (progn
          ;; Set up buf1
          (with-current-buffer buf1
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root (file-name-as-directory proj-dir))
            (setq-local kargu-chat--session-id "session-test-001")
            (setq-local kargu-chat--session-title "Test Chat Session")
            (setq-local kargu-chat--messages test-msgs)
            (setq kargu--message-history test-msgs)
            (let ((inhibit-read-only t))
              (insert "## you · 12:00\nHello Kargu\n\n## kargu · model\nHello! How can I help?\n"))
            (kargu-chat--ensure-idle-prompt)
            ;; Save session
            (let ((file (kargu-session-save buf1)))
              (should (stringp file))
              (should (file-exists-p file))))

          ;; List sessions
          (let ((sessions (kargu-session-list proj-dir)))
            (should (= (length sessions) 1))
            (should (equal (kargu--aget (car sessions) "id") "session-test-001"))
            (should (equal (kargu--aget (car sessions) "title") "Test Chat Session")))

          ;; Restore into buf2
          (with-current-buffer buf2
            (kargu-chat-mode)
            (kargu-session-load "session-test-001" buf2 proj-dir)
            ;; Verify properties restored in buf2
            (should (equal kargu-chat--session-id "session-test-001"))
            (should (equal kargu--session-id "session-test-001"))
            (should (equal kargu-chat--session-title "Test Chat Session"))
            (should (equal kargu-chat--messages test-msgs))
            (should (equal kargu--message-history test-msgs))
            (let ((content (buffer-string)))
              (should (string-match-p "Hello Kargu" content))
              (should (string-match-p "Hello! How can I help?" content))
              (should (string-match-p "restored session" content)))))
      (when (buffer-live-p buf1) (kill-buffer buf1))
      (when (buffer-live-p buf2) (kill-buffer buf2))
      (delete-directory temp-dir t)
      (delete-directory proj-dir t))))

(ert-deftest kargu-session-project-isolation-test ()
  "Ensure sessions are cleanly isolated between different projects."
  (let* ((temp-dir (make-temp-file "kargu-test-sessions-iso-" t))
         (kargu-sessions-directory temp-dir)
         (projA (make-temp-file "kargu-projA-" t))
         (projB (make-temp-file "kargu-projB-" t))
         (bufA (get-buffer-create "*kargu-chat-A*"))
         (bufB (get-buffer-create "*kargu-chat-B*")))
    (unwind-protect
        (progn
          (with-current-buffer bufA
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root (file-name-as-directory projA))
            (setq-local kargu-chat--session-id "session-A")
            (setq-local kargu-chat--session-title "Session in ProjA")
            (setq-local kargu-chat--messages '((("role" . "user") ("content" . "In Proj A"))))
            (let ((inhibit-read-only t))
              (insert "Turn A\n"))
            (kargu-session-save bufA))

          (with-current-buffer bufB
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root (file-name-as-directory projB))
            (setq-local kargu-chat--session-id "session-B")
            (setq-local kargu-chat--session-title "Session in ProjB")
            (setq-local kargu-chat--messages '((("role" . "user") ("content" . "In Proj B"))))
            (let ((inhibit-read-only t))
              (insert "Turn B\n"))
            (kargu-session-save bufB))

          ;; Verify Proj A sessions
          (let ((sessionsA (kargu-session-list projA)))
            (should (= (length sessionsA) 1))
            (should (equal (kargu--aget (car sessionsA) "id") "session-A")))

          ;; Verify Proj B sessions
          (let ((sessionsB (kargu-session-list projB)))
            (should (= (length sessionsB) 1))
            (should (equal (kargu--aget (car sessionsB) "id") "session-B"))))
      (when (buffer-live-p bufA) (kill-buffer bufA))
      (when (buffer-live-p bufB) (kill-buffer bufB))
      (delete-directory temp-dir t)
      (delete-directory projA t)
      (delete-directory projB t))))

(ert-deftest kargu-session-auto-restore-test ()
  "Ensure kargu-chat--buffer automatically restores the latest saved session."
  (let* ((temp-dir (make-temp-file "kargu-test-sessions-auto-" t))
         (kargu-sessions-directory temp-dir)
         (proj (make-temp-file "kargu-proj-auto-" t))
         (proj-root (file-name-as-directory proj))
         (buf-init (get-buffer-create "*kargu-chat-temp-init*"))
         (kargu-session-auto-restore t))
    (unwind-protect
        (progn
          ;; Create and save a session
          (with-current-buffer buf-init
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root proj-root)
            (setq-local kargu-chat--session-id "auto-restore-001")
            (setq-local kargu-chat--session-title "Auto Restore Session")
            (setq-local kargu-chat--messages '((("role" . "user") ("content" . "Persistent query"))))
            (let ((inhibit-read-only t))
              (insert "## you · 10:00\nPersistent query\n"))
            (kargu-session-save buf-init))
          ;; Kill all live chat buffers
          (dolist (b (kargu-chat-list-buffers))
            (kill-buffer b))
          (when (get-buffer kargu-chat-buffer-name)
            (kill-buffer (get-buffer kargu-chat-buffer-name)))

          ;; Call kargu-chat--buffer for this project
          (let ((chat-buf (kargu-chat--buffer proj-root)))
            (should (buffer-live-p chat-buf))
            (with-current-buffer chat-buf
              (should (equal kargu-chat--session-id "auto-restore-001"))
              (should (equal kargu-chat--session-title "Auto Restore Session"))
              (should (string-match-p "Persistent query" (buffer-string))))))
      (when (buffer-live-p buf-init) (kill-buffer buf-init))
      (when (get-buffer kargu-chat-buffer-name)
        (kill-buffer (get-buffer kargu-chat-buffer-name)))
      (delete-directory temp-dir t)
      (delete-directory proj t))))

(ert-deftest kargu-session-delete-test ()
  "Ensure deleting a session removes it from disk and listing."
  (let* ((temp-dir (make-temp-file "kargu-test-sessions-del-" t))
         (kargu-sessions-directory temp-dir)
         (proj (make-temp-file "kargu-proj-del-" t))
         (proj-root (file-name-as-directory proj))
         (buf (get-buffer-create "*kargu-chat-temp-del*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root proj-root)
            (setq-local kargu-chat--session-id "del-001")
            (setq-local kargu-chat--messages '((("role" . "user") ("content" . "To be deleted"))))
            (let ((inhibit-read-only t))
              (insert "To be deleted\n"))
            (kargu-session-save buf))
          (should (= (length (kargu-session-list proj-root)) 1))
          (kargu-session-delete "del-001" proj-root)
          (should (= (length (kargu-session-list proj-root)) 0)))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory temp-dir t)
      (delete-directory proj t))))

(provide 'tests/test-session)
;;; test-session.el ends here
