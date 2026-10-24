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

(defun kargu-stream-test--server (body stream &optional hold)
  "Serve captured BODY over loopback, as SSE when STREAM; keep open if HOLD."
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
           (let ((bytes (encode-coding-string body 'utf-8)))
             (process-send-string
              client (format "HTTP/1.1 200 OK\r\nContent-Type: %s\r\n%sConnection: close\r\n\r\n"
                             (if stream "text/event-stream" "application/json")
                             (if hold "" (format "Content-Length: %d\r\n" (length bytes)))))
             (process-send-string client bytes))
           (unless hold (delete-process client))))))))

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

(provide 'tests/test-stream)
;;; test-stream.el ends here
