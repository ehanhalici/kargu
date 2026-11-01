;;; test-native-diagnostics.el --- Raw diagnostic bridge contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Raw facts, bounded transport and actual native provider/tool consumption.
;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tests/test-native-symbols)
(require 'tests/test-stream)
(require 'kargu/bridge/sensor/diagnostics)
(require 'kargu/loop/native-owner)

(defun kargu-native-diagnostics-test--backend (report &rest _)
  "Publish a raw finding through actual Flymake REPORT."
  (funcall report (list (flymake-make-diagnostic (current-buffer) 10 12 :error "raw diagnostic 🦀"))))

(ert-deftest kargu-native-diagnostics-raw-capture-preserves-editor-facts-test ()
  (kargu-native-symbols-test--with-source "lsp_diagnostics"
    (setq-local flymake-diagnostic-functions '(kargu-native-diagnostics-test--backend))
    (cl-letf (((symbol-function 'trusted-content-p) (lambda () t)))
      (flymake-mode 1) (flymake-start))
    (goto-char 10) (narrow-to-region 8 (point-max))
    (let ((point-before (point)) (low (point-min)) (high (point-max)))
      (kargu-bridge-sensor-prepare-tool connection "prepare" params)
      (let* ((resource (gethash "resource" (cdar replies)))
             (requested (gethash "document" resource)))
        (puthash "resource" resource params)
        (cl-letf (((symbol-function 'kargu-lsp-format-diagnostics)
                   (lambda (&rest _) (ert-fail "Native capture called a legacy formatter"))))
          (kargu-bridge-sensor-call-tool connection "read" params))
        (let* ((result (cdar replies)) (observation (gethash "observation" result))
               (snapshot (gethash "snapshot" observation))
               (finding (aref (gethash "diagnostics" snapshot) 0)))
          (should (equal (gethash "kind" observation) "diagnostics"))
          (should (equal (gethash "outcome" result) "ok"))
          (should (eq (gethash "quiescent" result) t))
          (should (kargu-bridge-sensor--equal-p requested (gethash "requested" snapshot)))
          (should (kargu-bridge-sensor--equal-p requested (gethash "observed" snapshot)))
          (should (eq (gethash "reported" (aref (gethash "backends" snapshot) 0)) t))
          (should (equal (gethash "message" finding) "raw diagnostic 🦀"))
          (should (equal (gethash "severity" finding) "error"))
          (should-not (gethash "text" result))
          (should-not (gethash "freshness" snapshot))
          (should-not (gethash "symbol-call" (kargu-bridge-connection-sensor-calls connection)))))
      (should (= (point) point-before)) (should (= (point-min) low)) (should (= (point-max) high)))))

(ert-deftest kargu-native-diagnostics-missing-reports-and-source-replacement-are-explicit-test ()
  (kargu-native-symbols-test--with-source "lsp_diagnostics"
    (ignore params)
    (setq-local flymake-diagnostic-functions '(ignore))
    (cl-letf (((symbol-function 'trusted-content-p) (lambda () t))) (flymake-mode 1))
    (setq-local kargu-lsp--backend-reports nil)
    (let* ((document (gethash "document" (kargu-bridge-sensor--document source root)))
           (snapshot (kargu-bridge-diagnostics--snapshot source root document)))
      (should (eq (gethash "reported" (aref (gethash "backends" snapshot) 0)) :json-false))
      (insert "later")
      (let ((later (kargu-bridge-diagnostics--snapshot source root document)))
        (should-not (= (gethash "tick" (gethash "requested" later))
                       (gethash "tick" (gethash "observed" later))))))))

(ert-deftest kargu-native-diagnostics-large-message-and-small-frame-never-claim-completeness-test ()
  (kargu-native-symbols-test--with-source "lsp_diagnostics"
    (setq-local flymake-diagnostic-functions nil)
    (flymake-mode 1)
    (let ((finding (flymake-make-diagnostic source 10 12 :error (make-string 10000 ?x))))
      (cl-letf (((symbol-function 'flymake-diagnostics) (lambda (&rest _) (list finding)))
                ((symbol-function 'flymake-diagnostic-backend) (lambda (_) 'fixture)))
        (let* ((document (gethash "document" (kargu-bridge-sensor--document source root)))
               (snapshot (kargu-bridge-diagnostics--snapshot source root document))
               (result (kargu-bridge--object "scope" (gethash "scope" params) "call_id" "symbol-call"
                                             "quiescent" t "outcome" "ok" "observation"
                                             (kargu-bridge--object "kind" "diagnostics" "snapshot" snapshot))))
          (should (eq (gethash "truncated" snapshot) t))
          (should (<= (length (gethash "message" (aref (gethash "diagnostics" snapshot) 0))) 4096))
          (setf (kargu-bridge-connection-frame-limit connection) 1024)
          (kargu-bridge-sensor-symbols--fit connection "read" result)
          (should (equal (gethash "outcome" result) "failed"))
          (should (eq (gethash "quiescent" result) t))
          (should (equal (gethash "kind" (gethash "observation" result)) "unavailable")))))))

(ert-deftest kargu-native-diagnostics-real-provider-gets-rust-rendered-flymake-finding-test ()
  (kargu-bridge-test--with-core
    (let* ((root (make-temp-file "kargu-diagnostic-live-" t))
           (source (generate-new-buffer " *native diagnostic live*"))
           (application (kargu-application-create))
           (call (kargu-bridge--object "id" "diag" "type" "function" "function"
                                      (kargu-bridge--object "name" "lsp_diagnostics"
                                                           "arguments" "{\"file_path\":\"source.el\"}")))
           (first (json-serialize (kargu-bridge--object "choices" (vector (kargu-bridge--object
                            "message" (kargu-bridge--object "role" "assistant" "content" :json-null "tool_calls" (vector call))
                            "finish_reason" "tool_calls"))) :null-object :json-null))
           (last "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"done\"},\"finish_reason\":\"stop\"}]}")
           requests server done failure result)
      (unwind-protect
          (progn
            (with-current-buffer source
              (emacs-lisp-mode)
              (setq buffer-file-name (expand-file-name "source.el" root))
              (insert "prefix\n  🦀β suffix\n")
              (setq-local flymake-diagnostic-functions '(kargu-native-diagnostics-test--backend))
              (cl-letf (((symbol-function 'trusted-content-p) (lambda () t)))
                (flymake-mode 1) (flymake-start)))
            (setq server (kargu-stream-test--server
                          first nil nil (lambda (body) (push (kargu--json-decode-safe body) requests))
                          nil nil nil (list (list :body first) (list :body last))))
            (with-current-buffer source
              (kargu-loop-native-owned-start
               application
               (kargu-bridge--object
                "root" root "mode" "agent" "prompt" (kargu-bridge--object "role" "user" "content" "fixture")
                "tools_enabled" t "editor_available" ["lsp_diagnostics"] "tool_limit" 1 "turn_limit" 2
                "timeout_ms" 5000 "config_revision" 1 "policy_revision" 1
                "connection" (kargu-bridge--object "url" (format "http://127.0.0.1:%d/v1" (process-contact server :service))
                              "model" "fixture" "headers" (kargu-bridge--object) "stream" :json-false
                              "timeouts" (kargu-bridge--object "connect_ms" 1000 "first_byte_ms" 1000 "deadline_ms" 4000)))
               (lambda (value error-data) (setq result value failure error-data done t)) :owner source))
            (kargu-bridge-test--wait (lambda () done))
            (should-not failure)
            (should (equal (gethash "status" result) "completed"))
            (should (= (length requests) 2))
            (let* ((messages (gethash "messages" (car requests)))
                   (tool (aref messages (1- (length messages))))
                   (text (gethash "content" tool)))
              (should (equal (gethash "role" tool) "tool"))
              (should (string-match-p "(fresh)" text))
              (should (string-match-p "raw diagnostic 🦀" text))
              (should (string-match-p "Project-wide effects are unverified" text))))
        (when (and (processp server) (process-live-p server)) (delete-process server))
        (when (buffer-live-p source) (with-current-buffer source (set-buffer-modified-p nil)) (kill-buffer source))
        (delete-directory root t)))))

(ert-deftest kargu-native-diagnostics-publication-cannot-borrow-a-restarted-eglot-process-test ()
  (kargu-native-symbols-test--with-source "lsp_diagnostics"
    (ignore params)
    (let* ((server (vector 'server))
           (old (make-pipe-process :name "kargu-diagnostic-old" :noquery t))
           (new (make-pipe-process :name "kargu-diagnostic-new" :noquery t))
           (process old))
      (unwind-protect
          (progn
            (setq-local eglot--managed-mode t eglot--versioned-identifier 3)
            (cl-letf (((symbol-function 'eglot-current-server) (lambda () server))
                      ((symbol-function 'jsonrpc--process) (lambda (_) process))
                      ((symbol-function 'eglot-uri-to-path) (lambda (_) buffer-file-name)))
              (kargu-lsp--observe-publication server "fixture-uri" 3)
              (should (eq (kargu-lsp--publication-process kargu-lsp--publication) old))
              (let ((before (kargu-bridge-diagnostics--server)))
                (should (equal (gethash "requested_server" before) (gethash "observed_server" before))))
              (setq process new)
              (let ((restarted (kargu-bridge-diagnostics--server)))
                (should-not (equal (gethash "requested_server" restarted) (gethash "observed_server" restarted))))
              (kargu-lsp--observe-publication server "fixture-uri" 3)
              (let ((after (kargu-bridge-diagnostics--server)))
                (should (equal (gethash "requested_server" after) (gethash "observed_server" after))))))
        (delete-process old) (delete-process new)))))

(ert-deftest kargu-native-diagnostics-capture-quit-settles-the-owned-read-test ()
  (kargu-native-symbols-test--with-source "lsp_diagnostics"
    (kargu-bridge-sensor-prepare-tool connection "prepare" params)
    (puthash "resource" (gethash "resource" (cdar replies)) params)
    (cl-letf (((symbol-function 'kargu-bridge-diagnostics--snapshot)
               (lambda (&rest _) (signal 'quit nil))))
      (kargu-bridge-sensor-call-tool connection "read" params))
    (let ((result (cdar replies)))
      (should (equal (gethash "outcome" result) "cancelled"))
      (should (eq (gethash "quiescent" result) t))
      (should-not (gethash "symbol-call" (kargu-bridge-connection-sensor-calls connection))))))

(provide 'tests/test-native-diagnostics)
;;; test-native-diagnostics.el ends here
