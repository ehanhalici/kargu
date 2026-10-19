;;; test-dape-commands.el --- Debugger command tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exercise debugger tools with fake adapters and asynchronous replies.

;;; Code:

;; Ensure the package root is on `load-path` during byte/native compilation.
(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'ert)
(require 'cl-lib)
(require 'tests/test-helpers)
(require 'kargu/tools/dape)
(require 'kargu/loop/tools)
(require 'kargu/languages)

(defvar dape-active-mode-off-hook)

(ert-deftest kargu-dape-render-strips-terminal-control-sequences-test ()
  "Colors and terminal hyperlinks never enter variable or context text."
  (let* ((colored "\e[31mvalue\e[0m")
         (linked "\e]8;;https://example.invalid\avariable\e]8;;\a")
         (frame (list :id 1 :name colored
                      :source '(:path "main.el") :line 1)))
    (should (equal (kargu-dape--trunc colored) "value"))
    (should (equal (kargu-dape--plain-text linked) "variable"))
    (should (equal (kargu-dape--plain-text "\e]0;title\e\\text") "text"))
    (should (equal (kargu-dape--format-var-line
                    (list :name linked :value colored))
                   "  variable = value"))
    (cl-letf (((symbol-function 'dape--file-name-local) (lambda (_conn path) path)))
      (let ((text (kargu-dape--render-context nil nil (list frame) frame)))
        (should (string-search "value" text))
        (should-not (string-search "\e" text))))))

(ert-deftest kargu-dape-delayed-frame-range-error-delivers-once-test ()
  "An out-of-range selection after a delayed stack reply closes the task."
  (let* ((frame '(:id 1 :name "main"))
         (thread (list :id 1 :stackFrames (vector frame))) held results)
    (cl-letf (((symbol-function 'kargu-dape--connection) (lambda () 'conn))
              ((symbol-function 'dape--current-thread) (lambda (_) thread))
              ((symbol-function 'dape--current-stack-frame) (lambda (_) frame))
              ((symbol-function 'dape--stack-trace)
               (lambda (_conn _thread _limit callback) (setq held callback))))
      (kargu-dape-up 2 (lambda (text) (push text results)))
      (should-not results)
      (funcall held)
      (funcall held)
      (should (= (length results) 1))
      (should (string-search "outside the available stack" (car results))))))

(ert-deftest kargu-dape-policy-covers-all-tools-and-aliases-test ()
  "Every debugger executor and alias obeys the same mode and session policy."
  (dolist (mode '(ask plan))
    (kargu-test-mode mode)
    (dolist (name (append (mapcar #'car kargu-dape--tool-specs)
                          (mapcar #'car kargu-dape--tool-aliases)))
      (should-not (kargu-tool-visible-p name))
      (should (string-prefix-p "ERROR:" (kargu-execute-tool name nil)))))
  (kargu-test-mode 'debug)
  (cl-letf (((symbol-function 'kargu-dape--raw-connection) (lambda () 'conn))
            ((symbol-function 'dape--stopped-threads) (lambda (_) nil))
            ((symbol-function 'dape--capable-p) (lambda (_conn _cap) nil)))
    (should (kargu-tool-visible-p "debug_pause"))
    (should-not (kargu-tool-visible-p "debug_scope"))
    (should-not (kargu-tool-visible-p "scope"))
    (should-not (kargu-tool-visible-p "debug_restart"))
    (should-not (string-search "debug_scope" (kargu-dape-tool-guide)))))

(ert-deftest kargu-dape-running-is-not-inspectable-test ()
  "An active adapter is not ready for inspection until a thread stops."
  (let ((dape-active-mode t))
    (cl-letf (((symbol-function 'kargu-dape--raw-connection) (lambda () 'conn))
              ((symbol-function 'dape--stopped-threads) (lambda (_) nil)))
      (should-not (kargu-dape-ready-p)))))

(ert-deftest kargu-dape-owned-exit-completes-before-connection-reset-test ()
  "Only the captured adapter's exit can finish before connection removal."
  (let ((dape-stopped-hook nil) (dape-active-mode-off-hook nil)
        (kargu-dape-event-hook nil) results)
    (cl-letf (((symbol-function 'kargu-dape-project-connections) (lambda (&optional _) '(conn))))
      (kargu-dape--start-action 'conn #'ignore (lambda (text) (push text results))
                                :name "continue" :timeout 30)
      (run-hooks 'dape-active-mode-off-hook)
      (run-hook-with-args 'kargu-dape-event-hook 'foreign 'exited)
      (should-not results)
      (run-hook-with-args 'kargu-dape-event-hook 'conn 'exited)
      (run-hook-with-args 'kargu-dape-event-hook 'conn 'exited)
      (should (= (length results) 1))
      (should (string-search "PROGRAM EXITED" (car results)))
      (should-not dape-stopped-hook)
      (should-not dape-active-mode-off-hook)
      (should-not kargu-dape-event-hook))))

(ert-deftest kargu-dape-session-wait-cleans-up-once-test ()
  "Readiness and timeout both release launch hooks and timers exactly once."
  (dolist (outcome '(:ready :cancelled))
    (let ((dape-start-hook nil)
          (dape-stopped-hook nil)
          (ready 0) (cancelled 0) wait)
      (cl-letf (((symbol-function 'kargu-dape-ready-p) (lambda () nil)))
        (unwind-protect
            (progn
              (setq wait (kargu-dape--wait-for-session-ready
                          (lambda () (cl-incf ready))
                          (lambda (_) (cl-incf cancelled))))
              (run-hooks 'dape-start-hook)
              (let ((poll (kargu-dape--session-wait-timer wait))
                    (deferred (kargu-dape--session-wait-deferred wait)))
                (if (eq outcome :ready)
                    (run-hooks 'dape-stopped-hook)
                  (setf (kargu-dape--session-wait-started wait) 0)
                  (kargu-dape--poll-session-wait wait))
                (kargu-dape--poll-session-wait wait)
                (kargu-dape--finish-session-wait wait :ready)
                (should (= (+ ready cancelled) 1))
                (should (eq (kargu-dape--session-wait-state wait) outcome))
                (should-not dape-start-hook)
                (should-not dape-stopped-hook)
                (should-not (memq poll timer-list))
                (should-not (memq deferred timer-list))))
          (when wait
            (kargu-dape--finish-session-wait wait :cancelled "test cleanup")))))))

(ert-deftest kargu-dape-missing-dependencies-leave-mode-unchanged-test ()
  "Missing adapter executables reject debug without publishing a mode change."
  (kargu-test-mode 'ask)
  (let ((kargu-dape-config 'missing)
        (dape-configs '((missing command "kargu-nonexistent-adapter")))
        (kargu-dape--verified nil))
    (cl-letf (((symbol-function 'kargu-dape-live-p) (lambda () nil)))
      (kargu-set-mode 'debug)
      (should (eq (kargu-state-mode) 'ask))
      (should-error (kargu-state-set-mode 'debug) :type 'user-error))))

(ert-deftest kargu-dape-debug-waits-for-module-probe-test ()
  "A module adapter is checked asynchronously before debug mode is published."
  (kargu-test-mode 'ask)
  (let ((kargu-dape-config 'configured)
        (dape-configs '((configured command "python" command-args ("-m" "debugpy.adapter"))))
        (kargu-dape--verified nil) probe)
    (cl-letf (((symbol-function 'kargu-dape-live-p) (lambda () nil))
              ((symbol-function 'executable-find) (lambda (_) "/test/python"))
              ((symbol-function 'kargu-process-run)
               (lambda (_program _args callback &rest _opts) (setq probe callback) nil)))
      (kargu-set-mode 'debug)
      (should (eq (kargu-state-mode) 'ask))
      (funcall probe '(:code 0))
      (should (eq (kargu-state-mode) 'debug))
      (should (eq (kargu-dape-selected-config) 'configured)))))

(ert-deftest kargu-dape-failed-or-stale-probe-does-not-switch-mode-test ()
  "Probe failure and a newer user selection cannot switch into debug."
  (dolist (scenario '(failure stale running config-changed))
    (kargu-test-mode 'ask)
    (let ((kargu-dape-config 'configured)
          (dape-configs '((configured command "python" command-args ("-m" "debugpy.adapter"))))
          (kargu-dape--verified nil) probe)
      (cl-letf (((symbol-function 'kargu-dape-live-p) (lambda () nil))
                ((symbol-function 'executable-find) (lambda (_) "/test/python"))
                ((symbol-function 'kargu-process-run)
                 (lambda (_program _args callback &rest _opts) (setq probe callback) nil)))
        (kargu-set-mode 'debug)
        (when (eq scenario 'stale) (kargu-set-mode 'plan))
        (when (eq scenario 'running) (setq kargu--loop-run (list :state 'tools)))
        (when (eq scenario 'config-changed)
          (setq dape-configs '((configured command "python" command-args ("-m" "other.adapter")))))
        (funcall probe (list :code (if (eq scenario 'failure) 1 0)))
        (should (eq (kargu-state-mode) (if (eq scenario 'stale) 'plan 'ask)))
        (setq kargu--loop-run nil)))))

(ert-deftest kargu-dape-verification-cache-retains-project-identities-test ()
  "Checking a second project never discards the first project's verification."
  (let* ((root (kargu-permission-project-root))
         (other (file-name-as-directory (expand-file-name "other" root)))
         (kargu-dape--verified nil) (kargu-dape-config 'demo)
         (dape-configs '((demo port 1234))) (verified 0))
    (cl-letf (((symbol-function 'dape) #'ignore)
              ((symbol-function 'kargu-dape-live-p) (lambda () nil)))
      (dolist (project (list root other))
        (let ((kargu-permission--override-root project))
          (kargu-dape-prepare-debug (lambda () (cl-incf verified)))
          (should-not (kargu-dape-debug-refusal))))
      (should (= verified 2))
      (should (= (hash-table-count kargu-dape--verified) 2))
      (dolist (project (list root other root))
        (let ((kargu-permission--override-root project))
          (should (eq (kargu-dape-selected-config) 'demo))))
      (setq dape-configs '((demo port 4567)))
      (should (kargu-dape-debug-refusal)))))

(ert-deftest kargu-dape-start-uses-a-verified-plist-after-approval-test ()
  "Startup passes Dape its actual config plist, not an unsupported symbol."
  (kargu-test-with-git-repo '(("main.el" . "(message \"test\")\n"))
    (let ((kargu-dape-config 'demo)
          (dape-configs '((demo command "sh" :program "main")))
          (kargu-dape--verified nil)
          (kargu-permission--mock-decision :approve)
          (source (find-file-noselect (expand-file-name "main.el" repo))) seen result)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-dape-project-connections) (lambda (&optional _) nil))
                    ((symbol-function 'dape) (lambda (config &rest _) (setq seen config))))
            (setq kargu-context-buffer source)
            (kargu-dape-start "demo" (lambda (text) (setq result text)))
            (should (equal (plist-get seen 'command) "sh"))
            (should (eq (plist-get seen :stopOnEntry) t))
            (should (string-search "started" result)))
        (kill-buffer source)))))

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
  "Ensure Dape command names resolve via `kargu-register-tool-alias'."
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
        (should (equal (kargu-aget (gethash alias-name kargu--tool-registry) "description")
                       (kargu-aget (gethash target-name kargu--tool-registry) "description")))))))

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
    (let ((res (funcall (kargu-aget spec "executor") '(("expression" . "")))))
      (should (equal res "ERROR: expression is required")))))

(ert-deftest kargu-dape-delayed-errors-complete-once-test ()
  "Errors after returning from the starter cannot strand the tool result."
  (dolist (failure '(stack scopes variables))
    (let* ((frame (list :id 3 :name "main" :scopes '((:name "Locals"))))
           (thread (list :id 1 :stackFrames (vector frame)))
           held results)
      (cl-letf (((symbol-function 'kargu-dape--connection) (lambda () 'conn))
                ((symbol-function 'dape--current-thread) (lambda (_) thread))
                ((symbol-function 'dape--current-stack-frame) (lambda (_) frame))
                ((symbol-function 'dape--stack-trace)
                 (lambda (_conn _thread _n callback) (setq held callback)))
                ((symbol-function 'dape--scopes)
                 (lambda (_conn _frame callback)
                   (if (eq failure 'scopes) (error "Adapter disconnected")
                     (funcall callback))))
                ((symbol-function 'dape--variables)
                 (lambda (&rest _) (error "Adapter disconnected"))))
        (kargu-dape-get-context (lambda (text) (push text results)))
        (should-not results)
        (if (eq failure 'stack) (funcall held nil "Adapter disconnected")
          (funcall held))
        (funcall held)
        (should (= (length results) 1))
        (should (string-prefix-p "ERROR:" (car results)))
        (should (string-search "Adapter disconnected" (car results)))))))

(ert-deftest kargu-dape-cancel-cleans-chain-and-action-hooks-test ()
  "Cancellation releases inspection timers and execution hooks, ignoring late replies."
  (let ((kargu--loop-run (list :state 'tools))
        (dape-stopped-hook nil) (dape-active-mode-off-hook nil)
        (kargu-dape-event-hook nil)
        held results)
    (cl-letf (((symbol-function 'kargu-dape--connection) (lambda () 'conn))
              ((symbol-function 'kargu-dape-project-connections) (lambda (&optional _) '(conn)))
              ((symbol-function 'dape--current-stack-frame) (lambda (_) nil))
              ((symbol-function 'dape--current-thread) (lambda (_) '(:id 1)))
              ((symbol-function 'dape--stack-trace)
               (lambda (_conn _thread _n cb) (setq held cb))))
      (kargu-dape-get-context (lambda (text) (push text results)))
      (kargu-dape--start-action 'conn #'ignore (lambda (text) (push text results))
                                :name "continue" :timeout 30)
      (should kargu-dape-event-hook)
      (let ((tasks (seq-filter (lambda (task)
                                (eq (kargu-async-task-owner task) kargu--loop-run))
                              kargu-async--pending)))
        (kargu-async-cancel-owner kargu--loop-run)
        (funcall held)
        (should-not results)
        (should-not dape-stopped-hook)
        (should-not dape-active-mode-off-hook)
        (should-not kargu-dape-event-hook)
        (dolist (task tasks)
          (should-not (kargu-async-task-timer task))
          (should-not (memq task kargu-async--pending)))))))

(ert-deftest kargu-dape-connection-loss-and-deadline-test ()
  "Connection replacement and overall deadline each produce one error result."
  (let ((connection 'conn) held result)
    (cl-letf (((symbol-function 'kargu-dape--connection) (lambda () connection))
              ((symbol-function 'dape--current-stack-frame) (lambda (_) nil))
              ((symbol-function 'dape--current-thread) (lambda (_) '(:id 1)))
              ((symbol-function 'dape--stack-trace)
               (lambda (_conn _thread _n cb) (setq held cb))))
      (let ((task (kargu-dape-get-context (lambda (text) (push text result)))))
        (setq connection 'another-connection)
        (funcall held)
        (should (= (length result) 1))
        (should (string-prefix-p "ERROR:" (car result)))
        (should-not (kargu-async-task-timer task)))
      (setq result nil connection 'conn)
      (let ((task (kargu-dape-get-context (lambda (text) (push text result)))))
        (kargu-async-finish task nil "Request timed out")
        (funcall held)
        (should (= (length result) 1))
        (should (string-search "timed out" (car result)))))))

(ert-deftest kargu-dape-get-context-chains-callbacks-test ()
  "Context fetches stack, then scopes, then variables, then answers."
  (let* ((var (list :name "x" :value "1"))
         (scope (list :name "Locals" :expensive nil :variables (vector var)))
         (frame (list :id 7 :name "main" :line 3
                      :source (list :path "/tmp/a.c")
                      :scopes (vector scope)))
         (thread (list :id 1 :status "stopped" :stackFrames (vector frame)))
         (order nil))
    (cl-letf (((symbol-function 'kargu-dape--connection) (lambda () 'conn))
              ((symbol-function 'dape--current-thread) (lambda (_) thread))
              ((symbol-function 'dape--stopped-threads) (lambda (_) (list thread)))
              ((symbol-function 'dape--stack-trace)
               (lambda (_conn _thread _n cb)
                 (push 'stack order)
                 (funcall cb)))
              ((symbol-function 'dape--current-stack-frame) (lambda (_) frame))
              ((symbol-function 'dape--scopes)
               (lambda (_conn _frame cb)
                 (push 'scopes order)
                 (funcall cb)))
              ((symbol-function 'dape--variables)
               (lambda (_conn _scope cb)
                 (push 'vars order)
                 (funcall cb)))
              ((symbol-function 'kargu-dape--frame-path) (lambda (_c _f) "/tmp/a.c")))
      (let ((got (kargu-test-await (lambda (cb) (kargu-dape-get-context cb)))))
        (should (equal (reverse order) '(stack scopes vars)))
        (should (string-search "main" got))
        (should (string-search "x = 1" got))))))

(ert-deftest kargu-dape-eval-uses-the-callback-test ()
  "Evaluation reports through the callback instead of a blocking request."
  (cl-letf (((symbol-function 'kargu-dape--connection) (lambda () 'conn))
            ((symbol-function 'dape--current-stack-frame) (lambda (_) (list :id 3)))
            ((symbol-function 'dape--evaluate-expression)
             (lambda (_conn _id _expr _ctx cb)
               (funcall cb (list :result "9") nil))))
    (let ((got (kargu-test-await
                (lambda (done)
                  (kargu-dape-eval-expression "1+1" "repl" done)))))
      (should (string-search "1+1 => 9" got)))))

(ert-deftest kargu-dape-eval-rust-pitfall-advice-on-no-session-test ()
  "Ensure debug_eval appends active language advice for Rust method calls."
  (let ((res (cl-letf (((symbol-function 'kargu-language-active)
                        (lambda (&optional _dir) (kargu-language-get 'rust))))
               (kargu-dape-eval-expression "frame.landmarks_2d.len()"))))
    (should (stringp res))
    (should (string-match-p "Rust LLDB" res))
    (should (string-match-p "debug_scope" res))))

(ert-deftest kargu-dape-tools-never-cached-test ()
  "Ensure Dape tools return nil for `kargu-loop--tool-cacheable-p'."
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

;;; test-dape-commands.el ends here
