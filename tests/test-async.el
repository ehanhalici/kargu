;;; test-async.el --- Asynchronous task lifetime regressions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Losing an origin buffer must still close its pending task exactly once.

;;; Code:

(require 'ert)
(require 'kargu/async)

(ert-deftest kargu-async-closed-origin-delivers-one-error-test ()
  "Closed temporary buffers produce an error result, not an uncaught exception."
  (let (task held results)
    (with-temp-buffer
      (setq task (kargu-async-start
                  (lambda (value error) (push (list value error) results)) :timeout 10))
      (setq held (kargu-async-wrap task (lambda () (error "Must not resume here")))))
    (funcall held)
    (funcall held)
    (should (= (length results) 1))
    (should (equal (cadar results) "Origin buffer was closed"))
    (should-not (kargu-async-task-timer task))
    (should-not (memq task kargu-async--pending))))

(ert-deftest kargu-async-late-operation-errors-do-not-fail-the-parent-test ()
  "An operation error after its own delivery cannot be blamed on its parent."
  (let ((kargu-async--pending nil) parent child answers)
    (unwind-protect
        (progn
          (setq parent (kargu-async-start (lambda (&rest _) (push :parent answers))))
          (let ((kargu-async--current-task parent))
            (setq child (kargu-async-start (lambda (&rest _) (push :child answers)))))
          (funcall (kargu-async-wrap
                    child (lambda ()
                            (kargu-async-finish child :ok)
                            (error "Late operation error"))))
          (should (equal answers '(:child)))
          (should (kargu-async-pending-p parent)))
      (kargu-async--close parent :cancelled))))

(ert-deftest kargu-async-callback-errors-have-an-explicit-owner-test ()
  "Timer deliveries fail a pending parent, or log a root callback error."
  (dolist (has-parent '(nil t))
    (let ((kargu-async--pending nil) parent child results)
      (when has-parent
        (setq parent (kargu-async-start
                      (lambda (value error) (push (list value error) results)))))
      (let ((kargu-async--current-task parent))
        (setq child (kargu-async-start (lambda (&rest _) (error "Callback failed"))
                                      :timeout 60)))
      (kargu-async-finish child :ok)
      (kargu-async-finish child :again)
      (should-not kargu-async--pending)
      (should-not (kargu-async-task-timer child))
      (should (equal results (and has-parent '((nil "Callback failed"))))))))

(ert-deftest kargu-async-start-failure-does-not-leak-a-task-test ()
  "A failed deadline setup removes the newly registered task."
  (let ((kargu-async--pending nil))
    (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) (error "Timer failed"))))
      (should-error (kargu-async-start #'ignore :timeout 1)))
    (should-not kargu-async--pending)))

(provide 'tests/test-async)
;;; test-async.el ends here
