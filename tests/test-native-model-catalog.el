;;; test-native-model-catalog.el --- Native discovery boundary contracts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public editor -> core -> loopback GET, not a replacement Lisp envelope parser.

;;; Code:

(require 'ert)
(require 'tests/test-stream)
(require 'kargu/api/catalog)

(defmacro kargu-model-catalog-test--with-server (body &rest forms)
  "Serve raw discovery BODY and evaluate FORMS with the public async consumer."
  (declare (indent 1) (debug t))
  `(let* ((kargu-application--bound (kargu-application-create))
          (kargu-providers--table (copy-hash-table kargu-providers--table))
          (posts 0) captured
          (server (kargu-stream-test--server ,body nil nil
                                            (lambda (_) (cl-incf posts))
                                            (lambda (headers) (setq captured headers))))
          (url (format "http://127.0.0.1:%d/models" (process-contact server :service)))
          (provider "native-model-catalog-fixture"))
     (unwind-protect
         (progn
           (kargu-register-provider :id provider :api url :models-api url
                                    :format 'openapi :keyless t)
           (cl-letf (((symbol-function 'kargu--api-base) (lambda (&optional _) url))
                     ((symbol-function 'kargu--resolve-api-key) (lambda (&rest _) nil)))
             ,@forms))
       (delete-process server))))

(ert-deftest kargu-native-model-catalog-public-consumer-handles-real-envelopes-test ()
  "Every provider envelope reaches the public consumer as canonical ordered IDs."
  (kargu-bridge-test--with-core
    (dolist (source '("{\"data\":[{\"id\":\"vendor/Model\"}]}"
                      "{\"models\":[{\"name\":\"models/vendor/Model\"}]}"
                      "{\"items\":[\"vendor/Model\"]}" "[\"vendor/Model\"]"))
      (kargu-model-catalog-test--with-server source
        (let (done result failure (deliveries 0))
          (kargu-api-fetch-model-ids
           provider (lambda (ids) (setq result ids done t) (cl-incf deliveries))
           (lambda (message) (setq failure message done t)))
          (kargu-bridge-test--wait (lambda () done))
          (should-not failure)
          (should (equal result '("vendor/Model")))
          (should (= posts 1)) (should (= deliveries 1))
          (should (string-prefix-p "GET /models " captured))
          (should (kargu-model-get-metadata "vendor/Model" provider)))))))

(ert-deftest kargu-native-model-catalog-malformed-is-not-empty-and-retains-cache-test ()
  "Real malformed/error responses retain last good data; explicit [] prunes it."
  (kargu-bridge-test--with-core
    (dolist (source '("{}" "{\"data\":null}" "{\"data\":42}" "[42]"
                      "{\"data\":[],\"error\":\"synthetic-provider-secret\"}" "{\"data\":[]}"))
      (kargu-model-catalog-test--with-server source
        (kargu--catalog-cache-live-models provider '((("id" . "kept") ("context_length" . 100))))
        (let (done result failure)
          (kargu-api-fetch-model-ids provider
           (lambda (ids) (setq result ids done t))
           (lambda (message) (setq failure message done t)))
          (kargu-bridge-test--wait (lambda () done))
          (should (= posts 1))
          (if (equal source "{\"data\":[]}")
              (progn
                (should-not failure) (should-not result)
                (should-not (kargu-model-get-metadata "kept" provider)))
            (should failure)
            (should-not (string-search "synthetic-provider-secret" failure))
            (should (kargu-model-get-metadata "kept" provider))
            (should (equal (gethash provider (kargu-metadata-table :catalog kargu--live-models-cache)) '("kept")))))))))

(ert-deftest kargu-native-model-catalog-real-id-only-refresh-clears-stale-fields-test ()
  "A real bare-ID provider response replaces stale capabilities and fields."
  (kargu-bridge-test--with-core
    (kargu-model-catalog-test--with-server "[\"kept\"]"
      (kargu--catalog-cache-live-models provider
       '((("id" . "kept") ("context_length" . 100) ("supports_tools" . :json-false))))
      (should-not (kargu-model-supports-tools-p "kept" provider))
      (let (done result)
        (kargu-api-fetch-model-ids provider (lambda (ids) (setq result ids done t)))
        (kargu-bridge-test--wait (lambda () done))
        (should (equal result '("kept")))
        (should-not (kargu-model-context-window "kept" provider))
        (should (kargu-model-supports-tools-p "kept" provider))
        (should (= posts 1))))))

(ert-deftest kargu-native-model-catalog-price-lexemes-and-large-body-survive-paging-test ()
  "Raw price precision and a >1 MiB catalog reach the actual metadata consumer."
  (kargu-bridge-test--with-core
    (kargu-model-catalog-test--with-server
        (concat "{\"data\":[{\"id\":\"priced\",\"pricing\":{\"prompt\":0.000000000000000000123456789012345678},\"description\":\""
                (make-string 1200000 ?x) "\"}]}")
      (let (done result failure)
        (kargu-api-list-models (lambda (models) (setq result models done t)) provider)
        (kargu-bridge-test--wait (lambda () done))
        (setq failure (kargu-aget result "error"))
        (should-not failure)
        (should (= posts 1))
        (should (= (length (kargu-aget (car result) "description")) 1200000))
        (should (equal (kargu-aget (kargu-aget (car result) "pricing") "prompt")
                       "0.000000000000000000123456789012345678"))))))

(ert-deftest kargu-native-model-catalog-missing-capability-never-starts-owner-or-get-test ()
  "An old core is rejected before native scope startup or a discovery socket."
  (let (failure)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback)
                 (funcall callback (kargu-bridge--connection-create
                                     :state 'ready :capabilities ["api_request" "api_failure"]) nil)
                 #'ignore))
              ((symbol-function 'kargu-bridge-application-ensure)
               (lambda (&rest _) (ert-fail "No owner startup on an old core")))
              ((symbol-function 'kargu-bridge-call)
               (lambda (&rest _) (ert-fail "No GET on an old core"))))
      (kargu-transport-request 'get "https://fixture.invalid/models"
                               :application (kargu-application-context) :model-catalog t
                               :then (lambda (_) (ert-fail "No old-core catalog"))
                               :else (lambda (error-data) (setq failure error-data)))
      (should (eq (kargu-result-err-code failure) :service-unavailable)))))

(ert-deftest kargu-native-model-catalog-capacities-survive-real-http-and-editor-decode-test ()
  "Capacity lexemes reach the public consumer without float rounding."
  (kargu-bridge-test--with-core
    (kargu-model-catalog-test--with-server
        "{\"data\":[{\"id\":\"exact\",\"context_length\":9007199254740992.5,\"outputTokenLimit\":18446744073709551615,\"top_provider\":[{\"max_completion_tokens\":1e999}],\"pricing\":[{\"prompt\":1e-38}]}]}"
      (let (done result)
        (kargu-api-list-models (lambda (models) (setq result models done t)) provider)
        (kargu-bridge-test--wait (lambda () done))
        (should (= posts 1))
        (let ((record (car result)))
          (should (equal (kargu-aget record "context_length") "9007199254740992.5"))
          (should (= (kargu-aget record "outputTokenLimit") 18446744073709551615))
          (should (equal (kargu-aget (aref (kargu-aget record "top_provider") 0) "max_completion_tokens") "1e999"))
          (should (equal (kargu-aget (aref (kargu-aget record "pricing") 0) "prompt") "1e-38")))))))

(provide 'tests/test-native-model-catalog)
;;; test-native-model-catalog.el ends here
