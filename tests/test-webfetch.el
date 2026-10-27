;;; test-webfetch.el --- Native webfetch consumer contracts -*- lexical-binding: t; -*-
;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; HTTP parsing/pinning/redirect/DNS corpus is in native webfetch tests.
;; Real stdio denies private addresses; controlled callbacks test editor ownership.
;;; Code:
(require 'ert)
(require 'tests/test-helpers)
(require 'tests/test-bridge)
(require 'kargu/tools/webfetch)

(ert-deftest kargu-webfetch-native-refuses-private-numeric-and-named-hosts-test ()
  "Real native egress refuses unsafe targets before any HTTP or resolver child."
  (kargu-bridge-test--with-core
    (dolist (url '("http://127.0.0.1/" "http://10.1.2.3/" "http://172.20.0.1/"
                   "http://169.254.169.254/" "http://localhost:8080/" "http://[::1]/"
                   "http://printer.local/" "http://db.internal/" "http://0.0.0.0/"
                   "http://2130706433/" "http://127.1/" "http://localhost./"
                   "http://[::ffff:127.0.0.1]/" "http://[64:ff9b::a00:1]/"
                   "ftp://example.com/" "https://user:secret@example.com/"))
      (should (string-prefix-p "ERROR:" (kargu-test-await (lambda (done) (kargu-webfetch-url done url))))))))

(ert-deftest kargu-webfetch-native-captures-inputs-and-never-runs-the-editor-process-test ()
  "Native arguments are copied before startup, with no curl/DNS fallback."
  (let ((connection (kargu-bridge--connection-create :state 'ready))
        (url (copy-sequence "https://example.com/original")) ready seen result task)
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (done) (setq ready done) #'ignore))
                  ((symbol-function 'kargu-process-run) (lambda (&rest _) (ert-fail "Elisp process")))
                  ((symbol-function 'kargu-bridge-webfetch)
                   (lambda (_conn arguments done &rest _)
                     (setq seen arguments) (funcall done (kargu-bridge--object "text" "native text") nil))))
          (setq task (kargu-webfetch-url (lambda (text) (setq result text)) url))
          (clear-string url) (funcall ready connection nil)
          (should (equal (gethash "url" seen) "https://example.com/original"))
          (should (= (gethash "timeout_ms" seen) 20000))
          (should (= (gethash "resolve_timeout_ms" seen) 5000))
          (should (equal result "native text")))
      (when task (kargu-async-cancel task)))))

(ert-deftest kargu-webfetch-native-stop-and-project-change-suppress-late-body-test ()
  "Stop revokes the exact RPC; a changed project cannot receive old body text."
  (dolist (ending '(cancel root close))
    (with-temp-buffer
      (let ((connection (kargu-bridge--connection-create :state 'ready))
            (kargu-permission--override-root kargu-permission--override-root) reply delivered cancelled task)
        (unwind-protect
            (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (done) (funcall done connection nil) #'ignore))
                      ((symbol-function 'kargu-bridge-webfetch) (lambda (_c _args done &rest _) (setq reply done) "fetch-owned"))
                      ((symbol-function 'kargu-bridge-cancel) (lambda (_c id) (should (equal id "fetch-owned")) (setq cancelled t))))
              (setq task (kargu-webfetch-url (lambda (text) (setq delivered text)) "https://example.com/"))
              (pcase ending ('cancel (kargu-async-cancel task)) ('root (setq kargu-permission--override-root "/synthetic/changed/")) ('close (fundamental-mode)))
              (funcall reply (kargu-bridge--object "text" "private late body") nil)
              (should (or (null delivered) (string-prefix-p "ERROR:" delivered)))
              (should-not (and delivered (string-search "private late body" delivered)))
              (should cancelled))
          (when task (kargu-async-cancel task)))))))

(ert-deftest kargu-webfetch-native-old-core-and-missing-binary-refuse-without-fallback-test ()
  "Capability/startup failures cannot invoke the removed resolver or curl engine."
  (let ((connection (kargu-bridge--connection-create :state 'ready :capabilities [])) result)
    (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (done) (funcall done connection nil) #'ignore))
              ((symbol-function 'kargu-process-run) (lambda (&rest _) (ert-fail "Fallback"))))
      (kargu-webfetch-url (lambda (value) (setq result value)) "https://example.com/")
      (should (string-prefix-p "ERROR:" result))))
  (dolist (function '(kargu-webfetch--fetch kargu-webfetch--resolve kargu-webfetch--resolve-fallback
                      kargu-webfetch--curl-args kargu-webfetch--split-response kargu-webfetch--check-url))
    (should-not (fboundp function))))

(ert-deftest kargu-webfetch-native-canonical-alias-and-mode-use-one-gate-test ()
  "Read-only webfetch aliases share the native port in all four modes."
  (let ((kargu--tool-registry (kargu-tool-registry-create))
        (connection (kargu-bridge--connection-create :state 'ready)))
    (kargu-webfetch-register-tools) (kargu-register-tool-alias "fetch-fixture" "webfetch")
    (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (done) (funcall done connection nil) #'ignore))
              ((symbol-function 'kargu-bridge-webfetch)
               (lambda (_c _args done &rest _) (funcall done (kargu-bridge--object "text" "native body") nil))))
      (dolist (mode '(ask plan debug agent))
        (let ((context (kargu-tool-execution-context-create :root default-directory :mode mode)))
          (dolist (name '("webfetch" "fetch-fixture"))
            (should (equal "native body" (kargu-test-await
             (lambda (done) (kargu-tool-gate-execute kargu--tool-registry context name '(("url" . "https://example.com/")) :callback done)))))))))))

(provide 'tests/test-webfetch)
;;; test-webfetch.el ends here
