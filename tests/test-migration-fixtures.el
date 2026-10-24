;;; test-migration-fixtures.el --- Saved migration inputs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Synthetic legacy and schema-v2 sessions, shared with the future Rust importer.
;; No user session is opened or rewritten.

;;; Code:

(require 'ert)
(require 'kargu/chat/session/validate)
(require 'kargu/json)

(ert-deftest kargu-migration-session-fixtures-preserve-legacy-and-off-test ()
  "Validate shared fixtures without mutating the original decoded record."
  (dolist (name '("session-legacy.json" "session-v2.json"))
    (let* ((file (expand-file-name (concat "kargu-core/tests/fixtures/" name)
                                   (file-name-directory (locate-library "kargu"))))
           (record (with-temp-buffer
                     (insert-file-contents file)
                     (kargu-json-decode (buffer-string))))
           (before (json-serialize record :null-object :json-null :false-object :json-false))
           (validated (kargu-session-validate record)))
      (should (= (gethash "schema_version" validated) 2))
      (should (equal before (json-serialize record :null-object :json-null :false-object :json-false)))
      (should (equal (gethash "tokens_in" validated) (gethash "tokens_in" record)))
      (should (equal (json-serialize (gethash "messages" validated)
                                     :null-object :json-null :false-object :json-false)
                     (json-serialize (gethash "messages" record)
                                     :null-object :json-null :false-object :json-false)))
      (should (equal (gethash "kind" (gethash "effort" validated))
                     (if (equal name "session-legacy.json") "inherit" "off"))))))

(provide 'tests/test-migration-fixtures)
;;; test-migration-fixtures.el ends here
