;;; test-skill-native.el --- Skill preparation ownership -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Controlled native reply delivery complements the real filesystem corpus.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu/tools/skill)
(require 'kargu/loop)
(require 'tests/test-fs)
(require 'tests/test-connection-native)

(defun kargu-skill-native-test--view (name)
  "Return a completed synthetic native catalog containing NAME."
  (kargu-bridge--object
   "text" (format "catalog: %s" name) "truncated" :json-false "skipped" 0
   "skills" (vector (kargu-bridge--object "name" name "description" "description" "path" "/synthetic/SKILL.md"))))

(defmacro kargu-skill-native-test--held (&rest body)
  "Run BODY with native `replies' held and `cancels' observed."
  (declare (indent 0))
  `(let ((connection (kargu-bridge--connection-create :state 'ready)) replies cancels)
     (cl-letf (((symbol-function 'kargu-skill-refresh) kargu-test-real-skill-refresh)
               ((symbol-function 'kargu-bridge-ensure)
                (lambda (done) (funcall done connection nil) #'ignore))
               ((symbol-function 'kargu-bridge-skills)
                (lambda (_connection _arguments done &rest _options)
                  (push done replies) (length replies)))
               ((symbol-function 'kargu-bridge-cancel)
                (lambda (_connection id) (push id cancels))))
       ,@body)))

(ert-deftest kargu-skill-native-refresh-is-take-once-and-newest-intent-wins-test ()
  "Older native completion cannot replace a newer completed catalog."
  (with-temp-buffer
    (kargu-skill-native-test--held
      (let (first second)
        (kargu-skill-refresh (lambda (r) (setq first r)))
        (kargu-skill-refresh (lambda (r) (setq second r)))
        (funcall (car replies) (kargu-skill-native-test--view "new") nil)
        (funcall (cadr replies) (kargu-skill-native-test--view "old") nil)
        (should (kargu-ok-p second))
        (should (kargu-err-p first))
        (should (equal (kargu-skill-format-catalog) "catalog: new"))
        (funcall (car replies) (kargu-skill-native-test--view "duplicate") nil)
        (should (equal (kargu-skill-format-catalog) "catalog: new"))
        (should (= (length cancels) 2))))))

(ert-deftest kargu-skill-native-passive-view-is-detached-and-does-no-io-test ()
  "List/catalog readers do not canonicalize paths, scan, read or start Rust."
  (with-temp-buffer
    (kargu-skill-native-test--held
      (kargu-skill-refresh #'ignore)
      (funcall (car replies) (kargu-skill-native-test--view "one") nil)
      (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (&rest _) (ert-fail "startup")))
                ((symbol-function 'file-truename) (lambda (&rest _) (ert-fail "filesystem")))
                ((symbol-function 'directory-files) (lambda (&rest _) (ert-fail "scan")))
                ((symbol-function 'insert-file-contents) (lambda (&rest _) (ert-fail "read"))))
        (let ((entries (kargu-skill-list)) (catalog (kargu-skill-format-catalog)))
          (aset (plist-get (car entries) :name) 0 ?X)
          (aset catalog 0 ?X)
          (should (equal (plist-get (car (kargu-skill-list)) :name) "one"))
          (should (equal (kargu-skill-format-catalog) "catalog: one")))))))

(ert-deftest kargu-skill-native-root-session-settings-and-mode-changes-reject-publication-test ()
  "Delayed callbacks cannot publish into changed context or changed inputs."
  (dolist (change '(root session settings mode))
    (with-temp-buffer
      (let ((kargu-permission--override-root kargu-permission--override-root)
            (kargu-skill-max-chars kargu-skill-max-chars) result)
        (kargu-skill-native-test--held
          (kargu-skill-refresh (lambda (r) (setq result r)))
          (pcase change
            ('root (setq kargu-permission--override-root "/synthetic/changed/"))
            ('session (setq-local kargu-session--context nil) (kargu-session-context))
            ('settings (setq kargu-skill-max-chars 5))
            ('mode (fundamental-mode)))
          (funcall (car replies) (kargu-skill-native-test--view "stale") nil)
          (should-not (kargu-skill-format-catalog))
          (unless (eq change 'mode) (should (or (null result) (kargu-err-p result)))))))))

(ert-deftest kargu-skill-native-buffer-isolation-and-owner-close-cancel-test ()
  "Foreign current buffers cannot adopt a catalog; closing owner revokes RPC."
  (let ((one (generate-new-buffer " *kargu-skill-one*"))
        (two (generate-new-buffer " *kargu-skill-two*")))
    (unwind-protect
        (kargu-skill-native-test--held
          (with-current-buffer one (kargu-skill-refresh #'ignore))
          (with-current-buffer two
            (funcall (car replies) (kargu-skill-native-test--view "one") nil)
            (should-not (kargu-skill-list))
            (kargu-skill-refresh #'ignore))
          (should (with-current-buffer one (equal (kargu-skill-format-catalog) "catalog: one")))
          (kill-buffer two)
          (funcall (car replies) (kargu-skill-native-test--view "dead") nil)
          (should (= (length cancels) 2)))
      (dolist (b (list one two)) (when (buffer-live-p b) (kill-buffer b))))))

(ert-deftest kargu-skill-native-closed-expired-parent-never-invalidates-live-intent-test ()
  "Invalid admission neither starts native work nor stales another refresh."
  (dolist (expired '(nil t))
    (with-temp-buffer
      (kargu-skill-native-test--held
        (kargu-skill-refresh #'ignore)
        (let* ((intent kargu-skill--intent)
               (parent (kargu-async-start #'ignore :parent nil :owner nil)))
          (unwind-protect
              (progn
                (if expired (setf (kargu-async-task-deadline parent) (1- (float-time)))
                  (kargu-async-cancel parent))
                (let ((kargu-async--current-task parent)) (kargu-skill-refresh #'ignore))
                (should (eq intent kargu-skill--intent))
                (should (= (length replies) 1))
                (funcall (car replies) (kargu-skill-native-test--view "live") nil)
                (should (equal (kargu-skill-format-catalog) "catalog: live")))
            (kargu-async-cancel parent)))))))

(ert-deftest kargu-skill-native-failure-keeps-observation-and-old-core-has-no-fallback-test ()
  "Missing capability sends no RPC and cannot replace a good observation."
  (with-temp-buffer
    (kargu-skill-native-test--held
      (kargu-skill-refresh #'ignore)
      (funcall (car replies) (kargu-skill-native-test--view "good") nil)
      (kargu-skill-refresh #'ignore)
      (funcall (car replies) nil (kargu-bridge--object "message" "native failure"))
      (should (equal (kargu-skill-format-catalog) "catalog: good")))
    (let ((connection (kargu-bridge--connection-create :state 'ready :capabilities ["workspace_read_file"])) failure)
      (cl-letf (((symbol-function 'kargu-bridge-call) (lambda (&rest _) (ert-fail "RPC"))))
        (kargu-bridge-skills connection (kargu-bridge--object)
                              (lambda (_value err) (setq failure err))))
      (should (equal (gethash "status" (gethash "data" failure)) "unavailable"))))
  (dolist (old '(kargu-skill--read kargu-skill--parse kargu-skill--collect
                 kargu-skill--collect-paths kargu-skill--metadata-files
                 kargu-skill--field kargu-skill--scalar kargu-skill--paths-under))
    (should-not (fboundp old))))

(ert-deftest kargu-skill-native-load-rejects-late-root-change-test ()
  "A native body from the old workspace cannot become tool context."
  (with-temp-buffer
    (let ((kargu-permission--override-root kargu-permission--override-root) result)
      (kargu-skill-native-test--held
        (kargu-skill-load "one" (lambda (r) (setq result r)))
        (setq kargu-permission--override-root "/synthetic/other/")
        (funcall (car replies) (kargu-skill-native-test--view "private body") nil)
        (should (string-prefix-p "ERROR:" result))
        (should-not (string-search "private body" result))))))

(ert-deftest kargu-skill-native-expired-reply-and-mutated-settings-cannot-publish-test ()
  "Elapsed deadlines beat delayed timers; captured settings cannot alias edits."
  (with-temp-buffer
    (let ((kargu-fs-skip-dirs (list (copy-sequence ".git"))) result)
      (kargu-skill-native-test--held
        (kargu-skill-refresh #'ignore)
        (funcall (car replies) (kargu-skill-native-test--view "good") nil)
        (let ((task (kargu-skill-refresh (lambda (r) (setq result r)))))
          (setf (kargu-async-task-deadline task) (1- (float-time)))
          (funcall (car replies) (kargu-skill-native-test--view "late") nil)
          (should (kargu-err-p result))
          (should (equal (kargu-skill-format-catalog) "catalog: good")))
        (kargu-skill-refresh (lambda (r) (setq result r)))
        (aset (car kargu-fs-skip-dirs) 1 ?X)
        (should-not (kargu-skill-format-catalog))
        (funcall (car replies) (kargu-skill-native-test--view "changed") nil)
        (should (kargu-err-p result))
        (should-not (kargu-skill-format-catalog))))))

(ert-deftest kargu-skill-native-loop-waits-for-catalog-and-stop-revokes-it-test ()
  "A claimed run sends no model request before discovery; Stop revokes it."
  (dolist (stop '(nil t))
    (with-temp-buffer
      (let ((kargu--loop-run nil) (kargu--busy nil)
            (kargu-session-auto-save nil) (sent 0) report)
        (kargu-test-mode 'ask)
        (kargu-skill-native-test--held
          (cl-letf (((symbol-function 'kargu-model-supports-tools-p) (lambda (&rest _) t))
                    ((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
                    ((symbol-function 'kargu-prompt-wrap-user) #'identity)
                    ((symbol-function 'kargu--loop-request)
                     (lambda (run _prompt)
                       (cl-incf sent)
                       (should (equal (kargu-skill-format-catalog) "catalog: admitted"))
                       (kargu-execution-request-started)
                       (kargu--loop-finish run :done "complete"))))
            (let ((run (kargu-loop-send "hello" nil (lambda (r) (setq report r)))))
              (should (kargu-loop-running-p))
              (should (zerop sent))
              (should-not (plist-get run :request-started))
              (should-error (kargu-loop-send "second") :type 'user-error)
              (when stop (kargu-loop-stop))
              (funcall (car replies) (kargu-skill-native-test--view "admitted") nil)
              (should (= sent (if stop 0 1)))
              (should-not (kargu-loop-running-p))
              (should report)
              (should (eq (plist-get report :request-started) (not stop))))))))))

(ert-deftest kargu-skill-native-loop-discovery-failure-preserves-unsent-history-test ()
  "Failed native discovery closes preparation without publishing a user turn."
  (with-temp-buffer
    (let ((kargu--loop-run nil) (kargu--busy nil) (kargu-session-auto-save nil) report)
      (kargu-test-mode 'ask)
      (kargu-history-replace '((("role" . "user") ("content" . "previous"))))
      (let ((before (kargu-history-snapshot)))
        (kargu-skill-native-test--held
          (cl-letf (((symbol-function 'kargu-model-supports-tools-p) (lambda (&rest _) t))
                    ((symbol-function 'kargu-deps-missing) (lambda (&rest _) nil))
                    ((symbol-function 'kargu--loop-request) (lambda (&rest _) (ert-fail "model request"))))
            (kargu-loop-send "unsent" nil (lambda (r) (setq report r)))
            (funcall (car replies) nil (kargu-bridge--object "message" "discovery failed"))
            (should (eq (plist-get report :status) :error))
            (should-not (plist-get report :request-started))
            (should (equal before (kargu-history-snapshot)))
            (should-not (kargu-loop-running-p))))))))

(ert-deftest kargu-skill-native-real-preparation-publishes-catalog-before-first-request-test ()
  "Real config and skill pipes finish before the loop's model request port."
  (kargu-skill-test--with-tree '(("skills/native/SKILL.md" . "native instructions"))
    (kargu-test-with-real-connection
      (let ((sent 0) report)
        (cl-letf (((symbol-function 'kargu--loop-request)
                   (lambda (run _prompt)
                     (cl-incf sent)
                     (should (string-search "<name>native</name>" (kargu-skill-format-catalog)))
                     (kargu-execution-request-started)
                     (kargu--loop-finish run :done "complete"))))
          (kargu-test-await
           (lambda (done)
             (kargu-loop-send "hello" nil (lambda (r) (setq report r) (funcall done r)))))
          (should (= sent 1))
          (should (plist-get report :request-started))
          (let ((kargu--loop-run '(:no-tools t)))
            (should-not (kargu-prompt--skills-block))))))))

(ert-deftest kargu-skill-native-registered-tool-and-alias-share-read-only-gate-test ()
  "Real skill execution stays asynchronous and available in every mode."
  (kargu-skill-test--with-tree '(("skills/native/SKILL.md" . "native instructions"))
    (let ((kargu--tool-registry (kargu-tool-registry-create)))
      (kargu-skill-register-tools)
      (kargu-register-tool-alias "skill-fixture" "skill")
      (dolist (mode '(ask plan debug agent))
        (let ((context (kargu-tool-execution-context-create :root root :mode mode)))
          (dolist (name '("skill" "skill-fixture"))
            (should (string-search
                     "native instructions"
                     (kargu-test-await
                      (lambda (done)
                        (kargu-tool-gate-execute kargu--tool-registry context name
                                                 '(("name" . "native")) :callback done))))))))
      (should (zerop (kargu-tool-execution-active-task-count kargu--tool-registry "skill")))
      (should (zerop (hash-table-count (kargu-bridge-connection-pending conn)))))))

(provide 'tests/test-skill-native)
;;; test-skill-native.el ends here
