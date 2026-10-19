;;; dape-fixtures.el --- Stable fake debugger identities -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Legacy command tests override transport stages, not ownership admission.

;;; Code:

(require 'cl-lib)

(defmacro kargu-test-with-debug-adapter (binding overrides &rest body)
  "Run BODY under debugger BINDING and transport OVERRIDES.
BINDING is (CONNECTION THREAD FRAME-ID).  THREAD must have stable identity."
  (declare (indent 2))
  (cl-destructuring-bind (connection thread frame-id) binding
    (let ((live (make-symbol "live")))
      `(let ((,live ,thread))
         (cl-letf (((symbol-function 'kargu-dape--raw-connection) (lambda () ,connection))
                   ((symbol-function 'kargu-dape-project-connections) (lambda (&optional _) (list ,connection)))
                   ((symbol-function 'dape--threads) (lambda (_) (list ,live)))
                   ((symbol-function 'dape--thread-id) (lambda (_) (plist-get ,live :id)))
                   ((symbol-function 'dape--stack-id) (lambda (_) ,frame-id))
                   ((symbol-function 'dape--stack-trace)
                    (lambda (_conn work _limit callback)
                      (setf (plist-get work :stackFrames) (copy-tree (plist-get ,live :stackFrames) t))
                      (funcall callback))))
           (cl-letf ,overrides ,@body))))))

(provide 'tests/dape-fixtures)
;;; dape-fixtures.el ends here
