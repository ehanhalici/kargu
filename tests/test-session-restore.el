;;; test-session-restore.el --- Transactional restoration tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Valid records may still fail during preparation.  No partial session or
;; view may escape, and delayed completion cannot overwrite a newer draft.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu/chat)

(defconst kargu-session-restore-test--data
  '(("id" . "restored") ("mode" . "plan") ("provider" . "new-provider")
    ("model" . "new-model") ("transcript" . "new transcript\n")
    ("requests" . 4) ("tokens_in" . 30) ("tokens_out" . 20)
    ("messages" . [(("role" . "user") ("content" . "new message"))]))
  "Valid legacy record used by publication regression tests.")

(defmacro kargu-session-restore-test--with-chat (&rest body)
  "Run BODY in an initialized chat containing an unsent draft."
  (declare (indent 0))
  `(with-temp-buffer
     (let ((kargu-session-auto-save nil)
           (kargu-state-before-mode-change-hook nil))
       (cl-letf (((symbol-function 'kargu-api-prefetch-models) #'ignore))
         (kargu-chat-mode))
       (insert "old transcript\n")
       (kargu-chat--ensure-idle-prompt)
       (insert "unsent draft")
       (kargu-state-set-mode 'agent)
       ,@body)))

(ert-deftest kargu-session-restore-preparation-failures-are-atomic-test ()
  "Render and footer failures preserve text, owner, draft and marker identity."
  (dolist (function '(kargu-session--render-restored-transcript
                     kargu-chat--ensure-idle-prompt))
    (kargu-session-restore-test--with-chat
      (let ((owner (kargu-session-context)) (text (buffer-string))
            (output kargu-chat--output-marker) (prompt kargu-chat--prompt-marker)
            (position (point)) events)
        (narrow-to-region 3 (1- (point-max)))
        (goto-char 5)
        (let ((maximum (point-max))
              (kargu-state-change-hook (list (lambda (&rest args) (push args events)))))
          (cl-letf (((symbol-function function) (lambda (&rest _) (error "Injected failure"))))
            (should-error (kargu-session-load kargu-session-restore-test--data
                                              (current-buffer) default-directory)))
          (should (eq owner (kargu-session-context)))
          (should (eq (kargu-state-mode) 'agent))
          (should (= (point) 5))
          (should (= (point-min) 3))
          (should (= (point-max) maximum))
          (should (eq output kargu-chat--output-marker))
          (should (eq prompt kargu-chat--prompt-marker))
          (should (= (marker-position prompt) (- position (length "unsent draft"))))
          (should-not events)
          (widen)
          (should (equal-including-properties (buffer-string) text)))))))

(ert-deftest kargu-session-restore-publication-error-restores-local-state-test ()
  "A failure after installation restores locals, undo, markers and narrowing."
  (kargu-session-restore-test--with-chat
    (let ((owner (kargu-session-context)) (text (buffer-string))
          (output kargu-chat--output-marker) (prompt kargu-chat--prompt-marker)
          (output-position (marker-position kargu-chat--output-marker))
          (prompt-position (marker-position kargu-chat--prompt-marker))
          (install (symbol-function 'kargu-session-restore--install)))
      (set-mark 3)
      (narrow-to-region 2 8)
      (goto-char 4)
      (let ((undo buffer-undo-list))
        (cl-letf (((symbol-function 'kargu-session-restore--install)
                   (lambda (operation) (funcall install operation) (error "Publish failure"))))
          (should-error (kargu-session-load kargu-session-restore-test--data
                                            (current-buffer) default-directory)))
        (should (eq buffer-undo-list undo)))
      (should (eq owner (kargu-session-context)))
      (should (eq (kargu-state-mode) 'agent))
      (should (eq output kargu-chat--output-marker))
      (should (eq prompt kargu-chat--prompt-marker))
      (should (= output-position (marker-position output)))
      (should (= prompt-position (marker-position prompt)))
      (should (= (point) 4))
      (should (= (mark) 3))
      (should (= (point-min) 2))
      (should (= (point-max) 8))
      (widen)
      (should (equal-including-properties text (buffer-string))))))

(ert-deftest kargu-session-restore-success-publishes-complete-narrowed-view-test ()
  "A narrowed target is wholly replaced before any selection observer runs."
  (kargu-session-restore-test--with-chat
    (let (events
          (kargu-state-change-hook nil))
      (setq kargu-state-change-hook
            (list (lambda (key _value)
                    (push key events)
                    (should (equal (kargu-session-id) "restored"))
                    (should (equal (kargu-selection-model) "new-model"))
                    (should (eq (kargu-state-mode) 'plan))
                    (should (= (plist-get (kargu-session-snapshot) :tokens-in) 30))
                    (should (string-search "new transcript" (buffer-string)))
                    (should (kargu-chat--prompt-live-p)))))
      (narrow-to-region 2 6)
      (should (eq (kargu-session-load kargu-session-restore-test--data
                                      (current-buffer) default-directory)
                  (current-buffer)))
      (should (= (point-min) 1))
      (should-not (string-search "old transcript" (buffer-string)))
      (should (equal (kargu-chat--input-text) ""))
      (should (memq :mode events)))))

(ert-deftest kargu-session-restore-held-preparation-cannot-overwrite-newer-intent-test ()
  "Edits, selection/root changes, Stop and replacement invalidate restore."
  (dolist (case '(edit selection root stop replace))
    (kargu-session-restore-test--with-chat
      (let* (ready result
             (kargu-mode-prepare-functions
              `((plan . ,(lambda (success _failure) (setq ready success)))))
             (task (kargu-session-load
                    kargu-session-restore-test--data (current-buffer) default-directory
                    :callback (lambda (buffer error) (push (list buffer error) result)))))
        (should (kargu-async-pending-p task))
        (pcase case
          ('edit (insert "newer draft"))
          ('selection (kargu-selection-update :model "newer-model"))
          ('root (setq kargu-chat--project-root "/another/project/"))
          ('stop (kargu-chat-stop))
          ('replace (kargu-session-clear)))
        (let ((owner (kargu-session-context)) (text (buffer-string)))
          (with-temp-buffer (funcall ready) (funcall ready))
          (should (eq owner (kargu-session-context)))
          (should (equal-including-properties text (buffer-string)))
          (should (= (length result) 1))
          (should-not (caar result))
          (should (stringp (cadar result)))
          (should-not (kargu-async-pending-p task)))))))

(ert-deftest kargu-session-restore-awaits-mode-and-enters-captured-buffer-test ()
  "Restore waits for real preparation; a foreign-buffer callback cannot redirect it."
  (kargu-session-restore-test--with-chat
    (let* (ready result
           (kargu-mode-prepare-functions
            `((plan . ,(lambda (success _failure) (setq ready success)))))
           (owner (current-buffer)))
      (kargu-session-load kargu-session-restore-test--data owner default-directory
                          :callback (lambda (buffer error) (push (list buffer error) result)))
      (should (eq (kargu-state-mode) 'agent))
      (should-not result)
      (with-temp-buffer
        (funcall ready)
        (funcall ready)
        (should (eq (kargu-state-mode) 'ask)))
      (should (equal result (list (list owner nil))))
      (should (eq (kargu-state-mode) 'plan)))))

(ert-deftest kargu-session-schema-effort-roundtrip-test ()
  "Inherited, off and API values survive the new JSON schema distinctly."
  (dolist (effort (list kargu-selection-default-effort nil 'none 'high))
    (let* ((wire `(("id" . "safe") ("schema_version" . 2)
                   ("effort" . ,(kargu-session-encode-effort effort))))
           (validated (kargu-session-validate wire)))
      (should (eq effort (kargu-session-decode-effort (gethash "effort" validated))))
      (kargu-session-restore-test--with-chat
        (kargu-session-load validated (current-buffer) default-directory)
        (should (eq effort (kargu-selection-effort-value (kargu-selection-context))))))))

(ert-deftest kargu-session-schema-migration-is-pure-and-versioned-test ()
  "Legacy migration neither mutates its input nor accepts unsupported versions."
  (let* ((legacy '(("id" . "safe") ("messages" . [])))
         (copy (copy-tree legacy t))
         (validated (kargu-session-validate legacy)))
    (should (equal legacy copy))
    (should (= (gethash "schema_version" validated) 2))
    (should (eq (kargu-session-decode-effort (gethash "effort" validated))
                kargu-selection-default-effort)))
  (dolist (extra '(("schema_version" . 3) ("schema_version" . "2")
                   ("schema_version" . :json-null)))
    (should-error (kargu-session-validate (list '("id" . "safe") extra)) :type 'user-error))
  (dolist (effort '(nil (("kind" . "value")) (("kind" . "unknown"))
                       (("kind" . "value") ("value" . "nil"))))
    (should-error (kargu-session-validate
                     `(("id" . "safe") ("schema_version" . 2) ("effort" . ,effort)))
                  :type 'user-error)))

(ert-deftest kargu-session-restore-close-cancels-preparation-and-view-test ()
  "Closing the target drains its parent task and offscreen view once."
  (let ((target (generate-new-buffer " *kargu-restore-close*")) ready result task)
    (unwind-protect
        (let ((kargu-session-auto-save nil)
              (kargu-mode-prepare-functions
               `((plan . ,(lambda (success _failure) (setq ready success))))))
          (with-current-buffer target
            (kargu-chat-mode)
            (setq task (kargu-session-load
                        kargu-session-restore-test--data target default-directory
                        :callback (lambda (buffer error) (push (list buffer error) result)))))
          (kill-buffer target)
          (funcall ready)
          (should-not (kargu-async-pending-p task))
          (should (= (length result) 1))
          (should-not (caar result))
          (should (stringp (cadar result)))
          (should-not (cl-find-if
                       (lambda (buffer)
                         (string-prefix-p " *kargu-session-restore*" (buffer-name buffer)))
                       (buffer-list))))
      (when (buffer-live-p target) (kill-buffer target)))))

(ert-deftest kargu-session-save-preserves-full-narrowed-transcript-and-effort-test ()
  "Persistence writes schema two and the full transcript, not a narrow slice."
  (kargu-test-with-git-repo nil
    (let ((kargu-sessions-directory (expand-file-name "sessions" repo)))
      (kargu-session-restore-test--with-chat
        (kargu-history-replace '((("role" . "user") ("content" . "save me"))))
        (kargu-selection-update :effort 'none)
        (let ((transcript (kargu-session--extract-transcript (current-buffer))))
          (narrow-to-region 3 9)
          (kargu-session-save)
          (let ((saved (kargu-session-storage-read kargu-chat--session-id repo)))
            (should (= (kargu-aget saved "schema_version") 2))
            (should (equal (kargu-aget saved "transcript") transcript))
            (should (eq (kargu-session-decode-effort
                         (gethash "effort" (kargu-session-validate saved))) 'none)))
          (should (= (point-min) 3))
          (should (= (point-max) 9)))))))

(ert-deftest kargu-session-restore-refuses-standalone-request-before-mutation-test ()
  "Busy native requests refuse restore before target state or text is changed."
  (kargu-session-restore-test--with-chat
    (let ((owner (kargu-session-context)) (text (buffer-string)))
      (cl-letf (((symbol-function 'kargu-busy-p) (lambda () t)))
        (should-error (kargu-session-load kargu-session-restore-test--data
                                          (current-buffer) default-directory)
                      :type 'user-error))
      (should (eq owner (kargu-session-context)))
      (should (equal-including-properties text (buffer-string))))))

(provide 'tests/test-session-restore)
;;; test-session-restore.el ends here
