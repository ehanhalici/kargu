;;; test-connection-native.el --- Native connection preparation contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exercise the real preparation, config child, native admission and retry.
;; Only the remote transport is fake; credentials and files are synthetic.

;;; Code:

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)
(require 'tests/test-native-circuit)

(defmacro kargu-test-with-real-connection (&rest body)
  "Run BODY with real preparation and a synthetic temporary config file."
  (declare (indent 0))
  `(let* ((config-file (make-temp-file "kargu-native-config-" nil ".toml"))
          (refresh (symbol-function 'kargu-config-refresh-async))
          (kargu-application--bound (kargu-application-create))
          (kargu-session--context (kargu-test-session-with-history
                                   :provider "g02" :model "m" :messages nil))
          (kargu-providers--table (copy-hash-table kargu-providers--table))
          (kargu-api-key nil) (kargu--loop-run nil) (kargu--busy nil)
          (kargu-session-auto-save nil))
     (unwind-protect
         (progn
           (write-region "provider = \"g02\"\n[providers.g02]\napi = \"https://example.invalid/Original\"\napikey = \"synthetic-native-key\"\nmodel = \"m\"\n"
                         nil config-file nil 'silent)
           (kargu-register-provider :id "g02" :format 'openapi)
           (kargu-test-mode 'ask)
           (cl-letf (((symbol-function 'kargu-api-prepare-connection) kargu-test-real-prepare-connection)
                     ((symbol-function 'kargu-config-refresh-async)
                      (lambda (callback &rest options)
                        (apply refresh callback :paths (list config-file) options)))
                     ((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
                     ((symbol-function 'kargu-prompt-wrap-user) #'identity))
             ,@body))
       (when (kargu-loop-running-p) (kargu-loop-stop))
       (kargu-http-cancel)
       (delete-file config-file))))

(ert-deftest kargu-connection-native-preparation-stop-and-history-test ()
  "Admission is owned before config I/O; Stop preserves history and edits."
  (kargu-test-with-real-connection
   (let (report (posts 0) (resets 0))
     (kargu-history-replace '((("role" . "user") ("content" . "previous"))))
     (let ((before (kargu-history-snapshot)))
       (cl-letf (((symbol-function 'kargu-transport-request) (lambda (&rest _) (cl-incf posts)))
                 ((symbol-function 'kargu-edit-changes) (lambda (&rest _) (cl-incf resets) nil)))
         (let* ((run (kargu-loop-send "new prompt" nil (lambda (value) (setq report value))))
                (root (kargu-execution-task (plist-get run :context))))
           (should (kargu-loop-running-p))
           (should (eq (kargu-execution-state (plist-get run :context)) :starting))
           (should-error (kargu-loop-send "second") :type 'user-error)
           (kargu-loop-stop)
           (should (eq (kargu-async-task-state root) :cancelled))
           (should-not (plist-get report :request-started))
           (should (equal before (kargu-history-snapshot)))
           (should (zerop posts))
           ;; Report reads are allowed; there was no reset or abort.
           (should (< resets 4))))))))

(ert-deftest kargu-connection-native-config-failure-restores-draft-test ()
  "A real async TOML rejection restores unsent chat input without posting."
  (kargu-test-with-real-connection
   (write-region "model = 42\n" nil config-file nil 'silent)
   (with-temp-buffer
     (kargu-chat-mode)
     (kargu-selection-update :provider "g02" :model "m")
     (kargu-chat--ensure-idle-prompt)
     (insert "preserve this draft")
     (let ((reports 0))
       (cl-letf (((symbol-function 'kargu-chat--expand-prompt) #'identity)
                 ((symbol-function 'kargu-transport-request) (lambda (&rest _) (ert-fail "Unexpected POST"))))
         (kargu-test-await
          (lambda (done)
            (let ((finish (symbol-function 'kargu-chat--complete-submission)))
              (cl-letf (((symbol-function 'kargu-chat--complete-submission)
                         (lambda (report &rest options)
                           (cl-incf reports)
                           (apply finish report options)
                           (funcall done report))))
                (kargu-chat--send-input)
                (while (kargu-loop-running-p) (accept-process-output nil 0.02))))))
         (should (= reports 1))
         (should (equal (kargu-chat--input-text) "preserve this draft"))
         (should-not (kargu-loop-running-p)))))))

(ert-deftest kargu-connection-native-retry-retains-target-policy-and-key-test ()
  "Real native replay retains endpoint, key, model and policy across config edits."
  (kargu-bridge-test--with-core
    (kargu-test-with-real-connection
      (let* ((kargu-api-retry-max 1) calls headers report snapshot run
             (server (kargu-stream-test--server
                      "" nil nil (lambda (body) (push body calls))
                      (lambda (value) (push value headers)) nil nil
                      (list (list :status 503 :body "" :headers "Retry-After: 0\r\n")
                            (list :status 200 :body "{\"choices\":[{\"message\":{\"content\":\"done\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}"))))
             (endpoint (format "http://127.0.0.1:%d/Original" (process-contact server :service)))
             (kargu-api-retry-hook
              (list (lambda (&rest _)
                      (should (= (length calls) 1))
                      (kargu-register-provider :id "g02" :format 'blocks
                                               :request '(:max-output-key "max_completion_tokens"))
                      (kargu-config-publish
                       (kargu-config-service-context)
                       '(:providers (("g02" :api "https://other.invalid/New" :apikey "changed")))
                       "/fake" "changed")))))
        (unwind-protect
            (progn
              (write-region (format "[providers.g02]\napi = \"%s\"\napikey = \"synthetic-native-key\"\nmodel = \"m\"\n" endpoint)
                            nil config-file nil 'silent)
              (setq run (kargu-loop-send "hello" nil (lambda (value) (setq report value))))
              (kargu-bridge-test--wait (lambda () report))
              (setq snapshot (kargu-execution-connection (plist-get run :context)))
              (should (plist-get run :request-started))
              (should (= (length calls) 2))
              (should (equal (car calls) (cadr calls)))
              (should (equal (kargu-aget (kargu--json-decode (car calls)) "model") "m"))
              (should (cl-every (lambda (value) (string-search "POST /Original/chat/completions " value)) headers))
              (should (cl-every (lambda (value) (string-search "synthetic-native-key" value)) headers))
              (should (eq (plist-get report :status) :done))
              (should-not (kargu-connection-snapshot-secret snapshot)))
          (delete-process server))))))

(ert-deftest kargu-connection-preparation-rejects-replaced-selection-test ()
  "A credential result cannot enter a replaced selection or session."
  (kargu-test-with-real-connection
   (write-region "[providers.g02]\napi = \"https://example.invalid/v1\"\n" nil config-file nil 'silent)
   (let* (secret-task result
		      (kargu-config-credential-adapter
		       (lambda (_provider _host task) (setq secret-task task))))
     (funcall kargu-test-real-prepare-connection (lambda (value) (setq result value)))
     (let ((deadline (+ (float-time) 3)))
       (while (and (null secret-task) (< (float-time) deadline)) (accept-process-output nil 0.02)))
     (should secret-task)
     (kargu-selection-update :model "replacement")
     (kargu-async-finish secret-task (kargu-ok "late-synthetic-secret"))
     (should (kargu-err-p result)))))

(ert-deftest kargu-connection-nested-input-and-accessors-are-detached-test ()
  "Neither input nor accessor mutation changes snapshot strings or headers."
  (let* ((text (copy-sequence "original"))
         (snapshot (kargu-connection-snapshot--create
                    :provider text :capabilities (list :nested (list text))
                    :settings (list :headers (list (cons "x-private" "synthetic-header-secret"))))))
    (should-not (string-search "synthetic-header-secret" (prin1-to-string snapshot)))
    (aset text 0 ?X)
    (aset (kargu-connection-snapshot-provider snapshot) 0 ?Y)
    (aset (car (plist-get (kargu-connection-snapshot-capabilities snapshot) :nested)) 0 ?Z)
    (should (equal (kargu-connection-snapshot-provider snapshot) "original"))
    (should (equal (plist-get (kargu-connection-snapshot-capabilities snapshot) :nested) '("original")))))

(ert-deftest kargu-connection-redirect-does-not-replay-credential-test ()
  "Rust HTTP never replays captured credentials to a second origin."
  (skip-unless (getenv "KARGU_CORE_TEST_BINARY"))
  (let ((kargu-bridge-binary-path (getenv "KARGU_CORE_TEST_BINARY")))
    (dolist (header '("Authorization" "x-api-key"))
      (let (target source clients received)
	(unwind-protect
            (progn
              (condition-case nil
                  (setq target (make-network-process
				:name "kargu-redirect-target" :server t :host "127.0.0.1"
				:service t :noquery t
				:log (lambda (_server client _message) (push client clients))))
		(file-error (ert-skip "Loopback sockets require sandbox network permission")))
              (setq source
                    (make-network-process
                     :name "kargu-redirect-source" :server t :host "127.0.0.1" :service t :noquery t
                     :filter (lambda (client chunk)
                               (setq received (concat received chunk))
                               (when (string-search "\r\n\r\n" received)
				 (process-send-string
                                  client (format "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:%d/target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
						 (process-contact target :service)))
				 (delete-process client)))))
              (let ((result (kargu-test-await
                             (lambda (done)
                               (kargu-transport-request
				'post (format "http://127.0.0.1:%d/source" (process-contact source :service))
				:headers (list (cons header "synthetic-redirect-secret"))
				:body "{}" :timeout 3 :then done :else done)))))
		(should (kargu-err-p result))
		(should (eq (kargu-result-err-code result) :redirect-refused))
		(should (string-search "redirect refused" (kargu-result-err-message result))))
              (should (string-search "synthetic-redirect-secret" received))
              (should-not clients))
          (dolist (process (append clients (list source target)))
            (when (process-live-p process) (delete-process process)))))))

  )

(ert-deftest kargu-connection-metadata-and-circuits-belong-to-application-test ()
  "Two applications isolate catalogs, metadata, refusals and circuit resets."
  (kargu-circuit-test--with-peer
   (let ((first application) (second (kargu-application-create)))
    (kargu-bridge-circuit-observe first connection scope
      (kargu-circuit-test--view :provider "g02" :failures 1) t)
    (let ((kargu-application--bound first))
      (kargu--catalog-cache-live-models "g02" '((("id" . "shared") ("context_length" . 123))))
      (kargu-model-mark-tools-refused "shared" "g02")
      (puthash "g02" 7 (kargu-metadata-table :generations kargu--catalog-generations)))
    (let ((kargu-application--bound second))
      (should-not (kargu-model-get-metadata "shared" "g02"))
      (should (kargu-model-supports-tools-p "shared" "g02"))
      (should-not (kargu-selection-models-known-p "g02"))
      (should-not (gethash "g02" (kargu-metadata-table :generations kargu--catalog-generations)))
      (kargu-circuit-reset 'all))
    (let ((kargu-application--bound first))
      (should (= (kargu-model-context-window "shared" "g02") 123))
      (should-not (kargu-model-supports-tools-p "shared" "g02"))
      (should (kargu-selection-models-known-p "g02"))
      (should (= (gethash "failures" (kargu-circuit-get "g02")) 1))))))

(ert-deftest kargu-connection-conditional-reasoning-fixture-test ()
  "Conditional rules are captured unchanged for the native policy engine."
  ;; The synthetic endpoint rejection cases moved to api_policy.rs.
  (let ((kargu-providers--table (copy-hash-table kargu-providers--table))
        (kargu-reasoning-effort "none") (kargu-temperature 0.5))
    (kargu-register-provider :id "conditional-fixture" :format 'openapi
                             :request '(:sampling-parameters ("temperature")
                                        :reasoning-disallows-temperature t))
    (let* ((tuning (kargu-api-request-tuning "conditional-fixture" "fixture-v1"))
           (policy (kargu-aget tuning "provider_policy")))
      (should (plist-get policy :reasoning-disallows-temperature))
      (should (equal (plist-get policy :sampling-parameters) '("temperature")))
      (should (= (kargu-aget tuning "temperature") 0.5)))))

(ert-deftest kargu-connection-catalog-callback-keeps-application-owner-test ()
  "A delayed catalog response publishes only to its original application."
  (let ((first (kargu-application-create)) (second (kargu-application-create)) callback)
    (cl-letf (((symbol-function 'kargu--resolve-api-key) (lambda (&rest _) "synthetic"))
              ((symbol-function 'kargu-transport-request)
               (lambda (_method _url &rest options)
                 (setq callback (plist-get options :then)) nil)))
      (let ((kargu-application--bound first))
        (kargu-api-list-models #'ignore "openrouter"))
      (let ((kargu-application--bound second))
        (funcall callback "{\"data\":[{\"id\":\"owned-model\"}]}")
        (should-not (kargu-selection-models-known-p "openrouter")))
      (let ((kargu-application--bound first))
        (should (equal (kargu-selection-model-candidates "openrouter") '("owned-model")))))))

(provide 'tests/test-connection-native)
;;; test-connection-native.el ends here
