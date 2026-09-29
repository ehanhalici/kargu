;;; tests/test-heal.el --- Tests for post-edit verification and self-healing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'kargu/core)
(require 'kargu/loop)
(require 'kargu/loop/heal)
(require 'kargu/tools/lsp)

(defmacro kargu-heal-test--with-verification (diagnostics text timeout &rest body)
  "Verify one file whose diagnostics are DIAGNOSTICS and TEXT, then run BODY.
The finished result and the run are bound to `result' and `run'."
  (declare (indent 3))
  `(let* ((run (list :state 'tool))
          (kargu--loop-run run)
          (result nil))
     (cl-letf (((symbol-function 'kargu-lsp-wait-diagnostics)
                (lambda (file cb) (funcall cb file ,text ,timeout)))
               ((symbol-function 'kargu-lsp--diagnostics-data) (lambda (_p) ,diagnostics))
               ((symbol-function 'kargu-diff-consume-file) #'ignore)
               ((symbol-function 'kargu--loop-add-result-and-continue)
                (lambda (_run _id _name text _queue) (setq result text))))
       (kargu--loop-verify-files run "id1" "edit_file" "edited ok" nil '("/tmp/a.el"))
       ,@body)))

(ert-deftest kargu-heal-clean-file-passes-verification-test ()
  "No errors: the result says clean and no healing round is counted."
  (kargu-heal-test--with-verification nil "no problems" nil
    (should (string-search "Verification after edit (clean)" result))
    (should (string-search "Verification passed" result))
    (should-not (plist-get run :healing))))

(ert-deftest kargu-heal-errors-ask-for-a-fix-and-count-a-round-test ()
  "An error-severity diagnostic asks the model to fix it and counts the round."
  (kargu-heal-test--with-verification '((:severity 1) (:severity 2)) "boom" nil
    (should (string-search "1 error(s)" result))
    (should (string-search "SELF-HEALING (round 1 of" result))
    (should (= (plist-get run :healing) 1))))

(ert-deftest kargu-heal-timeout-is-not-reported-as-clean-test ()
  "A diagnostics timeout is stated, never passed off as a clean file."
  (kargu-heal-test--with-verification nil "partial" t
    (should (string-search "diagnostics timed out" result))
    (should (string-search "Verification incomplete" result))
    (should-not (string-search "Verification passed" result))))

(ert-deftest kargu-heal-counts-error-markers-in-the-text-test ()
  "Without structured data, [error] markers in the text are counted."
  (cl-letf (((symbol-function 'kargu-lsp--diagnostics-data) (lambda (_p) nil)))
    (should (= (kargu--loop-count-errors "/tmp/a.el" "[error] x\n[warn] y\n[error] z") 2))))

(ert-deftest kargu-heal-stopped-run-ignores-late-diagnostics-test ()
  "When the run was stopped, a late diagnostics callback does nothing."
  (let* ((run (list :state 'tool))
         (kargu--loop-run nil)
         (continued nil))
    (cl-letf (((symbol-function 'kargu-lsp-wait-diagnostics)
               (lambda (file cb) (funcall cb file "x" nil)))
              ((symbol-function 'kargu-diff-consume-file) #'ignore)
              ((symbol-function 'kargu-loop--set-state) #'ignore)
              ((symbol-function 'kargu--loop-add-result-and-continue)
               (lambda (&rest _) (setq continued t))))
      (kargu--loop-verify-files run "id1" "edit_file" "ok" nil '("/tmp/a.el"))
      (should-not continued))))

(provide 'tests/test-heal)
;;; test-heal.el ends here
