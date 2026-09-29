;;; tests/test-laws.el --- One named test per contract of skills.md -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; skills.md "Değişiklik disiplini" lists six contracts that must turn a
;; test red when they break.  Each has a test here, named after its letter:
;;
;;   (a) a tool-less model is refused in agent mode and the prompt stays
;;   (b) missing metadata keeps the tools open
;;   (c) an explicit off closes the tools
;;   (d) the protocol wall repairs orphan and half tool calls
;;   (e) a selection rejects text that is not in the list
;;   (f) the session brings back the last provider

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'kargu/core)
(require 'kargu/api)
(require 'kargu/loop)
(require 'kargu/chat)
(require 'kargu/chat/session)

(defmacro kargu-laws--with-catalog (&rest body)
  "Run BODY with an empty metadata table and no recorded refusals."
  (declare (indent 0))
  `(let ((kargu--model-metadata-table (make-hash-table :test 'equal))
         (kargu--tools-refused (make-hash-table :test 'equal)))
     ,@body))

(ert-deftest kargu-law-a-toolless-model-is-refused-and-the-prompt-stays-test ()
  "Agent mode with a model that cannot call tools is refused, the input stays."
  (kargu-laws--with-catalog
    (kargu-test-mode 'agent)
    (kargu-model-set-metadata "no-tools-model" '(("supports_tools" . :json-false)))
    (let ((kargu--session-model "no-tools-model")
          (kargu--loop-run nil)
          (b (get-buffer-create kargu-chat-buffer-name)))
      (unwind-protect
          (with-current-buffer b
            (kargu-chat-mode)
            (setq-local kargu-chat--session-provider "p")
            (setq-local kargu-chat--session-model "no-tools-model")
            (kargu-chat--ensure-prompt)
            (goto-char (point-max))
            (let ((inhibit-read-only t)) (insert "keep this text"))
            (should-error (kargu-loop-require-tools-for-agent) :type 'user-error)
            (cl-letf (((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil)))
              (should-error (kargu-chat--send-input) :type 'user-error))
            (should (kargu-chat--prompt-live-p))
            (should-not (kargu-loop-running-p))
            (should (string-match-p "keep this text" (kargu-chat--input-text))))
        (when (buffer-live-p b) (kill-buffer b))))))

(ert-deftest kargu-law-b-missing-metadata-keeps-tools-open-test ()
  "No metadata at all, or a record without the field, leaves tools on."
  (kargu-laws--with-catalog
    (let ((kargu--loop-run nil))
      (should (kargu-model-supports-tools-p "never-seen"))
      (kargu-model-set-metadata "bare" '(("id" . "bare")))
      (should (kargu-model-supports-tools-p "bare"))
      (let ((kargu--session-model "never-seen"))
        (should (kargu-tools-enabled-p))))))

(ert-deftest kargu-law-c-explicit-off-closes-tools-test ()
  "An explicit off in the metadata, a provider refusal, or a run flag closes tools."
  (kargu-laws--with-catalog
    (let ((kargu--loop-run nil))
      (kargu-model-set-metadata "off" '(("supports_tools" . :json-false)))
      (should-not (kargu-model-supports-tools-p "off"))
      (let ((kargu--session-model "refused-later"))
        (should (kargu-tools-enabled-p))
        (kargu-model-mark-tools-refused "refused-later")
        (should-not (kargu-tools-enabled-p)))
      (let ((kargu--session-model "plain"))
        (should (kargu-tools-enabled-p))
        (should-not (kargu-tools-enabled-p (list :no-tools t)))))))

(ert-deftest kargu-law-d-wall-repairs-orphan-and-half-tool-calls-test ()
  "An orphan result is dropped; a call without its result gets a synthetic one."
  (let ((kargu--message-history
         `((("role" . "system") ("content" . "sys"))
           (("role" . "user") ("content" . "hi"))
           (("role" . "tool") ("tool_call_id" . "orphan") ("name" . "bash")
            ("content" . "no call before me"))
           (("role" . "assistant") ("content" . "")
            ("tool_calls" . [(("id" . "c1") ("type" . "function")
                              ("function" . (("name" . "bash") ("arguments" . "{}"))))
                             (("id" . "c2") ("type" . "function")
                              ("function" . (("name" . "bash") ("arguments" . "{}"))))]))
           (("role" . "tool") ("tool_call_id" . "c1") ("name" . "bash")
            ("content" . "one result only")))))
    (kargu--validate-history)
    (let* ((tool-ids (cl-loop for m in kargu--message-history
                              when (equal (kargu-aget m "role") "tool")
                              collect (kargu-aget m "tool_call_id"))))
      (should-not (member "orphan" tool-ids))
      (should (member "c1" tool-ids))
      (should (member "c2" tool-ids)))
    ;; The user's own text is untouched.
    (should (equal (kargu-aget (nth 1 kargu--message-history) "content") "hi"))))

(ert-deftest kargu-law-e-selection-rejects-text-outside-the-list-test ()
  "Only a member of the candidate list is accepted."
  (let ((kargu--session-model "gpt-4o"))
    (dolist (typed '("not-in-the-list" "flash" ""))
      (cl-letf (((symbol-function 'kargu--completing-read-with-company)
                 (lambda (&rest _) typed))
                ((symbol-function 'kargu-chat-refresh-footer) #'ignore))
        (should-error (kargu-chat-select-model-company
                       '("gpt-4o" "gemini-2.5-flash") nil "mock")
                      :type 'user-error)
        (should (equal kargu--session-model "gpt-4o"))))))

(ert-deftest kargu-law-f-session-brings-back-the-last-provider-test ()
  "A saved session restores the provider and model that were live at save time."
  (let* ((dir (make-temp-file "kargu-law-sessions-" t))
         (proj (make-temp-file "kargu-law-project-" t))
         (kargu-sessions-directory dir)
         (buf (get-buffer-create "*kargu-law-f*"))
         (kargu--session-provider "openrouter")
         (kargu--session-model "last-model"))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (kargu-chat-mode)
            (setq-local kargu-chat--project-root (file-name-as-directory proj))
            (setq-local kargu-chat--session-id "law-f-001")
            (setq-local kargu-chat--session-provider "opencode")
            (setq-local kargu-chat--session-model "stale-model")
            (setq-local kargu-chat--messages
                        '((("role" . "user") ("content" . "remember me"))))
            (let ((inhibit-read-only t)) (insert "## you · 12:00\nremember me\n"))
            (kargu-session-save buf))
          (setq kargu--session-provider nil
                kargu--session-model nil)
          (with-current-buffer buf
            (kargu-session-load "law-f-001" buf proj))
          (should (equal kargu--session-provider "openrouter"))
          (should (equal kargu--session-model "last-model")))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory dir t)
      (delete-directory proj t)
      (kargu-state-reset))))

(provide 'tests/test-laws)
;;; test-laws.el ends here
