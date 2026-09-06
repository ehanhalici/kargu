;;; tests/test-contract.el --- Tests for kargu/contract -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'kargu/contract)
(require 'kargu/result)

(ert-deftest kargu-contract-mode-test ()
  "Test interaction mode contracts."
  (should (kargu-contract-mode-p 'ask))
  (should (kargu-contract-mode-p 'plan))
  (should (kargu-contract-mode-p 'debug))
  (should (kargu-contract-mode-p 'agent))
  (should-not (kargu-contract-mode-p 'build))
  (should-not (kargu-contract-mode-p 'invalid))
  (should-not (kargu-contract-mode-p "ask"))
  (should-not (kargu-contract-mode-p nil)))

(ert-deftest kargu-contract-role-test ()
  "Test message role contracts."
  (should (kargu-contract-role-p "system"))
  (should (kargu-contract-role-p "user"))
  (should (kargu-contract-role-p "assistant"))
  (should (kargu-contract-role-p "tool"))
  (should-not (kargu-contract-role-p "model"))
  (should-not (kargu-contract-role-p 'user))
  (should-not (kargu-contract-role-p ""))
  (should-not (kargu-contract-role-p nil)))

(ert-deftest kargu-contract-tool-call-test ()
  "Test tool call structural contracts."
  (should (kargu-contract-tool-call-p
           '(("id" . "call_1")
             ("function" . (("name" . "bash") ("arguments" . "{}"))))))
  (should-not (kargu-contract-tool-call-p "not-a-call"))
  (should-not (kargu-contract-tool-call-p '(("id" . "c1")))))

(ert-deftest kargu-contract-assert-test ()
  "Test contract assertion behavior."
  (should (equal (kargu-contract-assert #'kargu-contract-mode-p 'ask) 'ask))
  (should-error (kargu-contract-assert #'kargu-contract-mode-p 'bogus-mode)))

(ert-deftest kargu-contract-validate-railway-test ()
  "Test Railway-Oriented contract validation."
  (let ((ok-res (kargu-contract-validate #'kargu-contract-mode-p 'agent))
        (err-res (kargu-contract-validate #'kargu-contract-mode-p 'invalid)))
    (should (kargu-ok-p ok-res))
    (should (eq (kargu-result-value ok-res) 'agent))
    (should (kargu-err-p err-res))))

(ert-deftest kargu-contract-non-empty-string-test ()
  "Test non-empty string contract."
  (should (kargu-contract-non-empty-string-p "hello"))
  (should (kargu-contract-non-empty-string-p "   non-empty   "))
  (should-not (kargu-contract-non-empty-string-p ""))
  (should-not (kargu-contract-non-empty-string-p "   \t\n  "))
  (should-not (kargu-contract-non-empty-string-p nil))
  (should-not (kargu-contract-non-empty-string-p 'symbol)))

(ert-deftest kargu-contract-url-test ()
  "Test URL contract."
  (should (kargu-contract-url-p "https://example.com"))
  (should (kargu-contract-url-p "http://localhost:8080/api"))
  (should-not (kargu-contract-url-p "ftp://example.com"))
  (should-not (kargu-contract-url-p "javascript:alert(1)"))
  (should-not (kargu-contract-url-p "not a url"))
  (should-not (kargu-contract-url-p nil)))

(ert-deftest kargu-contract-tool-executor-test ()
  "Test tool executor contract."
  (should (kargu-contract-tool-executor-p #'identity))
  (should (kargu-contract-tool-executor-p (lambda (x) x)))
  (should-not (kargu-contract-tool-executor-p "not-a-func"))
  (should-not (kargu-contract-tool-executor-p nil)))

(provide 'tests/test-contract)
;;; test-contract.el ends here
