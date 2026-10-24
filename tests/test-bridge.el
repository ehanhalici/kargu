;;; test-bridge.el --- Rust IPC and lifecycle contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Set KARGU_CORE_TEST_BINARY to the built binary to run real-pipe checks.
;; No model, shell tool, user credential or real session file is used.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'kargu/bridge)

(defun kargu-bridge-test--wait (predicate)
  "Wait for PREDICATE in the test event loop, failing after ten seconds."
  (let ((deadline (+ (float-time) 10)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (should (funcall predicate))))

(defun kargu-bridge-test--call (connection method params)
  "Return a synchronous test-only reply for METHOD/PARAMS on CONNECTION."
  (let (finished reply)
    (kargu-bridge-call connection method params
                       (lambda (result error-data)
                         (setq reply (list result error-data) finished t)))
    (kargu-bridge-test--wait (lambda () finished))
    reply))

(defmacro kargu-bridge-test--with-core (&rest body)
  "Run BODY with a real core connection bound to `conn'."
  (declare (indent 0) (debug t))
  `(let* ((binary (getenv "KARGU_CORE_TEST_BINARY"))
          (kargu-bridge-binary-path binary)
          (kargu-bridge--connection nil)
          conn started startup-error)
     (skip-unless (and binary (file-executable-p binary)))
     (unwind-protect
         (progn
           (setq conn (kargu-bridge-start
                       (lambda (_connection error-data)
                         (setq startup-error error-data started t))))
           (kargu-bridge-test--wait (lambda () started))
           (should-not startup-error)
           ,@body)
       (when conn
         (kargu-bridge--close conn "test_cleanup")
         (when (buffer-live-p (kargu-bridge-connection-stderr-buffer conn))
           (kill-buffer (kargu-bridge-connection-stderr-buffer conn)))))))

(ert-deftest kargu-bridge-json-rejects-duplicate-keys-and-trailing-input-test ()
  (dolist (line '("{\"id\":1,\"id\":2}" "{\"params\":{\"x\":false,\"x\":1}}"
                  "{\"a\":[{\"x\":1,\"x\":2}]}" "{} false"))
    (should-error (kargu-bridge--decode line)))
  (let ((decoded (kargu-bridge--decode "{\"n\":null,\"f\":false,\"a\":[],\"o\":{}}")))
    (should (eq (gethash "n" decoded) :json-null))
    (should (eq (gethash "f" decoded) :json-false))
    (should (equal (gethash "a" decoded) []))
    (should (hash-table-p (gethash "o" decoded)))))

(ert-deftest kargu-bridge-null-result-is-delivered-once-test ()
  (let ((conn (kargu-bridge--connection-create :state 'ready)) (count 0) delivered)
    (puthash "e:1" (kargu-bridge--pending-create
                     :callback (lambda (result error-data)
                                 (cl-incf count) (setq delivered (list result error-data))))
             (kargu-bridge-connection-pending conn))
    (dotimes (_ 2)
      (kargu-bridge--dispatch-line conn "{\"jsonrpc\":\"2.0\",\"id\":\"e:1\",\"result\":null}"))
    (should (= count 1))
    (should (equal delivered '(:json-null nil)))
    (should (= 0 (hash-table-count (kargu-bridge-connection-pending conn))))))

(ert-deftest kargu-bridge-reverse-request-is-not-a-response-test ()
  (let ((conn (kargu-bridge--connection-create :state 'ready)) reply)
    (cl-letf (((symbol-function 'kargu-bridge--send)
               (lambda (_connection object) (setq reply object))))
      (kargu-bridge--dispatch-line
       conn "{\"jsonrpc\":\"2.0\",\"id\":\"r:1\",\"method\":\"editor/call_tool\",\"params\":{}}"))
    (should (equal (gethash "id" reply) "r:1"))
    (should (= (gethash "code" (gethash "error" reply)) -32601))))

(ert-deftest kargu-bridge-expired-response-cannot-beat-delayed-timer-test ()
  (let ((conn (kargu-bridge--connection-create :state 'ready)) result error-data)
    (puthash "late" (kargu-bridge--pending-create
                     :deadline (- (float-time) 1)
                     :callback (lambda (r e) (setq result r error-data e)))
             (kargu-bridge-connection-pending conn))
    (kargu-bridge--dispatch-line conn "{\"jsonrpc\":\"2.0\",\"id\":\"late\",\"result\":true}")
    (should-not result)
    (should (equal (gethash "status" (gethash "data" error-data)) "timeout"))))

(ert-deftest kargu-bridge-invalid-envelopes-close-and-release-test ()
  (dolist (line '("[]" "{\"jsonrpc\":\"2.0\",\"id\":1}"
                  "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null,\"error\":{}}"
                  "{\"jsonrpc\":\"1.0\",\"method\":\"x\"}"
                  "{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"id\":null}"))
    (let ((conn (kargu-bridge--connection-create :state 'ready)) (count 0))
      (puthash 9 (kargu-bridge--pending-create :callback (lambda (_r _e) (cl-incf count)))
               (kargu-bridge-connection-pending conn))
      (kargu-bridge--dispatch-line conn line)
      (should (eq (kargu-bridge-connection-state conn) 'closed))
      (should (= count 1)))))

(ert-deftest kargu-bridge-fragmented-and-combined-frames-test ()
  (let ((conn (kargu-bridge--connection-create :state 'ready :process 'fake)) replies)
    (cl-letf (((symbol-function 'kargu-bridge--dispatch-line)
               (lambda (_connection line) (push (kargu-bridge--decode line) replies))))
      (kargu-bridge--filter conn 'fake "{\"x\":\"Tür")
      (should-not replies)
      (kargu-bridge--filter conn 'fake "kçe🦀\"}\n{\"y\":null}\r\n")
      (should-not replies)
      (kargu-bridge--dispatch conn)
      (should (= (length replies) 2))
      (should (equal (gethash "x" (cadr replies)) "Türkçe🦀"))
      (should (string-empty-p (kargu-bridge-connection-partial conn))))))

(ert-deftest kargu-bridge-oversize-fragment-closes-without-newline-test ()
  (let ((conn (kargu-bridge--connection-create :state 'ready :process 'fake :frame-limit 16)))
    (kargu-bridge--filter conn 'fake (make-string 17 ?x))
    (should (eq (kargu-bridge-connection-state conn) 'closed))
    (should (string-empty-p (kargu-bridge-connection-partial conn)))))

(ert-deftest kargu-bridge-stale-process-cannot-touch-replacement-test ()
  (let* ((old (kargu-bridge--connection-create :state 'closed :process 'old))
         (new (kargu-bridge--connection-create :state 'ready :process 'new))
         (kargu-bridge--connection new))
    (kargu-bridge--filter old 'old "ignored\n")
    (cl-letf (((symbol-function 'process-live-p) (lambda (_proc) nil)))
      (kargu-bridge--sentinel old 'old "closed"))
    (should (eq kargu-bridge--connection new))
    (should (eq (kargu-bridge-connection-state new) 'ready))
    (should-not (kargu-bridge-connection-queue new))))

(ert-deftest kargu-bridge-callback-error-cannot-interrupt-cleanup-test ()
  (let ((conn (kargu-bridge--connection-create :state 'ready)) second)
    (puthash "bad" (kargu-bridge--pending-create :callback (lambda (_r _e) (error "Secret")))
             (kargu-bridge-connection-pending conn))
    (puthash "good" (kargu-bridge--pending-create :callback (lambda (_r _e) (setq second t)))
             (kargu-bridge-connection-pending conn))
    (kargu-bridge--close conn "disconnected")
    (should second)
    (should (= 0 (hash-table-count (kargu-bridge-connection-pending conn))))))

(ert-deftest kargu-bridge-real-core-lifecycle-test ()
  (kargu-bridge-test--with-core
    (should (eq (kargu-bridge-status conn) 'ready))
    (let* ((app-reply (kargu-bridge-test--call conn "application/create" (kargu-bridge--object)))
           (app (gethash "application_id" (car app-reply)))
           (session-reply (kargu-bridge-test--call
                           conn "session/create" (kargu-bridge--object "application_id" app)))
           (session (gethash "session_id" (car session-reply)))
           (scope (kargu-bridge--object "application_id" app "session_id" session)))
      (should-not (cadr app-reply))
      (should-not (cadr session-reply))
      (should (equal (gethash "state" (car (kargu-bridge-test--call conn "session/snapshot" scope))) "idle"))
      (should (cadr (kargu-bridge-test--call conn "session/prompt" scope)))
      (should (equal (gethash "status" (car (kargu-bridge-test--call conn "session/close" scope))) "closed")))
    (kargu-bridge-stop conn)
    (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-status conn) 'closed)))
    (should (= 0 (hash-table-count (kargu-bridge-connection-pending conn))))
    (should-not (kargu-bridge-connection-stop-timer conn))))

(ert-deftest kargu-bridge-startup-waiters-share-connection-and-cancel-independently-test ()
  (let* ((conn (kargu-bridge--connection-create :state 'starting))
         (kargu-bridge--connection conn) first second)
    (let ((cancel (kargu-bridge-ensure (lambda (&rest reply) (setq first reply)))))
      (kargu-bridge-ensure (lambda (&rest reply) (setq second reply)))
      (should (= (length (kargu-bridge-connection-ready-waiters conn)) 2))
      (funcall cancel)
      (should (= (length (kargu-bridge-connection-ready-waiters conn)) 1))
      (kargu-bridge--notify-ready conn nil)
      (kargu-bridge--notify-ready conn nil)
      (should-not first)
      (should (equal second (list conn nil)))
      (should-not (kargu-bridge-connection-ready-waiters conn)))))

(ert-deftest kargu-bridge-closing-startup-fails-all-waiters-once-test ()
  (let* ((conn (kargu-bridge--connection-create :state 'binding))
         (kargu-bridge--connection conn) (count 0) error-data)
    (dotimes (_ 2)
      (kargu-bridge-ensure (lambda (_conn error) (cl-incf count) (setq error-data error))))
    (kargu-bridge--close conn "test_failure")
    (kargu-bridge--close conn "test_failure")
    (should (= count 2))
    (should (equal (gethash "status" (gethash "data" error-data)) "test_failure"))
    (should-not (kargu-bridge-connection-ready-waiters conn))))

(ert-deftest kargu-bridge-real-native-find-files-test ()
  (kargu-bridge-test--with-core
    (let ((root (make-temp-file "kargu-native-find-" t)) finished reply failure)
      (unwind-protect
          (progn
            (write-region "fixture" nil (expand-file-name "kaynak.el" root) nil 'silent)
            (should (hash-table-p (kargu-bridge-connection-read-scope conn)))
            (kargu-bridge-find-files
             conn (kargu-bridge--object "root" root "path" :json-null "pattern" "*.el"
                                       "skip_directories" [] "max_files" 2000 "max_directories" 2000)
             (lambda (result error-data) (setq reply result failure error-data finished t)))
            (kargu-bridge-test--wait (lambda () finished))
            (should-not failure)
            (should (equal (gethash "text" reply) "kaynak.el\n"))
            (should (eq (gethash "truncated" reply) :json-false)))
        (delete-directory root t)))))

(ert-deftest kargu-bridge-real-native-list-files-test ()
  (kargu-bridge-test--with-core
    (let ((root (make-temp-file "kargu-native-list-" t)) finished reply failure)
      (unwind-protect
          (progn
            (write-region "fixture" nil (expand-file-name "kaynak.el" root) nil 'silent)
            (kargu-bridge-list-files
             conn (kargu-bridge--object "root" root "path" :json-null
                                       "skip_directories" [])
             (lambda (result error-data) (setq reply result failure error-data finished t)))
            (kargu-bridge-test--wait (lambda () finished))
            (should-not failure)
            (should (string-search "kaynak.el" (gethash "text" reply)))
            (should (equal (gethash "outcome" reply) "ok"))
            (should-not (gethash "entries" reply))
            (should (eq (gethash "truncated" reply) :json-false)))
        (delete-directory root t)))))

(ert-deftest kargu-bridge-missing-listing-capability-fails-without-disconnecting-test ()
  (let ((conn (kargu-bridge--connection-create
               :state 'ready :capabilities ["workspace_find_files"]
               :read-scope (kargu-bridge--object)))
        failure (count 0))
    (cl-letf (((symbol-function 'kargu-bridge-call) (lambda (&rest _) (ert-fail "Unnegotiated method called"))))
      (should-not (kargu-bridge-list-files
                   conn (kargu-bridge--object)
                   (lambda (_result error-data) (cl-incf count) (setq failure error-data))))
      (should (= count 1))
      (should (equal (gethash "status" (gethash "data" failure)) "unavailable"))
      (should (eq (kargu-bridge-status conn) 'ready)))))

(ert-deftest kargu-bridge-listing-only-capability-binds-read-service-test ()
  (let ((conn (kargu-bridge--connection-create :capabilities ["workspace_list_files_ls"])) ready failure methods)
    (cl-letf (((symbol-function 'kargu-bridge-call)
               (lambda (_conn method _arguments callback &rest _options)
                 (push method methods)
                 (funcall callback
                          (if (equal method "application/create")
                              (kargu-bridge--object "application_id" "app_fixture")
                            (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_fixture")) nil))))
      (kargu-bridge--bind-read-service conn (lambda (value error-data) (setq ready value failure error-data)))
      (should-not failure)
      (should (eq ready conn))
      (should (eq (kargu-bridge-status conn) 'ready))
      (should (hash-table-p (kargu-bridge-connection-read-scope conn)))
      (should (equal (nreverse methods) '("application/create" "session/create"))))))

(ert-deftest kargu-bridge-real-concurrent-ensure-binds-one-service-session-test ()
  (let* ((binary (getenv "KARGU_CORE_TEST_BINARY"))
         (kargu-bridge-binary-path binary) (kargu-bridge--connection nil)
         first second)
    (skip-unless (and binary (file-executable-p binary)))
    (unwind-protect
        (progn
          (kargu-bridge-ensure (lambda (conn error-data) (setq first (list conn error-data))))
          (kargu-bridge-ensure (lambda (conn error-data) (setq second (list conn error-data))))
          (kargu-bridge-test--wait (lambda () (and first second)))
          (should-not (cadr first))
          (should-not (cadr second))
          (should (eq (car first) (car second)))
          (should (eq (car first) kargu-bridge--connection))
          (should (hash-table-p (kargu-bridge-connection-read-scope (car first))))
          (should-not (kargu-bridge-connection-ready-waiters (car first))))
      (when kargu-bridge--connection
        (kargu-bridge--close kargu-bridge--connection "test_cleanup")
        (kill-buffer (kargu-bridge-connection-stderr-buffer kargu-bridge--connection))))))

(ert-deftest kargu-bridge-ensure-missing-binary-fails-once-test ()
  (let ((kargu-bridge-binary-path "/nonexistent-kargu-test-path/kargu-core")
        (kargu-bridge--connection nil) (count 0) failure)
    (funcall (kargu-bridge-ensure
              (lambda (conn error-data)
                (should-not conn) (cl-incf count) (setq failure error-data))))
    (should (= count 1))
    (should (equal (gethash "status" (gethash "data" failure)) "startup_failed"))
    (should-not kargu-bridge--connection)))

(ert-deftest kargu-bridge-real-timeout-and-owner-cancel-test ()
  (kargu-bridge-test--with-core
    (let (reply timeout-id)
      (cl-letf (((symbol-function 'kargu-bridge--send) #'ignore))
        (setq timeout-id (kargu-bridge-call conn "ping" (kargu-bridge--object)
                                           (lambda (_result err) (setq reply err)) :timeout 0.02)))
      (kargu-bridge-test--wait (lambda () reply))
      (should (equal (gethash "status" (gethash "data" reply)) "timeout"))
      (should-not (gethash timeout-id (kargu-bridge-connection-pending conn))))
    (let ((owner (generate-new-buffer " *bridge-owner*")) reply request-id)
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'kargu-bridge--send) #'ignore))
              (setq request-id (kargu-bridge-call conn "ping" (kargu-bridge--object)
                                                 (lambda (_result err) (setq reply err)) :owner owner)))
            (kill-buffer owner)
            (should (equal (gethash "status" (gethash "data" reply)) "owner_closed"))
            (should-not (gethash request-id (kargu-bridge-connection-pending conn))))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest kargu-bridge-real-process-death-releases-pending-test ()
  (kargu-bridge-test--with-core
    (let (reply)
      (cl-letf (((symbol-function 'kargu-bridge--send) #'ignore))
        (kargu-bridge-call conn "ping" (kargu-bridge--object)
                           (lambda (_result err) (setq reply err))))
      (delete-process (kargu-bridge-connection-process conn))
      (kargu-bridge-test--wait (lambda () reply))
      (should (eq (kargu-bridge-status conn) 'closed))
      (should (= 0 (hash-table-count (kargu-bridge-connection-pending conn)))))))

(provide 'tests/test-bridge)
;;; test-bridge.el ends here
