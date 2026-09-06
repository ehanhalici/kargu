;;; tests/test-integration.el --- Integration tests across modules -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'kargu/contract)
(require 'kargu/history)
(require 'kargu/api)
(require 'kargu/api/response)
(require 'kargu/loop)

(ert-deftest kargu-integration-history-protocol-pipeline-test ()
  "Test complete flow: prompt insertion, assistant tool response, tool execution, and firewall validation."
  ;; 1. Initialize clean history
  (setq kargu--message-history nil)
  (kargu-history-add "user" "Run a test command")
  (should (= (length kargu--message-history) 1))

  ;; 2. Simulate model responding with tool calls
  (let ((tool-response
         '(("choices" . ((("index" . 0)
                           ("message" . (("role" . "assistant")
                                         ("content" . "I will run the command.")
                                         ("tool_calls" . ((("id" . "call_integration_1")
                                                           ("type" . "function")
                                                           ("function" . (("name" . "bash")
                                                                          ("arguments" . "echo test"))))))))
                           ("finish_reason" . "tool_calls")))))))
    (kargu-api-store-assistant-turn tool-response)
    (should (= (length kargu--message-history) 2)))

  ;; 3. Simulate tool execution producing result
  (kargu-history-add-tool-result "call_integration_1" "bash" "test\n")
  (should (= (length kargu--message-history) 3))

  ;; 4. Simulate final model response
  (let ((final-response
         '(("choices" . ((("index" . 0)
                           ("message" . (("role" . "assistant")
                                         ("content" . "Command executed successfully.")))
                           ("finish_reason" . "stop")))))))
    (kargu-api-store-assistant-turn final-response)
    (should (= (length kargu--message-history) 4)))

  ;; 5. Run protocol firewall
  (kargu-history-validate)
  ;; Head must have system message, alternating user/assistant/tool/assistant
  (should (equal (alist-get "role" (car kargu--message-history) nil nil #'equal) "system"))
  (should (cl-every #'kargu-contract-message-p kargu--message-history)))

(provide 'tests/test-integration)
;;; test-integration.el ends here
