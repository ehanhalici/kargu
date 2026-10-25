;;; test-chat-target.el --- Native URL path consumer contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Use the actual temporary TOML refresh, base reader, connection preparation,
;; native policy and loopback HTTP.  Neither base nor target policy is mocked.

;;; Code:

(require 'ert)
(require 'tests/test-connection-native)
(require 'kargu/api/catalog)

(ert-deftest kargu-chat-target-config-query-reaches-real-catalog-get-test ()
  "Published config preserves opaque query values all the way to catalog GET."
  (kargu-bridge-test--with-core
    (dolist (suffix '("/v1/?tenant=a%2Fb/" "/v1///?tenant=a%2Fb/&x=%252F"))
      (kargu-test-with-real-connection
        (let* ((posts 0) captured done result
               (server (kargu-stream-test--server
                        "{\"data\":[{\"id\":\"query-model\"}]}" nil nil
                        (lambda (_) (cl-incf posts)) (lambda (value) (setq captured value))))
               (endpoint (format "http://127.0.0.1:%d%s" (process-contact server :service) suffix)))
          (unwind-protect
              (progn
                (write-region (format "[providers.g02]\napi = \"%s\"\napikey = \"\"\n" endpoint)
                              nil config-file nil 'silent)
                (should (kargu-ok-p (kargu-test-await #'kargu-config-refresh-async)))
                (should (equal (kargu--api-base "g02") endpoint))
                (kargu-api-list-models (lambda (value) (setq result value done t)) "g02")
                (kargu-bridge-test--wait (lambda () done))
                (should-not (kargu-aget result "error"))
                (should (equal (kargu-aget (car result) "id") "query-model"))
                (should (= posts 1))
                (should (string-prefix-p
                         (concat "GET /v1/models?" (cadr (split-string suffix "?" t)) " ") captured)))
            (delete-process server)))))))

(ert-deftest kargu-chat-target-real-send-derives-format-path-and-retains-query-test ()
  "Actual sends retain the raw base while Rust derives the captured format path."
  (kargu-bridge-test--with-core
    (dolist (format '(openapi anthropic))
      (kargu-test-with-real-connection
        (let* ((kargu-stream nil) (posts 0) captured report run
               (blocks (eq format 'anthropic))
               (body (if blocks
                         "{\"type\":\"message\",\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}"
                       "{\"choices\":[{\"message\":{\"content\":\"done\"},\"finish_reason\":\"stop\"}]}"))
               (server (kargu-stream-test--server body nil nil (lambda (_) (cl-incf posts))
                                                   (lambda (value) (setq captured value))))
               (endpoint (format "http://127.0.0.1:%d/v1///?tenant=a%%2Fb/"
                                 (process-contact server :service))))
          (unwind-protect
              (progn
                (kargu-register-provider :id "g02" :format format)
                (write-region (format "[providers.g02]\napi = \"%s\"\napikey = \"synthetic-query-key\"\nmodel = \"m\"\n" endpoint)
                              nil config-file nil 'silent)
                (setq run (kargu-loop-send "hello" nil (lambda (value) (setq report value))))
                (kargu-bridge-test--wait (lambda () report))
                (should (eq (plist-get report :status) :done))
                (should (= posts 1))
                (should (string-prefix-p
                         (concat "POST /v1" (if blocks "/messages" "/chat/completions")
                                 "?tenant=a%2Fb/ ") captured))
                (should (equal (kargu-connection-snapshot-endpoint
                                (kargu-execution-connection (plist-get run :context))) endpoint)))
            (delete-process server)))))))

(ert-deftest kargu-chat-target-old-core-never-starts-owner-or-posts-test ()
  "Missing chat-target support fails before owner startup or any forward call."
  (let (failure (calls 0))
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback)
                 (funcall callback (kargu-bridge--connection-create
                                    :state 'ready :capabilities ["api_request" "api_failure" "api_wire"]) nil)
                 #'ignore))
              ((symbol-function 'kargu-bridge-application-ensure)
               (lambda (&rest _) (ert-fail "No owner on old core")))
              ((symbol-function 'kargu-bridge-call) (lambda (&rest _) (cl-incf calls))))
      (let ((handle (kargu-transport-request
                     'post "https://fixture.invalid/v1/?tenant=a%2Fb/" :chat-target t
                     :application (kargu-application-context)
                     :then (lambda (_) (ert-fail "No completion on old core"))
                     :else (lambda (value) (setq failure value)))))
        (should (eq (kargu-result-err-code failure) :service-unavailable))
        (should (zerop calls))
        (should-not (kargu-transport-handle-id handle))
        (should-not (kargu-transport-handle-startup handle))
        (should-not (kargu-transport-handle-owner-cleanup handle))))))

(ert-deftest kargu-chat-target-legacy-url-functions-are-removed-test ()
  "Editor consumers neither strip opaque URL endings nor derive chat endpoints."
  (should-not (fboundp 'kargu-api-chat-url))
  (should-not (fboundp 'kargu--strip-trailing-slashes)))

(provide 'tests/test-chat-target)
;;; test-chat-target.el ends here
