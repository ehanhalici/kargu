;;; test-native-circuit.el --- Native circuit view ownership contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Circuit policy/probe/counting tests live in Rust.  These tests cover only
;; ordered detached projection, explicit reset delivery and live UI composition.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tests/test-native-retry)
(require 'kargu/bridge/circuit)

(cl-defun kargu-circuit-test--view (&key (sequence 1) (state "open") (failures 4)
                                         (id "circuit_fixture") (provider "fixture"))
  "Create a detached native fixture with SEQUENCE, STATE and FAILURES.
ID and PROVIDER identify only its UI observation."
  (kargu-bridge--object "circuit_id" id "provider" provider "sequence" sequence
                        "state" state "failures" failures "cooldown_remaining_ms" 1000
                        "probe_inflight" :json-false))

(defmacro kargu-circuit-test--with-peer (&rest body)
  "Run BODY with an isolated live native application binding."
  (declare (indent 0) (debug t))
  `(let* ((application (kargu-application-create))
          (connection (kargu-bridge--connection-create :state 'ready :epoch "epoch"))
          (scope (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_fixture"))
          (binding (kargu-bridge-application--make :connection connection :scope scope :state :ready)))
     (puthash :native-core binding (kargu-application-services application))
     ,@body))

(ert-deftest kargu-native-circuit-scope-projection-is-structural-and-detached-test ()
  "Native scope equality compares identifiers and never shares mutable strings."
  (kargu-circuit-test--with-peer
   (let ((copy (kargu-bridge-application-current-scope application connection)))
     (should-not (eq scope copy))
     (should (kargu-bridge-application-scope-equal-p scope copy))
     (aset (gethash "application_id" copy) 0 ?X)
     (should-not (kargu-bridge-application-scope-equal-p scope copy))
     (should (equal (gethash "application_id" (kargu-bridge-application-scope binding)) "app_fixture"))
     (should-not (kargu-bridge-application-scope-equal-p (kargu-bridge--object) (kargu-bridge--object)))
     (setf (kargu-bridge-application-state binding) :closed)
     (should-not (kargu-bridge-application-current-scope application connection)))))

(ert-deftest kargu-native-circuit-projections-are-detached-and-cannot-undo-reset-test ()
  "Native counters may reset; monotonic observation order rejects old snapshots."
  (kargu-circuit-test--with-peer
   (let ((input (kargu-circuit-test--view)))
     (should-not (kargu-bridge-circuit-observe application connection scope input t))
     (puthash "state" "closed" input)
     (should (equal (gethash "state" (kargu-bridge-circuit-view application "fixture")) "open"))
     (kargu-bridge-circuit-observe application connection scope
                                   (kargu-circuit-test--view :sequence 2 :state "closed" :failures 0))
     (kargu-bridge-circuit-observe application connection scope (kargu-circuit-test--view) t)
     (let ((view (kargu-bridge-circuit-view application "fixture")))
       (should (= (gethash "failures" view) 0))
       (should (equal (gethash "state" view) "closed"))
       (aset (gethash "circuit_id" view) 0 ?X)
       (should (equal (gethash "circuit_id" (kargu-bridge-circuit-view application "fixture")) "circuit_fixture"))))))

(ert-deftest kargu-native-circuit-foreign-and-replaced-bindings-never-retarget-view-test ()
  "An old ready connection cannot overwrite a replacement application's view."
  (kargu-circuit-test--with-peer
   (let ((foreign (kargu-application-create))
         (replacement (kargu-bridge--connection-create :state 'ready)))
     (kargu-bridge-circuit-observe application connection scope (kargu-circuit-test--view) t)
     (should-error (kargu-bridge-circuit-observe foreign connection scope (kargu-circuit-test--view)))
     (should-not (gethash :native-circuits (kargu-application-services foreign)))
     (setf (kargu-bridge-application-connection binding) replacement)
     (should-not (kargu-bridge-circuit-view application "fixture"))
     (should-error (kargu-bridge-circuit-observe application connection scope (kargu-circuit-test--view :sequence 9)))
     (kargu-bridge-circuit-observe application replacement scope (kargu-circuit-test--view :sequence 1 :state "closed" :failures 0) t)
     (should (= (gethash "sequence" (kargu-bridge-circuit-view application "fixture")) 1)))))

(ert-deftest kargu-native-circuit-display-cache-is-bounded-without-replaying-evicted-observations-test ()
  "Eviction only loses a display value; a late older snapshot cannot resurrect it."
  (kargu-circuit-test--with-peer
   (dotimes (index 257)
     (kargu-bridge-circuit-observe
      application connection scope
      (kargu-circuit-test--view :sequence (1+ index) :id (format "circuit_%d" index)
                                :provider (format "provider_%d" index) :state "closed" :failures 0) t))
   (let ((service (gethash :native-circuits (kargu-application-services application))))
     (should (= (hash-table-count (kargu-bridge-circuits-views service)) 256))
     (should (= (hash-table-count (kargu-bridge-circuits-latest service)) 256))
     (should (= (length (kargu-bridge-circuits-order service)) 256))
     (should-not (kargu-bridge-circuit-view application "provider_0"))
     (kargu-bridge-circuit-observe application connection scope
                                   (kargu-circuit-test--view :id "circuit_0" :provider "provider_0") t)
     (should-not (kargu-bridge-circuit-view application "provider_0"))
     (should (= (kargu-bridge-circuits-sequence service) 257)))))

(ert-deftest kargu-native-circuit-reset-is-explicit-owned-and-never-starts-a-core-test ()
  "Reset stays on a captured lease, and absent/closed leases cannot reconnect."
  (kargu-circuit-test--with-peer
   (let (called reply result failure)
     (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (&rest _) (ert-fail "Unexpected startup")))
               ((symbol-function 'kargu-bridge-call)
                (lambda (peer method params callback &rest _)
                  (should (eq peer connection)) (should (equal method "api/circuit/reset"))
                  (should (kargu-bridge-application-scope-equal-p (gethash "scope" params) scope))
                  (should (equal (gethash "provider" params) "fixture"))
                  (setq called t reply callback))))
       (kargu-bridge-circuit-reset application "fixture" (lambda (_ error-data) (setq failure error-data)))
       (should failure) (should-not called)
       (kargu-bridge-circuit-observe application connection scope (kargu-circuit-test--view) t)
       (kargu-bridge-circuit-reset application "fixture" (lambda (value error-data) (setq result value failure error-data)))
       (should called)
       (funcall reply (kargu-bridge--object "circuits" (vector (kargu-circuit-test--view :sequence 2 :state "closed" :failures 0))) nil)
       (should result) (should-not failure)
       (should (= (gethash "failures" (kargu-bridge-circuit-view application "fixture")) 0))
       (setf (kargu-bridge-application-state binding) :closed)
       (setq called nil)
       (kargu-bridge-circuit-reset application nil (lambda (_ error-data) (setq failure error-data)))
       (should failure) (should-not called)))))

(ert-deftest kargu-native-circuit-close-before-delivery-skips-obsolete-view-test ()
  "A closing view cannot replace the real native cancellation with a DTO error."
  (kargu-circuit-test--with-peer
    (let ((handle (kargu-transport--handle :connection connection :native-scope scope)) failure)
      (setf (kargu-bridge-application-state binding) :closing)
      (kargu-transport--deliver
       handle (list :application application :else (lambda (error-data) (setq failure error-data)))
       (kargu-bridge--object "failure" (kargu-bridge--object "code" "cancelled" "category" "cancelled" "message" "synthetic-cancelled")
                             "circuit" (kargu-circuit-test--view)) nil)
      (should (eq (kargu-result-err-code failure) :cancelled))
      (should (equal (kargu-result-err-message failure) "synthetic-cancelled"))
      (should (eq (kargu-transport-handle-state handle) :finished))
      (should-not (gethash :native-circuits (kargu-application-services application))))))

(ert-deftest kargu-native-circuit-real-transport-projection-reset-and-admission-test ()
  "Core refuses a cooling circuit before socket/debit; native reset permits IO."
  (kargu-bridge-test--with-core
   (let* ((application (kargu-application-create)) (budget (kargu-budget-create))
          (posts 0) finished failure reset-result
          (server (kargu-stream-test--server
                   "" nil nil (lambda (_) (cl-incf posts)) nil nil nil
                   (list (list :status 503 :body "")
                         (list :status 200 :body "{\"choices\":[{\"message\":{\"content\":\"ok\"}}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}"))))
          (url (format "http://127.0.0.1:%d/chat" (process-contact server :service))))
     (unwind-protect
         (progn
           (dotimes (attempt 3)
             (setq finished nil failure nil)
             (when (= attempt 2)
               (kargu-bridge-circuit-reset application "fixture"
                                           (lambda (result error-data) (should-not error-data) (setq reset-result result)))
               (kargu-bridge-test--wait (lambda () reset-result)))
             (kargu-transport-request
              'post url :application application :budget budget :provider "fixture" :body "{}" :timeout 3
              :retry '(("retry_max" . 0)) :circuit '(("failure_threshold" . 1) ("cooldown_ms" . 30000))
              :then (lambda (_) (setq finished t)) :else (lambda (error-data) (setq failure error-data finished t)))
             (kargu-bridge-test--wait (lambda () finished))
             (if (< attempt 2) (should failure) (should-not failure))
             (should (= posts (if (< attempt 2) 1 2)))
             (should (= (kargu-run-budget-requests-spent budget) (if (< attempt 2) 1 2))))
           (let ((view (kargu-bridge-circuit-view application "fixture")))
             (should (equal (gethash "state" view) "closed"))
             (should (= (gethash "failures" view) 0))))
       (kargu-budget-seal budget)
       (delete-process server)))))

(provide 'tests/test-native-circuit)
;;; test-native-circuit.el ends here
