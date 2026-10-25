;;; test-stream.el --- Native API delivery integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Parser and pressure contracts live in Rust api_stream/api_http tests.
;; These tests exercise the real editor -> stdio -> Rust -> loopback path.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'tests/test-bridge)
(require 'kargu/api/transport)

(defun kargu-stream-test--server (body stream &optional hold capture capture-headers status headers script)
  "Serve BODY as SSE when STREAM; keep open if HOLD.
Send the request body to CAPTURE and its headers to CAPTURE-HEADERS.
STATUS defaults to 200; HEADERS adds explicit response fixture fields.
SCRIPT optionally supplies per-request :body/:status/:headers response plists."
  (make-network-process
   :name "kargu-native-api-fixture" :server t :host "127.0.0.1" :service t
   :noquery t :coding 'binary
   :filter
   (lambda (client chunk)
     (save-match-data
       (let* ((raw (concat (or (process-get client :request) "") chunk))
              (end (string-search "\r\n\r\n" raw))
              (size (and end (string-match "content-length: \\([0-9]+\\)" (downcase (substring raw 0 end)))
                         (string-to-number (match-string 1 (downcase (substring raw 0 end)))))))
         (process-put client :request raw)
         (when (and end (>= (length raw) (+ end 4 (or size 0)))
                    (not (process-get client :answered)))
           (process-put client :answered t)
           (when capture (funcall capture (substring raw (+ end 4))))
           (when capture-headers (funcall capture-headers (substring raw 0 end)))
           (when script
             (let ((reply (pop script)))
               (setq body (plist-get reply :body) status (plist-get reply :status)
                     headers (plist-get reply :headers))))
           (let ((bytes (encode-coding-string body 'utf-8)))
             (process-send-string
              client (format "HTTP/1.1 %d Fixture\r\nContent-Type: %s\r\n%s%sConnection: close\r\n\r\n"
                             (or status 200)
                             (if stream "text/event-stream" "application/json")
                             (if hold "" (format "Content-Length: %d\r\n" (length bytes)))
                             (or headers "")))
             (process-send-string client bytes))
           (unless hold (delete-process client))))))))

(ert-deftest kargu-stream-native-oversized-retry-after-never-schedules-early-replay-test ()
  "A real oversized provider wait cannot vanish into the legacy retry path."
  (kargu-bridge-test--with-core
    (let* ((posts 0)
           (server (kargu-stream-test--server
                    "" nil nil (lambda (_) (cl-incf posts)) nil 503
                    (concat "Retry-After: " (make-string 129 ?9) "\r\n")))
           (url (format "http://127.0.0.1:%d/chat" (process-contact server :service)))
           (kargu-stream nil) result)
      (unwind-protect
          (progn
            (kargu--api-post url nil '(("messages" . [(("role" . "user") ("content" . "hi"))]))
                             (kargu-application-current-generation) (lambda (value) (setq result value)))
            (kargu-bridge-test--wait (lambda () result))
            (should (= posts 1))
            (should (string-match-p "automatic retry refused" (kargu-response-error-message result)))
            (should-not (kargu-application-current-request)))
        (kargu-http-cancel)
        (delete-process server)))))

(ert-deftest kargu-stream-native-round-trip-and-model-get-test ()
  "Chat plain/SSE and model discovery GET all use Rust, never plz/curl."
  (kargu-bridge-test--with-core
    (dolist (mode '(plain stream models models-large))
      (let* ((stream (eq mode 'stream))
             (body (cond (stream "data: {\"choices\":[{\"delta\":{\"content\":\"dünya 🦀\"}}]}\n\ndata: [DONE]\n\n")
                         ((eq mode 'models) "{\"data\":[{\"id\":\"local-model\"}]}")
                         ((eq mode 'models-large)
                          (concat "{\"data\":[{\"id\":\"local-model\",\"description\":\"" (make-string 1200000 ?x) "\"}]}"))
                         (t "{\"choices\":[{\"message\":{\"content\":\"dünya 🦀\"},\"finish_reason\":\"stop\"}]}")))
             (server (kargu-stream-test--server body stream))
             result failure deltas finished)
        (unwind-protect
            (cl-letf (((symbol-function 'plz) (lambda (&rest _) (ert-fail "Elisp HTTP engine invoked"))))
              (kargu-transport-request
               (if (memq mode '(models models-large)) 'get 'post)
               (format "http://127.0.0.1:%d/v1/chat/completions" (process-contact server :service))
               :headers '(("Authorization" . "synthetic-local-key"))
               :body (unless (memq mode '(models models-large)) (if stream "{\"stream\":true}" "{}"))
               :stream stream :timeout 3
               :on-delta (lambda (delta) (push delta deltas))
               :then (lambda (value) (setq result value finished t))
               :else (lambda (error-data) (setq failure error-data finished t)))
              (kargu-bridge-test--wait (lambda () finished))
              (should-not failure)
              (let ((response (kargu--json-decode result)))
                (if (memq mode '(models models-large))
                    (should (equal (kargu-aget (aref (kargu-aget response "data") 0) "id") "local-model"))
                  (should (equal (kargu-response-text response) "dünya 🦀"))))
              (should (= (length deltas) (if stream 1 0))))
          (delete-process server))))))

(ert-deftest kargu-stream-native-partial-failure-is-not-retried-test ()
  "A truncated stream is an error and never yields executable tool calls."
  (kargu-bridge-test--with-core
    (let* ((server (kargu-stream-test--server
                    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}}]}\n\n" t))
           result failure finished deltas)
      (unwind-protect
          (progn
            (kargu-transport-request
             'post (format "http://127.0.0.1:%d/v1" (process-contact server :service))
             :body "{\"stream\":true}" :stream t :timeout 3
             :on-delta (lambda (delta) (push delta deltas))
             :then (lambda (value) (setq result value finished t))
             :else (lambda (error-data) (setq failure error-data finished t)))
            (kargu-bridge-test--wait (lambda () finished))
            (should-not result)
            (should (= (length deltas) 1))
            (should (= (kargu--plz-http-status failure) 400))
            (should-not (kargu--api-retryable-p failure)))
        (delete-process server)))))

(ert-deftest kargu-stream-native-startup-cancel-never-posts-late-test ()
  "Cancelling a startup waiter prevents a late ensure result from sending."
  (let (ready (posts 0) (deliveries 0) (removed 0))
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (setq ready callback) (lambda () (cl-incf removed))))
              ((symbol-function 'kargu-bridge-call) (lambda (&rest _) (cl-incf posts))))
      (let ((handle (kargu-transport-request 'post "http://localhost:1" :body "{}"
                                            :then (lambda (_) (cl-incf deliveries))
                                            :else (lambda (_) (cl-incf deliveries)))))
        (kargu-transport-cancel handle)
        (kargu-transport-cancel handle)
        (funcall ready (kargu-bridge--connection-create :state 'ready :capabilities ["api_request"]) nil)
        (should (= removed 1))
        (should (zerop posts))
        (should (zerop deliveries))))))

(ert-deftest kargu-stream-native-capture-is-immutable-before-startup-test ()
  "Mutation of the caller's key/body cannot change a queued API capture."
  (let ((key (copy-sequence "original-key")) (body (copy-sequence "{}")) ready arguments)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (setq ready callback) #'ignore))
              ((symbol-function 'kargu-bridge-call)
               (lambda (_connection _method params _callback &rest _)
                 (setq arguments (gethash "arguments" params)) "owned-request")))
      (let ((handle (kargu-transport-request 'post "http://localhost:1"
                                            :headers (list (cons "Authorization" key))
                                            :body body :then #'ignore :else #'ignore)))
        (aset key 0 ?X)
        (aset body 0 ?X)
        (funcall ready (kargu-bridge--connection-create :state 'ready :capabilities ["api_request"]) nil)
        (should (equal (gethash "Authorization" (gethash "headers" arguments)) "original-key"))
        (should (equal (gethash "body" arguments) "{}"))
        (setf (kargu-transport-handle-state handle) :finished)))))

(ert-deftest kargu-stream-native-consumer-error-cancels-only-its-waiter-test ()
  "A failed UI consumer cannot retain its attempt or cancel a sibling."
  (let* ((connection (kargu-bridge--connection-create :state 'ready :epoch "fixture"))
         (deliveries 0) (deltas 0))
    (puthash "owned" (kargu-bridge--pending-create
                      :callback (lambda (&rest _) (cl-incf deliveries))
                      :on-delta (lambda (_) (cl-incf deltas) (error "Consumer failed")))
             (kargu-bridge-connection-pending connection))
    (puthash "sibling" (kargu-bridge--pending-create :callback #'ignore)
             (kargu-bridge-connection-pending connection))
    (cl-letf (((symbol-function 'kargu-bridge--send) #'ignore))
      (dotimes (_ 2)
        (kargu-bridge--dispatch-line
         connection "{\"jsonrpc\":\"2.0\",\"method\":\"api/delta\",\"params\":{\"request_id\":\"owned\",\"delta\":{}}}"))
      (kargu-bridge--finish connection "owned" (kargu-bridge--object "body_ready" t) nil))
    (should (= deltas 1))
    (should (= deliveries 1))
    (should (gethash "sibling" (kargu-bridge-connection-pending connection)))
    (should (eq (kargu-bridge-status connection) 'ready))))

(ert-deftest kargu-stream-native-wire-and-cache-round-trip-test ()
  "Real editor/core requests apply captured wire/cache policy exactly once."
  (kargu-bridge-test--with-core
    (dolist (mode '(native compatible disabled empty-tools))
      (let* ((native (memq mode '(native empty-tools)))
             (body (if native
                       "{\"type\":\"message\",\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}],\"usage\":{\"input_tokens\":100,\"cache_read_input_tokens\":80,\"cache_creation_input_tokens\":20}}"
                     "{\"choices\":[{\"message\":{\"content\":\"hello\"},\"finish_reason\":\"stop\"}]}"))
             (messages [(("role" . "system") ("content" . "Stable\n<runtime_environment>\nfile: a"))
                        (("role" . "user") ("content" . "one"))
                        (("role" . "assistant") ("content" . "answer"))
                        (("role" . "user") ("content" . "two"))])
             (tools (if (eq mode 'empty-tools) []
                      [(("type" . "function") ("function" . (("name" . "read") ("parameters" . :json-empty-object))))]))
             (payload (list (cons "model" "fixture") (cons "messages" messages) (cons "tools" tools)))
             (snapshot (copy-tree payload t))
             captured finished result failure
             (server (kargu-stream-test--server
                      body nil nil (lambda (raw) (setq captured (kargu--json-decode (decode-coding-string raw 'utf-8)))))))
        (unwind-protect
            (progn
              (kargu-transport-request
               'post (format "http://127.0.0.1:%d/messages" (process-contact server :service))
               :body (kargu-json-encode-record payload) :timeout 3
               :wire (kargu-provider-format-record (if native 'anthropic 'openrouter))
               :provider (if native "anthropic" "openrouter")
               :cache-markers (not (eq mode 'disabled))
               :then (lambda (value) (setq result (kargu--json-decode value) finished t))
               :else (lambda (error-data) (setq failure error-data finished t)))
              (kargu-bridge-test--wait (lambda () finished))
              (should-not failure)
              (should (equal payload snapshot))
              (should (equal (kargu-response-text result) "hello"))
              (let* ((sent (kargu-aget captured "messages"))
                     (system (if native (kargu-aget captured "system") (kargu-aget (aref sent 0) "content")))
                     (assistant (aref sent (if native 1 2))))
                (if (eq mode 'disabled)
                    (should-not (string-search "cache_control" (kargu-json-encode-record captured)))
                  (should (kargu-aget (aref system 0) "cache_control"))
                  (should-not (kargu-aget (aref system 1) "cache_control"))
                  (should (kargu-aget (aref (kargu-aget assistant "content") 0) "cache_control"))
                  (unless (eq mode 'empty-tools)
                    (should (kargu-aget (aref (kargu-aget captured "tools") 0) "cache_control"))))
                (should-not (kargu-aget (aref sent (1- (length sent))) "cache_control")))
              (when native
                (should (= (kargu-aget (kargu-aget result "usage") "prompt_tokens") 200))
                (should (equal (kargu-aget captured "max_tokens") 4096))))
          (delete-process server))))))

(ert-deftest kargu-stream-native-captures-wire-and-policy-before-startup-test ()
  "A queued request cannot borrow later provider or format mutations."
  (let ((wire (copy-tree (kargu-provider-format-record 'anthropic) t))
        (provider (copy-sequence "anthropic"))
        (key (copy-sequence "original-private-key"))
        (header (copy-sequence "original-header")) ready captured)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (setq ready callback) #'ignore))
              ((symbol-function 'kargu-bridge-call)
               (lambda (_connection _method params _callback &rest _)
                 (setq captured (gethash "arguments" params)) "fixture")))
      (let ((handle (kargu-transport-request 'post "http://localhost:1"
                                            :wire wire :provider provider :cache-markers t
                                            :auth (list (cons "key" key) (cons "extra_headers" (list (cons "x-private" header))))
                                            :body "{}" :then #'ignore :else #'ignore)))
        (setf (plist-get wire :max-tokens-default) 1)
        (aset provider 0 ?X)
        (aset key 0 ?X)
        (aset header 0 ?X)
        (funcall ready (kargu-bridge--connection-create
                        :state 'ready :capabilities ["api_request" "api_wire" "api_auth"]) nil)
        (should (= (gethash "max-tokens-default" (gethash "wire" captured)) 4096))
        (should (equal (gethash "provider" captured) "anthropic"))
        (should (eq (gethash "cache_markers" captured) t))
        (should (equal (gethash "key" (gethash "auth" captured)) "original-private-key"))
        (should (equal (gethash "x-private" (gethash "extra_headers" (gethash "auth" captured))) "original-header"))
        (setf (kargu-transport-handle-state handle) :finished)))))

(ert-deftest kargu-stream-native-rejects-old-core-before-wire-post-test ()
  "Missing native wire capability fails closed before any request is sent."
  (let (ready failure posted)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (setq ready callback) #'ignore))
              ((symbol-function 'kargu-bridge-call) (lambda (&rest _) (setq posted t))))
      (kargu-transport-request 'post "http://localhost:1" :body "{}" :wire '(:stream t)
                               :then #'ignore :else (lambda (err) (setq failure err)))
      (funcall ready (kargu-bridge--connection-create :state 'ready :capabilities ["api_request"]) nil)
      (should failure)
      (should-not posted))))

(ert-deftest kargu-stream-native-request-policy-full-editor-post-test ()
  "The actual chat POST uses captured native tuning and provider precedence."
  (kargu-bridge-test--with-core
    (let ((kargu-providers--table (copy-hash-table kargu-providers--table)))
      (kargu-register-provider :id "conditional" :format 'openapi
                               :request '(:reasoning-disallows-temperature t))
      (dolist (provider '("openai" "openrouter" "anthropic" "conditional"))
        (let* ((native (equal provider "anthropic"))
               (kargu-session--context
                (kargu-test-session-with-history :provider provider :model "fixture"
                                                 :messages '((("role" . "user") ("content" . "hello")))))
               (kargu-temperature 0.4) (kargu-max-tokens 8192)
               (kargu-reasoning-effort "none") (kargu-thinking-budget 4096)
               (kargu-stream nil)
               (settings (kargu-api-connection-settings provider "fixture"))
               (snapshot (kargu-connection-snapshot--create :provider provider :model "fixture" :settings settings))
               captured result
               (server (kargu-stream-test--server
                        (if native "{\"type\":\"message\",\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}"
                          "{\"choices\":[{\"message\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}")
                        nil nil (lambda (raw) (setq captured (kargu--json-decode (decode-coding-string raw 'utf-8)))))))
          (unwind-protect
              (progn
                (kargu-connection-call
                 snapshot
                 (lambda ()
                   (kargu--api-post
                    (format "http://127.0.0.1:%d/chat" (process-contact server :service)) nil
                    (kargu--build-payload) (kargu-application-current-generation)
                    (lambda (response) (setq result response)))))
                (setq kargu-temperature 1.0 kargu-max-tokens 1 kargu-thinking-budget nil kargu-reasoning-effort "off")
                (kargu-bridge-test--wait (lambda () result))
                (should (equal (kargu-response-text result) "ok"))
                (if (equal provider "openai")
                    (progn (should (= (kargu-aget captured "max_completion_tokens") 8192))
                           (should-not (kargu-aget captured "max_tokens")))
                  (should (= (kargu-aget captured "max_tokens") 8192))
                  (should-not (kargu-aget captured "max_completion_tokens")))
                (if (member provider '("openai" "conditional"))
                    (should-not (kargu-aget captured "temperature"))
                  (should (= (kargu-aget captured "temperature") 0.4)))
                (cond (native (should (= (kargu-aget (kargu-aget captured "thinking") "budget_tokens") 4096)))
                      ((equal provider "openrouter")
                       (should (equal (kargu-aget (kargu-aget captured "reasoning") "effort") "none"))
                       (should (= (kargu-aget (kargu-aget captured "reasoning") "max_tokens") 4096)))
                      (t (should (equal (kargu-aget captured "reasoning_effort") "none")))))
            (kargu-http-cancel)
            (delete-process server)))))))

(ert-deftest kargu-stream-native-invalid-policy-does-not-open-http-test ()
  "Conflicting explicit cap extras fail admission before any socket request."
  (kargu-bridge-test--with-core
    (let* (captured finished failure
           (server (kargu-stream-test--server "{}" nil nil (lambda (raw) (setq captured raw)))))
      (unwind-protect
          (progn
            (kargu-transport-request
             'post (format "http://127.0.0.1:%d/chat" (process-contact server :service))
             :body "{\"model\":\"fixture\",\"messages\":[],\"max_tokens\":200}"
             :tuning '(("max_tokens" . 100) ("provider_policy" . (:max-output-key "max_completion_tokens")))
             :then (lambda (_) (setq finished t))
             :else (lambda (err) (setq finished t failure err)))
            (kargu-bridge-test--wait (lambda () finished))
            (should failure)
            (should-not captured)
            (should (= (kargu--plz-http-status failure) 400)))
        (delete-process server)))))

(ert-deftest kargu-stream-native-auth-headers-and-model-get-round-trip-test ()
  "Rust builds captured auth, defaults and bindings for both POST and GET."
  (kargu-bridge-test--with-core
    (dolist (mode '(openai anthropic openrouter opencode public custom))
      (let* ((provider (if (memq mode '(public custom)) "openrouter" (symbol-name mode)))
             (format (kargu-provider-format provider))
             (auth (kargu-api-auth-intent (unless (eq mode 'public) "synthetic-header-key") provider))
             (public (eq mode 'public))
             (wire (kargu-provider-format-record format))
             headers finished failure
             (server (kargu-stream-test--server
                      (if public "{\"data\":[]}" "{\"choices\":[]}") nil nil nil
                      (lambda (raw) (setq headers (downcase raw))))))
        (when (eq mode 'custom)
          (setcdr (assoc "extra_headers" auth) '(("X-Title" . "explicit-title") ("X-Custom" . "explicit-value"))))
        (unwind-protect
            (progn
              (kargu-transport-request
               (if public 'get 'post) (format "http://127.0.0.1:%d/fixture" (process-contact server :service))
               :body (unless public "{\"model\":\"fixture\",\"messages\":[]}")
               :auth auth :wire wire :provider provider :timeout 3
               :then (lambda (_) (setq finished t))
               :else (lambda (err) (setq finished t failure err)))
              (kargu-bridge-test--wait (lambda () finished))
              (should-not failure)
              (should (string-search "content-type: application/json" headers))
              (cond ((eq mode 'anthropic)
                     (should (string-search "x-api-key: synthetic-header-key" headers))
                     (should (string-search "anthropic-version: 2023-06-01" headers))
                     (should-not (string-search "authorization:" headers)))
                    (public (should-not (string-search "authorization:" headers)))
                    (t (should (string-search "authorization: bearer synthetic-header-key" headers))))
              (when (eq mode 'opencode)
                (should (string-search (concat "x-opencode-session: " (downcase (kargu-aget auth "session"))) headers)))
              (when (memq mode '(openrouter public custom))
                (should (string-search (concat "http-referer: " (downcase kargu-app-url)) headers)))
              (when (eq mode 'custom)
                (should (string-search "x-title: explicit-title" headers))
                (should-not (string-search "x-title: kargu" headers))
                (should (string-search "x-custom: explicit-value" headers))))
          (delete-process server))))))

(ert-deftest kargu-stream-native-applications-have-isolated-api-scope-and-close-test ()
  "Real API leases use distinct native owners and close only their own scope."
  (kargu-bridge-test--with-core
    (let* ((first (kargu-application-create)) (second (kargu-application-create))
           scope-first scope-second binding-failure posted closed failure result
           (server (kargu-stream-test--server "" nil t (lambda (_) (setq posted t)))))
      (unwind-protect
          (progn
            (kargu-bridge-application-ensure conn first (lambda (scope err) (setq scope-first scope binding-failure err)))
            (kargu-bridge-application-ensure conn second (lambda (scope err) (setq scope-second scope binding-failure err)))
            (kargu-bridge-test--wait (lambda () (or binding-failure (and scope-first scope-second))))
            (should-not binding-failure)
            (should-not (equal (gethash "application_id" scope-first) (gethash "application_id" scope-second)))
            (should-not (equal (gethash "application_id" scope-first)
                               (gethash "application_id" (kargu-bridge-connection-read-scope conn))))
            (kargu-transport-request
             'post (format "http://127.0.0.1:%d/chat" (process-contact server :service)) :body "{}" :timeout 3
             :application first :then (lambda (value) (setq result value)) :else (lambda (err) (setq failure err)))
            (kargu-bridge-test--wait (lambda () posted))
            (kargu-bridge-application-close first (lambda (_ err) (should-not err) (setq closed t)))
            (kargu-bridge-test--wait (lambda () (and closed failure)))
            (should-not result)
            (let ((snapshot (kargu-bridge-test--call conn "session/snapshot" scope-second)))
              (should-not (cadr snapshot))
              (should (equal (gethash "state" (car snapshot)) "idle")))
            (should (cadr (kargu-bridge-test--call conn "session/snapshot" scope-first)))
            (let (refused)
              (kargu-bridge-application-ensure conn first (lambda (scope err) (should-not scope) (setq refused err)))
              (should refused))
            (setq closed nil)
            (kargu-bridge-application-close second (lambda (_ err) (should-not err) (setq closed t)))
            (kargu-bridge-test--wait (lambda () closed)))
        (delete-process server)))))

(provide 'tests/test-stream)
;;; test-stream.el ends here
