;;; test-process-session.el --- Native interactive session contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Preserve the former interactive transport tests through real native jobs.

;;; Code:

(require 'tests/test-helpers)
(require 'tests/test-bridge-jobs)
(require 'kargu/tools/process/session)

(defvar kargu-session-test--sessions nil
  "Interactive fixture handles requiring actual drain before core teardown.")

(defmacro kargu-session-test--with-core (&rest body)
  "Run BODY inside an explicitly approved temporary interactive project."
  (declare (indent 0) (debug t))
  `(kargu-bridge-test--with-core
     (with-temp-buffer
       (let* ((root (file-name-as-directory (file-truename (make-temp-file "kargu-session-native-" t))))
              (default-directory root) (kargu-permission--override-root root)
              (kargu-session-test--sessions nil))
         (kargu-test-mode 'agent)
         (unwind-protect
             (cl-letf (((symbol-function 'kargu-present-confirmation) #'kargu-bridge-job-test--approve)) ,@body)
           (dolist (session kargu-session-test--sessions)
             (when (eq (kargu-process-session-state session) :running)
               (kargu-process-session-close session))
             (when (eq (kargu-process-session-state session) :starting)
               (kargu-process-session-kill session)))
           (kargu-bridge-test--wait
            (lambda ()
              (and (cl-every (lambda (session) (eq (kargu-process-session-state session) :closed))
                             kargu-session-test--sessions)
                   (= 0 (hash-table-count (kargu-bridge-connection-jobs conn))))))
           (delete-directory root t))))))

(defun kargu-session-test--start (&rest options)
  "Start cat with OPTIONS, awaiting actual approval and native claim."
  (let ((session (apply #'kargu-process-session-start "cat" nil options)))
    (push session kargu-session-test--sessions)
    (kargu-bridge-test--wait (lambda () (not (eq (kargu-process-session-state session) :starting))))
    (should-not (kargu-process-session-failure session))
    (should (kargu-process-session-live-p session))
    session))

(ert-deftest kargu-process-session-start-and-send-input-test ()
  "Input, Unicode output and EOF use native acknowledgements and actual drain."
  (kargu-session-test--with-core
    (let* ((output "") (exits 0) code
           (session (kargu-session-test--start
                     :on-output (lambda (text) (setq output (concat output text)))
                     :on-exit (lambda (value) (setq code value) (cl-incf exits)))))
      (kargu-process-session-send session "hello ğ😀 session\n")
      (kargu-bridge-test--wait (lambda () (string-search "hello ğ😀 session" output)))
      (kargu-process-session-close session)
      (kargu-bridge-test--wait (lambda () (eq (kargu-process-session-state session) :closed)))
      (should (= code 0))
      (should (= exits 1))
      (should (eq (gethash "cleanup_complete" (kargu-process-session-result session)) t))
      (should-not (kargu-process-session-live-p session)))))

(ert-deftest kargu-process-session-idle-timeout-test ()
  "Rust idle termination closes the private view only after process-group drain."
  (kargu-session-test--with-core
    (let* ((session (kargu-session-test--start :idle-timeout 0.2))
           (pid (kargu-bridge-job-pid (kargu-process-session-handle session))))
      (kargu-bridge-test--wait (lambda () (eq (kargu-process-session-state session) :closed)))
      (should (equal "timeout" (gethash "outcome" (kargu-process-session-result session))))
      (should-not (buffer-live-p (kargu-process-session-buffer session)))
      (should-not (file-exists-p (format "/proc/%s" pid))))))

(ert-deftest kargu-process-session-max-bytes-bound-test ()
  "Native tail and editor view stay byte-bounded while the cursor retains total bytes."
  (kargu-session-test--with-core
    (let ((session (kargu-session-test--start :max-bytes 30)))
      (kargu-process-session-send session "0123456789012345678901234567890123456789\n")
      (kargu-bridge-test--wait (lambda () (>= (kargu-process-session-bytes-read session) 41)))
      (should (kargu-process-session-truncated session))
      (with-current-buffer (kargu-process-session-buffer session)
        (should (<= (string-bytes (buffer-string)) 30))
        (should (string-suffix-p "6789\n" (buffer-string)))))))

(ert-deftest kargu-process-session-kill-structured-test ()
  "Explicit kill requests cancellation, then releases resources after actual drain."
  (kargu-session-test--with-core
    (let* ((session (kargu-session-test--start)) (buffer (kargu-process-session-buffer session)))
      (kargu-process-session-kill session)
      (should (eq (kargu-process-session-state session) :closing))
      (should (buffer-live-p buffer))
      (kargu-bridge-test--wait (lambda () (eq (kargu-process-session-state session) :closed)))
      (should-not (buffer-live-p buffer))
      (should (equal "cancelled" (gethash "outcome" (kargu-process-session-result session)))))))

(ert-deftest kargu-process-session-missing-program-test ()
  "A missing executable fails before allocating a private buffer or native task."
  (let ((before (buffer-list)))
    (should-error (kargu-process-session-start "nonexistent_executable_12345" nil))
    (should (equal before (buffer-list)))))

(ert-deftest kargu-process-session-startup-is-async-and-input-cannot-race-approval-test ()
  "A starting session cannot send stdin or EOF before the captured approval."
  (kargu-session-test--with-core
    (let (decision ready)
      (cl-letf (((symbol-function 'kargu-present-confirmation)
                 (lambda (request)
                   (when (eq (kargu-confirmation-operation request) :prompt)
                     (setq decision (plist-get (kargu-confirmation-options request) :on-decision))))))
        (let ((session (kargu-process-session-start "cat" nil :on-ready (lambda (_) (setq ready t)))))
          (push session kargu-session-test--sessions)
          (should (eq (kargu-process-session-state session) :starting))
          (should-error (kargu-process-session-send session "never"))
          (should-error (kargu-process-session-close session))
          (kargu-bridge-test--wait (lambda () decision))
          (funcall decision :approve)
          (kargu-bridge-test--wait (lambda () ready))
          (should (kargu-process-session-live-p session)))))))

(ert-deftest kargu-process-session-send-eof-follows-input-ack-test ()
  "Combined send/EOF cannot drop its final Unicode payload."
  (kargu-session-test--with-core
    (let* ((output "") (acks 0)
           (session (kargu-session-test--start :on-output (lambda (text) (setq output (concat output text))))))
      (kargu-process-session-send session "final 😀" t
                                  (lambda (_value failure) (should-not failure) (cl-incf acks)))
      (kargu-bridge-test--wait (lambda () (eq (kargu-process-session-state session) :closed)))
      (should (= acks 1))
      (should (equal output "final 😀")))))

(ert-deftest kargu-process-session-oversized-input-fails-once-without-replay-test ()
  "An oversized write is an explicit failure, not truncation or automatic retry."
  (kargu-session-test--with-core
    (let ((session (kargu-session-test--start)) (replies 0) failure)
      (kargu-process-session-send
       session (make-string 32769 ?x) nil
       (lambda (_result error-data) (setq failure error-data) (cl-incf replies)))
      (kargu-bridge-test--wait (lambda () failure))
      (should (= replies 1))
      (should (equal "resource_limit" (gethash "status" (gethash "data" failure))))
      (kargu-bridge-test--wait (lambda () (eq (kargu-process-session-state session) :closed)))
      (should (= replies 1))
      (should (kargu-process-session-failure session)))))

(ert-deftest kargu-process-session-empty-poll-does-not-emit-output-test ()
  "Empty pages update byte metadata without inventing output callbacks."
  (with-temp-buffer
    (let ((calls 0)
          (session (kargu-process-session--create
                    :owner (current-buffer) :context-session (kargu-session-context)
                    :buffer (current-buffer) :max-bytes 10 :state :running)))
      (setf (kargu-process-session-on-output session) (lambda (_) (cl-incf calls)))
      (kargu-process-session--filter session "" 5)
      (should (= calls 0))
      (should (= 5 (kargu-process-session-bytes-read session))))))

(ert-deftest kargu-process-session-late-input-ack-cannot-use-closed-owner-test ()
  "Source revocation suppresses input/EOF callbacks as well as output and exit."
  (dolist (method '(send eof))
    (with-temp-buffer
      (let ((session (kargu-process-session--create
                      :owner (current-buffer) :context-session (kargu-session-context)
                      :handle 'fixture-handle :state :running)) held (calls 0))
        (cl-letf (((symbol-function 'kargu-bridge-job-write)
                   (lambda (_handle _text callback) (setq held callback)))
                  ((symbol-function 'kargu-bridge-job-eof)
                   (lambda (_handle callback) (setq held callback)))
                  ((symbol-function 'kargu-bridge-job-cancel) #'ignore))
          (if (eq method 'send)
              (kargu-process-session-send session "fixture" nil (lambda (&rest _) (cl-incf calls)))
            (kargu-process-session-close session (lambda (&rest _) (cl-incf calls))))
          (setf (kargu-process-session-owner-live session) nil)
          (funcall held nil (kargu-bridge--fault "owner_closed"))
          (should (= 0 calls)))))))

(ert-deftest kargu-process-session-cancelled-startup-disposes-late-receipt-test ()
  "A late receipt is disposed exactly once and cannot revive its cancelled source."
  (with-temp-buffer
    (kargu-test-mode 'agent)
    (let (held disposed (exits 0))
      (cl-letf (((symbol-function 'kargu-bridge-ensure)
                 (lambda (callback) (funcall callback 'fixture-connection nil) #'ignore))
                ((symbol-function 'kargu-bridge-job-start)
                 (lambda (_connection _arguments callback &rest _options) (setq held callback)))
                ((symbol-function 'kargu-bridge-job-dispose) (lambda (handle) (push handle disposed))))
        (let ((session (kargu-process-session-start "cat" nil :on-exit (lambda (_) (cl-incf exits)))))
          (kargu-process-session-kill session)
          (should (eq (kargu-process-session-state session) :closed))
          (funcall held 'late-handle nil)
          (should (equal disposed '(late-handle)))
          (should (= exits 1))
          (should-not (buffer-live-p (kargu-process-session-buffer session))))))))

(ert-deftest kargu-process-session-unknown-cleanup-is-never-legacy-success-test ()
  "A zero parent exit cannot hide unknown cleanup or a timed-out operation."
  (let ((unknown (kargu-bridge--object "outcome" "outcome_unknown" "cleanup_complete" :json-false "exit_code" 0))
        (timed-out (kargu-bridge--object "outcome" "timeout" "cleanup_complete" t "exit_code" 0)))
    (should-not (kargu-process-session--exit-code unknown))
    (should (= -1 (kargu-process-session--exit-code timed-out)))))

(ert-deftest kargu-process-session-source-close-preserves-sibling-test ()
  "Closing one source drains its session without cancelling another source."
  (kargu-session-test--with-core
    (let ((owner (generate-new-buffer " *kargu-session-owner*")) first (exits 0))
      (unwind-protect
          (progn
            (with-current-buffer owner
              (setq-local default-directory root kargu-permission--override-root root)
              (kargu-test-mode 'agent)
              (setq first (kargu-session-test--start :on-exit (lambda (_) (cl-incf exits)))))
            (let ((sibling (kargu-session-test--start)))
              (kill-buffer owner)
              (kargu-bridge-test--wait (lambda () (eq (kargu-process-session-state first) :closed)))
              (kargu-bridge-test--wait
               (lambda () (eq (kargu-bridge-job-state (kargu-process-session-handle first)) :forgotten)))
              (should-not (file-exists-p (format "/proc/%s" (kargu-bridge-job-pid (kargu-process-session-handle first)))))
              (should (= exits 0))
              (should (equal "running" (gethash "state" (kargu-bridge-job-test--call
                                                          #'kargu-bridge-job-status (kargu-process-session-handle sibling)))))))
        (when (buffer-live-p owner) (kill-buffer owner))))))

(ert-deftest kargu-process-session-rejection-releases-startup-once-test ()
  "Rejected approval closes the private view and delivers one typed failure."
  (kargu-session-test--with-core
    (let ((exits 0) ready)
      (cl-letf (((symbol-function 'kargu-present-confirmation)
                 (lambda (request)
                   (when (eq (kargu-confirmation-operation request) :prompt)
                     (funcall (plist-get (kargu-confirmation-options request) :on-decision) :reject)))))
        (let ((session (kargu-process-session-start
                        "cat" nil :on-ready (lambda (_) (setq ready t))
                        :on-exit (lambda (_) (cl-incf exits)))))
          (push session kargu-session-test--sessions)
          (kargu-bridge-test--wait (lambda () (eq (kargu-process-session-state session) :closed)))
          (should-not ready)
          (should (= exits 1))
          (should (kargu-process-session-failure session))
          (should-not (buffer-live-p (kargu-process-session-buffer session))))))))

(provide 'tests/test-process-session)
;;; test-process-session.el ends here
