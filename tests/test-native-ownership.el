;;; test-native-ownership.el --- Native application isolation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exercise real admission and HTTP delivery with offline transport callbacks.

;;; Code:

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)
(require 'kargu/tools/bash/native)

(defmacro kargu-test-native-boundary (&rest body)
  "Run BODY with offline provider and prompt boundaries."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
             ((symbol-function 'kargu-model-supports-tools-p) (lambda (&rest _) t))
             ((symbol-function 'kargu-prompt-wrap-user) #'identity)
             ((symbol-function 'kargu--resolve-api-key) (lambda () "offline"))
             ((symbol-function 'kargu--api-base) (lambda () "https://example.invalid")))
     ,@body))

(ert-deftest kargu-native-two-applications-interleaved-http-test ()
  "Stopping A cannot cancel B; callbacks arriving in B retain A's owner."
  (let ((a (generate-new-buffer " *native-a*"))
        (b (generate-new-buffer " *native-b*"))
        callbacks reports run-a run-b)
    (unwind-protect
        (kargu-test-native-boundary
         (cl-letf (((symbol-function 'plz)
                    (lambda (&rest options)
                      (push (plist-get (cddr options) :then) callbacks) nil)))
                  (with-current-buffer a
                    (setq-local kargu-application-owner (kargu-application-create))
                    (setq run-a (kargu-loop-send "A" nil (lambda (r) (push (cons 'a r) reports)))))
                  (with-current-buffer b
                    (setq-local kargu-application-owner (kargu-application-create))
                    (setq run-b (kargu-loop-send "B" nil (lambda (r) (push (cons 'b r) reports)))))
                  (should (= (length callbacks) 2))
                  (with-current-buffer a
                    (should-error (kargu-loop-send "second") :type 'user-error)
                    (kargu-loop-stop))
                  (with-current-buffer b
                    (should (kargu-loop--live-p run-b))
                    (funcall (cadr callbacks) "{\"choices\":[{\"message\":{\"content\":\"late A\"},\"finish_reason\":\"stop\"}]}")
                    (should (kargu-loop--live-p run-b))
                    (funcall (car callbacks) "{\"choices\":[{\"message\":{\"content\":\"answer B\"},\"finish_reason\":\"stop\"}]}")
                    (funcall (car callbacks) "{}")
                    (should-not (kargu-loop-running-p))
                    (should (equal (kargu-aget (kargu-history-last-message) "content") "answer B")))
                  (should-not (kargu-loop--live-p run-a))
                  (should (= (length reports) 2))
                  (should (eq (plist-get (cdr (assq 'a reports)) :status) :stopped))
                  (should (eq (plist-get (cdr (assq 'b reports)) :status) :done))))
      (kill-buffer a) (kill-buffer b))))

(ert-deftest kargu-native-cleanup-reentry-and-same-label-test ()
  "Cleanup retains admission; an obsolete claim cannot act on a reused label."
  (with-temp-buffer
    (setq-local kargu-application-owner (kargu-application-create))
    (let (old late rejected)
      (kargu-test-native-boundary
       (cl-letf (((symbol-function 'kargu-api-send) #'ignore)
                 ((symbol-function 'kargu--generate-session-id) (lambda () "same-label")))
                (setq old (kargu-loop-send "first" nil #'ignore))
                (setq late (kargu-loop--wrap old (lambda () (ert-fail "Stale continuation"))))
                (kargu-async-add-cleanup
                 (kargu-execution-task (plist-get old :context))
                 (lambda ()
                   (setq rejected (condition-case nil
                                      (progn (kargu-loop-send "reentry") nil)
                                    (user-error t)))))
                (kargu-loop-stop)
                (should rejected)
                (let ((new (kargu-loop-send "second" nil #'ignore)))
                  (should (equal (plist-get old :id) (plist-get new :id)))
                  (funcall late)
                  (should (kargu-loop--live-p new))
                  (kargu-loop-stop)))))))

(ert-deftest kargu-native-async-deadline-and-terminal-parent-test ()
  "Children inherit the earliest bound and cannot attach to a closed parent."
  (let* ((deadline (+ (float-time) 5))
         (parent (kargu-async-start #'ignore :owner nil :parent nil :deadline deadline))
         (child (kargu-async-start #'ignore :parent parent :timeout 60
                                   :deadline (+ deadline 30))) cleaned)
    (should (= deadline (kargu-async-task-deadline child)))
    (kargu-async-cancel parent)
    (should (eq (kargu-async-task-state child) :cancelled))
    (let ((late (kargu-async-start #'ignore :parent parent
                                   :cancel (lambda () (setq cleaned t)))))
      (should cleaned)
      (should-not (kargu-async-pending-p late)))))

(ert-deftest kargu-native-history-reset-does-not-cancel-foreign-request-test ()
  "A storage reset never owns transport cancellation."
  (with-temp-buffer
    (let ((cancelled nil))
      (cl-letf (((symbol-function 'kargu-api-cancel) (lambda () (setq cancelled t))))
               (kargu-history-reset)
               (should-not cancelled)))))

(ert-deftest kargu-native-standalone-http-releases-admission-test ()
  "The compatibility API clears its busy projection after owned delivery."
  (with-temp-buffer
    (let (held (calls 0))
      (kargu-test-native-boundary
       (cl-letf (((symbol-function 'plz)
                  (lambda (&rest options)
                    (setq held (plist-get (cddr options) :then)) nil)))
                (kargu-api-send "hello" (lambda (_) (cl-incf calls)))
                (should (kargu-busy-p))
                (funcall held "{\"choices\":[{\"message\":{\"content\":\"done\"}}]}")
                (should (= calls 1))
                (should-not (kargu-busy-p)))))))

(ert-deftest kargu-native-reset-is-owned-and-blocks-reentry-test ()
  "Reset closes its claim before replacing the session and rejects reentry."
  (with-temp-buffer
    (setq-local kargu-application-owner (kargu-application-create))
    (let (held rejected (old (kargu-session-context)))
      (kargu-test-native-boundary
       (cl-letf (((symbol-function 'kargu-api-send)
                  (lambda (_prompt callback &rest _) (setq held callback))))
                (let ((run (kargu-loop-send "hello" nil
                                            (lambda (_)
                                              (setq rejected
                                                    (condition-case nil
                                                        (progn (kargu-loop-send "reentry") nil)
                                                      (user-error t)))))))
                  (kargu-session-reset)
                  (should rejected)
                  (should-not (eq old (kargu-session-context)))
                  (should (eq (kargu-application-current-status) :idle))
                  (should-not (kargu-loop--live-p run))
                  (funcall held nil)
                  (should-not (kargu-history-messages))))))))

(ert-deftest kargu-native-foreign-session-reset-keeps-active-claim-test ()
  "A shared application's other session cannot reset the active session's run."
  (let ((app (kargu-application-create)) run)
    (with-temp-buffer
      (setq-local kargu-application-owner app)
      (kargu-test-native-boundary
       (cl-letf (((symbol-function 'kargu-api-send) #'ignore))
                (setq run (kargu-loop-send "hello" nil #'ignore))
                (with-temp-buffer
                  (setq-local kargu-application-owner app)
                  (kargu-session-reset))
                (should (kargu-loop--live-p run))
                (kargu-loop-stop))))))

(ert-deftest kargu-native-confirmation-cancellation-is-scoped-test ()
  "Run cancellation touches its own confirmation, not unrelated pending UI."
  (with-temp-buffer
    (setq-local kargu-application-owner (kargu-application-create))
    (let (decision cancellations foreign)
      (kargu-test-native-boundary
       (cl-letf (((symbol-function 'kargu-api-send) #'ignore)
                 ((symbol-function 'kargu-present-confirmation)
                  (lambda (request)
                    (pcase (kargu-confirmation-operation request)
                      (:prompt
                       (setq decision (plist-get (kargu-confirmation-options request) :on-decision))
                       (list :handle))
                      (:cancel
                       (push (plist-get (kargu-confirmation-options request) :handle) cancellations))
                      (:dismiss (setq foreign t))))))
                (let* ((run (kargu-loop-send "hello" nil #'ignore))
                       (handle (kargu-execution-call
                                (plist-get run :context) #'kargu-confirm
                                :default-action :stop :on-decision (lambda (_) (ert-fail "Late decision")))))
                  (kargu-loop-stop)
                  (should (equal cancellations (list handle)))
                  (should-not foreign)
                  (funcall decision :approve)))))))

(ert-deftest kargu-native-job-cleanup-preserves-foreign-job-test ()
  "Foreground jobs register exact cleanup handles, even in a shared project."
  (with-temp-buffer
    (setq-local kargu-application-owner (kargu-application-create))
    (kargu-test-mode 'agent)
    (let ((foreign (kargu-bash--make-job :id "foreign" :state :running))
          (kargu-job--services (make-hash-table :test #'equal))
          (kargu-bash--processes (make-hash-table :test #'equal)) cancelled)
      (puthash "foreign" foreign (kargu-job-service-jobs (kargu-job-service-for-project)))
      (puthash "foreign" foreign kargu-bash--processes)
      (kargu-test-native-boundary
       (cl-letf (((symbol-function 'kargu-api-send) #'ignore)
                 ((symbol-function 'kargu-bridge-ensure) (lambda (&rest _) #'ignore))
                 ((symbol-function 'kargu-job-cancel) (lambda (job &rest _) (push job cancelled))))
                (let ((run (kargu-loop-send "hello" nil #'ignore)))
                  (kargu-execution-call (plist-get run :context) #'kargu-bash-start-job
                                        "echo test" default-directory "sh" :callback #'ignore)
                  (kargu-loop-stop)
                  (should (= (length cancelled) 1))
                  (should-not (memq foreign cancelled))
                  (should (eq (kargu-bash--job-state foreign) :running))))))))

(ert-deftest kargu-native-edit-cleanup-preserves-foreign-service-test ()
  "Native change reset and abort cannot reach the compatibility review table."
  (with-temp-buffer
    (setq-local kargu-application-owner (kargu-application-create))
    (let ((foreign (kargu-edit-service-create :root default-directory)) aborted)
      (puthash "/foreign" (list :path "/foreign") (kargu-edit-service-reviews foreign))
      (kargu-test-native-boundary
       (cl-letf (((symbol-function 'kargu-api-send) #'ignore)
                 ((symbol-function 'kargu-diff--abort-session)
                  (lambda (review &rest _) (push review aborted))))
                (let* ((_run (kargu-loop-send "hello" nil #'ignore))
                       (service (cdr kargu-diff--execution-service))
                       (own (list :path "/owned")))
                  (should-not (eq service foreign))
                  (puthash "/owned" own (kargu-edit-service-reviews service))
                  (let ((kargu-diff--active-service foreign)) (kargu-loop-stop))
                  (should (equal aborted (list own)))
                  (should (= (hash-table-count (kargu-edit-service-reviews foreign)) 1))))))))

(ert-deftest kargu-native-terminal-request-refuses-late-retry-test ()
  "A timer registered after request cancellation cannot resurrect its state."
  (let* ((request (kargu-logical-request-create))
         (timer (run-at-time 60 nil #'ignore)))
    (kargu-logical-request-cancel request)
    (kargu-logical-request-set-retry-timer request timer)
    (should (eq (kargu-logical-request-state request) :cancelled))
    (should-not (kargu-logical-request-retry-timer request))
    (should-not (memq timer timer-list))))

(ert-deftest kargu-native-cleanup-failure-still-finishes-once-test ()
  "Failure in an optional editing cleanup cannot leak the claim or callback."
  (with-temp-buffer
    (setq-local kargu-application-owner (kargu-application-create))
    (let ((reports 0))
      (kargu-test-native-boundary
       (cl-letf (((symbol-function 'kargu-api-send) #'ignore)
                 ((symbol-function 'kargu-edit-changes)
                  (lambda (operation &rest _)
                    (when (eq operation :abort) (error "Cleanup failed")))))
                (kargu-loop-send "hello" nil (lambda (_) (cl-incf reports)))
                (kargu-loop-stop)
                (kargu-loop-stop)
                (should (= reports 1))
                (should-not (kargu-application-work-active-p)))))))

(ert-deftest kargu-native-same-generation-request-replacement-test ()
  "A numeric generation collision does not transfer authority to an old attempt."
  (with-temp-buffer
    (let* ((app (kargu-application-create :generation 7))
           (old (kargu-logical-request-create :app app :generation 7))
           (new (kargu-logical-request-create :app app :generation 7))
           (attempt (kargu-http--make-request :app app :logical old :generation 7)))
      (kargu-application-set-active-request old app)
      (should (kargu-http--live-request-p attempt))
      (kargu-application-set-active-request new app)
      (should-not (kargu-http--live-request-p attempt))
      (should-not (kargu-http--claim-response attempt))
      (should (eq new (kargu-application-current-request app))))))

(ert-deftest kargu-native-http-retry-reenters-its-application-test ()
  "An owned retry resumes in its origin, not the caller's application/buffer."
  (with-temp-buffer
    (setq-local kargu-application-owner (kargu-application-create :generation 7))
    (let* ((app kargu-application-owner)
           (origin (current-buffer))
           (request (kargu-logical-request-create :app app :generation 7))
           (kargu-api-retry-max 1) held posted)
      (kargu-application-set-active-request request app)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_time _repeat function &rest _) (setq held function)))
                ((symbol-function 'kargu--api-post)
                 (lambda (&rest _)
                   (setq posted (list (kargu-application-context) (current-buffer))))))
               (kargu--api-schedule-retry "https://example.invalid" nil nil 7 #'ignore nil 0 "offline")
               (with-temp-buffer
                 (setq-local kargu-application-owner (kargu-application-create :generation 7))
                 (funcall held))
               (should (equal posted (list app origin)))
               (kargu-logical-request-cancel request)))))

(ert-deftest kargu-native-standalone-owner-close-cancels-request-test ()
  "A standalone transport cannot keep admission after its origin closes."
  (let ((app (kargu-application-create))
        (origin (generate-new-buffer " *native-http-owner*")) request)
    (unwind-protect
        (with-current-buffer origin
          (setq-local kargu-application-owner app)
          (kargu-test-native-boundary
           (cl-letf (((symbol-function 'plz) (lambda (&rest _) nil)))
                    (kargu-api-send "hello" #'ignore)
                    (setq request (kargu-application-current-request app))
                    (should (kargu-logical-request-live-p request))
                    (kill-buffer origin))))
      (when (buffer-live-p origin) (kill-buffer origin)))
    (should (eq (kargu-logical-request-state request) :cancelled))
    (should-not (kargu-application-current-request app))))

(ert-deftest kargu-native-session-replacement-at-startup-cancels-claim-test ()
  "Replacing the session from the first observer cannot strand a claimed run."
  (with-temp-buffer
    (setq-local kargu-application-owner (kargu-application-create))
    (let ((posts 0) (reports 0)
          (kargu-state-change-hook
           (list (lambda (key value &rest _)
                   (when (and (eq key :status) (eq value :requesting))
                     (kargu-session-clear))))))
      (kargu-test-native-boundary
       (cl-letf (((symbol-function 'kargu-api-send) (lambda (&rest _) (cl-incf posts))))
                (kargu-loop-send "hello" nil (lambda (_) (cl-incf reports)))
                (should (= reports 1))
                (should (zerop posts))
                (should-not (kargu-application-work-active-p)))))))

(provide 'tests/test-native-ownership)
;;; test-native-ownership.el ends here
