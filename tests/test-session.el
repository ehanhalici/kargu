;;; tests/test-session.el --- Tests for kargu/chat/session -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'tests/test-helpers)
(require 'tests/test-bridge)
(require 'kargu)
(require 'kargu/chat/session)
(require 'kargu/chat)

(declare-function kargu-chat--focus-selection "kargu/chat/prompt" (&optional open-company))
(declare-function kargu-api-select--stay-on-field "kargu/api/select" (field))

(defmacro kargu-test-with-session-bridge (&rest body)
  "Run BODY against the real native persistence core.
Storage is native; tests observe it only through the public flows."
  (declare (indent 0))
  `(let ((binary (getenv "KARGU_CORE_TEST_BINARY")))
     (unless (and binary (file-executable-p binary))
       (ert-skip "A configured native test binary is required"))
     (let ((kargu-bridge-binary-path binary))
       ,@body)))

(defun kargu-test-session--await (start)
  "Call START with a callback, wait for it and return its arguments."
  (let (reply)
    (funcall start (lambda (&rest arguments) (setq reply (or arguments (list nil)))))
    (kargu-bridge-test--wait (lambda () reply))
    (should reply)
    reply))

(defun kargu-test-session--save (buffer)
  "Save BUFFER natively and return its (RESULT ERROR)."
  (let ((reply (kargu-test-session--await
                (lambda (done) (kargu-session-save buffer done)))))
    (should-not (cadr reply))
    reply))

(defun kargu-test-session--list (root)
  "Return ROOT's native session listing, newest first."
  (with-temp-buffer
    (kargu-chat-mode)
    (setq-local kargu-chat--project-root (file-name-as-directory root))
    (let ((reply (kargu-test-session--await
                  (lambda (done) (kargu-session-list-async root done (current-buffer))))))
      (should-not (cadr reply))
      (car reply))))

(defun kargu-test-session--load (session buffer root)
  "Load SESSION into BUFFER for ROOT natively and return (BUFFER ERROR)."
  (kargu-test-session--await
   (lambda (done) (kargu-session-load session buffer root :callback done))))

(ert-deftest kargu-session-storage-paths-reject-traversal-and-symlinks-test ()
  "Session identities cannot read, delete or overwrite files outside storage."
  (kargu-test-with-git-repo nil
			    (let* ((kargu-sessions-directory (expand-file-name "central" repo))
				   (kargu-session-storage-location 'project)
				   (storage (expand-file-name ".kargu/sessions" repo))
				   (victim (expand-file-name "victim.json" repo)))
			      (make-directory storage t)
			      (write-region "preserve" nil victim)
			      (dolist (id '(nil "" "../victim" "/absolute" "a/b" "a\\b" "C:target" "." ".."))
				(should-error (kargu-session-storage-file id repo)))
			      (make-symbolic-link victim (expand-file-name "safe.json" storage))
			      (should-error (kargu-session-storage-file "safe" repo))
			      (dolist (id '("../victim" "/absolute" "a/b"))
				(should-error (kargu-session-delete id repo))
				(should-error (kargu-session-load id nil repo)))
			      ;; The native reader never follows the planted link.
			      (kargu-test-with-session-bridge
				(should-not (kargu-test-session--list repo))
				(should (cadr (kargu-test-session--load "safe" nil repo))))
			      (with-temp-buffer
				(insert-file-contents victim)
				(should (equal (buffer-string) "preserve")))
			      (should (file-symlink-p (expand-file-name "safe.json" storage))))))

(ert-deftest kargu-session-load-metadata-cannot-switch-projects-test ()
  "Caller-owned project roots win, and rejected loads leave input untouched."
  (let* ((root (kargu-permission-project-root))
         (data '(("id" . "safe") ("project_root" . "/unrelated/project/")
                 ("transcript" . "") ("messages" . []))))
    (with-temp-buffer
      (kargu-session-load data (current-buffer) root)
      (should (equal kargu-chat--project-root root)))
    (with-temp-buffer
      (insert "user draft")
      (should-error (kargu-session-load '(("id" . "../unsafe")) (current-buffer) root))
      (should (equal (buffer-string) "user draft"))
      (cl-letf (((symbol-function 'kargu-loop-running-p) (lambda () t)))
        (should-error (kargu-session-load data (current-buffer) root))
        (should (equal (buffer-string) "user draft"))))))

(ert-deftest kargu-session-external-local-storage-symlink-is-not-followed-test ()
  "A repository symlink cannot redirect local session persistence outside it."
  (kargu-test-with-git-repo nil
			    (let ((kargu-sessions-directory (expand-file-name "central" repo))
				  (outside (make-temp-file "kargu-session-outside-" t)))
			      (unwind-protect
				  (progn
				    (make-directory (expand-file-name ".kargu" repo))
				    (make-symbolic-link outside (expand-file-name ".kargu/sessions" repo))
				    (let ((path (kargu-session-storage-file "safe" repo)))
				      (should (kargu-permission-within-project-p path kargu-sessions-directory))
				      (should-not (kargu-permission-within-project-p path outside)))
				    (let ((kargu-session-storage-location 'project))
				      (should-error (kargu-session-storage-file "safe" repo))))
				(delete-directory outside)))))

(ert-deftest kargu-session-project-key-test ()
  "Ensure project storage keys produce deterministic and valid slugs."
  (let ((slug1 (kargu-session-storage--project-key "/home/user/project-foo/"))
        (slug2 (kargu-session-storage--project-key "/home/user/project-foo"))
        (slug3 (kargu-session-storage--project-key "/home/user/project-bar/")))
    ;; Slashes should not affect canonical slug
    (should (equal slug1 slug2))
    (should (string-prefix-p "project-foo-" slug1))
    (should (string-prefix-p "project-bar-" slug3))
    (should-not (equal slug1 slug3))))

(ert-deftest kargu-session-explicit-root-bypasses-workspace-test ()
  "An explicit session root never falls back to an unrelated workspace."
  (let* ((root (make-temp-file "kargu-session-root-" t))
         (expected (file-name-as-directory (file-truename root))))
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-permission-project-root)
                   (lambda (&rest _) (error "Must not resolve the workspace"))))
          (should (equal (kargu-session-project-root root) expected))
          (with-temp-buffer
            (setq-local kargu-chat--project-root root)
            (should (equal (kargu-session-project-root (current-buffer)) expected))))
      (delete-directory root t))))

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
        (kargu-test-with-session-bridge
          ;; Set up buf1
          (with-current-buffer buf1
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root (file-name-as-directory proj-dir))
            (setq-local kargu-chat--session-id "session-test-001")
            (setq-local kargu-chat--session-title "Test Chat Session")
            (setf (kargu-history-messages) test-msgs)
            (let ((inhibit-read-only t))
              (insert "## you · 12:00\nHello Kargu\n\n## kargu · model\nHello! How can I help?\n"))
            (kargu-chat--ensure-idle-prompt)
            ;; Save session
            (kargu-test-session--save buf1)
            ;; Native layout matches the editor's legacy path for the same project.
            (let ((saved (with-temp-buffer
                           (insert-file-contents
                            (kargu-session-storage-file "session-test-001" proj-dir))
                           (json-parse-buffer))))
              ;; Editor accounting survives the native record schema.
              (dolist (key '("tokens_unknown" "monetary_spent" "monetary_reserved"
                             "monetary_unknown"))
                (should (gethash key saved)))
              (should (integerp (gethash "monetary_spent" saved)))))

          ;; List sessions
          (let ((sessions (kargu-test-session--list proj-dir)))
            (should (= (length sessions) 1))
            (should (equal (kargu-aget (car sessions) "id") "session-test-001"))
            (should (equal (kargu-aget (car sessions) "title") "Test Chat Session")))

          ;; Restore into buf2
          (with-current-buffer buf2
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root (file-name-as-directory proj-dir))
            (should-not (cadr (kargu-test-session--load "session-test-001" buf2 proj-dir)))
            ;; Verify properties restored in buf2
            (should (equal kargu-chat--session-id "session-test-001"))
            (should (equal kargu--session-id "session-test-001"))
            (should (equal kargu-chat--session-title "Test Chat Session"))
            ;; JSON objects carry no key order; compare the fields, not alist order.
            (let ((fields (lambda (messages)
                            (mapcar (lambda (m) (list (kargu-aget m "role") (kargu-aget m "content")))
                                    messages))))
              (should (equal (funcall fields (kargu-history-messages))
                             (funcall fields test-msgs))))
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
         (kargu-session--context
          (kargu-test-session-with-history :provider "openrouter" :model "kept-model")))
    (unwind-protect
        (kargu-test-with-session-bridge
          (with-current-buffer buf1
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root (file-name-as-directory proj-dir))
            (setq-local kargu-chat--session-id "session-prov-001")
            (setf (kargu-selection-provider) "opencode")
            (setf (kargu-selection-model) "stale-model")
            (setf (kargu-history-messages)
                  '((("role" . "user") ("content" . "Remember the provider"))))
            (let ((inhibit-read-only t))
              (insert "## you · 12:00\nRemember the provider\n"))
            (kargu-selection-update :provider "openrouter" :model "kept-model")
            (kargu-test-session--save buf1))
          (let ((sessions (kargu-test-session--list proj-dir)))
            (should (equal (kargu-aget (car sessions) "provider") "openrouter"))
            (should (equal (kargu-aget (car sessions) "model") "kept-model")))
          (setf (kargu-selection-provider) nil
                (kargu-selection-model) nil)
          (with-current-buffer buf2
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root (file-name-as-directory proj-dir))
            (should-not (cadr (kargu-test-session--load "session-prov-001" buf2 proj-dir)))
            (should (equal (kargu-selection-provider) "openrouter"))
            (should (equal (kargu-selection-model) "kept-model"))
            (should (eq (kargu-state-provider) 'openrouter))
            (should (equal (kargu-state-model) "kept-model")))
          (should-not (kargu-selection-provider))
          (should-not (kargu-selection-model)))
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
        (kargu-test-with-session-bridge
          (with-current-buffer bufA
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root (file-name-as-directory projA))
            (setq-local kargu-chat--session-id "session-A")
            (setq-local kargu-chat--session-title "Session in ProjA")
            (setf (kargu-history-messages) '((("role" . "user") ("content" . "In Proj A"))))
            (let ((inhibit-read-only t))
              (insert "Turn A\n"))
            (kargu-test-session--save bufA))

          (with-current-buffer bufB
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root (file-name-as-directory projB))
            (setq-local kargu-chat--session-id "session-B")
            (setq-local kargu-chat--session-title "Session in ProjB")
            (setf (kargu-history-messages) '((("role" . "user") ("content" . "In Proj B"))))
            (let ((inhibit-read-only t))
              (insert "Turn B\n"))
            (kargu-test-session--save bufB))

          ;; Verify Proj A sessions
          (let ((sessionsA (kargu-test-session--list projA)))
            (should (= (length sessionsA) 1))
            (should (equal (kargu-aget (car sessionsA) "id") "session-A")))

          ;; Verify Proj B sessions
          (let ((sessionsB (kargu-test-session--list projB)))
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
        (kargu-test-with-session-bridge
          ;; Create and save a session
          (with-current-buffer buf-init
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root proj-root)
            (setq-local kargu-chat--session-id "auto-restore-001")
            (setq-local kargu-chat--session-title "Auto Restore Session")
            (setf (kargu-history-messages) '((("role" . "user") ("content" . "Persistent query"))))
            (let ((inhibit-read-only t))
              (insert "## you · 10:00\nPersistent query\n"))
            (kargu-test-session--save buf-init))
          ;; Kill all live chat buffers
          (dolist (b (kargu-chat-list-buffers))
            (kill-buffer b))
          (when (get-buffer kargu-chat-buffer-name)
            (kill-buffer (get-buffer kargu-chat-buffer-name)))

          ;; Call kargu-chat--buffer for this project
          (let ((chat-buf (kargu-chat--buffer proj-root)))
            (should (buffer-live-p chat-buf))
            ;; The buffer opens at once; the newest native session restores into it.
            (kargu-bridge-test--wait
             (lambda () (equal (buffer-local-value 'kargu-chat--session-id chat-buf)
                               "auto-restore-001")))
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
        (kargu-test-with-session-bridge
          (with-current-buffer buf
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root proj-root)
            (setq-local kargu-chat--session-id "del-001")
            (setf (kargu-history-messages) '((("role" . "user") ("content" . "To be deleted"))))
            (let ((inhibit-read-only t))
              (insert "To be deleted\n"))
            (kargu-test-session--save buf))
          (should (= (length (kargu-test-session--list proj-root)) 1))
          (should-not (cadr (kargu-test-session--await
                             (lambda (done) (kargu-session-delete "del-001" proj-root done)))))
          (should (= (length (kargu-test-session--list proj-root)) 0)))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory temp-dir t)
      (delete-directory proj t))))

(ert-deftest kargu-chat-fresh-footer-ignores-live-selection-test ()
  "An unsaved chat shows empty provider and model slots."
  (let ((kargu-session--context
         (kargu-test-session-with-history :provider "cerebras" :model "llama3.1-70b"))

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

(ert-deftest kargu-chat-fresh-selection-does-not-clear-another-owner-test ()
  "Showing an unselected chat cannot clear another owner's explicit choice."
  (let ((kargu-session--context
         (kargu-test-session-with-history :provider "cerebras" :model "llama3.1-70b"))

        (buf (get-buffer-create "*kargu-activate-clear*")))
    (unwind-protect
        (progn
          (kargu-state-set-provider 'cerebras)
          (kargu-state-set-model "llama3.1-70b")
          (with-current-buffer buf
            (kargu-chat-mode)
            (should-not (kargu-selection-provider))
            (should-not (kargu-selection-model)))
          (should (equal (kargu-selection-provider) "cerebras"))
          (should (equal (kargu-selection-model) "llama3.1-70b")))
      (when (buffer-live-p buf) (kill-buffer buf))
      (setf (kargu-selection-provider) nil
            (kargu-selection-model) nil)
      (kargu-state-reset))))

(ert-deftest kargu-chat-fresh-selection-ignores-config-fallback-test ()
  "A fresh session's explicit choice never copies resolved configuration."
  (let ((kargu-session--context
         (kargu-test-session-with-history :provider nil :model nil))

        (buf (get-buffer-create "*kargu-note-empty*")))
    (unwind-protect
        (with-current-buffer buf
          (kargu-chat-mode)
          (kargu-test-config-publish (kargu-config-service-context)
                                     '(:provider "fallback" :model "fallback-model") "/fixture" "fallback")
          (should (equal (kargu--provider-name) "fallback"))
          (should (equal (kargu--model) "fallback-model"))
          (should-not (kargu-selection-provider))
          (should-not (kargu-selection-model)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest kargu-session-save-omits-unselected-provider-test ()
  "A chat that never chose a provider saves empty provider and model."
  (let* ((temp-dir (make-temp-file "kargu-test-sessions-empty-" t))
         (kargu-sessions-directory temp-dir)
         (proj (make-temp-file "kargu-proj-empty-" t))
         (proj-root (file-name-as-directory proj))
         (kargu-session--context
          (kargu-test-session-with-history :provider "cerebras" :model "llama3.1-70b"))

         (buf (get-buffer-create "*kargu-save-empty*")))
    (unwind-protect
        (kargu-test-with-session-bridge
          (with-current-buffer buf
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root proj-root)
            (setq-local kargu-chat--session-id "empty-selection")
            (setf (kargu-selection-provider) nil)
            (setf (kargu-selection-model) nil)
            (setf (kargu-history-messages)
                  '((("role" . "user") ("content" . "unsaved choice"))))
            ;; Save from another buffer so note-selection does not copy the live fallback.
            (with-temp-buffer
              (kargu-test-session--save buf)))
          (let ((saved (car (kargu-test-session--list proj-root))))
            ;; An unselected choice is absent, not an empty string.
            (should-not (stringp (kargu-aget saved "provider")))
            (should-not (stringp (kargu-aget saved "model")))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory temp-dir t)
      (delete-directory proj t))))

(ert-deftest kargu-chat-selection-chain-ends-at-prompt-test ()
  "Provider selection leaves the model empty, then a model choice lands in the prompt."
  (let ((kargu-session--context
         (kargu-test-session-with-history :provider nil :model "llama3.1-70b"))

        (kargu-reasoning-effort 'low)
        (opened nil)
        (buf (get-buffer-create "*kargu-chain-prompt*")))
    (unwind-protect
        (with-current-buffer buf
          (kargu-chat-mode)
          (kargu-chat--ensure-idle-prompt)
          (goto-char (point-min))
          (cl-letf (((symbol-function 'kargu-set-provider)
                     (lambda (name &optional no-model callback)
                       (setf (kargu-selection-provider) name
                             (kargu-selection-model) (unless no-model "from-provider"))
                       (funcall callback (kargu-ok (kargu-selection-context)))))
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
            (should (equal (kargu-selection-provider) "groq"))
            (should-not (kargu-selection-model))
            (should (equal (kargu-selection-provider) "groq"))
            (should-not (kargu-selection-model))
            (kargu-api-select--apply-model "chosen-model" "groq")
            (should (kargu-chat--in-input-p))
            (should (= (point) (marker-position kargu-chat--prompt-marker)))
            (kargu-api-select--apply-effort "off")
            (should (kargu-chat--in-input-p))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (setf (kargu-selection-provider) nil
            (kargu-selection-model) nil)
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
          (setf (kargu-selection-provider) "opencode")
          (setf (kargu-selection-model) "chosen-model")
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

(ert-deftest kargu-session-list-metadata-and-deterministic-tie-break-test ()
  "Listing returns metadata without conversation and breaks timestamp ties by id."
  (let* ((temp-dir (make-temp-file "kargu-test-sessions-meta-" t))
         (kargu-sessions-directory temp-dir)
         (proj (make-temp-file "kargu-proj-meta-" t))
         (proj-root (file-name-as-directory proj))
         (dir (kargu-session-storage-directory proj-root)))
    (unwind-protect
        (progn
          (make-directory dir t)
          (dolist (sid '("session-a" "session-c" "session-b"))
            (kargu-session-storage-write
             sid proj-root
             `(("schema_version" . 2)
               ("effort" . (("kind" . "inherit")))
               ("id" . ,sid)
               ("project_root" . ,proj-root)
               ("title" . ,(concat "Title " sid))
               ("updated_at" . "2026-10-21 12:00:00")
               ("mode" . "ask")
               ("provider" . "openai")
               ("model" . "gpt-4o")
               ("message_count" . 2)
               ("transcript" . "large transcript body")
               ("messages" . [(("role" . "user") ("content" . "hello"))
                              (("role" . "assistant") ("content" . "world"))]))))
          ;; Write corrupted and mismatched-id files that must be skipped
          (write-region "{corrupt" nil (expand-file-name "broken.json" dir))
          (kargu-session-storage-write
           "mismatch" proj-root '(("id" . "other-id") ("updated_at" . "2026-10-21 13:00:00")))
          (let ((sessions (kargu-test-session--list proj-root)))
            (should (equal (mapcar (lambda (s) (kargu-aget s "id")) sessions)
                           '("session-c" "session-b" "session-a")))
            (dolist (s sessions)
              (should (kargu-session-metadata-p s))
              (should (= (kargu-aget s "message_count") 2))
              (should-not (kargu-aget s "messages"))
              (should-not (kargu-aget s "transcript")))
            ;; Restoring from a metadata entry loads the full conversation on demand
            (let ((buf (get-buffer-create "*kargu-meta-restore*")))
              (unwind-protect
                  (with-current-buffer buf
                    (kargu-chat-mode)
                    (setq-local kargu-chat--project-root proj-root)
                    (should-not (cadr (kargu-test-session--load (car sessions) buf proj-root)))
                    (should (equal kargu-chat--session-id "session-c"))
                    (should (= (length (kargu-history-messages)) 2))
                    (should (string-match-p "large transcript body" (buffer-string))))
                (when (buffer-live-p buf) (kill-buffer buf))))))
      (delete-directory temp-dir t)
      (delete-directory proj t))))

(ert-deftest kargu-session-list-async-worker-cancel-and-stale-owner-test ()
  "Async session listing runs in the worker, supports cancel and drops stale owners."
  (let* ((temp-dir (make-temp-file "kargu-test-sessions-async-" t))
         (kargu-sessions-directory temp-dir)
         (proj (make-temp-file "kargu-proj-async-" t))
         (proj-root (file-name-as-directory proj))
         (other (make-temp-file "kargu-proj-other-" t))
         (other-root (file-name-as-directory other))
         (buf (get-buffer-create "*kargu-async-list*")))
    (unwind-protect
        (with-current-buffer buf
          (kargu-chat-mode)
          (setq-local kargu-chat--project-root proj-root)
          (kargu-session-storage-write
           "s-1" proj-root
           `(("schema_version" . 2) ("effort" . (("kind" . "inherit"))) ("id" . "s-1")
             ("title" . "Async 1") ("updated_at" . "2026-10-21 10:00:00")
             ("messages" . [(("role" . "user") ("content" . "hi"))])))
          ;; 1. Successful async worker listing
          (let (done-sessions done-err finished)
            (kargu-session-list-async
             proj-root
             (lambda (sessions err)
               (setq done-sessions sessions done-err err finished t))
             buf)
            (let ((deadline (+ (float-time) 10.0)))
              (while (and (not finished) (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should finished)
            (should-not done-err)
            (should (= (length done-sessions) 1))
            (should (equal (kargu-aget (car done-sessions) "id") "s-1"))
            (should (= (kargu-aget (car done-sessions) "message_count") 1))
            (should-not (kargu-aget (car done-sessions) "messages")))
          ;; 2. Cancellation suppresses delivery
          (let (called)
            (let ((task (kargu-session-list-async
                         proj-root (lambda (&rest _) (setq called t)) buf)))
              (kargu-async-cancel task)
              (accept-process-output nil 0.1)
              (should-not called)))
          ;; 3. Project root change before completion suppresses stale callback
          (let (called)
            (kargu-session-list-async
             proj-root (lambda (&rest _) (setq called t)) buf)
            (setq-local kargu-chat--project-root other-root)
            (accept-process-output nil 0.2)
            (should-not called)))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory temp-dir t)
      (delete-directory proj t)
      (delete-directory other t))))

(ert-deftest kargu-session-reset-is-scoped-to-target-session-test ()
  "Resetting an idle chat buffer does not stop or reset a foreign active chat run."
  (let ((buf-a (get-buffer-create "*kargu-reset-scope-a*"))
        (buf-b (get-buffer-create "*kargu-reset-scope-b*"))
        (stop-called nil)
        (circuit-reset-called nil))
    (unwind-protect
        (kargu-test-with-session-bridge
          (with-current-buffer buf-a
            (kargu-chat-mode)
            (kargu-history-append '(("role" . "user") ("content" . "keep me")))
            (kargu-session-record-usage 50 25))
          (with-current-buffer buf-b
            (kargu-chat-mode)
            (kargu-history-append '(("role" . "user") ("content" . "discard me")))
            (kargu-session-record-usage 10 5))
          (let ((run-a (with-current-buffer buf-a
                         (list :id "run-a"
                               :chat-buffer buf-a
                               :session (kargu-session-context buf-a)
                               :state 'wait))))
            (kargu-application-set-active-run run-a)
            (kargu-state-transition-status :waiting-model)
            (cl-letf (((symbol-function 'kargu-loop-stop)
                       (lambda (&rest _) (setq stop-called t)))
                      ((symbol-function 'kargu-circuit-reset)
                       (lambda () (setq circuit-reset-called t))))
              (with-current-buffer buf-b
                (kargu-session-reset)))
            ;; Chat A's run, history, usage and status are untouched
            (should-not stop-called)
            (should-not circuit-reset-called)
            (should (eq (kargu-application-current-run) run-a))
            (should (eq (kargu-state-status) :waiting-model))
            (with-current-buffer buf-a
              (should (= (length (kargu-history-messages)) 1))
              (should (equal (kargu-state-tokens)
                             '(:prompt 50 :completion 25 :total 75))))
            ;; Chat B's history and usage were reset
            (with-current-buffer buf-b
              (should (null (kargu-history-messages)))
              (should (equal (kargu-state-tokens)
                             '(:prompt 0 :completion 0 :total 0))))))
      (kargu-application-set-active-run nil)
      (when (buffer-live-p buf-a) (kill-buffer buf-a))
      (when (buffer-live-p buf-b) (kill-buffer buf-b)))))

(ert-deftest kargu-session-project-budget-invariants-test ()
  "Native budget projections advance counters monotonically and reject decrement."
  (let* ((session (kargu-session-create :id-value "test-mon-001"
                                        :usage-value (list :requests 0)))
         (snap1 (let ((ht (make-hash-table :test #'equal)))
                  (puthash "requests_spent" 3 ht)
                  (puthash "compactions_spent" 1 ht)
                  (puthash "tokens_spent" 250 ht)
                  (puthash "tokens_unknown" :json-false ht)
                  (puthash "monetary_spent" 1500 ht)
                  (puthash "monetary_unknown" :json-false ht)
                  ht))
         (snap2 (let ((ht (make-hash-table :test #'equal)))
                  (puthash "requests_spent" 1 ht)
                  (puthash "compactions_spent" 0 ht)
                  (puthash "tokens_spent" 100 ht)
                  (puthash "tokens_unknown" :json-false ht)
                  (puthash "monetary_spent" 500 ht)
                  (puthash "monetary_unknown" :json-false ht)
                  ht))
         (snap3 (let ((ht (make-hash-table :test #'equal)))
                  (puthash "requests_spent" 5 ht)
                  (puthash "compactions_spent" 2 ht)
                  (puthash "tokens_spent" 600 ht)
                  (puthash "tokens_unknown" t ht)
                  (puthash "monetary_spent" 3000 ht)
                  (puthash "monetary_unknown" t ht)
                  ht)))
    ;; Install snap1
    (kargu-session-project-budget snap1 session)
    (let ((usage (kargu-session-usage-value session)))
      (should (= (plist-get usage :requests-spent) 3))
      (should (= (plist-get usage :compactions-spent) 1))
      (should (= (plist-get usage :tokens-spent) 250))
      (should (= (plist-get usage :monetary-spent) 1500))
      (should-not (plist-get usage :tokens-unknown))
      (should-not (plist-get usage :monetary-unknown)))
    ;; An older reply (snap2) cannot decrement counters
    (kargu-session-project-budget snap2 session)
    (let ((usage (kargu-session-usage-value session)))
      (should (= (plist-get usage :requests-spent) 3))
      (should (= (plist-get usage :compactions-spent) 1))
      (should (= (plist-get usage :tokens-spent) 250))
      (should (= (plist-get usage :monetary-spent) 1500)))
    ;; Further advance with unknown usage (snap3)
    (kargu-session-project-budget snap3 session)
    (let ((usage (kargu-session-usage-value session)))
      (should (= (plist-get usage :requests-spent) 5))
      (should (= (plist-get usage :compactions-spent) 2))
      (should (= (plist-get usage :tokens-spent) 600))
      (should (= (plist-get usage :monetary-spent) 3000))
      (should (eq (plist-get usage :tokens-unknown) t))
      (should (eq (plist-get usage :monetary-unknown) t)))))

(ert-deftest kargu-session-usage-and-context-info-preserves-unknown-test ()
  "Missing token or pricing usage displays unknown and never zero."
  (let* ((session (kargu-session-create :id-value "test-unk-001"
                                        :usage-value (list :requests 0
                                                           :tokens-unknown t
                                                           :monetary-unknown t)))
         (report (kargu-session-usage session))
         (ctx (kargu-session-context-info session)))
    (should (string-search "tokens-in: unknown" report))
    (should (string-search "tokens-out: unknown" report))
    (should (equal (plist-get ctx :used) "unknown"))
    (should-not (plist-get ctx :percent))
    (should (string-search "unknown" (plist-get ctx :formatted)))
    (should-not (string-search "0/0" (plist-get ctx :formatted)))
    (should-not (string-search "0%" (plist-get ctx :formatted)))))

(ert-deftest kargu-session-chat-counters-isolation-test ()
  "Two chat sessions maintain isolated token and spend counters."
  (let* ((sess1 (kargu-session-create :id-value "chat-001"
                                      :usage-value (list :requests 0)))
         (sess2 (kargu-session-create :id-value "chat-002"
                                      :usage-value (list :requests 0))))
    (kargu-session-record-usage 100 50 sess1)
    (kargu-session-record-usage 10 5 sess2)
    (should (= (plist-get (kargu-session-usage-value sess1) :tokens-in) 100))
    (should (= (plist-get (kargu-session-usage-value sess1) :tokens-out) 50))
    (should (= (plist-get (kargu-session-usage-value sess2) :tokens-in) 10))
    (should (= (plist-get (kargu-session-usage-value sess2) :tokens-out) 5))
    ;; Projecting budget into sess1 leaves sess2 untouched
    (let ((snap (let ((ht (make-hash-table :test #'equal)))
                  (puthash "requests_spent" 4 ht)
                  (puthash "tokens_spent" 500 ht)
                  (puthash "monetary_spent" 2000 ht)
                  ht)))
      (kargu-session-project-budget snap sess1)
      (should (= (plist-get (kargu-session-usage-value sess1) :requests-spent) 4))
      (should (= (plist-get (kargu-session-usage-value sess1) :tokens-spent) 500))
      (should-not (plist-get (kargu-session-usage-value sess2) :requests-spent))
      (should (= (plist-get (kargu-session-usage-value sess2) :tokens-spent) 15)))))

(ert-deftest kargu-session-monetary-reserved-and-distinguished-zero-test ()
  "Active reservation is displayed, and known zero is distinct from unknown."
  (let* ((sess-zero (kargu-session-create :id-value "zero-001"
                                          :usage-value (list :requests 1
                                                             :monetary-spent 0
                                                             :monetary-reserved 50
                                                             :monetary-unknown nil)))
         (sess-unk (kargu-session-create :id-value "unk-001"
                                         :usage-value (list :requests 1
                                                            :monetary-spent 0
                                                            :monetary-unknown t)))
         (report-zero (kargu-session-usage sess-zero))
         (report-unk (kargu-session-usage sess-unk)))
    ;; Known zero spend formats as $0.000000, active reservation formats as $0.000050
    (should (string-search "spent: $0.000000" report-zero))
    (should (string-search "reserved: $0.000050" report-zero))
    ;; Unknown spend formats as unknown, never 0 or free
    (should (string-search "spent: unknown" report-unk))
    (should-not (string-search "spent: $0.000000" report-unk))))

(ert-deftest kargu-session-rejects-negative-or-invalid-dto-test ()
  "Negative or invalid DTO projections are rejected without corrupting session."
  (let* ((session (kargu-session-create :id-value "guard-001"
                                        :usage-value (list :requests-spent 2
                                                           :tokens-spent 100
                                                           :monetary-spent 500)))
         (orig (copy-tree (kargu-session-usage-value session))))
    ;; Negative requests_spent
    (let ((bad (make-hash-table :test #'equal)))
      (puthash "requests_spent" -1 bad)
      (should-error (kargu-session-project-budget bad session)))
    (should (equal (kargu-session-usage-value session) orig))

    ;; Negative tokens_spent
    (let ((bad (make-hash-table :test #'equal)))
      (puthash "tokens_spent" -100 bad)
      (should-error (kargu-session-project-budget bad session)))
    (should (equal (kargu-session-usage-value session) orig))

    ;; Negative monetary_spent
    (let ((bad (make-hash-table :test #'equal)))
      (puthash "monetary_spent" -50 bad)
      (should-error (kargu-session-project-budget bad session)))
    (should (equal (kargu-session-usage-value session) orig))

    ;; Negative monetary_reserved
    (let ((bad (make-hash-table :test #'equal)))
      (puthash "monetary_reserved" -10 bad)
      (should-error (kargu-session-project-budget bad session)))
    (should (equal (kargu-session-usage-value session) orig))))

(ert-deftest kargu-session-native-storage-names-a-choice-not-a-directory-test ()
  "Native persistence requests carry the location choice, never a directory."
  (let ((process-environment (cons "XDG_DATA_HOME" process-environment)))
    (let* ((kargu-session-storage-location 'central)
           (kargu-sessions-directory
            (eval (car (get 'kargu-sessions-directory 'standard-value)) t))
           (storage (kargu-session--native-storage "/tmp/kargu-proj/")))
      (should (equal (gethash "location" storage) "central"))
      (should (equal (gethash "project_root" storage) "/tmp/kargu-proj"))
      (should (eq (gethash "xdg_data_home" storage) :json-null))
      (should (equal (gethash "user_emacs_directory" storage)
                     (expand-file-name user-emacs-directory)))
      (should (eq (gethash "sessions_directory" storage) :json-null))
      (should-not (gethash "storage_root" storage)))
    (let* ((kargu-session-storage-location 'central)
           (kargu-sessions-directory "/tmp/kargu-custom-sessions/")
           (storage (kargu-session--native-storage "/tmp/kargu-proj")))
      (should (equal (gethash "sessions_directory" storage)
                     "/tmp/kargu-custom-sessions")))
    (let ((kargu-session-storage-location 'project))
      (should (equal (gethash "location" (kargu-session--native-storage "/tmp/p"))
                     "project")))
    (let ((kargu-session-storage-location 'elsewhere))
      (should-error (kargu-session--native-storage "/tmp/p")))))

(provide 'tests/test-session)
;;; test-session.el ends here
