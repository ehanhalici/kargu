;;; test-session-validate.el --- Untrusted session input tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Malformed records must fail before restoration changes a draft or state.

;;; Code:

(require 'ert)
(require 'kargu/chat/session)
(require 'tests/test-helpers)

(declare-function kargu-chat-mode "kargu/chat" ())

(ert-deftest kargu-session-validate-rejections-preserve-draft-and-state-test ()
  "Reject malformed fields without touching any existing conversation state."
  (let ((history (copy-tree (kargu-history-messages)))
        (counters (kargu-session-snapshot))
        (state (copy-tree kargu--state-store))
        (provider kargu--session-provider)
        (model kargu--session-model))
    (with-temp-buffer
      (insert "existing transcript and unsent draft")
      (setq-local kargu-chat--session-id "existing")
      (narrow-to-region 5 16)
      (goto-char 9)
      (dolist (field '(("transcript" . 12) ("messages" . "wrong")
                       ("messages" . :json-null) ("requests" . -1)
                       ("tokens_in" . 1.5) ("tokens_out" . "10")
                       ("provider" . []) ("model" . :json-null)
                       ("title" . []) ("created_at" . 4)
                       ("updated_at" . []) ("mode" . "unknown")
                       ("messages" . [(("role" . "unknown"))])
                       ("messages" . [(("role" . "user") ("content" . 2))])
                       ("messages" . [(("role" . "tool") ("content" . "x"))])
                       ("messages" . [(("role" . "assistant") ("tool_calls" . "bad"))])
                       ("messages" . [(("role" . "assistant") ("tool_calls" . [3]))])))
        (should-error (kargu-session-load (list '("id" . "safe") field)
                                          (current-buffer) default-directory)
                      :type 'user-error)
        (should (equal kargu-chat--session-id "existing"))
        (should (= (point) 9))
        (should (= (point-min) 5))
        (should (= (point-max) 16))
        (save-restriction
          (widen)
          (should (equal (buffer-string) "existing transcript and unsent draft")))))
    (should (equal (kargu-history-messages) history))
    (should (equal (kargu-session-snapshot) counters))
    (should (equal kargu--state-store state))
    (should (equal kargu--session-provider provider))
    (should (equal kargu--session-model model))))

(ert-deftest kargu-session-validate-copies-native-and-wire-records-test ()
  "Legacy records and typed JSON retain Unicode, nulls and tool-call arrays."
  (let* ((data '(("id" . "safe") ("transcript" . "ğ — transcript")
                 ("mode" . "ask") ("tokens_in" . 12)
                 ("extension" . (("enabled" . :json-false)))
                 ("messages" . [(("role" . "assistant") ("content" . :json-null)
                                  ("tool_calls" . ((("id" . "call-1") ("type" . "function")
                                                     ("function" . (("name" . "read_file")
                                                                     ("arguments" . "{}")))))))
                                 (("role" . "tool") ("tool_call_id" . "call-1")
                                  ("content" . "result"))])))
         (validated (kargu-session-validate data))
         (second (kargu-session-validate validated)))
    (should (equal (gethash "transcript" validated) "ğ — transcript"))
    (should (eq (kargu-aget (gethash "extension" validated) "enabled") :json-false))
    (should (= (length (gethash "messages" validated)) 2))
    (puthash "transcript" "changed by caller" validated)
    (should (equal (gethash "transcript" second) "ğ — transcript"))))

(ert-deftest kargu-session-validate-bounds-cycles-and-extensions-test ()
  "Reject deep, cyclic, oversized and non-JSON data before encoding it."
  (let ((cycle (make-hash-table :test #'equal))
        (circular (list '("id" . "safe")))
        (deep "leaf"))
    (puthash "cycle" cycle cycle)
    (setcdr circular circular)
    (dotimes (_ 40) (setq deep (vector deep)))
    (dolist (value (list cycle circular
                         (list '("id" . "safe") (cons "extension" deep))
                         '(("id" . "safe") ("extension" . unsupported-symbol))
                         '(("id" . "safe") ("id" . "duplicate"))))
      (should-error (kargu-session-validate value)))
    (let ((kargu-session-max-file-bytes 32))
      (should-error (kargu-session-validate
                     `(("id" . "safe") ("transcript" . ,(make-string 64 ?ğ))))
                    :type 'user-error))))

(ert-deftest kargu-session-validate-tool-functions-checked-test ()
  "Reject malformed tool functions while allowing an empty conversation."
  (should (hash-table-p (kargu-session-validate '(("id" . "safe") ("messages" . [])))))
  (dolist (call '((("id" . "x") ("type" . "function") ("function" . "bad"))
                  (("id" . "x") ("type" . "function")
                   ("function" . (("name" . "read_file") ("arguments" . []))))
                  (("id" . "") ("type" . "function")
                   ("function" . (("name" . "read_file") ("arguments" . "{}"))))))
    (should-error
     (kargu-session-validate
      `(("id" . "safe")
        ("messages" . ,(vector `(("role" . "assistant") ("tool_calls" . ,(vector call)))))))
     :type 'user-error)))

(ert-deftest kargu-session-load-refuses-mismatched-file-identity-test ()
  "A misleading record cannot redirect later saves to another session file."
  (kargu-test-with-git-repo nil
    (let ((kargu-sessions-directory (expand-file-name "central" repo))
          (kargu-session-storage-location 'central))
      (kargu-session-storage-write "safe" repo '(("id" . "other")))
      (with-temp-buffer
        (insert "keep my draft")
        (should-error (kargu-session-load "safe" (current-buffer) repo) :type 'user-error)
        (should (equal (buffer-string) "keep my draft"))))))

(ert-deftest kargu-session-load-clears-stale-buffer-selection-test ()
  "Loading an unselected session clears both the footer and live selection."
  (with-temp-buffer
    (kargu-chat-mode)
    (setq kargu-chat--session-provider "previous-provider"
          kargu-chat--session-model "previous-model")
    (kargu-session-load '(("id" . "blank") ("provider" . " ")
                          ("model" . "") ("messages" . []))
                        (current-buffer) default-directory)
    (should-not kargu-chat--session-provider)
    (should-not kargu-chat--session-model)
    (should-not kargu--session-provider)
    (should-not kargu--session-model)
    (should-not (kargu-state-provider))
    (should-not (kargu-state-model))))

(ert-deftest kargu-session-load-preserves-typed-content-blocks-test ()
  "Restoring a multimodal conversation preserves text and opaque attachments."
  (let* ((blocks [(("type" . "text") ("text" . "ğ prompt"))
                  (("type" . "image_url")
                   ("image_url" . (("url" . "data:image/png;base64,AAAA"))))])
         (data `(("id" . "attachments") ("messages" .
                  ,(vector `(("role" . "user") ("content" . ,blocks)))))))
    (with-temp-buffer
      (kargu-session-load data (current-buffer) default-directory)
      (let ((restored (kargu-aget (car (kargu-history-messages)) "content")))
        (should (vectorp restored))
        (should (equal (kargu-aget (aref restored 0) "text") "ğ prompt"))
        (should (equal (kargu-aget (kargu-aget (aref restored 1) "image_url") "url")
                       "data:image/png;base64,AAAA")))))
  (dolist (blocks '([42] [(("type" . "text") ("text" . 42))] [(("type" . ""))]))
    (should-error (kargu-session-validate
                   `(("id" . "invalid")
                     ("messages" . ,(vector `(("role" . "user") ("content" . ,blocks))))))
                  :type 'user-error)))

(provide 'tests/test-session-validate)
;;; test-session-validate.el ends here
