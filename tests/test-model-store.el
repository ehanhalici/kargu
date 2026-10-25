;;; test-model-store.el --- Provider metadata isolation tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Metadata refreshes, aliases, local overrides and inspector ownership.

;;; Code:

(require 'ert)
(require 'kargu/api/catalog)
(require 'kargu/models/store)
(require 'tests/test-helpers)

(ert-deftest kargu-model-store-same-id-is-provider-owned-test ()
  "Context, tools, price and efforts for the same ID never cross providers."
  (progn
    (kargu-test-set-model-metadata "shared"
                              '(("context_length" . 32000) ("supports_tools" . :json-false)
                                ("supports_reasoning" . :json-false)
                                ("pricing" . (("prompt" . "0.000001")))) "openrouter")
    (kargu-test-set-model-metadata "shared"
                              '(("context_length" . 128000) ("supports_tools" . t)
                                ("reasoning" . (("supported_efforts" . ["low" "high"])))
                                ("pricing" . (("prompt" . "0.000002")))) "cerebras")
    (should (= (kargu-model-context-window "shared" "OPENROUTER") 32000))
    (should (= (kargu-model-context-window "shared" "cerebras") 128000))
    (should-not (kargu-model-supports-tools-p "shared" "openrouter"))
    (should (kargu-model-supports-tools-p "shared" "cerebras"))
    (should-not (kargu-model-reasoning-efforts "shared" "openrouter"))
    (should (equal (kargu-model-reasoning-efforts "shared" "cerebras") '("low" "high")))
    (should (equal (plist-get (kargu-model-read "shared" "openrouter") :input-cost) "0.000001"))
    (should (string-search "128k ctx" (kargu-model-annotation-string "shared" "cerebras")))
    (should (= (plist-get (kargu-model-info-facts "shared" "openrouter") :threshold) 78400))
    (should-not (kargu-model-get-metadata "shared" "unrelated"))))

(ert-deftest kargu-model-store-aliases-are-unique-and-local-test ()
  "Only a unique basename in the requested provider can resolve as an alias."
  (progn
    (kargu-test-set-model-metadata "vendor/shared" '(("context_length" . 10)) "a")
    (kargu-test-set-model-metadata "other/shared" '(("context_length" . 20)) "b")
    (should (= (kargu-model-context-window "shared" "a") 10))
    (should (= (kargu-model-context-window "shared" "b") 20))
    (should-not (kargu-model-get-metadata "missing/shared" "a"))
    (kargu-test-set-model-metadata "second/shared" '(("context_length" . 30)) "a")
    (should-not (kargu-model-get-metadata "shared" "a"))
    (should-error (kargu-test-set-model-prop "shared" "context-window" 99 :provider "a")
                  :type 'user-error)
    (should (= (kargu-model-context-window "vendor/shared" "a") 10))
    (kargu-test-set-model-metadata "shared" '(("context_length" . 40)) "a")
    (should (= (kargu-model-context-window "shared" "a") 40))))

(ert-deftest kargu-model-store-preserves-opaque-id-case-test ()
  "Providers normalize case but opaque model IDs and identity tuples do not."
  (let (
        (id (copy-sequence "Model")))
    (kargu-test-set-model-metadata id '(("context_length" . 10)) "PROVIDER")
    (aset id 0 ?x)
    (kargu-test-set-model-metadata "model" '(("context_length" . 20)) "provider")
    (should (= (kargu-model-context-window "Model" "provider") 10))
    (should (= (kargu-model-context-window "model" "PROVIDER") 20))
    (should-not (kargu-model-get-metadata "xodel" "provider"))
    (kargu-test-set-model-metadata "b/c" '(("context_length" . 30)) "a")
    (kargu-test-set-model-metadata "c" '(("context_length" . 40)) "a/b")
    (should (= (kargu-model-context-window "b/c" "a") 30))
    (should (= (kargu-model-context-window "c" "a/b") 40))))

(ert-deftest kargu-model-store-overrides-survive-refresh-without-sharing-test ()
  "Explicit overrides survive refreshes only for the exact owning identity."
  (progn
    (kargu-test-set-model-metadata "shared" '(("context_length" . 10) ("description" . "old")) "a")
    (kargu-test-set-model-metadata "shared" '(("context_length" . 20)) "b")
    (kargu-test-set-model-prop "shared" "context-window" 99 :provider "a")
    (kargu-test-set-model-prop "shared" "supports-tools" nil :provider "a")
    (kargu-test-set-model-metadata "shared" '(("context_length" . 30) ("description" . "new")
                                        ("supports_tools" . t)) "a")
    (should (= (kargu-model-context-window "shared" "a") 99))
    (should (= (kargu-model-get-prop "shared" :context-window "a") 99))
    (should-not (kargu-model-supports-tools-p "shared" "a"))
    (should (equal (kargu-model-get-prop "shared" "description" "a") "new"))
    (should (= (kargu-model-context-window "shared" "b") 20))
    (should (kargu-model-supports-tools-p "shared" "b"))))

(ert-deftest kargu-model-store-plist-overrides-and-empty-records-test ()
  "Legacy plist metadata and empty wire objects support scoped overrides."
  (progn
    (kargu-test-set-model-metadata "legacy" '(:context-window 100 :supports-reasoning t) "a")
    (kargu-test-set-model-prop "legacy" :context-window 200 :provider "a")
    (kargu-test-set-model-prop "legacy" :supports-reasoning nil :provider "a")
    (should (= (kargu-model-context-window "legacy" "a") 200))
    (should-not (kargu-model-supports-reasoning-p "legacy" "a"))
    (kargu-test-set-model-metadata "empty" (make-hash-table :test #'equal) "a")
    (kargu-test-set-model-prop "empty" "max-output" 1024 :provider "a")
    (should (= (plist-get (kargu-model-read "empty" "a") :max-output) 1024))))

(ert-deftest kargu-model-store-overrides-use-canonical-alias-record-test ()
  "Editing a unique alias updates its canonical entry rather than a second copy."
  (progn
    (kargu-test-set-model-metadata "vendor/shared" '(("context_length" . 10)) "a")
    (kargu-test-set-model-prop "shared" "context-window" 50 :provider "a")
    (kargu-test-set-model-metadata "vendor/shared" '(("context_length" . 30)) "a")
    (should (= (kargu-model-context-window "vendor/shared" "a") 50))
    (should (= (length (gethash "records" (kargu-model-projection--view))) 1))
    (should-error (kargu-test-set-model-prop "vendor/shared" "provider" "b" :provider "a")
                  :type 'user-error)))

(ert-deftest kargu-model-store-container-copies-and-snapshots-test ()
  "Publishing and reading do not expose mutable record/vector containers."
  (let (
        (data (copy-tree '(("context_length" . 10) ("supported_parameters" . ["tools"])) t)))
    (kargu-test-set-model-metadata "shared" data "a")
    (setcdr (assoc "context_length" data) 99)
    (let* ((record (kargu-model-get-metadata "shared" "a"))
           (snapshot (kargu-bridge-models-snapshot (kargu-application-context))))
      (setcdr (assoc "context_length" record) 88)
      (aset (kargu-aget record "supported_parameters") 0 "temperature")
      (should (= (kargu-model-context-window "shared" "a") 10))
      (should (equal (kargu-model-request-parameters "shared" "a") '("tools")))
      (kargu-test-set-model-prop "shared" "context-window" 77 :provider "a")
      (should (= (plist-get (plist-get (kargu-model-projection-connection snapshot "a" "shared") :fields)
                            :context-window) 10)))))

(ert-deftest kargu-model-store-request-policy-never-borrows-aliases-test ()
  "Request fields remain exact even when display helpers accept a unique alias."
  (progn
    (kargu-test-set-model-metadata "vendor/shared"
                              '(("supported_parameters" . ["max_tokens"])) "a")
    (should (kargu-model-get-metadata "shared" "a"))
    (should-not (kargu-model-request-parameters "shared" "a"))
    (should (equal (kargu-model-request-parameters "vendor/shared" "a") '("max_tokens")))
    (should-not (kargu-model-request-parameters "vendor/shared" "b"))))

(ert-deftest kargu-model-store-refusals-use-unambiguous-owner-tuples-test ()
  "Tool refusals cannot collide across providers, case-sensitive IDs or slashes."
  (progn
    (kargu-test-mark-tools-refused "b/c" "A")
    (should-not (kargu-model-supports-tools-p "b/c" "a"))
    (should (kargu-model-supports-tools-p "c" "a/b"))
    (should (kargu-model-supports-tools-p "B/c" "a"))
    (kargu-test-forget-tools-refusals)
    (should (kargu-model-supports-tools-p "b/c" "a"))))

(ert-deftest kargu-model-store-late-catalog-responses-keep-owners-test ()
  "Two catalog responses in either order cannot publish into the active owner."
  (dolist (order '(("openrouter" "cerebras") ("cerebras" "openrouter")))
    (let (
          (kargu--catalog-generations (make-hash-table :test #'equal))
          (kargu--live-models-cache (make-hash-table :test #'equal))
          (kargu-session--context
           (kargu-test-session-with-history :provider "openrouter")) pending)
      (cl-letf (((symbol-function 'kargu--resolve-direct-api-key) (lambda (&rest _) "fake-key"))
                ((symbol-function 'kargu-transport-request)
                 (lambda (_method url &rest options)
                   (push (cons (if (string-search "openrouter" url) "openrouter" "cerebras")
                               (plist-get options :then)) pending))))
        (kargu-test-await-catalog-start #'kargu-api-list-models #'ignore "openrouter")
        (kargu-test-await-catalog-start #'kargu-api-list-models #'ignore "cerebras")
        (setf (kargu-selection-provider) "cerebras")
        (dolist (provider order)
          (funcall (cdr (assoc provider pending))
                   (format "{\"models\":[{\"id\":\"shared\",\"context_length\":%d}]}"
                           (if (equal provider "openrouter") 32000 128000)))
	  (kargu-test-drain-model-publishers))
        (should (= (kargu-model-context-window "shared" "openrouter") 32000))
        (should (= (kargu-model-context-window "shared" "cerebras") 128000))))))

(ert-deftest kargu-model-store-inspector-edit-keeps-captured-provider-test ()
  "Editing an old inspector after switching provider changes only its owner."
  (let (
        (kargu-session--context
         (kargu-test-session-with-history :provider "a" :model "shared"))  view)
    (unwind-protect
        (progn
          (kargu-test-set-model-metadata "shared" '(("context_length" . 10)) "a")
          (kargu-test-set-model-metadata "shared" '(("context_length" . 20)) "b")
          (cl-letf (((symbol-function 'kargu--prefetch-models-once) #'ignore))
            (kargu-model-info "shared" "a"))
          (setq view (get-buffer "*kargu model: a / shared*"))
          (should (buffer-live-p view))
          (setf (kargu-selection-provider) "b")
          (with-current-buffer view
            (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "context-window"))
                      ((symbol-function 'read-string) (lambda (&rest _) "777")))
              (call-interactively #'kargu-model-edit-prop)))
          (kargu-test-drain-model-publishers)
          (should (= (kargu-model-context-window "shared" "a") 777))
          (should (= (kargu-model-context-window "shared" "b") 20)))
      (when (buffer-live-p view) (kill-buffer view)))))

(ert-deftest kargu-model-store-removed-catalog-data-keeps-only-overrides-test ()
  "Pruning one provider preserves only overrides for removed models."
  (progn
    (kargu-test-set-model-metadata "removed" '(("context_length" . 10) ("description" . "obsolete")) "a")
    (kargu-test-set-model-metadata "kept" '(("context_length" . 20)) "a")
    (kargu-test-set-model-metadata "removed" '(("context_length" . 30)) "b")
    (kargu-test-set-model-prop "removed" "context-window" 99 :provider "a")
    (let ((snapshot (kargu-bridge-models-snapshot (kargu-application-context))))
      (kargu-test-cache-model-catalog "a" '((("id" . "kept") ("context_length" . 20))))
      (should (= (kargu-model-context-window "removed" "a") 99))
      (should-not (kargu-model-get-prop "removed" "description" "a"))
      (should (= (kargu-model-context-window "removed" "b") 30))
      (should (= (kargu-model-context-window "kept" "a") 20))
      (should (equal (kargu-aget (plist-get (kargu-model-projection-connection snapshot "a" "removed") :metadata)
                                 "description") "obsolete")))))

(ert-deftest kargu-model-store-successful-empty-catalog-clears-raw-data-test ()
  "Only successful complete catalogs prune metadata, preserving local overrides."
  (let (
        (kargu--live-models-cache (make-hash-table :test #'equal))
        (kargu--catalog-generations (make-hash-table :test #'equal)) then)
    (cl-letf (((symbol-function 'kargu-transport-request)
               (lambda (_method _url &rest options) (setq then (plist-get options :then)))))
      (kargu-test-await-catalog-start #'kargu-api-list-models #'ignore "opencode")
      (funcall then "{\"models\":[{\"id\":\"gone\",\"context_length\":10},{\"id\":\"kept\",\"context_length\":20}]}")
      (kargu-test-drain-model-publishers)
      (kargu-test-set-model-prop "gone" "context-window" 99 :provider "opencode")
      (kargu-test-await-catalog-start #'kargu-api-list-models #'ignore "opencode")
      (funcall then "{\"models\":[{\"id\":\"kept\",\"context_length\":30}]}")
      (kargu-test-drain-model-publishers)
      (should (equal (gethash "opencode" kargu--live-models-cache) '("kept")))
      (should (= (kargu-model-context-window "kept" "opencode") 30))
      (should (= (kargu-model-context-window "gone" "opencode") 99))
      (kargu-test-await-catalog-start #'kargu-api-list-models #'ignore "opencode")
      (funcall then "{\"models\":[]}")
      (kargu-test-drain-model-publishers)
      (should-not (kargu-model-get-metadata "kept" "opencode"))
      (should (= (kargu-model-context-window "gone" "opencode") 99)))))

(ert-deftest kargu-model-store-id-only-refresh-clears-old-capabilities-test ()
  "A fresh ID-only record cannot retain stale capabilities from an old response."
  (let (
        (kargu--live-models-cache (make-hash-table :test #'equal)) then)
    (kargu-test-set-model-metadata "plain" '(("context_length" . 10)) "opencode")
    (cl-letf (((symbol-function 'kargu-transport-request)
               (lambda (_method _url &rest options) (setq then (plist-get options :then)))))
      (kargu-test-await-catalog-start #'kargu-api-list-models #'ignore "opencode")
      (funcall then "{\"models\":[{\"id\":\"plain\"}]}")
      (kargu-test-drain-model-publishers))
    (should-not (kargu-model-context-window "plain" "opencode"))
    (should (equal (gethash "opencode" kargu--live-models-cache) '("plain")))))

(ert-deftest kargu-model-store-old-response-cannot-resurrect-cleared-catalog-test ()
  "A delayed nonempty reply cannot undo a newer empty catalog in storage or UI."
  (let (
        (kargu--live-models-cache (make-hash-table :test #'equal))
        (kargu--catalog-generations (make-hash-table :test #'equal)) pending old-result)
    (cl-letf (((symbol-function 'kargu-transport-request)
               (lambda (_method _url &rest options) (push (plist-get options :then) pending))))
      (kargu-test-await-catalog-start #'kargu-api-fetch-model-ids "opencode" (lambda (ids) (setq old-result ids)))
      (kargu-test-await-catalog-start #'kargu-api-list-models #'ignore "opencode")
      (funcall (car pending) "{\"models\":[]}")
      (kargu-test-drain-model-publishers)
      (funcall (cadr pending) "{\"models\":[{\"id\":\"old\",\"context_length\":10}]}")
      (kargu-test-drain-model-publishers))
    (should (equal old-result '("old")))
    (should-not (kargu-model-get-metadata "old" "opencode"))
    (should-not (kargu-chat--collect-model-candidates "opencode" old-result '("fallback")))))

(ert-deftest kargu-model-store-malformed-refresh-retains-last-good-catalog-test ()
  "Errors and malformed replies never act as successful empty catalogs."
  (let (
        (kargu--live-models-cache (make-hash-table :test #'equal)) then result)
    (kargu-test-set-model-metadata "kept" '(("context_length" . 10)) "opencode")
    (puthash "opencode" '("kept") kargu--live-models-cache)
    (dolist (body '("{\"error\":{\"message\":\"provider refused\"}}" "{\"models\":42}" "not-json"))
      (cl-letf (((symbol-function 'kargu-transport-request)
                 (lambda (_method _url &rest options) (setq then (plist-get options :then)))))
        (kargu-test-await-catalog-start #'kargu-api-list-models (lambda (reply) (setq result reply)) "opencode")
        (funcall then body)
	(kargu-test-drain-model-publishers))
      (should (kargu-aget result "error"))
      (should (= (kargu-model-context-window "kept" "opencode") 10))
      (should (equal (gethash "opencode" kargu--live-models-cache) '("kept"))))))

(ert-deftest kargu-model-store-selection-respects-authoritative-catalog-test ()
  "Candidate lists never append the active model or merge stale fallbacks."
  (let ((kargu--live-models-cache (make-hash-table :test #'equal))
        (kargu-session--context
         (kargu-test-session-with-history :model "stale")))
    (puthash "a" '("current") kargu--live-models-cache)
    (should (equal (kargu-chat--collect-model-candidates "a" '("late") '("fallback")) '("current")))
    (puthash "a" nil kargu--live-models-cache)
    (should-not (kargu-chat--collect-model-candidates "a" '("late") '("fallback")))
    (should (kargu-chat--models-known-p "a" nil))
    (remhash "a" kargu--live-models-cache)
    (should-not (kargu-chat--models-known-p "a" nil))
    (should (equal (kargu-chat--collect-model-candidates "a" '("live") '("fallback")) '("live")))
    (should (equal (kargu-chat--collect-model-candidates "a" nil '("fallback")) '("fallback")))
    (should-not (kargu-chat--collect-model-candidates "a" nil nil))))

(ert-deftest kargu-model-store-network-error-retains-last-good-catalog-test ()
  "A transport error does not clear metadata or the previous candidate list."
  (let (
        (kargu--live-models-cache (make-hash-table :test #'equal)) result)
    (kargu-test-set-model-metadata "kept" '(("context_length" . 10)) "opencode")
    (puthash "opencode" '("kept") kargu--live-models-cache)
    (cl-letf (((symbol-function 'kargu-transport-request)
               (lambda (_method _url &rest options)
                 (funcall (plist-get options :else) 'network-offline))))
      (kargu-test-await-catalog-start #'kargu-api-list-models (lambda (reply) (setq result reply)) "opencode"))
    (should (kargu-aget result "error"))
    (should (= (kargu-model-context-window "kept" "opencode") 10))
    (should (equal (gethash "opencode" kargu--live-models-cache) '("kept")))))

(ert-deftest kargu-model-store-empty-selector-does-not-refetch-or-offer-stale-id-test ()
  "A known empty catalog refuses selection without a fetch or synthetic choice."
  (let ((kargu--live-models-cache (make-hash-table :test #'equal)) fetched opened)
    (puthash "a" nil kargu--live-models-cache)
    (cl-letf (((symbol-function 'kargu-api-select--guard) #'ignore)
              ((symbol-function 'kargu-api-fetch-model-ids) (lambda (&rest _) (setq fetched t)))
              ((symbol-function 'kargu-api-select) (lambda (&rest _) (setq opened t))))
      (should-error (kargu-chat-select-model-company nil nil "a") :type 'user-error))
    (should-not fetched)
    (should-not opened)))

(provide 'tests/test-model-store)
;;; test-model-store.el ends here
