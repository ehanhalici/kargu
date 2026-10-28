;;; test-native-edit-activity.el --- Physical editor activity lifetime -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Actual forward waiters and bridge notification/EOF routing with a held peer.
;; The peer never mutates files; real issued writes use the pipe fixture.

;;; Code:

(require 'tests/test-bridge)
(require 'tests/test-native-edit-document)
(require 'kargu/bridge/edit/activity)

(defmacro kargu-edit-activity-test--with-peer (&rest body)
  "Evaluate BODY with held native messages and a private originating buffer."
  (declare (indent 0) (debug t))
  `(let* ((kargu-bridge-edit-activity--active nil)
          (connection (kargu-bridge--connection-create :state 'ready :epoch "old"))
          (replacement (kargu-bridge--connection-create :state 'ready :epoch "new"))
          (source (generate-new-buffer " *kargu-activity-source*"))
          (scope (kargu-bridge--object "application_id" "app_fixture" "session_id" "session_fixture"))
          (artifact (kargu-bridge-edit-artifact--make
                     :application 'fixture :connection connection :scope scope
                     :origin "editor_source_12345678-1234-4234-8234-123456789abc"
                     :id "edit_preparation_fixture"))
          (sent nil) (observations nil))
     (ignore observations)
     (cl-letf (((symbol-function 'kargu-bridge--send)
                (lambda (peer message) (push (cons peer message) sent)))
               ((symbol-function 'kargu-bridge-application-current-scope)
                (lambda (&rest _) scope)))
       (unwind-protect (progn ,@body)
         (kargu-bridge--close connection "fixture_done")
         (kargu-bridge--close replacement "fixture_done")
         (when (buffer-live-p source) (kill-buffer source))))))

(cl-defun kargu-edit-activity-test--start (artifact source &key handler callback valid-p)
  "Start ARTIFACT from SOURCE with HANDLER, CALLBACK and VALID-P overrides."
  (kargu-bridge-edit-activity-start
   artifact :edit-id "editor_edit_12345678-1234-4234-8234-123456789abc" :revision 1
   :preflight-digest (make-string 64 ?a) :journal-directory "/unused-private-fixture"
   :buffer source :handler (or handler (lambda (_) :observed))
   :callback (or callback #'ignore) :valid-p valid-p))

(defun kargu-edit-activity-test--issued (activity)
  "Build the exact held native issuance response for ACTIVITY."
  (kargu-bridge--object
   "edit_id" (kargu-bridge-edit-activity-edit activity) "state" "issued" "revision" 1
   "preflight_digest" (make-string 64 ?a)
   "issued_token" "editor_issue_12345678-1234-4234-8234-123456789abc"))

(cl-defun kargu-edit-activity-test--reply (sent method result &key failure)
  "Deliver RESULT or FAILURE for METHOD's latest request from SENT."
  (let* ((request (cl-find method sent :test #'equal
                           :key (lambda (entry) (gethash "method" (cdr entry)))))
         (message (kargu-bridge--object "jsonrpc" "2.0" "id" (gethash "id" (cdr request)))))
    (should request)
    (puthash (if failure "error" "result") (or failure result) message)
    (kargu-bridge--dispatch-line (car request)
                                 (json-serialize message :null-object :json-null :false-object :json-false))))

(defun kargu-edit-activity-test--terminal (activity effect)
  "Build native quiescence evidence for ACTIVITY and EFFECT."
  (kargu-bridge--object "edit_id" (kargu-bridge-edit-activity-edit activity)
                        "state" "quiescent" "effect" effect "journal_committed" t))

(ert-deftest kargu-native-edit-activity-cancel-retains-late-token-and-settlement-observer-test ()
  (kargu-edit-activity-test--with-peer
   (let* ((calls 0)
          (activity (kargu-edit-activity-test--start
                     artifact source :handler (lambda (_) (cl-incf calls))
                     :callback (lambda (&rest result) (push result observations)))))
     (maphash (lambda (_ entry)
                (should-not (kargu-bridge--pending-timer entry))
                (should-not (kargu-bridge--pending-owner entry)))
              (kargu-bridge-connection-pending connection))
     (kargu-bridge-edit-activity-cancel activity)
     (kargu-edit-activity-test--reply sent "edit/abort" (kargu-bridge--object "aborted" t))
     (should (eq activity kargu-bridge-edit-activity--active))
     (should (= (hash-table-count (kargu-bridge-connection-pending connection)) 1))
     (kargu-edit-activity-test--reply sent "edit/issue" (kargu-edit-activity-test--issued activity))
     (should (= calls 0)) (should-not observations)
     (should (eq (kargu-bridge-edit-activity-state activity) :settling))
     (kargu-edit-activity-test--reply sent "edit/quiescent"
                                      (kargu-edit-activity-test--terminal activity "not_dispatched"))
     (should (= (length observations) 1))
     (should-not kargu-bridge-edit-activity--active)
     ;; A replayed response has no waiter and cannot invoke the handler.
     (kargu-edit-activity-test--reply sent "edit/issue" (kargu-edit-activity-test--issued activity))
     (should (= calls 0)) (should (= (length observations) 1)))))

(ert-deftest kargu-native-edit-activity-eof-inside-handler-holds-cross-epoch-fence-test ()
  (kargu-edit-activity-test--with-peer
   (let ((activity
          (kargu-edit-activity-test--start
           artifact source
           :callback (lambda (&rest result) (push result observations))
           :handler (lambda (live-p)
                      (should (funcall live-p))
                      (kargu-bridge--close connection "disconnected")
                      (should-not (funcall live-p))
                      (should-not observations)
                      (let ((other (copy-kargu-bridge-edit-artifact artifact)))
                        (setf (kargu-bridge-edit-artifact-connection other) replacement)
                        (should-error (kargu-edit-activity-test--start other source)
                                      :type 'kargu-bridge-edit-activity-busy))
                      :actual-unwind))))
     (kargu-edit-activity-test--reply sent "edit/issue" (kargu-edit-activity-test--issued activity))
     (should (eq (kargu-bridge-edit-activity-state activity) :finished))
     (should (= (length observations) 1))
     (should (eq (plist-get (caar observations) :observation) :actual-unwind))
     (should-not kargu-bridge-edit-activity--active)
     (setf (kargu-bridge-edit-artifact-connection artifact) replacement)
     (should (kargu-edit-activity-test--start artifact source)))))

(ert-deftest kargu-native-edit-activity-source-kill-retains-pending-issuance-test ()
  (kargu-edit-activity-test--with-peer
   (let* ((calls 0)
          (activity (kargu-edit-activity-test--start
                     artifact source :handler (lambda (_) (cl-incf calls)))))
     (kill-buffer source)
     (should (kargu-bridge-edit-activity-revoked activity))
     (should (eq (kargu-bridge-edit-activity-state activity) :acquiring))
     (kargu-edit-activity-test--reply sent "edit/issue" (kargu-edit-activity-test--issued activity))
     (should (= calls 0))
     (should (eq (kargu-bridge-edit-activity-state activity) :settling))
     (kargu-edit-activity-test--reply sent "edit/quiescent"
                                      (kargu-edit-activity-test--terminal activity "not_dispatched"))
     (should-not kargu-bridge-edit-activity--active))))

(ert-deftest kargu-native-edit-activity-revoke-routing-and-reentrant-validity-test ()
  (kargu-edit-activity-test--with-peer
   (let* ((calls 0) activity
          (valid (lambda () (kargu-bridge-edit-activity-cancel activity) t)))
     (setq activity (kargu-edit-activity-test--start artifact source
                                                     :handler (lambda (_) (cl-incf calls)) :valid-p valid))
     (let ((notice (kargu-edit-activity-test--issued activity)))
       (puthash "origin_id" (kargu-bridge-edit-artifact-origin artifact) notice)
       (kargu-bridge-edit-activity-revoke replacement notice)
       (should-not (kargu-bridge-edit-activity-revoked activity)))
     (kargu-edit-activity-test--reply sent "edit/issue" (kargu-edit-activity-test--issued activity))
     (should (= calls 0))
     (kargu-edit-activity-test--reply sent "edit/quiescent"
                                      (kargu-edit-activity-test--terminal activity "not_dispatched"))
     (should-not kargu-bridge-edit-activity--active))))

(ert-deftest kargu-native-edit-activity-native-revoke-during-handler-is-not-quiescence-test ()
  (kargu-edit-activity-test--with-peer
   (let (activity)
     (setq activity
           (kargu-edit-activity-test--start
            artifact source :handler
            (lambda (live-p)
              (let ((notice (kargu-edit-activity-test--issued activity)))
                (puthash "origin_id" (kargu-bridge-edit-artifact-origin artifact) notice)
                (kargu-bridge--dispatch-line
                 connection (json-serialize
                             (kargu-bridge--object "jsonrpc" "2.0" "method" "editor/revoke_edit" "params" notice))))
              (should-not (funcall live-p))
              (should (eq (kargu-bridge-edit-activity-state activity) :running))
              (should (eq activity kargu-bridge-edit-activity--active)))))
     (kargu-edit-activity-test--reply sent "edit/issue" (kargu-edit-activity-test--issued activity))
     (should (eq (kargu-bridge-edit-activity-state activity) :settling))
     (kargu-edit-activity-test--reply sent "edit/quiescent"
                                      (kargu-edit-activity-test--terminal activity "outcome_unknown"))
     (should-not kargu-bridge-edit-activity--active))))

(ert-deftest kargu-native-edit-activity-nonlocal-handler-exit-still-settles-test ()
  (kargu-edit-activity-test--with-peer
   (let ((activity (kargu-edit-activity-test--start
                    artifact source :handler (lambda (_) (throw 'fixture-exit :gone)))))
     (should (eq (catch 'fixture-exit
                   (kargu-edit-activity-test--reply sent "edit/issue" (kargu-edit-activity-test--issued activity)))
                 :gone))
     (should (eq (kargu-bridge-edit-activity-state activity) :settling))
     (kargu-edit-activity-test--reply sent "edit/quiescent"
                                      (kargu-edit-activity-test--terminal activity "outcome_unknown"))
     (should-not kargu-bridge-edit-activity--active))))

(ert-deftest kargu-native-edit-activity-invalid-settlement-drains-old-connection-test ()
  (kargu-edit-activity-test--with-peer
   (let ((activity (kargu-edit-activity-test--start artifact source)))
     (kargu-edit-activity-test--reply sent "edit/issue" (kargu-edit-activity-test--issued activity))
     (kargu-edit-activity-test--reply sent "edit/quiescent" (kargu-bridge--object "applied" t))
     (should (eq (kargu-bridge-status connection) 'stopping))
     (should (eq activity kargu-bridge-edit-activity--active))
     (should-error (kargu-edit-activity-test--start artifact source)
                   :type 'kargu-bridge-edit-activity-busy)
     (kargu-bridge--close connection "shutdown_timeout")
     (should-not kargu-bridge-edit-activity--active))))

(ert-deftest kargu-native-edit-activity-eof-during-settlement-finishes-once-test ()
  (kargu-edit-activity-test--with-peer
   (let ((activity (kargu-edit-activity-test--start
                    artifact source :callback (lambda (&rest result) (push result observations)))))
     (kargu-edit-activity-test--reply sent "edit/issue" (kargu-edit-activity-test--issued activity))
     (kargu-bridge--close connection "disconnected")
     (should (eq (kargu-bridge-edit-activity-state activity) :finished))
     (should (= (length observations) 1))
     (should-not kargu-bridge-edit-activity--active)
     (should (= (hash-table-count (kargu-bridge-connection-pending connection)) 0)))))

(ert-deftest kargu-native-edit-activity-actual-timeout-keeps-acquisition-observer-test ()
  (kargu-edit-activity-test--with-peer
   (let* ((kargu-bridge-edit-activity--timeout 0.01)
          (activity (kargu-edit-activity-test--start artifact source)))
     (kargu-bridge-test--wait (lambda () (kargu-bridge-edit-activity-revoked activity)))
     (should (eq activity kargu-bridge-edit-activity--active))
     (should (eq (kargu-bridge-edit-activity-state activity) :acquiring))
     (should (= (hash-table-count (kargu-bridge-connection-pending connection)) 2))
     (kargu-edit-activity-test--reply sent "edit/issue" (kargu-edit-activity-test--issued activity))
     (kargu-edit-activity-test--reply sent "edit/quiescent"
                                      (kargu-edit-activity-test--terminal activity "not_dispatched"))
     (should-not kargu-bridge-edit-activity--active))))

(ert-deftest kargu-native-edit-activity-handler-quit-still-retains-until-settlement-test ()
  (kargu-edit-activity-test--with-peer
   (let ((activity (kargu-edit-activity-test--start
                    artifact source :handler (lambda (_) (signal 'quit nil)))))
     (kargu-edit-activity-test--reply sent "edit/issue" (kargu-edit-activity-test--issued activity))
     (should (eq (kargu-bridge-edit-activity-state activity) :settling))
     (should (kargu-bridge-edit-activity-failure activity))
     (should (eq activity kargu-bridge-edit-activity--active))
     (kargu-edit-activity-test--reply sent "edit/quiescent"
                                      (kargu-edit-activity-test--terminal activity "outcome_unknown"))
     (should-not kargu-bridge-edit-activity--active))))

(ert-deftest kargu-native-edit-activity-stop-inside-handler-keeps-fence-until-unwind-test ()
  (kargu-edit-activity-test--with-peer
    (let ((activity (kargu-edit-activity-test--start
                     artifact source :handler
                     (lambda (live-p)
                       (kargu-bridge-stop connection)
                       (should-not (funcall live-p))
                       (should (eq (kargu-bridge-status connection) 'stopping))
                       (should kargu-bridge-edit-activity--active)
                       :stopped))))
      (kargu-edit-activity-test--reply sent "edit/issue" (kargu-edit-activity-test--issued activity))
      (should (eq (kargu-bridge-edit-activity-state activity) :finished))
      (should (eq (kargu-bridge-status connection) 'closed))
      (should-not kargu-bridge-edit-activity--active))))

(defun kargu-edit-activity-test--change (buffer)
  "Create detached BUFFER facts for the held peer."
  (let* ((before (kargu-bridge-edit-document-capture buffer))
         (after (copy-kargu-bridge-edit-document before)))
    (setf (kargu-bridge-edit-document-text after) "new\n"
          (kargu-bridge-edit-document-tick after) 2
          (kargu-bridge-edit-document-dirty after) t)
    (kargu-bridge-edit-document-change--make
     :before before :after after :written "new\n" :write-tick 2 :stage :replaced)))

(defun kargu-edit-activity-test--receipt-ack (sent activity)
  "Reply to ACTIVITY's latest receipt action from SENT using exact offsets."
  (let* ((call (cl-find "edit/receipt" sent :test #'equal
                        :key (lambda (entry) (gethash "method" (cdr entry)))))
         (input (gethash "input" (gethash "arguments" (gethash "params" (cdr call)))))
         (reply
          (pcase (gethash "action" input)
            ("file" (kargu-bridge--object "file" 0 "recorded" t "files_received" 1 "files_total" 1))
            ("append" (kargu-bridge--object "file" 0 "part" (gethash "part" input)
                                             "next_offset" (+ (gethash "offset" input)
                                                              (string-bytes (encode-coding-string
                                                                             (gethash "text" input) 'utf-8-unix)))
                                             "complete" t))
            ("commit" (kargu-bridge--object
                       "edit_id" (kargu-bridge-edit-activity-edit activity)
                       "state" "quiescent" "journal_committed" t
                       "receipt" (kargu-bridge--object "outcome" "applied_full" "files_total" 1 "files_applied" 1
                                                       "files" (vector (kargu-bridge--object "file" 0 "outcome" "applied")))))
            (_ (error "Unexpected receipt action")))))
    (kargu-edit-activity-test--reply sent "edit/receipt" reply)))

(ert-deftest kargu-native-edit-activity-receipt-survives-cancel-and-validates-acks-test ()
  (kargu-edit-activity-test--with-peer
    (kargu-edit-document-test--with-file "old\n"
      (let* ((change (kargu-edit-activity-test--change buffer))
             (activity (kargu-edit-activity-test--start
                        artifact source :handler (lambda (_) change)
                        :callback (lambda (&rest result) (push result observations)))))
        (kargu-edit-activity-test--reply sent "edit/issue" (kargu-edit-activity-test--issued activity))
        (should (eq (kargu-bridge-edit-activity-state activity) :settling))
        (kargu-bridge-edit-activity-cancel activity)
        (should-not observations)
        (dotimes (_ 4) (kargu-edit-activity-test--receipt-ack sent activity))
        (should (eq (kargu-bridge-edit-activity-state activity) :finished))
        (should (= (length observations) 1))
        (should-not (cadar observations))
        (should-not kargu-bridge-edit-activity--active)))))

(ert-deftest kargu-native-edit-activity-receipt-rejects-wrong-offset-ack-test ()
  (kargu-edit-activity-test--with-peer
    (kargu-edit-document-test--with-file "old\n"
      (let* ((change (kargu-edit-activity-test--change buffer))
             (activity (kargu-edit-activity-test--start artifact source :handler (lambda (_) change))))
        (kargu-edit-activity-test--reply sent "edit/issue" (kargu-edit-activity-test--issued activity))
        (kargu-edit-activity-test--receipt-ack sent activity)
        (kargu-edit-activity-test--reply
         sent "edit/receipt" (kargu-bridge--object "file" 0 "part" "written" "next_offset" 3 "complete" t))
        (should (eq (kargu-bridge-status connection) 'stopping))
        (should (eq activity kargu-bridge-edit-activity--active))))))

(ert-deftest kargu-native-edit-activity-receipt-build-failure-drains-instead-of-stalling-test ()
  (kargu-edit-activity-test--with-peer
    (kargu-edit-document-test--with-file "old\n"
      (let* ((change (kargu-edit-activity-test--change buffer))
             (kargu-bridge-edit-activity--receipt-part-bytes 2)
             (activity (kargu-edit-activity-test--start artifact source :handler (lambda (_) change))))
        (kargu-edit-activity-test--reply sent "edit/issue" (kargu-edit-activity-test--issued activity))
        (should (eq (kargu-bridge-status connection) 'stopping))
        (should (eq activity kargu-bridge-edit-activity--active))))))

(provide 'tests/test-native-edit-activity)
;;; test-native-edit-activity.el ends here
