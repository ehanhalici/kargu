;;; tests/test-dape-commands.el --- Tests for complete Dape commands suite -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'kargu/tools/dape)
(require 'kargu/loop/tools)
(require 'kargu/languages)

(ert-deftest kargu-dape-tools-registered-all-twenty-test ()
  "Ensure all 20 Dape interactive commands are registered as first-class tools."
  (let ((expected-tools '("debug_start"
                          "debug_get_context"
                          "debug_eval"
                          "debug_list_breakpoints"
                          "debug_set_breakpoint"
                          "debug_clear_breakpoint"
                          "debug_toggle_breakpoint"
                          "debug_step_over"
                          "debug_step_in"
                          "debug_step_out"
                          "debug_continue"
                          "debug_pause"
                          "debug_up"
                          "debug_down"
                          "debug_threads"
                          "debug_stack"
                          "debug_modules"
                          "debug_sources"
                          "debug_scope"
                          "debug_watch"
                          "debug_restart"
                          "debug_kill"
                          "debug_disconnect"
                          "debug_quit")))
    (dolist (tool expected-tools)
      (should (gethash tool kargu--tool-registry)))))

(ert-deftest kargu-dape-aliases-mapped-test ()
  "Ensure the 20 Dape command names resolve via kargu-register-tool-alias."
  (let ((expected-aliases '(("debug" . "debug_start")
                            ("next" . "debug_step_over")
                            ("continue" . "debug_continue")
                            ("pause" . "debug_pause")
                            ("step" . "debug_step_in")
                            ("out" . "debug_step_out")
                            ("up" . "debug_up")
                            ("down" . "debug_down")
                            ("threads" . "debug_threads")
                            ("stack" . "debug_stack")
                            ("modules" . "debug_modules")
                            ("sources" . "debug_sources")
                            ("breakpoints" . "debug_list_breakpoints")
                            ("scope" . "debug_scope")
                            ("watch" . "debug_watch")
                            ("eval" . "debug_eval")
                            ("restart" . "debug_restart")
                            ("kill" . "debug_kill")
                            ("disconnect" . "debug_disconnect")
                            ("quit" . "debug_quit"))))
    (dolist (pair expected-aliases)
      (let ((alias-name (car pair))
            (target-name (cdr pair)))
        (should (gethash alias-name kargu--tool-registry))
        (should (equal (kargu--aget (gethash alias-name kargu--tool-registry) "description")
                       (kargu--aget (gethash target-name kargu--tool-registry) "description")))))))

(ert-deftest kargu-dape-validate-breakpoint-args-empty-test ()
  "Ensure empty args to debug_set_breakpoint return clear parameter guidance."
  (let ((err (kargu-dape--validate-bp-args nil "debug_set_breakpoint")))
    (should (stringp err))
    (should (string-match-p "requires 'file_path'" err))
    (should (string-match-p "'line'" err))
    (should (string-match-p "Example:" err))))

(ert-deftest kargu-dape-validate-breakpoint-args-missing-line-test ()
  "Ensure missing line returns descriptive error with path context."
  (let ((err (kargu-dape--validate-bp-args '(("file_path" . "src/main.rs")) "debug_set_breakpoint")))
    (should (stringp err))
    (should (string-match-p "requires 1-based positive integer 'line'" err))
    (should (string-match-p "src/main.rs" err))))

(ert-deftest kargu-dape-eval-expression-validation-test ()
  "Ensure debug_eval rejects empty expression."
  (let ((spec (gethash "debug_eval" kargu--tool-registry)))
    (should spec)
    (let ((res (funcall (kargu--aget spec "executor") '(("expression" . "")))))
      (should (equal res "ERROR: expression is required")))))

(ert-deftest kargu-dape-eval-rust-pitfall-advice-on-no-session-test ()
  "Ensure debug_eval appends active language advice for Rust method calls."
  (let ((res (cl-letf (((symbol-function 'kargu-language-active)
                        (lambda (&optional _dir) (kargu-language-get 'rust))))
               (kargu-dape-eval-expression "frame.landmarks_2d.len()"))))
    (should (stringp res))
    (should (string-match-p "Rust LLDB" res))
    (should (string-match-p "debug_scope" res))))

(ert-deftest kargu-dape-tools-never-cached-test ()
  "Ensure all Dape tools and aliases return nil for kargu-loop--tool-cacheable-p."
  (let ((non-cacheable-tools '("debug_start"
                               "debug_get_context"
                               "debug_eval"
                               "debug_step_over"
                               "debug_step_in"
                               "debug_step_out"
                               "debug_continue"
                               "debug_pause"
                               "debug_up"
                               "debug_down"
                               "debug_scope"
                               "debug_watch"
                               "debug_restart"
                               "debug_kill"
                               "debug_disconnect"
                               "debug_quit"
                               "debug" "next" "step" "out" "continue"
                               "pause" "up" "down" "threads" "stack"
                               "modules" "sources" "breakpoints" "scope"
                               "watch" "eval" "restart" "kill" "disconnect" "quit")))
    (dolist (tool non-cacheable-tools)
      (should-not (kargu-loop--tool-cacheable-p tool)))))

(provide 'tests/test-dape-commands)

;;; tests/test-dape-commands.el ends here
