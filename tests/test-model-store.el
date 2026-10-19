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
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal))
        (kargu--tools-refused (make-hash-table :test #'equal)))
    (kargu-model-set-metadata "shared"
                              '(("context_length" . 32000) ("supports_tools" . :json-false)
                                ("supports_reasoning" . :json-false)
                                ("pricing" . (("prompt" . "0.000001")))) "openrouter")
    (kargu-model-set-metadata "shared"
                              '(("context_length" . 128000) ("supports_tools" . t)
                                ("reasoning" . (("supported_efforts" . ["low" "high"])))
                                ("pricing" . (("prompt" . "0.000002")))) "cerebras")
    (should (= (kargu-model-context-window "shared" "OPENROUTER") 32000))
    (should (= (kargu-model-context-window "shared" "cerebras") 128000))
    (should-not (kargu-model-supports-tools-p "shared" "openrouter"))
    (should (kargu-model-supports-tools-p "shared" "cerebras"))
    (should-not (kargu-model-reasoning-efforts "shared" "openrouter"))
    (should (equal (kargu-model-reasoning-efforts "shared" "cerebras") '("low" "high")))
    (should (= (plist-get (kargu-model-read "shared" "openrouter") :input-cost) 0.000001))
    (should (string-search "128k ctx" (kargu-model-annotation-string "shared" "cerebras")))
    (should (= (plist-get (kargu-model-info-facts "shared" "openrouter") :threshold) 78400))
    (should-not (kargu-model-get-metadata "shared" "unrelated"))))

(ert-deftest kargu-model-store-aliases-are-unique-and-local-test ()
  "Only a unique basename in the requested provider can resolve as an alias."
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal)))
    (kargu-model-set-metadata "vendor/shared" '(("context_length" . 10)) "a")
    (kargu-model-set-metadata "other/shared" '(("context_length" . 20)) "b")
    (should (= (kargu-model-context-window "shared" "a") 10))
    (should (= (kargu-model-context-window "shared" "b") 20))
    (should-not (kargu-model-get-metadata "missing/shared" "a"))
    (kargu-model-set-metadata "second/shared" '(("context_length" . 30)) "a")
    (should-not (kargu-model-get-metadata "shared" "a"))
    (should-error (kargu-model-set-prop "shared" "context-window" 99 :provider "a")
                  :type 'user-error)
    (should (= (kargu-model-context-window "vendor/shared" "a") 10))
    (kargu-model-set-metadata "shared" '(("context_length" . 40)) "a")
    (should (= (kargu-model-context-window "shared" "a") 40))))

(ert-deftest kargu-model-store-preserves-opaque-id-case-test ()
  "Providers normalize case but opaque model IDs and identity tuples do not."
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal))
        (id (copy-sequence "Model")))
    (kargu-model-set-metadata id '(("context_length" . 10)) "PROVIDER")
    (aset id 0 ?x)
    (kargu-model-set-metadata "model" '(("context_length" . 20)) "provider")
    (should (= (kargu-model-context-window "Model" "provider") 10))
    (should (= (kargu-model-context-window "model" "PROVIDER") 20))
    (should-not (kargu-model-get-metadata "xodel" "provider"))
    (kargu-model-set-metadata "b/c" '(("context_length" . 30)) "a")
    (kargu-model-set-metadata "c" '(("context_length" . 40)) "a/b")
    (should (= (kargu-model-context-window "b/c" "a") 30))
    (should (= (kargu-model-context-window "c" "a/b") 40))))

(ert-deftest kargu-model-store-overrides-survive-refresh-without-sharing-test ()
  "Explicit overrides survive refreshes only for the exact owning identity."
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal)))
    (kargu-model-set-metadata "shared" '(("context_length" . 10) ("description" . "old")) "a")
    (kargu-model-set-metadata "shared" '(("context_length" . 20)) "b")
    (kargu-model-set-prop "shared" "context-window" 99 :provider "a")
    (kargu-model-set-prop "shared" "supports-tools" nil :provider "a")
    (kargu-model-set-metadata "shared" '(("context_length" . 30) ("description" . "new")
                                        ("supports_tools" . t)) "a")
    (should (= (kargu-model-context-window "shared" "a") 99))
    (should (= (kargu-model-get-prop "shared" :context-window "a") 99))
    (should-not (kargu-model-supports-tools-p "shared" "a"))
    (should (equal (kargu-model-get-prop "shared" "description" "a") "new"))
    (should (= (kargu-model-context-window "shared" "b") 20))
    (should (kargu-model-supports-tools-p "shared" "b"))))

(ert-deftest kargu-model-store-plist-overrides-and-empty-records-test ()
  "Legacy plist metadata and empty wire objects support scoped overrides."
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal)))
    (kargu-model-set-metadata "legacy" '(:context-window 100 :supports-reasoning t) "a")
    (kargu-model-set-prop "legacy" :context-window 200 :provider "a")
    (kargu-model-set-prop "legacy" :supports-reasoning nil :provider "a")
    (should (= (kargu-model-context-window "legacy" "a") 200))
    (should-not (kargu-model-supports-reasoning-p "legacy" "a"))
    (kargu-model-set-metadata "empty" (make-hash-table :test #'equal) "a")
    (kargu-model-set-prop "empty" "max-output" 1024 :provider "a")
    (should (= (plist-get (kargu-model-read "empty" "a") :max-output) 1024))))

(ert-deftest kargu-model-store-overrides-use-canonical-alias-record-test ()
  "Editing a unique alias updates its canonical entry rather than a second copy."
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal)))
    (kargu-model-set-metadata "vendor/shared" '(("context_length" . 10)) "a")
    (kargu-model-set-prop "shared" "context-window" 50 :provider "a")
    (kargu-model-set-metadata "vendor/shared" '(("context_length" . 30)) "a")
    (should (= (kargu-model-context-window "vendor/shared" "a") 50))
    (should (= (hash-table-count kargu--model-metadata-table) 1))
    (should-error (kargu-model-set-prop "vendor/shared" "provider" "b" :provider "a")
                  :type 'user-error)))

(ert-deftest kargu-model-store-container-copies-and-snapshots-test ()
  "Publishing and reading do not expose mutable record/vector containers."
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal))
        (data (copy-tree '(("context_length" . 10) ("supported_parameters" . ["tools"])) t)))
    (kargu-model-set-metadata "shared" data "a")
    (setcdr (assoc "context_length" data) 99)
    (let* ((record (kargu-model-get-metadata "shared" "a"))
           (snapshot (copy-hash-table kargu--model-metadata-table)))
      (setcdr (assoc "context_length" record) 88)
      (aset (kargu-aget record "supported_parameters") 0 "temperature")
      (should (= (kargu-model-context-window "shared" "a") 10))
      (should (equal (kargu-model-request-parameters "shared" "a") '("tools")))
      (kargu-model-set-prop "shared" "context-window" 77 :provider "a")
      (let ((kargu--model-metadata-table snapshot))
        (should (= (kargu-model-context-window "shared" "a") 10))))))

(ert-deftest kargu-model-store-request-policy-never-borrows-aliases-test ()
  "Request fields remain exact even when display helpers accept a unique alias."
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal)))
    (kargu-model-set-metadata "vendor/shared"
                              '(("supported_parameters" . ["max_tokens"])) "a")
    (should (kargu-model-get-metadata "shared" "a"))
    (should-not (kargu-model-request-parameters "shared" "a"))
    (should (equal (kargu-model-request-parameters "vendor/shared" "a") '("max_tokens")))
    (should-not (kargu-model-request-parameters "vendor/shared" "b"))))

(ert-deftest kargu-model-store-refusals-use-unambiguous-owner-tuples-test ()
  "Tool refusals cannot collide across providers, case-sensitive IDs or slashes."
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal))
        (kargu--tools-refused (make-hash-table :test #'equal)))
    (kargu-model-mark-tools-refused "b/c" "A")
    (should-not (kargu-model-supports-tools-p "b/c" "a"))
    (should (kargu-model-supports-tools-p "c" "a/b"))
    (should (kargu-model-supports-tools-p "B/c" "a"))
    (kargu-model-forget-tools-refusals)
    (should (kargu-model-supports-tools-p "b/c" "a"))))

(ert-deftest kargu-model-store-late-catalog-responses-keep-owners-test ()
  "Two catalog responses in either order cannot publish into the active owner."
  (dolist (order '(("openrouter" "cerebras") ("cerebras" "openrouter")))
    (let ((kargu--model-metadata-table (make-hash-table :test #'equal))
          (kargu--catalog-generations (make-hash-table :test #'equal))
          (kargu--live-models-cache (make-hash-table :test #'equal))
          (kargu--session-provider "openrouter") pending)
      (cl-letf (((symbol-function 'kargu--resolve-api-key) (lambda (&rest _) "fake-key"))
                ((symbol-function 'plz)
                 (lambda (_method url &rest options)
                   (push (cons (if (string-search "openrouter" url) "openrouter" "cerebras")
                               (plist-get options :then)) pending))))
        (kargu-api-list-models #'ignore "openrouter")
        (kargu-api-list-models #'ignore "cerebras")
        (setq kargu--session-provider "cerebras")
        (dolist (provider order)
          (funcall (cdr (assoc provider pending))
                   (format "{\"data\":[{\"id\":\"shared\",\"context_length\":%d}]}"
                           (if (equal provider "openrouter") 32000 128000))))
        (should (= (kargu-model-context-window "shared" "openrouter") 32000))
        (should (= (kargu-model-context-window "shared" "cerebras") 128000))))))

(ert-deftest kargu-model-store-inspector-edit-keeps-captured-provider-test ()
  "Editing an old inspector after switching provider changes only its owner."
  (let ((kargu--model-metadata-table (make-hash-table :test #'equal))
        (kargu--session-provider "a") (kargu--session-model "shared") view)
    (unwind-protect
        (progn
          (kargu-model-set-metadata "shared" '(("context_length" . 10)) "a")
          (kargu-model-set-metadata "shared" '(("context_length" . 20)) "b")
          (cl-letf (((symbol-function 'kargu--prefetch-models-once) #'ignore))
            (kargu-model-info "shared" "a"))
          (setq view (get-buffer "*kargu model: a / shared*"))
          (should (buffer-live-p view))
          (setq kargu--session-provider "b")
          (with-current-buffer view
            (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "context-window"))
                      ((symbol-function 'read-string) (lambda (&rest _) "777")))
              (call-interactively #'kargu-model-edit-prop)))
          (should (= (kargu-model-context-window "shared" "a") 777))
          (should (= (kargu-model-context-window "shared" "b") 20)))
      (when (buffer-live-p view) (kill-buffer view)))))

(provide 'tests/test-model-store)
;;; test-model-store.el ends here
