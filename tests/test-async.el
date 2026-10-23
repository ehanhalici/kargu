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

(ert-deftest kargu-async-cleanups-compose-and-release-late-resources-test ()
  "Cleanup registration preserves earlier cleanup even when a newer one fails."
  (let ((cleaned nil) delivered)
    (let ((task (kargu-async-start (lambda (value _error) (setq delivered value)))))
      (kargu-async-add-cleanup task (lambda () (push 'first cleaned)))
      (kargu-async-add-cleanup task (lambda () (push 'second cleaned) (error "cleanup failure")))
      (kargu-async-finish task "ok")
      (should (equal cleaned '(first second)))
      (should (equal delivered "ok"))
      (kargu-async-add-cleanup task (lambda () (push 'late cleaned)))
      (should (equal cleaned '(late first second))))))

(ert-deftest kargu-async-explicit-scope-and-hierarchy-test ()
  "Async tasks track explicit owner, parent, deadline and buffer (Contract 2)."
  (let ((kargu-async--pending nil))
    (with-temp-buffer
      (let* ((orig-buf (current-buffer))
             (deadline (+ (float-time) 5.0))
             (parent (kargu-async-start #'ignore :owner "owner-a" :buffer orig-buf :deadline deadline))
             (child1 (kargu-async-start #'ignore :owner "owner-a" :parent parent :buffer orig-buf))
             (child2 (kargu-async-start #'ignore :owner "owner-a" :parent parent :buffer orig-buf))
             (sibling (kargu-async-start #'ignore :owner "owner-b" :buffer orig-buf)))
        (should (stringp (kargu-async-task-id parent)))
        (should (string-prefix-p "task-" (kargu-async-task-id parent)))
        (should (equal (kargu-async-task-owner parent) "owner-a"))
        (should (eq (kargu-async-task-parent child1) parent))
        (should (eq (kargu-async-task-parent child2) parent))
        (should-not (kargu-async-task-parent parent))
        (should (= (length kargu-async--pending) 4))

        ;; Cancelling child1 cancels only child1
        (kargu-async-cancel child1)
        (should (eq (kargu-async-task-state child1) :cancelled))
        (should (eq (kargu-async-task-state child2) :pending))
        (should (eq (kargu-async-task-state parent) :pending))
        (should (eq (kargu-async-task-state sibling) :pending))

        ;; Cancelling parent cancels parent and remaining child2, but leaves sibling untouched
        (kargu-async-cancel parent)
        (should (eq (kargu-async-task-state parent) :cancelled))
        (should (eq (kargu-async-task-state child2) :cancelled))
        (should (eq (kargu-async-task-state sibling) :pending))

        ;; Cancelling owner-b cancels sibling
        (kargu-async-cancel-owner "owner-b")
        (should (eq (kargu-async-task-state sibling) :cancelled))
        (should-not kargu-async--pending)))))

(provide 'tests/test-async)
;;; test-async.el ends here
