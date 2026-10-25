;;; test-native-model-consumers.el --- Public native metadata contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public setters/readers, actual preparation and atomic catalog generation
;; changes.  These are real core tests, not a second metadata implementation.

;;; Code:

(require 'tests/test-native-model-publication)

(ert-deftest kargu-native-model-consumers-public-fields-are-exact-and-committed-test ()
  "UI stays at the previous commit and never parses prices or rounds capacities."
  (kargu-bridge-test--with-core
   (let* ((kargu-application--bound (kargu-application-create))
          (data '(("context_length" . "9007199254740992.5")
                  ("outputTokenLimit" . "2e3") ("pricing" . (("prompt" . "1e-38")))
                  ("supported_parameters" . ["tools"]))) ticket)
     (kargu-test-set-model-metadata "Model" '(:context-window 10) "a")
     (setq ticket (kargu-model-set-metadata "Model" (copy-tree data t) "a"))
     (should (eq (kargu-bridge-model-ticket-status ticket) :pending))
     (should (= (kargu-model-context-window "Model" "a") 10))
     (kargu-test-await-model-ticket ticket)
     (let ((fields (kargu-model-read "Model" "a"))
           (label (kargu-model-annotation-string "Model" "a")))
       (should-not (plist-get fields :context-window))
       (should (= (plist-get fields :max-output) 2000))
       (should (equal (plist-get fields :input-cost) "0.00000000000000000000000000000000000001"))
       (should-not (plist-get fields :free))
       (should-not (string-search "free" label))
       (should-not (string-search "$0.00/1M" label)))
     (should-error (kargu-model-set-metadata "Model" '(:input-cost 0.000001) "a") :type 'user-error)
     (should-error (kargu-model-set-metadata "Model" '(("pricing" . [(("prompt" . 0.000001))])) "a") :type 'user-error)
     (should (eq ticket (kargu-bridge-models-capture kargu-application--bound)))
     (kargu-test-set-model-metadata "Model" '(("pricing" . (("prompt" . "invalid9")))) "a")
     (should-not (plist-get (kargu-model-read "Model" "a") :free))
     (should-not (plist-get (kargu-model-read "Model" "a") :input-cost))
     (should-not (plist-get (kargu-model-read "Model" "a") :price-label)))))

(ert-deftest kargu-native-model-consumers-public-override-failure-is-not-publication-test ()
  "Public failures are asynchronous typed receipts, not an optimistic cache edit."
  (kargu-bridge-test--with-core
   (let ((kargu-application--bound (kargu-application-create)) failure delivered ticket)
     (kargu-test-set-model-metadata "Model" '(:context-window 10) "a")
     (setq ticket (kargu-model-set-prop "Model" "provider" "foreign" :provider "a"
					:callback (lambda (_view fault) (setq failure fault delivered t))))
     (should-not delivered)
     (kargu-bridge-test--wait (lambda () delivered))
     (should (eq (kargu-bridge-model-ticket-status ticket) :failed))
     (should (equal (gethash "status" (gethash "data" failure)) "invalid_metadata"))
     (should (= (kargu-model-context-window "Model" "a") 10))
     (should (= (gethash "revision" (kargu-bridge-models-snapshot kargu-application--bound)) 1))
     (kargu-test-set-model-prop "Model" "context-window" 20 :provider "a")
     (should (= (kargu-model-context-window "Model" "a") 20))
     (should (= (gethash "revision" (kargu-bridge-models-snapshot kargu-application--bound)) 2)))))

(ert-deftest kargu-native-model-consumers-initial-preparation-observes-without-mutation-test ()
  "Unknown UI uses native offline data; real preparation reads actual head zero."
  (kargu-bridge-test--with-core
   (kargu-test-with-real-connection
    (let ((original (symbol-function 'kargu-bridge-call)) methods result)
      (cl-letf (((symbol-function 'kargu-bridge-ensure)
                 (lambda (&rest _) (ert-fail "Passive getters cannot start a core"))))
        (should-not (kargu-model-get-metadata "unknown" "g02"))
        (should-not (kargu-model-context-window "unknown" "g02"))
        (should (kargu-model-supports-tools-p "unknown" "g02")))
      (cl-letf (((symbol-function 'kargu-bridge-call)
                 (lambda (connection method params callback &rest options)
                   (push method methods)
                   (apply original connection method params callback options))))
        (kargu-api-prepare-connection (lambda (value) (setq result value)) :provider "g02" :model "m")
        (kargu-bridge-test--wait (lambda () result)))
      (should (kargu-ok-p result))
      (should (member "models/snapshot" methods))
      (should (member "models/read" methods))
      (dolist (method '("models/begin" "models/append" "models/commit")) (should-not (member method methods)))
      (let ((snapshot (kargu-result-value result)))
        (unwind-protect
            (progn
              (should (= (plist-get (kargu-connection-snapshot-settings snapshot) :metadata-revision) 0))
              (should (plist-get (kargu-connection-snapshot-settings snapshot) :tools)))
          (kargu-connection-snapshot-wipe snapshot)))))))

(ert-deftest kargu-native-model-consumers-catalog-generation-change-drains-or-orders-commit-test ()
  "New generations revoke uploads but cannot undo commits already issued."
  (kargu-bridge-test--with-core
   (dolist (phase '("models/begin" "models/commit"))
     (let ((kargu-application--bound (kargu-application-create))
           (original (symbol-function 'kargu-bridge-call)) held intercepted pending results methods)
       (kargu-test-set-model-metadata "seed" '(:context-window 1) "opencode")
       (cl-letf (((symbol-function 'kargu-transport-request)
                  (lambda (_method _url &rest options) (push (plist-get options :then) pending)))
                 ((symbol-function 'kargu-bridge-call)
                  (lambda (connection method params callback &rest options)
                    (push method methods)
                    (let ((hold (and (not intercepted) (equal method phase))))
                      (when hold (setq intercepted t))
                      (apply original connection method params
                             (if hold (lambda (value failure)
                                        (setq held (lambda () (funcall callback value failure)))) callback)
                             options)))))
         (kargu-api-fetch-model-ids "opencode" (lambda (ids) (push (cons 'old ids) results)))
         (funcall (car pending) "{\"models\":[{\"id\":\"old\",\"context_length\":10}]}")
         (kargu-bridge-test--wait (lambda () held))
         (kargu-api-fetch-model-ids "opencode" (lambda (ids) (push (cons 'new ids) results)))
         (funcall (car pending) "{\"models\":[{\"id\":\"new\",\"context_length\":20}]}")
         (should-not results)
         (funcall held)
         (kargu-bridge-test--wait (lambda () (= (length results) 2)))
         (should (equal (cdr (assq 'old results)) '("old")))
         (should (equal (cdr (assq 'new results)) '("new")))
         (should (= (kargu-model-context-window "new" "opencode") 20))
         (should-not (kargu-model-get-metadata "old" "opencode"))
         (should (equal (kargu-selection-model-candidates "opencode") '("new")))
         (should (= (gethash "revision" (kargu-bridge-models-snapshot kargu-application--bound))
                    (if (equal phase "models/begin") 2 3)))
         (when (equal phase "models/begin") (should (member "models/abort" methods))))))))

(provide 'tests/test-native-model-consumers)
;;; test-native-model-consumers.el ends here
