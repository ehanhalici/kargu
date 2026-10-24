;;; test-cache.el --- Cache and bounded-context regressions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Payload markers must survive wire adaptation without changing history.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'kargu)
(require 'tests/test-helpers)

;; Pure marker and native wire cases moved to kargu-core/tests/api_wire.rs:
;; stable_cache_prefix_is_pure_and_runtime_is_not_marked,
;; native_cache_boundaries_survive_tools_and_completed_tool_results.
;; The real editor/core loopback path is covered by tests/test-stream.el.

(ert-deftest kargu-cache-tools-are-canonical-and-deterministic-test ()
  "Aliases remain executable without duplicate schemas or guidance."
  (let ((kargu--tool-registry (kargu-tool-registry-create)))
    (kargu-test-mode 'agent)
    (kargu-register-tool "z" "Last" nil (lambda (_) "z"))
    (kargu-register-tool "a" "First" nil (lambda (_) "a"))
    (kargu-register-tool-alias "alias" "a")
    (let ((tools (kargu--build-tools-vector)))
      (should (equal (kargu-advertised-tools) '("a" "z")))
      (should (= (length tools) 2))
      (kargu-register-tool "z" "Last" nil (lambda (_) "z"))
      (should (equal tools (kargu--build-tools-vector)))
      (should (equal (kargu-execute-tool "alias" nil) "a"))
      (kargu-register-tool "a" "Updated" nil (lambda (_) "a2"))
      (should (equal (kargu-execute-tool "alias" nil) "a2"))
      (should (equal (kargu-tool-description "alias") "Updated"))
      (kargu-set-tool-policy "a" '(:modes (plan)))
      (should-not (kargu-tool-visible-p "alias"))
      (should (string-prefix-p "ERROR:" (kargu-execute-tool "alias" nil))))))

(ert-deftest kargu-cache-tool-schema-evaluates-availability-once-test ()
  "One schema build evaluates each canonical tool's availability once."
  (let ((kargu--tool-registry (kargu-tool-registry-create)) (calls 0))
    (kargu-register-tool "probe" "Probe" nil #'ignore
                         (list :available-p (lambda () (cl-incf calls) nil)))
    (kargu-register-tool-alias "alias" "probe")
    (should (= (length (kargu--build-tools-vector)) 1))
    (should (= calls 1))))

(ert-deftest kargu-cache-tool-refusal-is-not-recomputed-test ()
  "The refusal returned by availability is delivered without a second call."
  (let ((kargu--tool-registry (kargu-tool-registry-create)) (calls 0) results)
    (kargu-register-tool
     "probe" "Probe" nil (lambda (_) (ert-fail "Denied tool was executed"))
     (list :available-p (lambda () (when (= (cl-incf calls) 1) "ERROR: denied"))))
    (kargu-execute-tool "probe" nil (lambda (text) (push text results)))
    (should (equal results '("ERROR: denied")))
    (should (= calls 1))))

(ert-deftest kargu-cache-tool-visibility-override-cannot-bypass-policy-test ()
  "An explicit advertisement predicate does not override availability."
  (let ((kargu--tool-registry (kargu-tool-registry-create))
        (kargu--tools-visible-p (lambda (_) t)) (calls 0))
    (kargu-register-tool
     "probe" "Probe" nil #'ignore
     (list :available-p (lambda () (cl-incf calls) "ERROR: unavailable")))
    (should-not (kargu-tool-visible-p "probe"))
    (should (= calls 1))))

(ert-deftest kargu-cache-tool-execution-decodes-arguments-once-test ()
  "Tool ingress decodes once and gives the executor the same object."
  (let ((kargu--tool-registry (kargu-tool-registry-create))
        (decode (symbol-function 'kargu--json-decode-lenient)) (calls 0))
    (kargu-register-tool "probe" "Probe" nil
                         (lambda (args) (kargu-aget args "value")))
    (cl-letf (((symbol-function 'kargu--json-decode-lenient)
               (lambda (wire) (cl-incf calls) (funcall decode wire))))
      (should (equal (kargu-execute-tool "probe" "{\"value\":\"Türkçe 🙂\"}")
                     "Türkçe 🙂")))
    (should (= calls 1))))

(ert-deftest kargu-cache-tool-execution-rejects-nonobjects-test ()
  "Decoded native scalars and arrays are refused just like JSON text."
  (let ((kargu--tool-registry (kargu-tool-registry-create)))
    (kargu-register-tool "probe" "Probe" nil
                         (lambda (_) (ert-fail "Malformed arguments reached executor")))
    (dolist (args '(7 t [] :json-false ("not-an-object")
                     "[]" "false" "null" "\"text\"" "{not-json"))
      (let (results)
        (kargu-execute-tool "probe" args (lambda (text) (push text results)))
        (should (= (length results) 1))
        (should (string-prefix-p "ERROR: the arguments of tool probe"
                                 (car results)))))))

(ert-deftest kargu-cache-usage-preserves-unknown-and-counts-native-input-test ()
  "Cache metrics use only provider measurements and include native cached input."
  (let* ((kargu-session--context
          (kargu-session-create :id-value (kargu-session-id)
                                :usage-value (list :requests 0)))
         ;; Core has already normalized native input/cache counters; the
         ;; original wire response is covered by api_wire.rs.
         (response '(("choices" . [(("message" . (("content" . "Done"))))])
                     ("usage" . (("prompt_tokens" . 200) ("completion_tokens" . 1)
                                 ("prompt_tokens_details" . (("cached_tokens" . 80)
                                                             ("cache_write_tokens" . 20))))))))
    (should (string-search "cache-read: unknown" (kargu-session-usage)))
    (kargu--record-usage response)
    (should (= (plist-get (kargu-session-snapshot) :tokens-in) 200))
    (should (string-search "measured-hit: 40.0%" (kargu-session-usage)))
    (kargu--record-usage '(("usage" . (("prompt_tokens" . 50) ("completion_tokens" . 2)))))
    (should (= (plist-get (kargu-session-snapshot) :cache-measured-input) 200))
    (should (= (plist-get (kargu-session-snapshot) :cache-read) 80))))

(ert-deftest kargu-cache-unregistered-tool-and-alias-cannot-execute-test ()
  "Unregistration reaches the same gate used for direct and alias execution."
  (let ((kargu--tool-registry (kargu-tool-registry-create)) (calls 0))
    (kargu-register-tool "read" "Read" nil (lambda (_) (cl-incf calls) "Read"))
    (kargu-register-tool-alias "r" "read")
    (should (= (kargu-registered-tool-count) 2))
    (should (kargu-unregister-tool "read"))
    (should (zerop (kargu-registered-tool-count)))
    (dolist (name '("read" "r"))
      (should-not (kargu-find-tool name))
      (should (string-prefix-p "ERROR: no such tool:"
                               (kargu-execute-tool name nil))))
    (should (zerop calls))))

(ert-deftest kargu-cache-low-usage-preserves-model-and-full-output-test ()
  "Low usage bounds model context, retaining the full output locally."
  (let ((kargu-low-usage-mode t) (kargu-low-usage-output-limit 5)
        (kargu-tool-output-limit 100) (model (kargu--model))
        (kargu--truncated-counter 99900))
    (unwind-protect
        (let ((result (kargu--truncate-for-model "abcdefghij")))
          (should (string-prefix-p "abcde\n" result))
          (should (equal (with-current-buffer "*kargu-output-99901*" (buffer-string)) "abcdefghij"))
          (should (equal (kargu--model) model))
          (should (= (kargu-usage-limit 800 200) 200)))
      (when-let* ((buffer (get-buffer "*kargu-output-99901*"))) (kill-buffer buffer)))))

(ert-deftest kargu-cache-async-startup-text-is-not-a-result-test ()
  "An async startup message must not finish the tool before its callback."
  (let ((kargu--tool-registry (kargu-tool-registry-create)) held results)
    (kargu-register-tool "delayed" "Wait" nil
                         (lambda (_args callback) (setq held callback) "Started"))
    (kargu-execute-tool "delayed" nil (lambda (text) (push text results)))
    (should-not results)
    (funcall held "Done")
    (funcall held "Again")
    (should (equal results '("Done")))))

(ert-deftest kargu-cache-mutation-invalidates-read-results-test ()
  "Read/edit/read observes the edit; identical writes execute separately."
  (let* ((run (list :state 'tools)) (kargu--loop-run run)
         (content "old") (reads 0) (edits 0) results)
    (cl-letf (((symbol-function 'kargu-loop--gate-tool) (lambda (_) nil))
              ((symbol-function 'kargu--loop-after-tool)
               (lambda (_run _id _name result _queue) (push result results)))
              ((symbol-function 'kargu-execute-tool)
               (lambda (name _args callback)
                 (if (equal name "read_file")
                     (progn (cl-incf reads) (funcall callback content))
                   (cl-incf edits) (setq content "new") (funcall callback "Edited")))))
      (dolist (name '("read_file" "edit_file" "read_file" "edit_file"))
        (kargu--loop-run-call
         run (list (cons "id" name) (cons "function" (list (cons "name" name)))) nil))
      (should (= reads 2))
      (should (= edits 2))
      (should (equal (reverse results) '("old" "Edited" "new" "Edited"))))))

(ert-deftest kargu-cache-continuation-error-cannot-redeliver-tool-test ()
  "An exception in the next request stops the loop without replaying its tool."
  (let* ((run (list :state 'tools)) (kargu--loop-run run)
         (delivered 0) (finished 0))
    (cl-letf (((symbol-function 'kargu-loop--gate-tool) (lambda (_) nil))
              ((symbol-function 'kargu-execute-tool)
               (lambda (_name _args callback)
                 (funcall callback "Done") (funcall callback "Duplicate")))
              ((symbol-function 'kargu--loop-after-tool)
               (lambda (&rest _) (cl-incf delivered) (error "Next request failed")))
              ((symbol-function 'kargu--loop-finish)
               (lambda (_run status &optional _text)
                 (should (eq status :error)) (cl-incf finished) (setq kargu--loop-run nil))))
      (kargu--loop-execute-call run :id "c1" :name "read_file" :sig "sig")
      (should (= delivered 1))
      (should (= finished 1)))))

(provide 'tests/test-cache)
;;; test-cache.el ends here
