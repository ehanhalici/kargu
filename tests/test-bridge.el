;;; test-bridge.el --- Rust IPC and lifecycle contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Set KARGU_CORE_TEST_BINARY to the built binary to run real-pipe checks.
;; No model, user credential or real session file is used.  Approval fixtures
;; run only explicit printf commands in temporary directories.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'kargu/bridge)
(require 'kargu/bridge/approval)

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
     (unless (and binary (file-executable-p binary))
       (ert-skip "A configured native test binary is required"))
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

(defun kargu-bridge-test--command (root script)
  "Build explicit fixture arguments for SCRIPT in ROOT with no inherited env."
  (kargu-bridge--object "root" root "mode" "agent" "program" (executable-find "sh")
                        "arguments" (vector "-c" script) "cwd" :json-null "timeout_ms" 1000
                        "environment" (kargu-bridge--object) "config_revision" 1 "policy_revision" 1))

(ert-deftest kargu-bridge-command-approval-real-pipe-and-exact-capture-test ()
  "Only the captured action runs; duplicate UI decisions cannot execute twice."
  (kargu-bridge-test--with-core
    (let* ((root (make-temp-file "kargu-approved-command-" t))
           (args (kargu-bridge-test--command root "printf original"))
           finished reply failure decision details)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-present-confirmation)
                     (lambda (request)
                       (when (eq (kargu-confirmation-operation request) :prompt)
                         (setq decision (plist-get (kargu-confirmation-options request) :on-decision)
                               details (plist-get (kargu-confirmation-options request) :details))))))
            (kargu-bridge-execute conn args (lambda (result error-data) (setq reply result failure error-data finished t)))
            (puthash "arguments" ["-c" "printf mutated"] args)
            (kargu-bridge-test--wait (lambda () decision))
            (should (string-search "original" details))
            (should-not (string-search "mutated" details))
            (should (equal (gethash "status" (car (kargu-bridge-test--call conn "ping" (kargu-bridge--object)))) "ok"))
            (funcall decision :approve) (funcall decision :approve)
            (kargu-bridge-test--wait (lambda () finished))
            (should-not failure)
            (should (equal (gethash "stdout" reply) "original"))
            (should (equal (gethash "outcome" reply) "ok"))
            (should (= 0 (hash-table-count (kargu-bridge-connection-reverse-cleanups conn)))))
        (delete-directory root t)))))

(ert-deftest kargu-bridge-command-headless-and-quit-reject-without-effects-test ()
  "Missing UI and keyboard quit never grant arbitrary execution."
  (kargu-bridge-test--with-core
    (let ((root (make-temp-file "kargu-rejected-command-" t)))
      (unwind-protect
          (dolist (quit '(nil t))
            (let (finished failure)
              (cl-letf (((symbol-function 'kargu-present-confirmation)
                         (lambda (request)
                           (when (eq (kargu-confirmation-operation request) :prompt)
                             (if quit (signal 'quit nil)
                               (funcall (plist-get (kargu-confirmation-options request) :on-decision) :reject))))))
                (kargu-bridge-execute conn (kargu-bridge-test--command root "printf bad > effect")
                                      (lambda (_result error-data) (setq failure error-data finished t)))
                (kargu-bridge-test--wait (lambda () finished))
                (should (equal (gethash "status" (gethash "data" failure)) "rejected"))
                (should-not (file-exists-p (expand-file-name "effect" root)))
                (should (= 0 (hash-table-count (kargu-bridge-connection-reverse-cleanups conn)))))))
        (delete-directory root t)))))

(ert-deftest kargu-bridge-command-owner-close-dismisses-ui-and-rejects-late-click-test ()
  "Closing the captured source owner dismisses only its confirmation."
  (kargu-bridge-test--with-core
    (let ((root (make-temp-file "kargu-owner-command-" t))
          (owner (generate-new-buffer " *kargu-command-owner*")) decision cancelled failure)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-present-confirmation)
                     (lambda (request)
                       (pcase (kargu-confirmation-operation request)
                         (:prompt (setq decision (plist-get (kargu-confirmation-options request) :on-decision)) 'owned-handle)
                         (:cancel (setq cancelled t))))))
            (kargu-bridge-execute conn (kargu-bridge-test--command root "printf bad > effect")
                                  (lambda (_result error-data) (setq failure error-data)) :owner owner)
            (kargu-bridge-test--wait (lambda () decision))
            (kill-buffer owner)
            (should cancelled)
            (funcall decision :approve)
            (should (equal (gethash "status" (gethash "data" failure)) "owner_closed"))
            (should (= 0 (hash-table-count (kargu-bridge-connection-reverse-cleanups conn)))))
        (when (buffer-live-p owner) (kill-buffer owner))
        (kargu-bridge-stop conn)
        (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-status conn) 'closed)))
        (should-not (file-exists-p (expand-file-name "effect" root)))
        (delete-directory root t)))))

(ert-deftest kargu-bridge-command-server-revoke-dismisses-reverse-ui-test ()
  "Rust owner closure cancels its reverse UI and makes a late approval inert."
  (kargu-bridge-test--with-core
    (let ((root (make-temp-file "kargu-revoke-command-" t)) decision cancelled finished failure)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-present-confirmation)
                     (lambda (request)
                       (pcase (kargu-confirmation-operation request)
                         (:prompt (setq decision (plist-get (kargu-confirmation-options request) :on-decision)) 'reverse-handle)
                         (:cancel (setq cancelled t))))))
            (kargu-bridge-execute conn (kargu-bridge-test--command root "printf bad > effect")
                                  (lambda (_result error-data) (setq failure error-data finished t)))
            (kargu-bridge-test--wait (lambda () decision))
            (kargu-bridge-test--call conn "session/close" (kargu-bridge-connection-read-scope conn))
            (kargu-bridge-test--wait (lambda () finished))
            (should cancelled)
            (should (equal (gethash "status" (gethash "data" failure)) "stale_owner"))
            (funcall decision :approve)
            (should-not (file-exists-p (expand-file-name "effect" root)))
            (should (= 0 (hash-table-count (kargu-bridge-connection-reverse-cleanups conn)))))
        (delete-directory root t)))))

(ert-deftest kargu-bridge-json-rejects-duplicate-keys-and-trailing-input-test ()
  (dolist (line '("{\"id\":1,\"id\":2}" "{\"params\":{\"x\":false,\"x\":1}}"
                  "{\"a\":[{\"x\":1,\"x\":2}]}" "{} false"))
    (should-error (kargu-bridge--decode line)))
  (let ((decoded (kargu-bridge--decode "{\"n\":null,\"f\":false,\"a\":[],\"o\":{}}")))
    (should (eq (gethash "n" decoded) :json-null))
    (should (eq (gethash "f" decoded) :json-false))
    (should (equal (gethash "a" decoded) []))
    (should (hash-table-p (gethash "o" decoded)))))

(ert-deftest kargu-bridge-command-unsolicited-approval-is-rejected-without-ui-test ()
  "An unsolicited reverse review cannot borrow authority from another request."
  (let ((conn (kargu-bridge--connection-create :state 'ready)) reply)
    (cl-letf (((symbol-function 'kargu-bridge--send) (lambda (_conn value) (setq reply value)))
              ((symbol-function 'kargu-present-confirmation) (lambda (&rest _) (ert-fail "Unsolicited approval UI"))))
      (kargu-bridge--dispatch-line
       conn "{\"jsonrpc\":\"2.0\",\"id\":\"r:unknown:1\",\"method\":\"editor/request_approval\",\"params\":{\"request_id\":\"e:unknown:1\"}}")
      (should (eq (gethash "approved" (gethash "result" reply)) :json-false))
      (should (eq (kargu-bridge-status conn) 'ready)))))

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

(ert-deftest kargu-bridge-unlimited-forward-request-keeps-owner-cancel-test ()
  "An unlimited forward waiter has no timer but still loses its source lease."
  (let ((connection (kargu-bridge--connection-create :state 'ready :epoch "test"))
        (owner (generate-new-buffer " *kargu-unlimited-owner*")) id failure)
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-bridge--send) #'ignore))
          (setq id (kargu-bridge-call connection "workspace/grep" (kargu-bridge--object)
                                      (lambda (_value error-data) (setq failure error-data))
                                      :owner owner :timeout :unlimited))
          (let ((entry (gethash id (kargu-bridge-connection-pending connection))))
            (should entry)
            (should-not (kargu-bridge--pending-deadline entry))
            (should-not (kargu-bridge--pending-timer entry)))
          (kill-buffer owner)
          (should (equal (gethash "status" (gethash "data" failure)) "owner_closed"))
          (should-not (gethash id (kargu-bridge-connection-pending connection))))
      (when (buffer-live-p owner) (kill-buffer owner)))))

(provide 'tests/test-bridge)
;;; test-bridge.el ends here
