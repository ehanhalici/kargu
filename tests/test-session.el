;;; tests/test-session.el --- Tests for kargu/chat/session -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Ensure the package root is on `load-path` during byte/native compilation.
(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'ert)
(require 'kargu)
(require 'kargu/chat/session)
(require 'kargu/chat)

(declare-function kargu-chat--focus-selection "kargu/chat/prompt" (&optional open-company))
(declare-function kargu-api-select--stay-on-field "kargu/api/select" (field))

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
            (should (equal (kargu-aget (car sessions) "id") "session-test-001"))
            (should (equal (kargu-aget (car sessions) "title") "Test Chat Session")))

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

(ert-deftest kargu-session-remembers-live-provider-test ()
  "A later provider choice replaces the buffer's older copy and survives reload."
  (let* ((temp-dir (make-temp-file "kargu-test-sessions-prov-" t))
         (kargu-sessions-directory temp-dir)
         (proj-dir (make-temp-file "kargu-test-project-prov-" t))
         (buf1 (get-buffer-create "*kargu-test-chat-prov-1*"))
         (buf2 (get-buffer-create "*kargu-test-chat-prov-2*"))
         (kargu--session-provider "openrouter")
         (kargu--session-model "kept-model"))
    (unwind-protect
        (progn
          (with-current-buffer buf1
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root (file-name-as-directory proj-dir))
            (setq-local kargu-chat--session-id "session-prov-001")
            (setq-local kargu-chat--session-provider "opencode")
            (setq-local kargu-chat--session-model "stale-model")
            (setq-local kargu-chat--messages
                        '((("role" . "user") ("content" . "Remember the provider"))))
            (let ((inhibit-read-only t))
              (insert "## you · 12:00\nRemember the provider\n"))
            (kargu-session-save buf1))
          (let ((sessions (kargu-session-list proj-dir)))
            (should (equal (kargu-aget (car sessions) "provider") "openrouter"))
            (should (equal (kargu-aget (car sessions) "model") "kept-model")))
          (setq kargu--session-provider nil
                kargu--session-model nil)
          (with-current-buffer buf2
            (kargu-chat-mode)
            (kargu-session-load "session-prov-001" buf2 proj-dir))
          (should (equal kargu--session-provider "openrouter"))
          (should (equal kargu--session-model "kept-model"))
          (should (eq (kargu-state-provider) 'openrouter))
          (should (equal (kargu-state-model) "kept-model")))
      (when (buffer-live-p buf1) (kill-buffer buf1))
      (when (buffer-live-p buf2) (kill-buffer buf2))
      (delete-directory temp-dir t)
      (delete-directory proj-dir t)
      (kargu-state-reset))))

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
            (should (equal (kargu-aget (car sessionsA) "id") "session-A")))

          ;; Verify Proj B sessions
          (let ((sessionsB (kargu-session-list projB)))
            (should (= (length sessionsB) 1))
            (should (equal (kargu-aget (car sessionsB) "id") "session-B"))))
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

(ert-deftest kargu-chat-fresh-footer-ignores-live-selection-test ()
  "An unsaved chat shows empty provider and model slots."
  (let ((kargu--session-provider "cerebras")
        (kargu--session-model "llama3.1-70b")
        (buf (get-buffer-create "*kargu-fresh-footer*")))
    (unwind-protect
        (with-current-buffer buf
          (kargu-chat-mode)
          (kargu-chat--ensure-idle-prompt)
          (let ((text (buffer-string)))
            (should (string-match-p "\\[select provider\\]" text))
            (should (string-match-p "\\[select model\\]" text))
            (should-not (string-match-p "cerebras" text))
            (should-not (string-match-p "llama3.1-70b" text))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest kargu-chat-activate-clears-unset-selection-test ()
  "Showing a chat with no saved choice clears the previous live selection."
  (let ((kargu--session-provider "cerebras")
        (kargu--session-model "llama3.1-70b")
        (buf (get-buffer-create "*kargu-activate-clear*")))
    (unwind-protect
        (progn
          (kargu-state-set-provider 'cerebras)
          (kargu-state-set-model "llama3.1-70b")
          (with-current-buffer buf
            (kargu-chat-mode)
            (kargu-chat-activate-selection buf))
          (should-not kargu--session-provider)
          (should-not kargu--session-model)
          (should-not (kargu-state-provider))
          (should-not (kargu-state-model)))
      (when (buffer-live-p buf) (kill-buffer buf))
      (setq kargu--session-provider nil
            kargu--session-model nil)
      (kargu-state-reset))))

(ert-deftest kargu-chat-note-selection-ignores-config-fallback-test ()
  "Noting a selection does not copy the resolved config provider."
  (let ((kargu--session-provider nil)
        (kargu--session-model nil)
        (buf (get-buffer-create "*kargu-note-empty*")))
    (unwind-protect
        (with-current-buffer buf
          (kargu-chat-mode)
          (setq-local kargu-chat--session-provider "stale")
          (setq-local kargu-chat--session-model "stale-model")
          (kargu-chat-note-selection buf)
          (should-not kargu-chat--session-provider)
          (should-not kargu-chat--session-model))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest kargu-session-save-omits-unselected-provider-test ()
  "A chat that never chose a provider saves empty provider and model."
  (let* ((temp-dir (make-temp-file "kargu-test-sessions-empty-" t))
         (kargu-sessions-directory temp-dir)
         (proj (make-temp-file "kargu-proj-empty-" t))
         (proj-root (file-name-as-directory proj))
         (kargu--session-provider "cerebras")
         (kargu--session-model "llama3.1-70b")
         (buf (get-buffer-create "*kargu-save-empty*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root proj-root)
            (setq-local kargu-chat--session-id "empty-selection")
            (setq-local kargu-chat--session-provider nil)
            (setq-local kargu-chat--session-model nil)
            (setq-local kargu-chat--messages
                        '((("role" . "user") ("content" . "unsaved choice"))))
            ;; Save from another buffer so note-selection does not copy the live fallback.
            (with-temp-buffer
              (kargu-session-save buf)))
          (let ((saved (car (kargu-session-list proj-root))))
            (should (equal (kargu-aget saved "provider") ""))
            (should (equal (kargu-aget saved "model") ""))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory temp-dir t)
      (delete-directory proj t))))

(ert-deftest kargu-chat-selection-chain-ends-at-prompt-test ()
  "Provider selection leaves the model empty, then a model choice lands in the prompt."
  (let ((kargu--session-provider nil)
        (kargu--session-model "llama3.1-70b")
        (kargu-reasoning-effort 'low)
        (opened nil)
        (buf (get-buffer-create "*kargu-chain-prompt*")))
    (unwind-protect
        (with-current-buffer buf
          (kargu-chat-mode)
          (kargu-chat--ensure-idle-prompt)
          (goto-char (point-min))
          (cl-letf (((symbol-function 'kargu-set-provider)
                     (lambda (name)
                       (setq kargu--session-provider name
                             kargu--session-model "from-provider")))
                    ((symbol-function 'kargu-chat-select-model-company)
                     (lambda (&rest _) (setq opened t)))
                    ((symbol-function 'kargu-model-reasoning-efforts)
                     (lambda (&rest _) nil))
                    ((symbol-function 'kargu-model-context-window)
                     (lambda (&rest _) nil))
                    ((symbol-function 'kargu-history-compact-threshold)
                     (lambda (&rest _) nil)))
            (kargu-api-select--apply-provider "groq")
            (should opened)
            (should (equal kargu--session-provider "groq"))
            (should-not kargu--session-model)
            (should (equal kargu-chat--session-provider "groq"))
            (should-not kargu-chat--session-model)
            (kargu-api-select--apply-model "chosen-model" "groq")
            (should (kargu-chat--in-input-p))
            (should (= (point) (marker-position kargu-chat--prompt-marker)))
            (kargu-api-select--apply-effort "off")
            (should (kargu-chat--in-input-p))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (setq kargu--session-provider nil
            kargu--session-model nil)
      (kargu-state-reset))))

(ert-deftest kargu-chat-cancel-stays-on-field-test ()
  "Cancelling a footer selection leaves point on that field."
  (let ((buf (get-buffer-create "*kargu-cancel-field*")))
    (unwind-protect
        (with-current-buffer buf
          (kargu-chat-mode)
          (kargu-chat--ensure-idle-prompt)
          (goto-char (point-max))
          (should (kargu-chat--in-input-p))
          (kargu-api-select--stay-on-field 'provider)
          (should-not (kargu-chat--in-input-p))
          (should (looking-back "provider: \\[" (line-beginning-position))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest kargu-chat-focus-selection-test ()
  "A fresh chat focuses provider.  A chosen pair focuses the prompt."
  (let ((buf (get-buffer-create "*kargu-focus-selection*")))
    (unwind-protect
        (with-current-buffer buf
          (kargu-chat-mode)
          (kargu-chat--ensure-idle-prompt)
          (goto-char (point-max))
          (kargu-chat--focus-selection nil)
          (should (looking-back "provider: \\[" (line-beginning-position)))
          (setq-local kargu-chat--session-provider "opencode")
          (setq-local kargu-chat--session-model "chosen-model")
          (kargu-chat-refresh-footer)
          (kargu-chat--focus-selection t)
          (should (kargu-chat--in-input-p)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest kargu-chat-submit-requires-selection-test ()
  "Sending without a provider and model signals an error."
  (let ((buf (get-buffer-create "*kargu-submit-selection*"))
        (kargu--loop-run nil))
    (unwind-protect
        (with-current-buffer buf
          (kargu-chat-mode)
          (kargu-chat--ensure-idle-prompt)
          (cl-letf (((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
                    ((symbol-function 'kargu-loop-running-p) (lambda () nil)))
            (let ((err (should-error (kargu-chat--submit "hello") :type 'user-error)))
              (should (string-match-p "select a provider and model"
                                      (error-message-string err))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(provide 'tests/test-session)
;;; test-session.el ends here
