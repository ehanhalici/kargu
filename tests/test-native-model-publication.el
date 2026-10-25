;;; test-native-model-publication.el --- Owned async metadata receipts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Actual editor -> native actor publications, with controlled receipt delivery.
;; Assertions cover captured-intent barriers rather than a queue-empty shortcut.

;;; Code:

(require 'ert)
(require 'tests/test-bridge)
(require 'kargu/bridge/models)
(require 'tests/test-connection-native)

(defun kargu-model-publication-test--source (capacity)
  "Build an exact native metadata fixture for CAPACITY."
  (format "{\"operation\":\"put\",\"model\":\"Model\",\"metadata\":{\"context_length\":%d}}" capacity))

(defun kargu-model-publication-test--capacity (view)
  "Read a known capacity from canonical native VIEW, without extraction logic."
  (gethash "value" (gethash "context_window"
                            (gethash "fields" (aref (gethash "records" view) 0)))))

(defun kargu-model-publication-test--submit (connection app capacity &optional callback)
  "Submit CAPACITY using CONNECTION/APP and optional CALLBACK."
  (kargu-bridge-models-submit connection app "A"
                              (kargu-model-publication-test--source capacity) []
                              (or callback #'ignore)))

(ert-deftest kargu-native-model-publication-first-intent-starts-real-core-test ()
  "A first publication is visible to barriers before native startup completes."
  (let* ((binary (getenv "KARGU_CORE_TEST_BINARY"))
         (kargu-bridge-binary-path binary) (kargu-bridge--connection nil)
         (app (kargu-application-create)) ticket)
    (skip-unless (and binary (file-executable-p binary)))
    (unwind-protect
        (progn
          (setq ticket (kargu-bridge-models-publish
                        app "a" (kargu-model-publication-test--source 10) [] #'ignore))
          (should (eq ticket (kargu-bridge-models-capture app)))
          (should-not (kargu-bridge-models-snapshot app))
          (should (eq (kargu-bridge-model-ticket-status ticket) :pending))
          (let (received failure)
            (kargu-bridge-models-await ticket (lambda (view fault) (setq received view failure fault)))
            (kargu-bridge-test--wait (lambda () received))
            (should-not failure)
            (should (= (gethash "revision" received) 1))
            (should (= (kargu-model-publication-test--capacity received) 10))))
      (when kargu-bridge--connection
        (kargu-bridge--close kargu-bridge--connection "fixture_cleanup")
        (when (buffer-live-p (kargu-bridge-connection-stderr-buffer kargu-bridge--connection))
          (kill-buffer (kargu-bridge-connection-stderr-buffer kargu-bridge--connection)))))))

(ert-deftest kargu-native-model-publication-startup-captures-intent-before-real-preparation-test ()
  "Preparation waits for the first registered intent, not an empty legacy view."
  (kargu-bridge-test--with-core
   (kargu-test-with-real-connection
    (let ((original (symbol-function 'kargu-bridge-ensure)) held ticket second result
          (source (copy-sequence "{\"operation\":\"put\",\"model\":\"m\",\"metadata\":{\"context_length\":100,\"supports_tools\":false}}")))
      (cl-letf (((symbol-function 'kargu-bridge-ensure)
                 (lambda (callback)
                   (should (kargu-bridge-models-capture kargu-application--bound))
                   (setq held callback) #'ignore)))
        (setq ticket (kargu-bridge-models-publish kargu-application--bound "g02" source [] #'ignore))
        (aset source 0 ?x)
        (should (eq ticket (kargu-bridge-models-capture kargu-application--bound)))
        (kargu-api-prepare-connection (lambda (value) (setq result value)) :provider "g02" :model "m")
        ;; A later queued update cannot replace the intent captured by preparation.
        (setq second (kargu-bridge-models-publish kargu-application--bound "g02"
                     "{\"operation\":\"put\",\"model\":\"m\",\"metadata\":{\"context_length\":200}}" [] #'ignore)))
      (accept-process-output nil 0.03)
      (should-not result)
      (funcall original (lambda (connection failure) (funcall held connection failure)))
      (kargu-bridge-test--wait (lambda () result))
      (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status second) :committed)))
      (should (kargu-ok-p result))
      (let ((snapshot (kargu-result-value result)))
        (unwind-protect
            (let ((settings (kargu-connection-snapshot-settings snapshot)))
              (should (= (plist-get settings :metadata-revision) 1))
              (should (= (plist-get (plist-get settings :fields) :context-window) 100))
              (should-not (plist-get settings :tools)))
          (kargu-connection-snapshot-wipe snapshot)))
      (should (= (gethash "revision" (kargu-bridge-model-ticket-view second)) 2))))))

(ert-deftest kargu-native-model-publication-cancel-startup-detaches-only-one-waiter-test ()
  "Cancellation releases one cold-start waiter, never a sibling or shared core."
  (kargu-bridge-test--with-core
   (let ((app (kargu-application-create)) held first next
         (cleanups 0) (deliveries 0) (begins 0)
         (original (symbol-function 'kargu-bridge-call)))
     (cl-letf (((symbol-function 'kargu-bridge-ensure)
                (lambda (callback) (push callback held) (lambda () (cl-incf cleanups))))
               ((symbol-function 'kargu-bridge-call)
                (lambda (connection method params callback &rest options)
                  (when (equal method "models/begin") (cl-incf begins))
                  (apply original connection method params callback options))))
       (setq first (kargu-bridge-models-publish app "a" (kargu-model-publication-test--source 10) []
                     (lambda (_view failure) (should failure) (cl-incf deliveries))))
       (kargu-bridge-models-cancel first)
       (should (kargu-bridge-model-ticket-released first))
       (should (= cleanups 1))
       (setq next (kargu-bridge-models-publish app "a" (kargu-model-publication-test--source 20) [] #'ignore))
       (funcall (cadr held) conn nil)
       (should (= begins 0))
       (should-not (kargu-bridge-models-snapshot app))
       (funcall (car held) conn nil)
       (funcall (car held) conn nil)
       (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status next) :committed)))
       (should (= begins 1))
       (should (= deliveries 1))
       (should (= cleanups 2))
       (should (eq (kargu-bridge-status conn) 'ready))
       (should (= (gethash "revision" (kargu-bridge-models-snapshot app)) 1))))))

(ert-deftest kargu-native-model-publication-first-startup-failure-or-old-core-is-closed-test ()
  "Startup and capability failure cannot allocate an owner, replay or fall back."
  (dolist (reason '(:startup :capability))
    (let ((app (kargu-application-create)) (starts 0) first next failure)
      (cl-letf (((symbol-function 'kargu-bridge-ensure)
                 (lambda (callback)
                   (cl-incf starts)
                   (funcall callback
                            (unless (eq reason :startup)
                              (kargu-bridge--connection-create :state 'ready :capabilities ["model_metadata"]))
                            (when (eq reason :startup) (kargu-bridge--fault "startup_failed")))
                   #'ignore))
                ((symbol-function 'kargu-bridge-application-ensure)
                 (lambda (&rest _) (ert-fail "No owner allocation before capability"))))
        (setq first (kargu-bridge-models-publish app "a" (kargu-model-publication-test--source 10) []
                      (lambda (_view fault) (setq failure fault))))
        (should failure)
        (should (eq (kargu-bridge-model-ticket-status first) :failed))
        (setq next (kargu-bridge-models-publish app "a" (kargu-model-publication-test--source 20) [] #'ignore))
        (should (eq (kargu-bridge-model-ticket-status next) :failed))
        (should (= starts 1))
        (should-not (kargu-bridge-models-snapshot app))))))

(ert-deftest kargu-native-model-publication-first-intent-respects-existing-lost-lease-test ()
  "The first metadata write cannot replace an application's earlier API lease."
  (kargu-bridge-test--with-core
   (let ((app (kargu-application-create)) ready)
     (kargu-bridge-application-ensure conn app (lambda (_scope failure) (should-not failure) (setq ready t)))
     (kargu-bridge-test--wait (lambda () ready))
     (kargu-bridge--close conn "fixture_epoch_loss")
     (cl-letf (((symbol-function 'kargu-bridge-ensure)
                (lambda (&rest _) (ert-fail "No replacement connection for an existing owner")))
               ((symbol-function 'kargu-bridge-application-ensure)
                (lambda (&rest _) (ert-fail "No replacement application lease"))))
       (let ((ticket (kargu-bridge-models-publish app "a" (kargu-model-publication-test--source 10) [] #'ignore)))
         (should (eq (kargu-bridge-model-ticket-status ticket) :failed))
         (should-not (kargu-bridge-models-snapshot app)))))))

(ert-deftest kargu-native-model-publication-committed-reads-and-exact-ticket-barrier-test ()
  "A preparation receipt cannot borrow a later submission's model fields."
  (kargu-bridge-test--with-core
   (let* ((app (kargu-application-create))
          (first (kargu-model-publication-test--submit conn app 10))
          (original (symbol-function 'kargu-bridge-call))
          held second third captured delivered failure)
     (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status first) :committed)))
     (cl-letf (((symbol-function 'kargu-bridge-call)
                (lambda (connection method params callback &rest options)
                  (apply original connection method params
                         (if (equal method "models/commit")
                             (lambda (result fault)
                               (setq held (lambda () (funcall callback result fault)))) callback)
                         options))))
       (setq second (kargu-model-publication-test--submit conn app 20))
       (should (eq (kargu-bridge-models-capture app) second))
       (kargu-bridge-models-await second (lambda (view fault) (setq captured view failure fault delivered t)))
       (kargu-bridge-test--wait (lambda () held))
       (should-not delivered)
       (should (= (kargu-model-publication-test--capacity (kargu-bridge-models-snapshot app)) 10))
       (let (old)
         (kargu-bridge-models-await first (lambda (view fault) (should-not fault) (setq old view)))
         (should (= (kargu-model-publication-test--capacity old) 10)))
       (setq third (kargu-model-publication-test--submit conn app 30)))
     (funcall held)
     (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status third) :committed)))
     (should delivered) (should-not failure)
     (should (= (kargu-model-publication-test--capacity captured) 20))
     (puthash "revision" 999 (kargu-bridge-model-ticket-view second))
     (should (= (gethash "revision" (kargu-bridge-model-ticket-view second)) 2))
     (should (= (kargu-model-publication-test--capacity (kargu-bridge-models-snapshot app)) 30))
     (let ((view (kargu-bridge-models-snapshot app)))
       (puthash "revision" 999 view)
       (puthash "value" 999 (gethash "context_window" (gethash "fields" (aref (gethash "records" view) 0)))))
     (should (= (kargu-model-publication-test--capacity (kargu-bridge-models-snapshot app)) 30))
     (should (= (kargu-model-publication-test--capacity captured) 20)))))

(ert-deftest kargu-native-model-publication-cancelled-late-begin-aborts-before-next-start-test ()
  "Cancelled allocation is drained, not hidden by native Busy or another lease."
  (kargu-bridge-test--with-core
   (let* ((app (kargu-application-create))
          (original (symbol-function 'kargu-bridge-call))
          held first next methods (deliveries 0))
     (cl-letf (((symbol-function 'kargu-bridge-call)
                (lambda (connection method params callback &rest options)
                  (push method methods)
                  (apply original connection method params
                         (if (equal method "models/begin")
                             (lambda (result fault)
                               (setq held (lambda () (funcall callback result fault)))) callback)
                         options))))
       (setq first (kargu-model-publication-test--submit conn app 10
							 (lambda (_view fault) (should fault) (cl-incf deliveries))))
       (kargu-bridge-test--wait (lambda () held))
       (kargu-bridge-models-cancel first)
       (kargu-bridge-models-cancel first)
       (should (= deliveries 1))
       (should-not (kargu-bridge-models-snapshot app))
       (setq next (kargu-model-publication-test--submit conn app 20))
       (should (= (cl-count "models/begin" methods :test #'equal) 1)))
     (funcall held)
     (funcall held)
     (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status next) :committed)))
     (should (= deliveries 1))
     (should (kargu-bridge-model-ticket-released first))
     (should (= (gethash "revision" (kargu-bridge-models-snapshot app)) 1))
     (should (= (kargu-model-publication-test--capacity (kargu-bridge-models-snapshot app)) 20)))))

(ert-deftest kargu-native-model-publication-cancel-after-issued-commit-fails-closed-test ()
  "A real commit with a cancelled receipt cannot authorize the old view."
  (kargu-bridge-test--with-core
   (let* ((app (kargu-application-create))
          (first (kargu-model-publication-test--submit conn app 10))
          (original (symbol-function 'kargu-bridge-call)) held second next failure barrier)
     (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status first) :committed)))
     (cl-letf (((symbol-function 'kargu-bridge-call)
                (lambda (connection method params callback &rest options)
                  (apply original connection method params
                         (if (equal method "models/commit")
                             (lambda (result fault) (setq held (lambda () (funcall callback result fault)))) callback)
                         options))))
       (setq second (kargu-model-publication-test--submit conn app 20))
       (kargu-bridge-test--wait (lambda () held))
       (kargu-bridge-models-cancel second)
       (setq next (kargu-model-publication-test--submit conn app 30
							(lambda (_view fault) (setq failure fault)))))
     (funcall held)
     (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status next) :failed)))
     (should failure)
     (kargu-bridge-models-await (kargu-bridge-models-capture app)
                                (lambda (_view fault) (setq barrier fault)))
     (should barrier)
     (should (= (kargu-model-publication-test--capacity (kargu-bridge-models-snapshot app)) 10))
     (let* ((service (kargu-bridge-model-ticket-service second))
            (reply (kargu-bridge-test--call conn "models/snapshot"
					    (kargu-bridge--object "scope" (kargu-bridge-models-scope service)
								  "arguments" (kargu-bridge--object)))))
       (should-not (cadr reply))
       (should (= (gethash "revision" (car reply)) 2)))
     (let ((repair (kargu-bridge-models-reconcile app #'ignore)))
       (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status repair) :committed)))
       (should (= (gethash "revision" (kargu-bridge-models-snapshot app)) 2))
       (should (= (kargu-model-publication-test--capacity (kargu-bridge-models-snapshot app)) 20)))
     (let ((fresh (kargu-model-publication-test--submit conn app 30)))
       (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status fresh) :committed)))
       (should (= (gethash "revision" (kargu-bridge-models-snapshot app)) 3))))))

(ert-deftest kargu-native-model-publication-invalid-command-keeps-view-and-next-update-live-test ()
  "A definite native validation failure is not an unknown successful commit."
  (kargu-bridge-test--with-core
   (let* ((app (kargu-application-create))
          (first (kargu-model-publication-test--submit conn app 10)) bad next barrier)
     (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status first) :committed)))
     (setq bad (kargu-bridge-models-submit conn app "a" "{broken" [] #'ignore)
           next (kargu-model-publication-test--submit conn app 20))
     (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status next) :committed)))
     (should (eq (kargu-bridge-model-ticket-status bad) :failed))
     (kargu-bridge-models-await bad (lambda (_view failure) (setq barrier failure)))
     (should barrier)
     (should (= (gethash "revision" (kargu-bridge-models-snapshot app)) 2))
     (should (= (kargu-model-publication-test--capacity (kargu-bridge-models-snapshot app)) 20)))))

(ert-deftest kargu-native-model-publication-large-unicode-exact-prices-and-captured-input-test ()
  "Owned transfer keeps >1 MiB UTF-8, exact prices and detached submission DTOs."
  (kargu-bridge-test--with-core
   (let* ((app (kargu-application-create))
          (description (make-string 300000 ?🦀))
          (source (concat "{\"operation\":\"put\",\"model\":\"Model\",\"metadata\":{\"description\":\""
                          description "\",\"input-cost\":1e-38,\"options\":[\"low\",\"high\"]}}"))
          (specs (vector (kargu-bridge--object "path" ["options"] "type" "list")))
          (ticket (kargu-bridge-models-submit conn app "a" source specs #'ignore)))
     (aset source 0 ?x)
     (aset (gethash "path" (aref specs 0)) 0 "changed")
     (kargu-bridge-test--wait (lambda () (not (eq (kargu-bridge-model-ticket-status ticket) :pending))))
     (should (eq (kargu-bridge-model-ticket-status ticket) :committed))
     (let* ((view (kargu-bridge-models-snapshot app))
            (record (aref (gethash "records" view) 0))
            (fields (gethash "fields" record)))
       (should (equal (gethash "description" (gethash "metadata" record)) description))
       (should (equal (gethash "value" (gethash "input_cost" fields))
                      "0.00000000000000000000000000000000000001"))
       (should (equal (gethash "value" (gethash "reasoning_efforts" fields)) ["low" "high"]))
       (should-not (kargu-bridge-model-ticket-source ticket))))))

(ert-deftest kargu-native-model-publication-missing-capability-and-passive-read-never-start-core-test ()
  "Passive reads and old-core rejection cannot create a native application."
  (let* ((app (kargu-application-create))
         (conn (kargu-bridge--connection-create :state 'ready :capabilities [])) failure)
    (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (&rest _) (ert-fail "Unexpected core startup")))
              ((symbol-function 'kargu-bridge-application-ensure) (lambda (&rest _) (ert-fail "Unexpected owner startup"))))
      (should-not (kargu-bridge-models-snapshot app))
      (should-not (kargu-bridge-models-capture app))
      (let ((ticket (kargu-model-publication-test--submit conn app 10
							  (lambda (_view fault) (setq failure fault)))))
        (should (eq (kargu-bridge-model-ticket-status ticket) :failed)))
      (should (equal (gethash "status" (gethash "data" failure)) "unsupported_model_metadata")))))

(ert-deftest kargu-native-model-publication-owner-close-drains-late-allocation-test ()
  "Killing the source owner cancels the exact upload and never republishes it."
  (kargu-bridge-test--with-core
   (let* ((app (kargu-application-create))
          (owner (generate-new-buffer " *metadata-owner*"))
          (original (symbol-function 'kargu-bridge-call)) held ticket)
     (unwind-protect
         (progn
           (cl-letf (((symbol-function 'kargu-bridge-call)
                      (lambda (connection method params callback &rest options)
                        (apply original connection method params
                               (if (equal method "models/begin")
                                   (lambda (result fault) (setq held (lambda () (funcall callback result fault)))) callback)
                               options))))
             (setq ticket (kargu-bridge-models-submit conn app "a"
						      (kargu-model-publication-test--source 10) [] #'ignore :owner owner))
             (kargu-bridge-test--wait (lambda () held)))
           (kill-buffer owner)
           (funcall held)
           (kargu-bridge-test--wait (lambda () (kargu-bridge-model-ticket-released ticket)))
           (should (eq (kargu-bridge-model-ticket-status ticket) :cancelled))
           (should-not (kargu-bridge-models-snapshot app))
           (let ((next (kargu-model-publication-test--submit conn app 20)))
             (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status next) :committed)))
             (should (= (gethash "revision" (kargu-bridge-models-snapshot app)) 1))))
       (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest kargu-native-model-publication-real-preparation-freezes-captured-revision-test ()
  "Real config/credential preparation waits for its captured native publication."
  (kargu-bridge-test--with-core
   (kargu-test-with-real-connection
    (let* ((original (symbol-function 'kargu-bridge-call))
           (configured-function (symbol-function 'kargu-api-prepare--configured))
           held ticket newer task result configured)
      (cl-letf (((symbol-function 'kargu-api-prepare--configured)
                 (lambda (preparation value)
                   (funcall configured-function preparation value)
                   (setq configured t)))
                ((symbol-function 'kargu-bridge-call)
                 (lambda (connection method params callback &rest options)
                   (apply original connection method params
                          (if (equal method "models/commit")
                              (lambda (view fault) (setq held (lambda () (funcall callback view fault)))) callback)
                          options))))
        (setq ticket (kargu-bridge-models-submit conn kargu-application--bound "g02"
						 "{\"operation\":\"put\",\"model\":\"m\",\"metadata\":{\"context_length\":100,\"supports_tools\":false,\"supported_parameters\":[\"max_completion_tokens\"]}}"
						 [] #'ignore))
        (kargu-bridge-test--wait (lambda () held))
        (setq task (kargu-api-prepare-connection (lambda (value) (setq result value))
                                                 :provider "g02" :model "m"))
        (kargu-bridge-test--wait (lambda () configured))
        (should (kargu-async-pending-p task))
        (should-not result)
        (setq newer (kargu-bridge-models-submit conn kargu-application--bound "g02"
						"{\"operation\":\"put\",\"model\":\"m\",\"metadata\":{\"context_length\":200,\"supports_tools\":true,\"supported_parameters\":[\"max_tokens\"]}}"
						[] #'ignore)))
      (funcall held)
      (kargu-bridge-test--wait (lambda () result))
      (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status newer) :committed)))
      (should (kargu-ok-p result))
      (let ((snapshot (kargu-result-value result)))
        (unwind-protect
            (let ((settings (kargu-connection-snapshot-settings snapshot)))
              (should (= (plist-get settings :metadata-revision) 1))
              (should (= (plist-get (plist-get settings :fields) :context-window) 100))
              (should-not (plist-get settings :tools))
              (should (equal (kargu-aget (plist-get settings :tuning) "supported_parameters") ["max_completion_tokens"])))
          (kargu-connection-snapshot-wipe snapshot)))
      (should (= (kargu-model-publication-test--capacity (kargu-bridge-model-ticket-view ticket)) 100))
      (should (= (kargu-model-publication-test--capacity (kargu-bridge-models-snapshot kargu-application--bound)) 200))))))

(ert-deftest kargu-native-model-publication-failed-ticket-refuses-real-preparation-test ()
  "A failed captured update cannot fall back to legacy or last-good UI metadata."
  (kargu-bridge-test--with-core
   (kargu-test-with-real-connection
    (let ((ticket (kargu-bridge-models-submit conn kargu-application--bound "g02" "{broken" [] #'ignore)) result)
      (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status ticket) :failed)))
      (cl-letf (((symbol-function 'kargu-connection-resolve-async)
                 (lambda (&rest _) (ert-fail "Credentials cannot precede the metadata barrier"))))
        (kargu-api-prepare-connection (lambda (value) (setq result value)) :provider "g02" :model "m")
        (kargu-bridge-test--wait (lambda () result)))
      (should (kargu-err-p result))
      (should (eq (kargu-result-err-code result) :metadata-unavailable))))))

(ert-deftest kargu-native-model-publication-revoked-guard-and-invalid-ack-drain-before-next-test ()
  "Resource revision loss and malformed protocol ACK cannot leave a live upload."
  (kargu-bridge-test--with-core
   (dolist (reason '(:guard :ack))
     (let* ((app (kargu-application-create))
            (original (symbol-function 'kargu-bridge-call))
            (valid t) held ticket next)
       (cl-letf (((symbol-function 'kargu-bridge-call)
                  (lambda (connection method params callback &rest options)
                    (apply original connection method params
                           (cond
                            ((and (eq reason :guard) (equal method "models/begin"))
                             (lambda (result failure) (setq held (lambda () (funcall callback result failure)))))
                            ((and (eq reason :ack) (equal method "models/append"))
                             (lambda (result failure)
                               (puthash "offset" 999 result)
                               (funcall callback result failure)))
                            (t callback)) options))))
         (setq ticket (kargu-bridge-models-submit conn app "a"
						  (kargu-model-publication-test--source 10) [] #'ignore :valid-p (lambda () valid)))
         (if (eq reason :guard)
             (progn (kargu-bridge-test--wait (lambda () held)) (setq valid nil))
           (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status ticket) :failed)))))
       (setq next (kargu-model-publication-test--submit conn app 20))
       (when held (funcall held))
       (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status next) :committed)))
       (should (eq (kargu-bridge-model-ticket-status ticket) :failed))
       (should (= (gethash "revision" (kargu-bridge-models-snapshot app)) 1))
       (should (= (kargu-model-publication-test--capacity (kargu-bridge-models-snapshot app)) 20))))))

(ert-deftest kargu-native-model-publication-lost-epoch-never-reinitializes-old-owner-test ()
  "A replacement core cannot acquire a zero revision for an old metadata owner."
  (kargu-bridge-test--with-core
   (let* ((app (kargu-application-create))
          (first (kargu-model-publication-test--submit conn app 10)) second ready failure)
     (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status first) :committed)))
     (kargu-bridge--close conn "fixture_epoch_loss")
     (unwind-protect
         (progn
           (setq second (kargu-bridge-start (lambda (_connection fault) (setq failure fault ready t))))
           (kargu-bridge-test--wait (lambda () ready)) (should-not failure)
           (cl-letf (((symbol-function 'kargu-bridge-application-ensure)
                      (lambda (&rest _) (ert-fail "An old owner cannot be rebound"))))
             (let ((ticket (kargu-model-publication-test--submit second app 20)))
               (should (eq (kargu-bridge-model-ticket-status ticket) :failed)))
             (should-not (kargu-bridge-models-reconcile app (lambda (_view fault) (setq failure fault))))
             (should failure)
             (should-not (kargu-bridge-models-snapshot app)))
           (let* ((fresh-app (kargu-application-create))
                  (fresh (kargu-model-publication-test--submit second fresh-app 30)))
             (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status fresh) :committed)))
             (should (= (gethash "revision" (kargu-bridge-models-snapshot fresh-app)) 1))))
       (when second
         (kargu-bridge--close second "fixture_cleanup")
         (when (buffer-live-p (kargu-bridge-connection-stderr-buffer second))
           (kill-buffer (kargu-bridge-connection-stderr-buffer second))))))))

(ert-deftest kargu-native-model-publication-queue-and-byte-bounds-release-cancelled-work-test ()
  "Queued commands and captured source bytes stay bounded and release on cancel."
  (kargu-bridge-test--with-core
   (let* ((app (kargu-application-create))
          (original (symbol-function 'kargu-bridge-call)) held active queued)
     (cl-letf (((symbol-function 'kargu-bridge-call)
                (lambda (connection method params callback &rest options)
                  (apply original connection method params
                         (if (equal method "models/begin")
                             (lambda (result failure) (setq held (lambda () (funcall callback result failure)))) callback)
                         options))))
       (setq active (kargu-model-publication-test--submit conn app 10))
       (kargu-bridge-test--wait (lambda () held))
       (let* ((large (make-string (* 8 1024 1024) ?\s))
              (accepted (kargu-bridge-models-submit conn app "a" large [] #'ignore))
              (rejected (kargu-bridge-models-submit conn app "a" large [] #'ignore)))
         (should (eq (kargu-bridge-model-ticket-status accepted) :pending))
         (should (eq (kargu-bridge-model-ticket-status rejected) :failed))
         (should (<= (kargu-bridge-models-bytes (kargu-bridge-model-ticket-service active)) (* 16 1024 1024)))
         (kargu-bridge-models-cancel accepted))
       (dotimes (_ 32) (push (kargu-model-publication-test--submit conn app 20) queued))
       (let ((rejected (kargu-model-publication-test--submit conn app 30)))
         (should (eq (kargu-bridge-model-ticket-status rejected) :failed)))
       (dolist (ticket queued) (kargu-bridge-models-cancel ticket))
       (kargu-bridge-models-cancel active))
     (funcall held)
     (kargu-bridge-test--wait (lambda () (kargu-bridge-model-ticket-released active)))
     (should (zerop (kargu-bridge-models-bytes (kargu-bridge-model-ticket-service active))))
     (should-not (kargu-bridge-models-snapshot app)))))

(ert-deftest kargu-native-model-publication-cannot-run-alongside-a-legacy-writer-test ()
  "An application's native revision cannot silently ignore subsequent Lisp writes."
  (kargu-bridge-test--with-core
   (let* ((kargu-application--bound (kargu-application-create))
          (ticket (kargu-model-publication-test--submit conn kargu-application--bound 10)))
     (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status ticket) :committed)))
     (should-error (kargu-model-set-metadata "Model" '(:context-window 99) "a") :type 'user-error)
     (should-error (kargu-model-set-prop "Model" :context-window 99 :provider "a") :type 'user-error)
     (should-error (kargu-model-store-retain "a" nil) :type 'user-error)
     (should-error (kargu-model-mark-tools-refused "Model" "a") :type 'user-error)
     (should (= (kargu-model-publication-test--capacity
                 (kargu-bridge-models-snapshot kargu-application--bound)) 10)))))

(ert-deftest kargu-native-model-publication-projection-keeps-request-parameters-exact-test ()
  "A native display alias cannot lend its canonical request parameter policy."
  (kargu-bridge-test--with-core
   (let* ((app (kargu-application-create))
          (ticket (kargu-bridge-models-submit conn app "a"
					      "{\"operation\":\"put\",\"model\":\"vendor/shared\",\"metadata\":{\"context_length\":10,\"supported_parameters\":[\"max_tokens\",\"tools\"]}}"
					      [] #'ignore)))
     (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status ticket) :committed)))
     (let ((refusal (kargu-bridge-models-submit conn app "a"
						"{\"operation\":\"refuse_tools\",\"model\":\"shared\"}" [] #'ignore)))
       (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status refusal) :committed))))
     (let* ((view (kargu-bridge-models-snapshot app))
            (alias (kargu-model-projection-connection view "a" "shared"))
            (exact (kargu-model-projection-connection view "a" "vendor/shared"))
            (unknown (kargu-model-projection-connection view "a" "unknown")))
       (should (= (plist-get (plist-get alias :fields) :context-window) 10))
       (should (eq (plist-get alias :supported-parameters) :json-null))
       (should-not (plist-get alias :tools))
       (should (plist-get exact :tools))
       (should (equal (plist-get exact :supported-parameters) ["max_tokens" "tools"]))
       (should (plist-get unknown :tools))
       (should-not (plist-get (plist-get unknown :fields) :context-window))
       (should-not (plist-get (plist-get unknown :fields) :input-cost))
       (aset (plist-get exact :supported-parameters) 0 "mutated")
       (should (equal (plist-get (kargu-model-projection-connection view "a" "vendor/shared")
                                 :supported-parameters) ["max_tokens" "tools"]))))))

(ert-deftest kargu-native-model-publication-cancelled-preparation-detaches-only-its-waiter-test ()
  "Stopping connection preparation does not cancel a shared metadata publication."
  (kargu-bridge-test--with-core
   (kargu-test-with-real-connection
    (let* ((original (symbol-function 'kargu-bridge-call))
           (configured-function (symbol-function 'kargu-api-prepare--configured))
           held ticket task configured delivered)
      (cl-letf (((symbol-function 'kargu-api-prepare--configured)
                 (lambda (preparation value)
                   (funcall configured-function preparation value) (setq configured t)))
                ((symbol-function 'kargu-bridge-call)
                 (lambda (connection method params callback &rest options)
                   (apply original connection method params
                          (if (equal method "models/commit")
                              (lambda (view failure) (setq held (lambda () (funcall callback view failure)))) callback)
                          options))))
        (setq ticket (kargu-bridge-models-submit conn kargu-application--bound "g02"
						 "{\"operation\":\"put\",\"model\":\"m\",\"metadata\":{\"context_length\":10}}" [] #'ignore))
        (kargu-bridge-test--wait (lambda () held))
        (setq task (kargu-api-prepare-connection (lambda (_) (setq delivered t)) :provider "g02" :model "m"))
        (kargu-bridge-test--wait (lambda () configured))
        (should (kargu-bridge-model-ticket-waiters ticket))
        (kargu-async-cancel task)
        (should-not (kargu-bridge-model-ticket-waiters ticket)))
      (funcall held)
      (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-model-ticket-status ticket) :committed)))
      (should (eq (kargu-async-task-state task) :cancelled))
      (should-not delivered)))))

(provide 'tests/test-native-model-publication)
;;; test-native-model-publication.el ends here
