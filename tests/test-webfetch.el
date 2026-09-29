;;; tests/test-webfetch.el --- Tests for the webfetch tool -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'kargu/core)
(require 'kargu/tools/webfetch)

(ert-deftest kargu-webfetch-refuses-non-public-hosts-test ()
  "Loopback, private, link-local and internal names are all refused."
  (dolist (url '("http://127.0.0.1/" "http://10.1.2.3/x" "http://192.168.0.5/"
                 "http://172.20.0.1/" "http://169.254.169.254/latest" "http://localhost:8080/"
                 "http://[::1]/" "http://printer.local/" "http://db.internal/" "http://0.0.0.0/"))
    (should-error (kargu-webfetch--check-url url)))
  (should-error (kargu-webfetch--check-url "ftp://example.com/x"))
  (should (null (kargu-webfetch--check-url "https://example.com/x"))))

(ert-deftest kargu-webfetch-splits-status-location-and-body-test ()
  "The curl -i answer splits into status, redirect target and body."
  (let ((reply (kargu-webfetch--split-response
                "HTTP/1.1 302 Found\r\nLocation: /next\r\nX: y\r\n\r\nbody text")))
    (should (= (plist-get reply :status) 302))
    (should (equal (plist-get reply :location) "/next"))
    (should (equal (plist-get reply :body) "body text"))))

(defun kargu-webfetch-test--run (result)
  "Feed RESULT to the handler of one fetch and return what the callback got."
  (let (got)
    (kargu-webfetch--handle (lambda (text) (setq got text))
                            "https://example.com/a" 5 result)
    got))

(ert-deftest kargu-webfetch-handle-returns-the-body-test ()
  "A 200 answer gives the body; an empty body is named."
  (should (equal (kargu-webfetch-test--run
                  '(:code 0 :output "HTTP/1.1 200 OK\r\n\r\nhello"))
                 "hello"))
  (should (equal (kargu-webfetch-test--run
                  '(:code 0 :output "HTTP/1.1 200 OK\r\n\r\n"))
                 "(empty body)")))

(ert-deftest kargu-webfetch-handle-reports-failures-as-error-text-test ()
  "Timeouts and curl failures become ERROR text for the model."
  (should (string-prefix-p "ERROR: webfetch timed out"
                           (kargu-webfetch-test--run '(:code nil :timed-out t :output ""))))
  (should (string-prefix-p "ERROR: curl exit 7"
                           (kargu-webfetch-test--run '(:code 7 :output "refused")))))

(ert-deftest kargu-webfetch-redirect-to-a-private-host-is-refused-test ()
  "Every redirect hop is checked, so a public URL cannot bounce to localhost."
  (let ((fetched nil))
    (cl-letf (((symbol-function 'kargu-webfetch--fetch)
               (lambda (&rest _) (setq fetched t))))
      (should (string-prefix-p
               "ERROR: webfetch refuses local or private address"
               (kargu-webfetch-test--run
                '(:code 0 :output "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/admin\r\n\r\n"))))
      (should-not fetched))))

(ert-deftest kargu-webfetch-redirect-to-a-public-host-is-followed-test ()
  "A safe redirect is fetched with one hop fewer left."
  (let (next)
    (cl-letf (((symbol-function 'kargu-webfetch--fetch)
               (lambda (_cb url left) (setq next (cons url left)))))
      (kargu-webfetch-test--run
       '(:code 0 :output "HTTP/1.1 301 Moved\r\nLocation: /b\r\n\r\n"))
      (should (equal next '("https://example.com/b" . 4))))))

(ert-deftest kargu-webfetch-gives-up-after-too-many-redirects-test ()
  "With no hops left the answer is an error, not another request."
  (let (got)
    (kargu-webfetch--handle (lambda (text) (setq got text))
                            "https://example.com/a" 0
                            '(:code 0 :output "HTTP/1.1 302 Found\r\nLocation: /b\r\n\r\n"))
    (should (string-search "too many redirects" got))))

(provide 'tests/test-webfetch)
;;; test-webfetch.el ends here
