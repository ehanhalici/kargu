;;; test-native-application.el --- Native scope lease contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Only control RPC delivery is mocked here; actual drain is tested in Rust.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'kargu/bridge/application)
(require 'kargu/api/transport)

(defmacro kargu-native-app-test--with-peer (&rest body)
  "Run BODY in an isolated fake control peer."
  (declare (indent 0) (debug t))
  `(let ((connection (kargu-bridge--connection-create
                      :state 'ready :epoch "fixture"
                      :capabilities ["application_lifecycle" "session_lifecycle" "application_close"])) calls)
     (cl-letf (((symbol-function 'kargu-bridge-call)
                (lambda (_connection method params callback &rest options)
                  (push (list method params callback options) calls) "fixture-call")))
       (unwind-protect (progn ,@body)
         ;; Finalizers must not use a fake peer after its RPC interception ends.
         (setf (kargu-bridge-connection-state connection) 'closed)))))

(defun kargu-native-app-test--reply (pending method result &optional failure)
  "Deliver RESULT/FAILURE to METHOD's latest recorded entry in PENDING."
  (let ((call (cl-find method pending :key #'car :test #'equal)))
    (should call)
    (funcall (nth 2 call) result failure)))

(ert-deftest kargu-native-application-coalesces-and-detaches-scope-test ()
  "Waiters share creation but cannot mutate a sibling's native authority."
  (kargu-native-app-test--with-peer
   (let ((app (kargu-application-create)) first second (cancelled 0))
     (kargu-bridge-application-ensure connection app (lambda (scope _) (setq first scope)))
     (funcall (kargu-bridge-application-ensure connection app (lambda (&rest _) (cl-incf cancelled))))
     (kargu-bridge-application-ensure connection app (lambda (scope _) (setq second scope)))
     (should (= (length calls) 1))
     (kargu-native-app-test--reply calls "application/create" (kargu-bridge--object "application_id" "app_fixture"))
     (kargu-native-app-test--reply calls "session/create"
                                   (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_fixture"))
     (should (zerop cancelled))
     (should-not (eq first second))
     (should (equal (gethash "application_id" first) (gethash "application_id" second)))
     (should (equal (gethash "session_id" first) (gethash "session_id" second)))
     (aset (gethash "session_id" first) 0 ?X)
     (should (equal (gethash "session_id" second) "sess_fixture"))
     (kargu-bridge-application-ensure connection app
                                      (lambda (scope _) (should (equal (gethash "session_id" scope) "sess_fixture")))))))

(ert-deftest kargu-native-application-close-during-create-releases-late-acquisition-test ()
  "A late create is closed without creating a session or reviving a waiter."
  (kargu-native-app-test--with-peer
   (let ((app (kargu-application-create)) (failed 0) (closed 0))
     (kargu-bridge-application-ensure connection app
                                      (lambda (scope failure) (should-not scope) (should failure) (cl-incf failed)))
     (kargu-bridge-application-close app (lambda (_ failure) (should-not failure) (cl-incf closed)))
     (should (= failed 1))
     (should (zerop closed))
     (kargu-native-app-test--reply calls "application/create" (kargu-bridge--object "application_id" "app_fixture"))
     (should-not (cl-find "session/create" calls :key #'car :test #'equal))
     (kargu-native-app-test--reply calls "application/close" (kargu-bridge--object "status" "closed"))
     (should (= closed 1))
     (should (= failed 1))
     (let ((before (length calls)))
       (kargu-bridge-application-close app (lambda (&rest _) (cl-incf closed)))
       (should (= (length calls) before))
       (should (= closed 2))))))

(ert-deftest kargu-native-application-reentrant-close-revokes-undelivered-scopes-test ()
  "A scope callback closing its owner prevents later waiters from borrowing it."
  (kargu-native-app-test--with-peer
   (let ((app (kargu-application-create)) (ready 0) (refused 0))
     (kargu-bridge-application-ensure connection app
                                      (lambda (_scope failure)
                                        (should-not failure) (cl-incf ready)
                                        (kargu-bridge-application-close app)))
     (kargu-bridge-application-ensure connection app
                                      (lambda (scope failure) (should-not scope) (should failure) (cl-incf refused)))
     (kargu-native-app-test--reply calls "application/create" (kargu-bridge--object "application_id" "app_fixture"))
     (kargu-native-app-test--reply calls "session/create"
                                   (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_fixture"))
     (should (= ready 1))
     (should (= refused 1))
     (kargu-native-app-test--reply calls "application/close" (kargu-bridge--object "status" "closed")))))

(ert-deftest kargu-native-application-close-and-create-failure-finish-once-test ()
  "An explicit close remains revoked even when pending creation itself fails."
  (kargu-native-app-test--with-peer
   (let ((app (kargu-application-create)) (closed 0))
     (kargu-bridge-application-ensure connection app #'ignore)
     (kargu-bridge-application-close app (lambda (_ failure) (should failure) (cl-incf closed)))
     (kargu-native-app-test--reply calls "application/create" nil (kargu-bridge--fault "resource_limit"))
     (should (= closed 1))
     (let ((before (length calls)))
       (kargu-bridge-application-ensure connection app (lambda (scope failure) (should-not scope) (should failure)))
       (should (= (length calls) before))))))

(ert-deftest kargu-native-application-old-core-is-rejected-before-create-test ()
  "Unavailable application-close support never silently uses the root scope."
  (kargu-native-app-test--with-peer
   (setf (kargu-bridge-connection-capabilities connection) ["application_lifecycle" "session_lifecycle"])
   (let (refused)
     (kargu-bridge-application-ensure connection (kargu-application-create)
                                      (lambda (scope failure) (should-not scope) (setq refused failure)))
     (should refused)
     (should-not calls))))

(ert-deftest kargu-native-application-sync-startup-keeps-every-cleanup-test ()
  "Synchronous connection readiness cannot overwrite a pending scope ticket."
  (kargu-native-app-test--with-peer
   (setf (kargu-bridge-connection-capabilities connection)
         (vconcat ["api_request"] (kargu-bridge-connection-capabilities connection)))
   (let ((app (kargu-application-create)) (cleaned 0))
     (cl-letf (((symbol-function 'kargu-bridge-ensure)
                (lambda (callback) (funcall callback connection nil) (lambda () (cl-incf cleaned)))))
       (let* ((handle (kargu-transport-request 'post "http://localhost:1" :body "{}" :application app
                                               :then #'ignore :else #'ignore))
              (binding (gethash :native-core (kargu-application-services app))))
         (should (= (length (kargu-bridge-application-waiters binding)) 1))
         (kargu-transport-cancel handle)
         (should (= cleaned 1))
         (should-not (kargu-bridge-application-waiters binding))
         (kargu-native-app-test--reply calls "application/create" (kargu-bridge--object "application_id" "app_fixture"))
         (kargu-native-app-test--reply calls "session/create"
                                       (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_fixture"))
         (should-not (cl-find "api/request" calls :key #'car :test #'equal)))))))

(ert-deftest kargu-native-application-startup-owner-death-never-posts-test ()
  "Owner kill or mode change revokes both startup delivery and its late POST."
  (dolist (mode '(kill mode))
    (let ((owner (generate-new-buffer " *kargu-native-startup-owner*"))
          ready (removed 0) (posts 0) (deliveries 0) handle)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-bridge-ensure)
                     (lambda (callback) (setq ready callback) (lambda () (cl-incf removed))))
                    ((symbol-function 'kargu-bridge-call) (lambda (&rest _) (cl-incf posts))))
            (with-current-buffer owner
              (setq handle (kargu-transport-request 'post "http://localhost:1" :body "{}"
                                                    :then (lambda (_) (cl-incf deliveries))
                                                    :else (lambda (_) (cl-incf deliveries)))))
            (if (eq mode 'kill) (kill-buffer owner) (with-current-buffer owner (text-mode)))
            (should (eq (kargu-transport-handle-state handle) :cancelled))
            (funcall ready (kargu-bridge--connection-create :state 'ready :capabilities ["api_request"]) nil)
            (should (= removed 1))
            (should (zerop posts))
            (should (zerop deliveries)))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest kargu-native-application-late-session-callback-cannot-revive-closed-test ()
  "A delayed session result cannot publish a scope after native close finished."
  (kargu-native-app-test--with-peer
   (let ((app (kargu-application-create)) (deliveries 0))
     (kargu-bridge-application-ensure connection app (lambda (&rest _) (cl-incf deliveries)))
     (kargu-native-app-test--reply calls "application/create" (kargu-bridge--object "application_id" "app_fixture"))
     (kargu-bridge-application-close app)
     (kargu-native-app-test--reply calls "application/close" (kargu-bridge--object "status" "closed"))
     (kargu-native-app-test--reply calls "session/create"
                                   (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_fixture"))
     (should (= deliveries 1))
     (let ((binding (gethash :native-core (kargu-application-services app))))
       (should (eq (kargu-bridge-application-state binding) :closed))
       (should-not (kargu-bridge-application-scope binding))))))

(ert-deftest kargu-native-application-failed-startup-close-is-revoked-before-observer-test ()
  "Closing a failed startup revokes the lease before reentrant observers run."
  (kargu-native-app-test--with-peer
   (let ((app (kargu-application-create)) (refused 0))
     (kargu-bridge-application-ensure
      connection app
      (lambda (_scope failure)
        (should failure)
        (kargu-bridge-application-close
         app (lambda (&rest _)
               (kargu-bridge-application-ensure
                connection app (lambda (scope err) (should-not scope) (should err) (cl-incf refused)))))))
     (kargu-native-app-test--reply calls "application/create" nil (kargu-bridge--fault "resource_limit"))
     (should (= refused 1))
     (should (= (length calls) 1)))))

(provide 'tests/test-native-application)
;;; test-native-application.el ends here
