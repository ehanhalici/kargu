;;; test-config-native.el --- Native parser publication ownership -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Hold real native replies between file capture and editor publication.
;; Files, credentials and owners are synthetic; no upstream request is made.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'tests/test-bridge)

(defmacro kargu-config-native-test--held (&rest body)
  "Run BODY while a real captured configuration parse reply awaits delivery."
  (declare (indent 0) (debug t))
  `(kargu-bridge-test--with-core
     (let* ((file (make-temp-file "kargu-native-parse-" nil ".toml"))
            (kargu-application--bound (kargu-application-create))
            (kargu-diff-review-mode 'auto)
            (call (symbol-function 'kargu-bridge-call))
            (task nil) (held nil) (source nil) (result nil) (next nil) (delivered 0))
       (unwind-protect
           (progn
             (ignore task held source result next delivered)
             (write-region "provider='parsed'\nreview_mode='blocking'\n[provider.parsed]\napikey='synthetic-native-secret'\n"
                           nil file nil 'silent)
             (kargu-config-publish (kargu-config-service-context) '(:provider "stable") "/fixture" "before")
             (cl-letf (((symbol-function 'kargu-bridge-call)
                        (lambda (connection method params callback &rest options)
                          (when (equal method "configuration/parse")
                            (setq source (gethash "source" (gethash "arguments" params))))
                          (apply call connection method params
                                 (if (equal method "configuration/parse")
                                     (lambda (value failure) (setq held (lambda () (funcall callback value failure))))
                                   callback) options))))
               (setq task (kargu-config-refresh-async
                           (lambda (value) (setq result value) (cl-incf delivered)) :paths (list file)))
               (kargu-bridge-test--wait (lambda () held))
               ,@body))
         (when task (kargu-async-cancel task))
         (when next (kargu-async-cancel next))
         (delete-file file)))))

(ert-deftest kargu-config-native-late-reply-cannot-publish-after-revocation-test ()
  "Cancel, deadline, supersession and a lost lease preserve the old publication."
  (dolist (ending '(cancel timeout deadline supersede owner-close))
    (kargu-config-native-test--held
      (pcase ending
        ('cancel (kargu-async-cancel task))
        ('timeout (kargu-async-finish task nil "Configuration timed out"))
        ('deadline (setf (kargu-async-task-deadline (car (kargu-async-task-children task))) (1- (float-time))))
        ('supersede (cl-letf (((symbol-function 'kargu-config-worker-start) #'ignore))
                      (setq next (kargu-config-refresh-async #'ignore :paths (list file)))))
        ('owner-close (puthash :native-core (kargu-bridge-application--make :connection conn :state :closed)
                              (kargu-application-services kargu-application--bound))))
      (funcall held)
      (should (equal (plist-get (kargu--config-plist) :provider) "stable"))
      (should (eq kargu-diff-review-mode 'auto))
      (should (= delivered (if (eq ending 'cancel) 0 1)))
      (when result (should (kargu-err-p result)))
      (should-not (kargu-async-pending-p task))
      (should-not (kargu-async-task-children task))
      (should-not (kargu-async-task-timer task))
      (should (cl-every #'zerop (string-to-list source)))
      (should (equal (gethash "status" (car (kargu-bridge-test--call conn "ping" (kargu-bridge--object)))) "ok")))))

(ert-deftest kargu-config-native-reply-publishes-only-to-initiating-application-test ()
  "A different current application cannot receive another owner's config."
  (kargu-config-native-test--held
    (let ((kargu-application--bound (kargu-application-create)))
      (funcall held)
      (should-not (kargu--config-plist)))
    (should (kargu-ok-p result))
    (should (= delivered 1))
    (should (equal (plist-get (kargu--config-plist) :provider) "parsed"))
    (should (equal (plist-get (cdar (kargu--config-providers)) :apikey) "synthetic-native-secret"))
    (should-not (string-search "synthetic-native-secret" (prin1-to-string (kargu-result-value result))))))

(ert-deftest kargu-config-native-malformed-projection-cannot-publish-test ()
  "Foreign generation, invalid digest, bad config or unknown status fail closed."
  (dolist (field '("generation" "digest" "config" "status"))
    (kargu-config-native-test--held
      (let ((parsed (symbol-function 'kargu-config--parsed)))
        (cl-letf (((symbol-function 'kargu-config--parsed)
                   (lambda (root path generation value failure)
                     (puthash field :json-null value)
                     (funcall parsed root path generation value failure))))
          (funcall held)))
      (should (kargu-err-p result))
      (should (equal (plist-get (kargu--config-plist) :provider) "stable"))
      (should (eq kargu-diff-review-mode 'auto)))))

(ert-deftest kargu-config-native-old-core-has-no-parser-fallback-or-owner-start-test ()
  "A missing capability never invokes a parser, creates an owner or leaks source."
  (let ((source (copy-sequence "apikey='synthetic-private-source'")) failure)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback)
                 (funcall callback (kargu-bridge--connection-create :state 'ready :capabilities []) nil)
                 #'ignore))
              ((symbol-function 'kargu-bridge-call) (lambda (&rest _) (ert-fail "No parse on old core")))
              ((symbol-function 'kargu-bridge-application-ensure) (lambda (&rest _) (ert-fail "No owner startup"))))
      (let ((task (kargu-bridge-config-parse source 1 (lambda (_value error-data) (setq failure error-data))
                                             :application (kargu-application-create))))
        (should (equal (gethash "status" (gethash "data" failure)) "unsupported_configuration_parse"))
        (should-not (string-search "synthetic-private-source" (prin1-to-string failure)))
        (should (equal source "apikey='synthetic-private-source'"))
        (should-not (kargu-async-task-timer task))))))

(ert-deftest kargu-config-native-source-is-captured-before-startup-yield-test ()
  "Mutating input during startup cannot change native configuration intent."
  (kargu-bridge-test--with-core
    (let ((source (copy-sequence "provider='original'")) release done result failure)
      (cl-letf (((symbol-function 'kargu-bridge-ensure)
                 (lambda (callback) (setq release (lambda () (funcall callback conn nil))) #'ignore)))
        (kargu-bridge-config-parse source 7 (lambda (value error-data) (setq result value failure error-data done t))
                                   :application (kargu-application-create)))
      (aset source 10 ?X)
      (funcall release)
      (kargu-bridge-test--wait (lambda () done))
      (should-not failure)
      (should (equal (gethash "provider" (gethash "config" result)) "original")))))

(ert-deftest kargu-config-native-absent-file-and-closed-parent-never-start-core-test ()
  "No file means an empty publication; a revoked parent cannot start any child."
  (let ((root (make-temp-file "kargu-config-absent-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (&rest _) (ert-fail "No core startup"))))
          (should (kargu-ok-p (kargu-test-await
                              (lambda (done) (kargu-config-refresh-async done :paths (list (expand-file-name "absent.toml" root)))))))
          (should-not (kargu--config-plist))
          (let ((parent (kargu-async-start #'ignore :owner nil :parent nil)))
            (kargu-async-cancel parent)
            (cl-letf (((symbol-function 'kargu-config-worker-start) (lambda (&rest _) (ert-fail "No file worker"))))
              (let ((task (kargu-config-refresh-async #'ignore :parent parent)))
                (should-not (kargu-async-pending-p task))
                (should-not (kargu-async-task-children parent))))))
      (delete-directory root t))))

(ert-deftest kargu-config-native-oversized-source-and-deleted-parser-test ()
  "Oversized text is refused without startup; no legacy parser remains callable."
  (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (&rest _) (ert-fail "No startup for oversized text"))))
    (let (failure)
      (kargu-bridge-config-parse (make-string 65537 ?x) 0 (lambda (_value error-data) (setq failure error-data))
                                 :application (kargu-application-create))
      (should failure)))
  (dolist (symbol '(kargu--read-toml-config kargu--toml-read-entries kargu--toml-read-value))
    (should-not (fboundp symbol))))

(ert-deftest kargu-config-provider-switch-never-reports-private-endpoint-test ()
  "Provider switching preserves selection without reading/reporting URL secrets."
  (dolist (no-model '(nil t))
    (let ((kargu-application--bound (kargu-application-create))
          (kargu-session--context (kargu-test-session-with-history :provider "before" :model "old"))
          messages logs prefetched)
      (kargu-config-publish
       (kargu-config-service-context)
       '(:providers (("private-switch" :api "https://fixture.invalid/v1?key=synthetic-query-secret&tenant=synthetic-tenant/"
                      :apikey "synthetic-config-key" :model "chosen-model"))) "/fixture" "private")
      (cl-letf (((symbol-function 'kargu-api-prefetch-models) (lambda (provider) (push provider prefetched)))
                ((symbol-function 'kargu--api-base) (lambda (&rest _) (ert-fail "Reports must not read the endpoint")))
                ((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format format args) messages)))
                ((symbol-function 'kargu-log)
                 (lambda (_level format &rest args) (push (apply #'format format args) logs))))
        (should (equal (kargu-set-provider "private-switch" no-model) "private-switch"))
        (should (equal (kargu-selection-provider) "private-switch"))
        (should (equal (kargu-selection-model) (unless no-model "chosen-model")))
        (should (equal prefetched '("private-switch")))
        (should (cl-some (lambda (text) (string-search "private-switch" text)) messages))
        (should (cl-some (lambda (text) (string-search "private-switch" text)) logs))
        (dolist (secret '("fixture.invalid" "synthetic-query-secret" "synthetic-tenant" "synthetic-config-key"))
          (should-not (string-search secret (prin1-to-string (append messages logs)))))))))

(provide 'tests/test-config-native)
;;; test-config-native.el ends here
