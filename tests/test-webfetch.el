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

(ert-deftest kargu-webfetch-address-prefixes-do-not-reject-domain-names-test ()
  "IPv6 ULA prefixes apply only to addresses, never to ordinary DNS names."
  (dolist (host '("fdroid.org" "fcc.gov" "fda.gov" "fd.io" "fc-example.org"))
    (should-not (kargu-webfetch--internal-host-p host))
    (should-not (kargu-webfetch--check-url (concat "https://" host "/"))))
  (dolist (host '("fc00::1" "FD12:3456::1" "[fd00::1]"))
    (should (kargu-webfetch--internal-host-p host))))

(ert-deftest kargu-webfetch-ignores-curl-config-and-environment-proxies-test ()
  "DNS pinning cannot be overridden by a curlrc or a proxy environment."
  (let* ((process-environment
          (append '("http_proxy=http://127.0.0.1:8080"
                    "https_proxy=http://127.0.0.1:8080"
                    "ALL_PROXY=socks5://127.0.0.1:1080") process-environment))
         (args (kargu-webfetch--curl-args "https://example.com/a" "93.184.216.34")))
    (should (equal (car args) "--disable"))
    (should (equal (cadr (member "--noproxy" args)) "*"))
    (should (equal (cadr (member "--resolve" args))
                   "example.com:443:93.184.216.34"))
    (should-not (member "--location" args))))

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
  (should (string-prefix-p "ERROR: Webfetch timed out"
                           (kargu-webfetch-test--run '(:code nil :timed-out t :output ""))))
  (should (string-prefix-p "ERROR: Curl exit 7"
                           (kargu-webfetch-test--run '(:code 7 :output "refused")))))

(ert-deftest kargu-webfetch-skips-informational-response-headers-test ()
  "Only the final response determines status, location and returned body."
  (dolist (newline '("\r\n" "\n"))
    (let* ((raw (mapconcat #'identity
                           '("HTTP/1.1 100 Continue" "" "HTTP/2 103 Early Hints"
                             "Location: /not-the-final-location" ""
                             "HTTP/2 200 OK" "Content-Type: text/plain" ""
                             "HTTP/1.1 404 is literal body text") newline))
           reply)
      (string-match "saved" "saved")
      (let ((saved (match-data)))
        (setq reply (kargu-webfetch--split-response raw))
        (should (equal (match-data) saved)))
      (should (= (plist-get reply :status) 200))
      (should-not (plist-get reply :location))
      (should (equal (plist-get reply :body) "HTTP/1.1 404 is literal body text")))))

(ert-deftest kargu-webfetch-http-errors-are-not-successful-documents-test ()
  "HTTP errors, missing statuses and incomplete redirects return ERROR text."
  (dolist (status '(400 403 404 429 500 503))
    (let ((out (kargu-webfetch-test--run
                (list :code 0 :output (format "HTTP/2 %s Error\r\n\r\nerror page" status)))))
      (should (string-prefix-p "ERROR:" out))
      (should (string-search (number-to-string status) out))))
  (dolist (raw '("" "not HTTP\r\n\r\nbody" "HTTP/1.1 100 Continue\r\n\r\n"
                 "HTTP/1.1 200 OK\r\nHeader: unfinished"
                 "HTTP/1.1 302 Found\r\n\r\nredirect without location"))
    (should (string-prefix-p "ERROR:" (kargu-webfetch-test--run
                                      (list :code 0 :output raw)))))
  (should (equal (kargu-webfetch-test--run
                  '(:code 0 :output "HTTP/2 204 No Content\r\n\r\n"))
                 "(empty body)")))

(ert-deftest kargu-webfetch-redirect-to-a-private-host-is-refused-test ()
  "Every redirect hop is checked, so a public URL cannot bounce to localhost."
  (let ((fetched nil))
    (cl-letf (((symbol-function 'kargu-webfetch--fetch)
               (lambda (&rest _) (setq fetched t))))
      (should (string-prefix-p
               "ERROR: Webfetch refuses local or private address"
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

(ert-deftest kargu-webfetch-refuses-a-private-resolution-test ()
  "A public name that resolves only to a private address is not fetched."
  (let ((got nil)
        (curled nil))
    (cl-letf (((symbol-function 'kargu-process-run)
               (lambda (prog _args cb &rest _)
                 (if (equal prog "getent")
                     (funcall cb '(:code 0 :output "10.1.2.3 STREAM evil.example\n10.1.2.3 DGRAM\n"))
                   (setq curled t)))))
      (kargu-webfetch--fetch (lambda (text) (setq got text))
                             "https://evil.example/a" 1)
      (should (string-prefix-p "ERROR: webfetch refuses local or private address" got))
      (should-not curled))))

(ert-deftest kargu-webfetch-resolver-output-must-be-numeric-and-public-test ()
  "No curl request is made for malformed or private numeric resolver answers."
  (dolist (address '("not-an-IP" "0:0:0:0:0:0:0:1" "::ffff:127.0.0.1"
                     "fe90::1" "64:ff9b::a00:1" "64:ff9b:1::1"))
    (let (result curled)
      (cl-letf (((symbol-function 'kargu-process-run)
                 (lambda (program _args callback &rest _)
                   (if (equal program "getent")
                       (funcall callback (list :code 0 :output (concat address " STREAM host\n")))
                     (setq curled t)))))
        (kargu-webfetch--fetch (lambda (value) (setq result value)) "https://host.example/" 1)
        (should (string-prefix-p "ERROR:" result))
        (should-not curled)))))

(ert-deftest kargu-webfetch-checks-numeric-policy-on-every-redirect-test ()
  "Redirect names are resolved again; a private IPv6 answer cannot reach curl."
  (let ((resolutions 0) (requests 0) result)
    (cl-letf (((symbol-function 'kargu-process-run)
               (lambda (program _args callback &rest _)
                 (if (equal program "getent")
                     (funcall callback
                              (list :code 0 :output
                                    (if (= (cl-incf resolutions) 1)
                                        "93.184.216.34 STREAM host\n"
                                      "0:0:0:0:0:ffff:a00:1 STREAM host\n")))
                   (cl-incf requests)
                   (funcall callback
                            '(:code 0 :output "HTTP/2 302 Found\r\nLocation: https://next.example/\r\n\r\n"))))))
      (kargu-webfetch--fetch (lambda (value) (setq result value)) "https://host.example/" 3)
      (should (= resolutions 2))
      (should (= requests 1))
      (should (string-prefix-p "ERROR:" result)))))

(ert-deftest kargu-webfetch-refuses-when-getent-is-missing-test ()
  "Without a resolver the request is not sent."
  (let ((got nil)
        (curled nil))
    (cl-letf (((symbol-function 'kargu-process-run)
               (lambda (prog _args cb &rest _)
                 (if (equal prog "getent")
                     (funcall cb '(:code 127 :output ""))
                   (setq curled t)))))
      (kargu-webfetch--fetch (lambda (text) (setq got text))
                             "https://example.com/a" 1)
      (should (string-search "getent not found" got))
      (should-not curled))))

(ert-deftest kargu-webfetch-pins-the-resolved-address-test ()
  "curl is started with --resolve set to the first public address."
  (let (args got)
    (cl-letf (((symbol-function 'kargu-webfetch--resolve)
               (lambda (_url cb) (funcall cb "93.184.216.34" nil)))
              ((symbol-function 'kargu-process-run)
               (lambda (_prog argv cb &rest _)
                 (setq args argv)
                 (funcall cb '(:code 0 :output "HTTP/1.1 200 OK\r\n\r\nok")))))
      (kargu-webfetch--fetch (lambda (text) (setq got text))
                             "https://example.com/a" 1)
      (should (equal got "ok"))
      (should (member "--resolve" args))
      (should (member "example.com:443:93.184.216.34" args))
      (should (equal (kargu-webfetch--resolve-mapping "example.com" 443 "2606:2800::1")
                     "example.com:443:[2606:2800::1]")))))

(ert-deftest kargu-webfetch-gives-up-after-too-many-redirects-test ()
  "With no hops left the answer is an error, not another request."
  (let (got)
    (kargu-webfetch--handle (lambda (text) (setq got text))
                            "https://example.com/a" 0
                            '(:code 0 :output "HTTP/1.1 302 Found\r\nLocation: /b\r\n\r\n"))
    (should (string-search "too many redirects" got))))

(ert-deftest kargu-webfetch-stop-during-dns-never-starts-curl-test ()
  "Stop closes the owned resolver and invalidates its late completion."
  (let* ((run (list :state 'tools)) (kargu--loop-run run)
         (kargu-async--pending nil) resolve commands delivered
         (pipe (make-pipe-process :name "kargu-test-resolve" :noquery t)))
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-process-run)
                   (lambda (program _args callback &rest _)
                     (push program commands) (setq resolve callback) pipe))
                  ((symbol-function 'kargu-process-cancel)
                   (lambda (process) (delete-process process))))
          (kargu-webfetch-url (lambda (value) (setq delivered value)) "https://example.com/")
          (kargu-async-cancel-owner run)
          (setq kargu--loop-run nil)
          (should-not (process-live-p pipe))
          (funcall resolve '(:code 0 :output "93.184.216.34 STREAM host\n"))
          (should (equal commands '("getent")))
          (should-not delivered)
          (should-not kargu-async--pending))
      (when (process-live-p pipe) (delete-process pipe)))))

(ert-deftest kargu-webfetch-stop-during-curl-never-follows-redirect-test ()
  "A late redirect response cannot continue a cancelled request chain."
  (let* ((run (list :state 'tools)) (kargu--loop-run run)
         (kargu-async--pending nil) curl commands delivered)
    (cl-letf (((symbol-function 'kargu-process-run)
               (lambda (program _args callback &rest _)
                 (push program commands)
                 (if (equal program "getent")
                     (funcall callback '(:code 0 :output "93.184.216.34 STREAM host\n"))
                   (setq curl callback)))))
      (kargu-webfetch-url (lambda (value) (setq delivered value)) "https://example.com/")
      (kargu-async-cancel-owner run)
      (setq kargu--loop-run nil)
      (funcall curl '(:code 0 :output "HTTP/2 302 Found\r\nLocation: /next\r\n\r\n"))
      (should (equal (reverse commands) '("getent" "curl")))
      (should-not delivered)
      (should-not kargu-async--pending))))

(ert-deftest kargu-webfetch-context-change-prevents-the-next-process-test ()
  "A closed origin or changed project prevents DNS from starting curl."
  (dolist (change '(closed-buffer changed-project))
    (let ((origin (generate-new-buffer " *kargu-fetch-origin*"))
          (root "/captured-project/") (kargu-async--pending nil) resolve commands result)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-permission-project-root) (lambda (&optional _) root))
                    ((symbol-function 'kargu-process-run)
                     (lambda (program _args callback &rest _)
                       (push program commands) (setq resolve callback))))
            (with-current-buffer origin
              (kargu-webfetch-url (lambda (value) (setq result value)) "https://example.com/"))
            (pcase change
              ('closed-buffer (kill-buffer origin))
              (_ (setq root "/different-project/")))
            (funcall resolve '(:code 0 :output "93.184.216.34 STREAM host\n"))
            (should (string-prefix-p "ERROR:" result))
            (should (equal commands '("getent")))
            (should-not kargu-async--pending))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(provide 'tests/test-webfetch)
;;; test-webfetch.el ends here
