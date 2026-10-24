;;; test-job-owner.el --- Tests for owned job service lifecycle -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for kargu-job-service and project-scoped job lifecycle.

;;; Code:

(require 'ert)
(require 'kargu/state/store)
(require 'kargu/api/catalog)
(require 'kargu/models/store)
(defvar kargu-context-buffer nil)
(require 'tests/test-helpers)
(require 'kargu/tools/bash)
(require 'kargu/tools/bash/jobs)

(ert-deftest kargu-job-service-isolation-test ()
  "Two different project roots have isolated job services."
  (let* ((root-a (file-name-as-directory (make-temp-file "kargu-job-a-" t)))
         (root-b (file-name-as-directory (make-temp-file "kargu-job-b-" t)))
         (svc-a (kargu-job-service-for-project root-a))
         (svc-b (kargu-job-service-for-project root-b)))
    (unwind-protect
        (progn
          (should-not (equal (kargu-job-service-id svc-a) (kargu-job-service-id svc-b)))
          (should (equal (kargu-job-service-project-root svc-a) root-a))
          (should (equal (kargu-job-service-project-root svc-b) root-b))
          ;; Adding a job to A does not affect B
          (cl-incf (kargu-job-service-counter svc-a))
          (puthash "p1" 'job-a (kargu-job-service-jobs svc-a))
          (should (gethash "p1" (kargu-job-service-jobs svc-a)))
          (should-not (gethash "p1" (kargu-job-service-jobs svc-b))))
      (delete-directory root-a t)
      (delete-directory root-b t))))

(ert-deftest kargu-job-service-monotonic-counter-test ()
  "Job counter increments monotonically per project service."
  (let* ((root (file-name-as-directory (make-temp-file "kargu-job-cnt-" t)))
         (svc (kargu-job-service-for-project root)))
    (unwind-protect
        (progn
          (setf (kargu-job-service-counter svc) 0)
          (should (= (cl-incf (kargu-job-service-counter svc)) 1))
          (should (= (cl-incf (kargu-job-service-counter svc)) 2)))
      (delete-directory root t))))

(ert-deftest kargu-job-service-pruning-test ()
  "Completed jobs beyond limit are pruned while live jobs are preserved."
  (let* ((root (file-name-as-directory (make-temp-file "kargu-job-prune-" t)))
         (svc (kargu-job-service-for-project root))
         (kargu-bash-completed-jobs 2)
         (jobs (kargu-job-service-jobs svc)))
    (unwind-protect
        (let (buffers)
          (dotimes (i 4)
            (let* ((buf (generate-new-buffer (format " *test-prune-%d*" i)))
                   (job (kargu-bash--make-job
                         :id (format "p%d" i)
                         :root root :service svc :buffer buf
                         :started (+ 1000 i) :ended-at (+ 1001 i)
                         :state :done)))
              (push buf buffers)
              (puthash (format "p%d" i) job jobs)))
          (kargu-bash--prune-jobs svc)
          ;; Only the 2 newest should remain in jobs
          (should-not (gethash "p0" jobs))
          (should-not (gethash "p1" jobs))
          (should (gethash "p2" jobs))
          (should (gethash "p3" jobs))
          (dolist (b buffers)
            (when (buffer-live-p b) (kill-buffer b))))
      (delete-directory root t))))

(ert-deftest kargu-job-structured-cancellation-test ()
  "Cancelling a job transitions state and clears active foreground handle."
  (let* ((root (kargu-permission-project-root))
         (svc (kargu-job-service-for-project root))
         (job (kargu-bash--make-job
               :id "p99" :root root :service svc :state :running)))
    (setf (kargu-job-service-active-async-proc svc) 'fake-proc)
    (setq kargu-bash--active-async-proc 'fake-proc)
    (setf (kargu-bash--job-handle job) 'fake-proc)
    (cl-letf (((symbol-function 'kargu-bridge-job-cancel) #'ignore))
      (kargu-job-cancel job 0.01))
    (should (eq (kargu-bash--job-state job) :cancelling))
    (should-not (kargu-job-service-active-async-proc svc))
    (should-not kargu-bash--active-async-proc)))

(ert-deftest kargu-job-service-fallback-global-test ()
  "Fallback service is used consistently when project root is nil."
  (cl-letf (((symbol-function 'kargu-permission-project-root) (lambda () nil)))
    (let* ((svc1 (kargu-job-service-for-project nil))
           (svc2 (kargu-job-service-for-project nil)))
      (should (equal (kargu-job-service-id svc1) (kargu-job-service-id svc2)))
      (should-not (kargu-job-service-project-root svc1)))))

(ert-deftest kargu-job-services-reset-test ()
  "Reset clears all registered job services and compatibility tables."
  (let* ((root (file-name-as-directory (make-temp-file "kargu-job-reset-" t)))
         (svc (kargu-job-service-for-project root)))
    (unwind-protect
        (progn
          (puthash "p1" 'dummy (kargu-job-service-jobs svc))
          (puthash "p1" 'dummy kargu-bash--processes)
          (setq kargu-bash--counter 42)
          (kargu-job-services-reset)
          (should (= (hash-table-count kargu-job--services) 0))
          (should (= (hash-table-count kargu-bash--processes) 0))
          (should (= kargu-bash--counter 0)))
      (delete-directory root t))))

(provide 'tests/test-job-owner)

;;; test-job-owner.el ends here
