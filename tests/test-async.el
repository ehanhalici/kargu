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

(provide 'tests/test-async)
;;; test-async.el ends here
