;;; test-process-stress.el --- Stress and anomaly verification for processes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Stress and concurrency verification for processes and cancellation lifecycle (RISK-01).

;;; Code:

(require 'ert)
(require 'kargu/state/store)
(require 'kargu/api/catalog)
(require 'kargu/models/store)
(defvar kargu-context-buffer nil)
(require 'tests/test-helpers)
(require 'kargu/tools/process)

(ert-deftest kargu-process-stress-child-group-reap-test ()
  "Cancelling a process group terminates background children without leaking orphans."
  (skip-unless (memq system-type '(gnu/linux darwin berkeley-unix)))
  (let ((buffer (generate-new-buffer " *kargu-stress-child*"))
        process child result)
    (unwind-protect
        (progn
          (setq process (kargu-process-run
                         "sh" '("-c" "sleep 30 & echo $!; wait")
                         (lambda (value) (setq result value))
                         :timeout nil :buffer buffer :keep-buffer t))
          (let ((deadline (+ (float-time) 2)))
            (while (and (with-current-buffer buffer (= (buffer-size) 0))
                        (< (float-time) deadline))
              (accept-process-output nil 0.02)))
          (setq child (string-to-number (string-trim (with-current-buffer buffer (buffer-string)))))
          (should (> child 0))
          ;; Cancel the process group
          (kargu-process-cancel process)
          (let ((deadline (+ (float-time) 2)))
            (while (and (not result) (< (float-time) deadline))
              (accept-process-output nil 0.02)))
          (should result)
          ;; Verify child was reaped and is not lingering
          (let ((deadline (+ (float-time) 2)) attributes)
            (while (and (setq attributes (process-attributes child))
                        (not (equal (alist-get 'state attributes) "Z"))
                        (< (float-time) deadline))
              (accept-process-output nil 0.02))
            (should (or (not attributes)
                        (equal (alist-get 'state attributes) "Z")))))
      (when process (kargu-process-cancel process))
      (when (and child (> child 0) (process-attributes child))
        (signal-process child 'SIGKILL))
      (kill-buffer buffer))))

(ert-deftest kargu-process-stress-accept-output-non-starvation-test ()
  "Dead process output acceptance does not busy-spin or starve other streams."
  (let* ((state (list :main-exited nil :stderr-closed nil))
         (pipe (make-pipe-process :name "kargu-stress-err" :noquery t
                                  :sentinel (lambda (_p _e)
                                              (plist-put state :stderr-closed t))))
         (proc (make-process :name "kargu-stress-proc"
                             :command (list "sh" "-c" "exit 0")
                             :stderr pipe
                             :sentinel (lambda (_p _e)
                                         (plist-put state :main-exited t))))
         (t0 (float-time)))
    (unwind-protect
        (progn
          (while (and (not (and (plist-get state :main-exited)
                                (plist-get state :stderr-closed)))
                      (< (- (float-time) t0) 2.0))
            (accept-process-output nil 0.02))
          (should (plist-get state :main-exited))
          (should (plist-get state :stderr-closed)))
      (when (process-live-p proc) (delete-process proc))
      (when (process-live-p pipe) (delete-process pipe)))))

(ert-deftest kargu-process-stress-stderr-drain-concurrency-test ()
  "Concurrent processes with late stderr output close cleanly without leaking pipes."
  (let ((count 10) (finished 0) results)
    (dotimes (_ count)
      (kargu-process-run
       "sh" '("-c" "(sleep 0.02; printf err >&2) & printf out")
       (lambda (res)
         (cl-incf finished)
         (push res results))
       :timeout 0.5))
    (let ((deadline (+ (float-time) 5.0)))
      (while (and (< finished count) (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    (should (= finished count))
    (should (= (length results) count))
    (dolist (res results)
      (should (equal (plist-get res :output) "out")))))

(ert-deftest kargu-process-stress-graceful-cancel-test ()
  "Graceful cancellation signals process group with SIGINT before force kill."
  (skip-unless (memq system-type '(gnu/linux darwin berkeley-unix)))
  (let* ((called-sigint nil)
         (called-sigkill nil)
         (dummy-proc (make-process :name "dummy" :command '("sleep" "30") :noquery t)))
    (unwind-protect
        (progn
          (process-put dummy-proc 'kargu-pgid (process-id dummy-proc))
          (cl-letf (((symbol-function 'signal-process)
                     (lambda (_pid sig)
                       (when (eq sig 'SIGINT) (setq called-sigint t))
                       (when (eq sig 'SIGKILL) (setq called-sigkill t)))))
            (kargu-process-cancel dummy-proc 0.05)
            (should called-sigint)
            ;; Wait for grace timer to fire
            (let ((deadline (+ (float-time) 0.5)))
              (while (and (not called-sigkill) (< (float-time) deadline))
                (accept-process-output nil 0.02)))
            (should called-sigkill)))
      (when (process-live-p dummy-proc)
        (delete-process dummy-proc)))))

(provide 'tests/test-process-stress)

;;; test-process-stress.el ends here
