;;; tests/test-loop.el --- Tests for kargu/loop -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'kargu/loop)
(require 'kargu/loop/tools)
(require 'kargu/loop/machine)

(ert-deftest kargu-loop-doom-p-test ()
  "Ensure kargu--loop-doom-p detects 3 consecutive identical tool calls."
  (let ((run (list :doom-sigs nil))
        (sig "bash\0ls -la"))
    (should-not (kargu--loop-doom-p run sig))
    (should-not (kargu--loop-doom-p run sig))
    (should (kargu--loop-doom-p run sig))))

(ert-deftest kargu-loop-classify-response-test ()
  "Ensure kargu-loop--classify-response identifies tools, answers, and errors correctly."
  (let* ((run (list :state 'wait))
         (kargu--loop-run run)
        (tool-resp '(("choices" . ((("index" . 0)
                                    ("message" . (("role" . "assistant")
                                                  ("tool_calls" . ((("id" . "c1")
                                                                    ("function" . (("name" . "bash"))))))))
                                    ("finish_reason" . "tool_calls"))))))
        (ans-resp '(("choices" . ((("index" . 0)
                                   ("message" . (("role" . "assistant")
                                                 ("content" . "all done")))
                                   ("finish_reason" . "stop"))))))
        (err-resp '(("error" . (("message" . "rate limit exceeded"))))))
    (should (eq (kargu-loop--classify-response run tool-resp) 'tools))
    (should (eq (kargu-loop--classify-response run ans-resp) 'answer))
    (should (eq (kargu-loop--classify-response run err-resp) 'error))
    ;; Test length classification respecting run-specific :max-iterations
    (let ((len-resp '(("choices" . ((("index" . 0)
                                     ("message" . (("role" . "assistant")
                                                   ("content" . "partial")))
                                     ("finish_reason" . "length"))))))
          (continued-run (list :state 'wait
                               :iterations kargu-max-iterations
                               :max-iterations (+ kargu-max-iterations 5)
                               :length-continues 0)))
      (let ((kargu--loop-run continued-run))
        (should (eq (kargu-loop--classify-response continued-run len-resp) 'length))))))

(provide 'tests/test-loop)
;;; test-loop.el ends here
