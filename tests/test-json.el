;;; test-json.el --- Typed JSON boundary tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Objects, arrays and scalars retain their wire identity.

;;; Code:

(require 'ert)
(require 'kargu/json)

(ert-deftest kargu-json-empty-values-retain-wire-types-test ()
  "Empty containers, null and false have distinct representations."
  (dolist (wire '("{}" "[]" "null" "false" "true"))
    (should (equal (kargu--json-encode (kargu--json-decode wire)) wire)))
  (should (hash-table-p (kargu--json-decode "{}")))
  (should (vectorp (kargu--json-decode "[]"))))

(ert-deftest kargu-json-nested-matrices-retain-arrays-test ()
  "String matrices cannot become objects during a round trip."
  (dolist (wire '("[[\"a\",\"b\"],[\"c\",\"d\"]]"
                  "{\"rows\":[[\"a\",\"b\"],[],{}]}"))
    (should (equal (kargu--json-encode (kargu--json-decode wire)) wire))))

(ert-deftest kargu-json-native-serializer-preserves-unicode-text-test ()
  "The serializer returns text, not UTF-8 bytes disguised as characters."
  (let* ((text "Türkçe, 日本語, 🙂")
         (wire (kargu--json-encode (vector text))))
    (should (multibyte-string-p wire))
    (should (equal wire (concat "[\"" text "\"]")))
    (with-temp-buffer
      (insert wire)
      (should (equal (aref (kargu--json-decode (buffer-string)) 0) text)))))

(ert-deftest kargu-json-encoding-refuses-ambiguous-lists-test ()
  "The wire encoder requires explicit objects and arrays."
  (should-error (kargu--json-encode '(("a" "b") ("c" "d"))))
  (should-error (kargu--json-encode '(("a" . "b"))))
  (should (equal (kargu--json-encode [["a" "b"] ["c" "d"]])
                 "[[\"a\",\"b\"],[\"c\",\"d\"]]")))

(ert-deftest kargu-json-native-record-conversion-is-explicit-test ()
  "Native records convert at the adapter without changing array identity."
  (let* ((wire "{\"content\":[{\"text\":\"ok\"}],\"args\":{},\"rows\":[[\"a\",\"b\"]]}")
         (typed (kargu--json-decode wire))
         (record (kargu-json-to-record typed)))
    (should (listp record))
    (should (vectorp (kargu-aget record "rows")))
    (should (hash-table-p (kargu-aget record "args")))
    (should (equal (kargu-json-encode-record record) wire))
    (setcdr (assoc "content" record) [])
    (should (= (length (gethash "content" typed)) 1))))

(ert-deftest kargu-json-reader-does-not-intern-untrusted-keys-test ()
  "Wire object keys remain strings without creating Lisp symbols."
  (let ((key (format "kargu-json-untrusted-%s" (make-temp-name "key"))))
    (should-not (intern-soft key))
    (should (hash-table-p (kargu--json-decode (format "{\"%s\":{}}" key))))
    (should-not (intern-soft key))))

(ert-deftest kargu-json-codec-rejects-deep-and-circular-values-test ()
  "Encoding malformed values fails rather than rewriting their meaning."
  (let ((object (make-hash-table :test #'equal)))
    (puthash "self" object object)
    (should-error (kargu--json-encode object)))
  (let ((object (make-hash-table :test #'eq)))
    (puthash 'not-a-string t object)
    (should-error (kargu--json-encode object))))

(ert-deftest kargu-json-tool-arguments-retain-nested-wire-types-test ()
  "Tool arguments preserve empty objects and nested string arrays."
  (require 'kargu/api/tools)
  (let ((wire "{\"options\":{},\"rows\":[[\"a\",\"b\"],[\"c\",\"d\"]]}"))
    (should (equal (kargu--encode-tool-arguments wire) wire))
    (should (hash-table-p (kargu-aget (kargu--decode-tool-arguments wire) "options"))))
  (should (equal (kargu--encode-tool-arguments "[]") "{}")))

(ert-deftest kargu-json-native-response-conversion-does-not-mutate-wire-test ()
  "Tool-call normalization owns its native record, not the decoded reply."
  (require 'kargu/api/tool-calls)
  (let* ((response (kargu--json-decode
                    "{\"choices\":[{\"message\":{\"tool_calls\":[{\"function\":{\"name\":\"probe\",\"arguments\":{}}}]}}]}"))
         (canonical (kargu-api-normalize-tool-calls response))
         (call (aref (kargu-aget (kargu-aget
                                  (aref (kargu-aget canonical "choices") 0)
                                  "message") "tool_calls") 0))
         (original (aref (kargu-aget (kargu-aget
                                      (aref (kargu-aget response "choices") 0)
                                      "message") "tool_calls") 0)))
    (should (kargu-aget call "id"))
    (should-not (kargu-aget original "id"))
    (should (hash-table-p (kargu-aget (kargu-aget call "function") "arguments")))))

(provide 'tests/test-json)
;;; test-json.el ends here
