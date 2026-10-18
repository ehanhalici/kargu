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

(ert-deftest kargu-cache-system-prefix-is-stable-and-pure-test ()
  "Volatile environment changes cannot alter the marked stable prefix."
  (let* ((first (list (list (cons "role" "system")
                            (cons "content" (concat "Instructions\n" kargu-cache-runtime-boundary "file: a")))
                      '(("role" . "user") ("content" . "Question"))))
         (snapshot (copy-tree first t))
         (marked (kargu-cache-prepare-messages first))
         (content (kargu-aget (car marked) "content")))
    (should (equal first snapshot))
    (should (kargu-aget (aref content 0) "cache_control"))
    (should-not (kargu-aget (aref content 1) "cache_control"))
    (should-not (kargu-aget (car marked) "cache_control"))
    (setcdr (assoc "content" (car first)) (concat "Instructions\n" kargu-cache-runtime-boundary "file: b"))
    (should (equal (aref content 0)
                   (aref (kargu-aget (car (kargu-cache-prepare-messages first)) "content") 0)))))

(ert-deftest kargu-cache-native-wire-keeps-block-and-tool-markers-test ()
  "Native Messages requests retain cache boundaries on tools, system and results."
  (let* ((messages '((("role" . "system") ("content" . "Stable instructions"))
                     (("role" . "user") ("content" . "Question"))
                     (("role" . "assistant") ("content" . "")
                      ("tool_calls" . [(("id" . "c1") ("function" . (("name" . "read_file") ("arguments" . "{}"))))]))
                     (("role" . "tool") ("tool_call_id" . "c1") ("content" . "Result"))))
         (tools [(("type" . "function") ("function" . (("name" . "read_file") ("parameters" . :json-empty-object))))])
         (body (kargu-api-prepare-payload
                (list (cons "model" "test")
                      (cons "messages" (vconcat (kargu-cache-prepare-messages messages)))
                      (cons "tools" (kargu-cache-prepare-tools tools))) 'anthropic))
         (result (car (kargu-aget (car (last (kargu-aget body "messages"))) "content"))))
    (should (kargu-aget (car (kargu-aget body "system")) "cache_control"))
    (should (kargu-aget (aref (kargu-aget body "tools") 0) "cache_control"))
    (should (kargu-aget (aref (kargu-aget result "content") 0) "cache_control"))
    (should (string-search "cache_control" (kargu--json-encode body)))
    (should-not (kargu-aget (aref tools 0) "cache_control"))))

(ert-deftest kargu-cache-tools-are-canonical-and-deterministic-test ()
  "Aliases remain executable without duplicate schemas or guidance."
  (let ((kargu--tool-registry (make-hash-table :test #'equal)))
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

(ert-deftest kargu-cache-usage-preserves-unknown-and-counts-native-input-test ()
  "Cache metrics use only provider measurements and include native cached input."
  (let* ((kargu--session (list :requests 0))
         (response (kargu-api-normalize-response
                    '(("type" . "message") ("stop_reason" . "end_turn")
                      ("content" . [(("type" . "text") ("text" . "Done"))])
                      ("usage" . (("input_tokens" . 100) ("output_tokens" . 1)
                                  ("cache_read_input_tokens" . 80) ("cache_creation_input_tokens" . 20)))))))
    (should (string-search "cache-read: unknown" (kargu-session-usage)))
    (kargu--record-usage response)
    (should (= (plist-get kargu--session :tokens-in) 200))
    (should (string-search "measured-hit: 40.0%" (kargu-session-usage)))
    (kargu--record-usage '(("usage" . (("prompt_tokens" . 50) ("completion_tokens" . 2)))))
    (should (= (plist-get kargu--session :cache-measured-input) 200))
    (should (= (plist-get kargu--session :cache-read) 80))))

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
  (let ((kargu--tool-registry (make-hash-table :test #'equal)) held results)
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
