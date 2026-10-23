;;; test-process-session.el --- Tests for interactive process session -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for interactive process session transport (DEEP-05).

;;; Code:

(require 'ert)
(require 'kargu/state/store)
(require 'kargu/api/catalog)
(require 'kargu/models/store)
(defvar kargu-context-buffer nil)
(require 'tests/test-helpers)
(require 'kargu/tools/process/session)

(ert-deftest kargu-process-session-start-and-send-input-test ()
  "Interactive session receives input, streams output, and terminates cleanly."
  (skip-unless (executable-find "cat"))
  (let* ((output "")
         (exit-code nil)
         (session (kargu-process-session-start
                   "cat" nil
                   :on-output (lambda (chunk) (setq output (concat output chunk)))
                   :on-exit (lambda (code) (setq exit-code code))
                   :idle-timeout 5.0)))
    (unwind-protect
        (progn
          (should (kargu-process-session-live-p session))
          (kargu-process-session-send session "hello session\n")
          (let ((deadline (+ (float-time) 2.0)))
            (while (and (not (string-search "hello session" output))
                        (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should (string-search "hello session" output))
          (kargu-process-session-close session)
          (let ((deadline (+ (float-time) 2.0)))
            (while (and (null exit-code) (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should (eq exit-code 0))
          (should-not (kargu-process-session-live-p session)))
      (when (kargu-process-session-live-p session)
        (kargu-process-session-kill session)))))

(ert-deftest kargu-process-session-idle-timeout-test ()
  "Interactive session automatically closes when idle timeout is exceeded."
  (skip-unless (executable-find "cat"))
  (let* ((exit-code nil)
         (session (kargu-process-session-start
                   "cat" nil
                   :on-exit (lambda (code) (setq exit-code code))
                   :idle-timeout 0.1)))
    (unwind-protect
        (let ((deadline (+ (float-time) 2.0)))
          (while (and (null exit-code)
                      (< (float-time) deadline))
            (accept-process-output nil 0.05))
          (should-not (kargu-process-session-live-p session))
          (should (numberp exit-code)))
      (when (kargu-process-session-live-p session)
        (kargu-process-session-kill session)))))

(ert-deftest kargu-process-session-max-bytes-bound-test ()
  "Interactive session bounds internal buffer to max-bytes."
  (skip-unless (executable-find "cat"))
  (let* ((session (kargu-process-session-start
                   "cat" nil
                   :idle-timeout 5.0
                   :max-bytes 30)))
    (unwind-protect
        (progn
          (kargu-process-session-send session "0123456789012345678901234567890123456789\n")
          (let ((deadline (+ (float-time) 2.0)))
            (while (and (< (kargu-process-session-bytes-read session) 40)
                        (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (let ((buf (kargu-process-session-buffer session)))
            (should (buffer-live-p buf))
            (should (<= (with-current-buffer buf (buffer-size)) 30))))
      (when (kargu-process-session-live-p session)
        (kargu-process-session-kill session)))))

(ert-deftest kargu-process-session-kill-structured-test ()
  "Explicit kill terminates process and releases session buffer."
  (skip-unless (executable-find "cat"))
  (let* ((session (kargu-process-session-start "cat" nil :idle-timeout 10.0))
         (buf (kargu-process-session-buffer session)))
    (should (kargu-process-session-live-p session))
    (should (buffer-live-p buf))
    (kargu-process-session-kill session)
    (should-not (kargu-process-session-live-p session))
    (should-not (buffer-live-p buf))
    (should (eq (kargu-process-session-state session) :closed))))

(ert-deftest kargu-process-session-missing-program-test ()
  "Starting a missing executable raises an error without leaking resources."
  (should-error (kargu-process-session-start "nonexistent_executable_12345" nil)))

(provide 'tests/test-process-session)

;;; test-process-session.el ends here
