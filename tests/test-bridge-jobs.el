;;; test-bridge-jobs.el --- Native job client ownership contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Explicit fixture approval only; no paid application, login or model call.

;;; Code:

(require 'tests/test-bridge)
(require 'kargu/bridge/jobs)
(require 'kargu/bridge/job-output)

(defun kargu-bridge-job-test--approve (request)
  "Approve only the fixture command described by confirmation REQUEST."
  (when (eq (kargu-confirmation-operation request) :prompt)
    (funcall (plist-get (kargu-confirmation-options request) :on-decision) :approve)))

(ert-deftest kargu-bridge-output-utf8-carry-at-every-byte-boundary-test ()
  "Page framing never corrupts a Unicode codepoint or keeps more than three bytes."
  (let* ((text "ağ😀€z") (bytes (encode-coding-string text 'utf-8 t)))
    (dotimes (cut (1+ (length bytes)))
      (let* ((first (kargu-bridge-output--split (substring bytes 0 cut) nil))
             (last (kargu-bridge-output--split (concat (cdr first) (substring bytes cut)) t)))
        (should (<= (length (cdr first)) 3))
        (should (equal (concat (car first) (car last)) text))
        (should (equal (cdr last) ""))))))

(ert-deftest kargu-bridge-job-idle-missing-capability-does-not-start-test ()
  "An older core cannot silently discard an enabled idle termination policy."
  (let ((conn (kargu-bridge--connection-create
               :state 'ready :capabilities ["process_jobs"] :read-scope (kargu-bridge--object))) failure)
    (cl-letf (((symbol-function 'kargu-bridge-call) (lambda (&rest _) (ert-fail "Unsupported idle job sent RPC"))))
      (kargu-bridge-approval-execute conn (kargu-bridge--object "idle_timeout_ms" 100)
                                      (lambda (_value error-data) (setq failure error-data)) :capability "process_jobs")
      (should (equal "unavailable" (gethash "status" (gethash "data" failure)))))))

(ert-deftest kargu-bridge-output-real-merged-drain-test ()
  "Output polling delivers merged text and completes only after real native drain."
  (kargu-bridge-test--with-core
    (let ((root (make-temp-file "kargu-output-poll-" t)) job reader done result failure (text ""))
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-present-confirmation) #'kargu-bridge-job-test--approve))
            (setq job (kargu-bridge-job-test--start conn root "printf 'ğ😀'; printf 'stderr' >&2" nil '(("stderr" . "merge"))))
            (setq reader (kargu-bridge-output-start
                          job (lambda (chunk _truncated) (setq text (concat text chunk)))
                          (lambda (value error-data) (setq result value failure error-data done t))))
            (kargu-bridge-test--wait (lambda () done))
            (should-not failure)
            (should (equal text "ğ😀stderr"))
            (should (eq (gethash "cleanup_complete" result) t))
            (should (= (gethash "exit_code" result) 0))
            (should (kargu-bridge-output-closed reader)))
        (when reader (kargu-bridge-output-close reader))
        (kargu-bridge-job-test--dispose job)
        (delete-directory root t)))))

(ert-deftest kargu-bridge-job-domain-freshness-rechecked-after-prompt-test ()
  "A delayed approval cannot bypass the consumer's captured domain policy."
  (kargu-bridge-test--with-core
    (let ((root (make-temp-file "kargu-output-freshness-" t)) (valid t) decision done failure)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-present-confirmation)
                     (lambda (request)
                       (when (eq (kargu-confirmation-operation request) :prompt)
                         (setq decision (plist-get (kargu-confirmation-options request) :on-decision))))))
            (kargu-bridge-job-start
             conn (kargu-bridge-test--command root "printf bad > effect")
             (lambda (_job error-data) (setq failure error-data done t)) :valid-p (lambda () valid))
            (kargu-bridge-test--wait (lambda () decision))
            (setq valid nil)
            (funcall decision :approve)
            (kargu-bridge-test--wait (lambda () done))
            (should failure)
            (should-not (file-exists-p (expand-file-name "effect" root))))
        (delete-directory root t)))))

(ert-deftest kargu-bridge-job-idle-policy-is-exactly-reviewed-test ()
  "Changing idle metadata fails exact review; the captured interval is displayed."
  (kargu-bridge-test--with-core
    (let ((root (make-temp-file "kargu-idle-review-" t)) job details
          (validate (symbol-function 'kargu-bridge-approval--valid)))
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-present-confirmation)
                     (lambda (request)
                       (when (eq (kargu-confirmation-operation request) :prompt)
                         (setq details (plist-get (kargu-confirmation-options request) :details))
                         (kargu-bridge-job-test--approve request))))
                    ((symbol-function 'kargu-bridge-approval--valid)
                     (lambda (connection params entry)
                       (let ((wrong (kargu-bridge-approval--copy params)))
                         (puthash "idle_timeout_ms" 101 wrong)
                         (should-not (funcall validate connection wrong entry)))
                       (funcall validate connection params entry))))
            (setq job (kargu-bridge-job-test--start conn root "printf idle-safe" nil '(("idle_timeout_ms" . 100))))
            (should (string-search "idle: 100 ms" details))
            (should (equal (gethash "outcome" (kargu-bridge-job-test--exited job)) "ok")))
        (kargu-bridge-job-test--dispose job)
        (delete-directory root t)))))

(defun kargu-bridge-job-test--start (connection root script &optional owner extras)
  "Start fixture SCRIPT on CONNECTION in ROOT for OWNER with EXTRAS."
  (let ((args (kargu-bridge-test--command root script)) finished job failure)
    (puthash "timeout_ms" :json-null args)
    (dolist (pair extras) (puthash (car pair) (cdr pair) args))
    (kargu-bridge-job-start connection args
                            (lambda (value error-data) (setq job value failure error-data finished t)) :owner owner)
    (kargu-bridge-test--wait (lambda () finished))
    (should-not failure)
    (should (kargu-bridge-job-p job))
    job))

(defun kargu-bridge-job-test--call (function &rest arguments)
  "Await test-only FUNCTION with ARGUMENTS, returning its native result."
  (let (finished result failure)
    (apply function (append arguments (list (lambda (value error-data)
                                            (setq result value failure error-data finished t)))))
    (kargu-bridge-test--wait (lambda () finished))
    (should-not failure)
    result))

(defun kargu-bridge-job-test--exited (job)
  "Await JOB's actual native terminal result, never just its startup receipt."
  (let (result)
    (kargu-bridge-test--wait
     (lambda ()
       (setq result (kargu-bridge-job-test--call #'kargu-bridge-job-status job))
       (equal (gethash "state" result) "exited")))
    (gethash "result" result)))

(defun kargu-bridge-job-test--dispose (job)
  "Drain fixture JOB before closing its core connection."
  (when job
    (kargu-bridge-job-dispose job)
    (kargu-bridge-test--wait (lambda () (memq (kargu-bridge-job-state job) '(:forgotten :disconnected))))))

(ert-deftest kargu-bridge-job-real-stdin-eof-and-claimed-owner-test ()
  "The client claims only after installing owner hooks; stdin remains interactive."
  (kargu-bridge-test--with-core
    (let ((root (make-temp-file "kargu-job-client-" t)) job)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-present-confirmation) #'kargu-bridge-job-test--approve))
            (setq job (kargu-bridge-job-test--start conn root "while IFS= read -r line; do printf '%s' \"$line\"; done"))
            (should (eq (kargu-bridge-job-state job) :running))
            (should (eq (gethash "claimed" (kargu-bridge-job-test--call #'kargu-bridge-job-status job)) t))
            (should (eq (gethash "accepted" (kargu-bridge-job-test--call #'kargu-bridge-job-write job "echo😀\n")) t))
            (kargu-bridge-job-test--call #'kargu-bridge-job-eof job)
            (should (equal (gethash "outcome" (kargu-bridge-job-test--exited job)) "ok"))
            (let* ((page (kargu-bridge-job-test--call #'kargu-bridge-job-read job "stdout" 0))
                   (bytes (apply #'unibyte-string (append (gethash "data" page) nil))))
              (should (equal (decode-coding-string bytes 'utf-8) "echo😀")))
            (kargu-bridge-job-test--call #'kargu-bridge-job-forget job)
            (should (= 0 (hash-table-count (kargu-bridge-connection-jobs conn)))))
        (kargu-bridge-job-test--dispose job)
        (delete-directory root t)))))

(ert-deftest kargu-bridge-job-source-close-drains-and-forgets-only-its-job-test ()
  "Source closure cancels its job without closing another owner's pipe."
  (kargu-bridge-test--with-core
    (let ((root (make-temp-file "kargu-job-owner-" t))
          (owner (generate-new-buffer " *kargu-native-job-owner*")) first second)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-present-confirmation) #'kargu-bridge-job-test--approve))
            (setq first (kargu-bridge-job-test--start conn root "read value" owner)
                  second (kargu-bridge-job-test--start conn root "read value"))
            (kill-buffer owner)
            (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-job-state first) :forgotten)))
            (should-not (file-exists-p (format "/proc/%s" (kargu-bridge-job-pid first))))
            (should (equal (gethash "state" (kargu-bridge-job-test--call #'kargu-bridge-job-status second)) "running")))
        (when (buffer-live-p owner) (kill-buffer owner))
        (kargu-bridge-job-test--dispose first)
        (kargu-bridge-job-test--dispose second)
        (delete-directory root t)))))

(ert-deftest kargu-bridge-job-environment-is-exact-but-not-printed-in-review-test ()
  "Approval keeps the exact environment while withholding its plaintext values."
  (kargu-bridge-test--with-core
    (let ((root (make-temp-file "kargu-job-environment-" t)) details job)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-present-confirmation)
                     (lambda (request)
                       (when (eq (kargu-confirmation-operation request) :prompt)
                         (setq details (plist-get (kargu-confirmation-options request) :details))
                         (kargu-bridge-job-test--approve request)))))
            (setq job (kargu-bridge-job-test--start
                       conn root "printf '%s' \"$KARGU_FIXTURE_PRIVATE\"" nil
                       `(("environment" . ,(kargu-bridge--object "KARGU_FIXTURE_PRIVATE" "synthetic-private-value")))))
            (should (string-search "KARGU_FIXTURE_PRIVATE" details))
            (should-not (string-search "synthetic-private-value" details))
            (kargu-bridge-job-test--exited job)
            (let ((page (kargu-bridge-job-test--call #'kargu-bridge-job-read job "stdout" 0)))
              (should (equal (append (gethash "data" page) nil) (string-to-list "synthetic-private-value")))))
        (kargu-bridge-job-test--dispose job)
        (delete-directory root t)))))

(ert-deftest kargu-bridge-job-forgotten-handle-never-reconnects-or-sends-test ()
  "A forgotten job is inert and cannot borrow a replacement connection."
  (let* ((conn (kargu-bridge--connection-create :state 'ready))
         (job (kargu-bridge-job--create :connection conn :state :forgotten)) failure)
    (cl-letf (((symbol-function 'kargu-bridge-call) (lambda (&rest _) (ert-fail "Stale job sent RPC"))))
      (kargu-bridge-job-cancel job (lambda (_result error-data) (setq failure error-data)))
      (should failure)
      (should (eq (kargu-bridge-job-state job) :forgotten)))))

(ert-deftest kargu-bridge-job-owner-dies-between-receipt-and-claim-test ()
  "A startup handoff race is an explicit error, not an orphaned client waiter."
  (kargu-bridge-test--with-core
    (let ((root (make-temp-file "kargu-job-handoff-" t))
          (owner (generate-new-buffer " *kargu-job-handoff*")) finished failure pid
          (adopt (symbol-function 'kargu-bridge-job--adopt)))
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-present-confirmation) #'kargu-bridge-job-test--approve)
                    ((symbol-function 'kargu-bridge-job--adopt)
                     (lambda (connection receipt project source callback)
                       (setq pid (gethash "process_id" receipt))
                       (kill-buffer source)
                       (funcall adopt connection receipt project source callback))))
            (let ((args (kargu-bridge-test--command root "read value")))
              (puthash "timeout_ms" :json-null args)
              (kargu-bridge-job-start conn args (lambda (_job error-data) (setq failure error-data finished t)) :owner owner))
            (kargu-bridge-test--wait (lambda () finished))
            (should (equal (gethash "status" (gethash "data" failure)) "stale_owner"))
            (should (= 0 (hash-table-count (kargu-bridge-connection-jobs conn)))))
        (when (buffer-live-p owner) (kill-buffer owner))
        (kargu-bridge-stop conn)
        (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-status conn) 'closed)))
        (when pid (should-not (file-exists-p (format "/proc/%s" pid))))
        (delete-directory root t)))))

(ert-deftest kargu-bridge-job-shutdown-waits-beyond-term-grace-test ()
  "The client keeps the shutdown RPC alive through native TERM/grace/KILL/drain."
  (kargu-bridge-test--with-core
    (let ((root (make-temp-file "kargu-shutdown-drain-" t)) job reply failure
          (call (symbol-function 'kargu-bridge-call)))
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-present-confirmation) #'kargu-bridge-job-test--approve)
                    ((symbol-function 'kargu-bridge-call)
                     (lambda (connection method params callback &rest options)
                       (apply call connection method params
                              (if (equal method "shutdown")
                                  (lambda (value error-data)
                                    (setq reply value failure error-data)
                                    (funcall callback value error-data)) callback) options))))
            (setq job (kargu-bridge-job-test--start conn root "trap '' TERM; printf ready; while :; do read value || :; done"))
            (kargu-bridge-test--wait
             (lambda () (let ((page (kargu-bridge-job-test--call #'kargu-bridge-job-read job "stdout" 0)))
                          (> (length (gethash "data" page)) 0))))
            (kargu-bridge-stop conn)
            (kargu-bridge-test--wait (lambda () (eq (kargu-bridge-status conn) 'closed)))
            (should-not failure)
            (should (eq reply :json-null))
            (should-not (file-exists-p (format "/proc/%s" (kargu-bridge-job-pid job)))))
        (kargu-bridge-job-test--dispose job)
        (delete-directory root t)))))

(provide 'tests/test-bridge-jobs)
;;; test-bridge-jobs.el ends here
