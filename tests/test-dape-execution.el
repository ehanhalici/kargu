;;; test-dape-execution.el --- Owned debugger execution waits -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Fake adapters, delayed replies and manually fired real timers exercise
;; connection ownership independently of Dape's global UI selection.

;;; Code:

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)

(defvar dape-active-mode-off-hook)

(cl-defstruct (kargu-dape-test--alarm (:constructor kargu-dape-test--make-alarm))
  "A real timer registration whose intended callback is fired manually."
  timer function args)

(defun kargu-dape-test--fire-alarm (alarms function)
  "Fire the alarm in ALARMS corresponding to FUNCTION."
  (let ((alarm (seq-find (lambda (entry) (eq function (kargu-dape-test--alarm-function entry))) alarms)))
    (should alarm)
    (apply function (kargu-dape-test--alarm-args alarm))))

(defmacro kargu-dape-test--with-action (&rest body)
  "Run BODY with owned action tasks, controllable timers and DAP replies."
  (declare (indent 0))
  `(with-temp-buffer
     (setq-local kargu--session-id "execution-session")
     (let* ((origin (current-buffer))
            (kargu--loop-run (list :state 'tools)) (kargu-async--pending nil)
            (kargu-dape-event-hook nil) (dape-stopped-hook nil) (dape-active-mode-off-hook nil)
            (kargu-dape--event-generations (make-hash-table :test #'eq :weakness 'key))
            (connections '(local foreign)) (paused '(local foreign)) (selected 'local)
            (timers nil) (requests nil) (stack-reply nil) (results nil)
            (native-timer (symbol-function 'run-at-time)))
       (ignore origin paused selected requests stack-reply results)
       (unwind-protect
           (cl-letf (((symbol-function 'kargu-dape-project-connections) (lambda (&optional _) connections))
                     ((symbol-function 'kargu-dape--raw-connection) (lambda () selected))
                     ((symbol-function 'kargu-dape--connection) (lambda () selected))
                     ((symbol-function 'dape--stopped-threads) (lambda (conn) (and (memq conn paused) '(stopped))))
                     ((symbol-function 'dape--current-thread)
                      (lambda (conn) (list :id 1 :stackFrames (vector (list :id 1 :name (symbol-name conn))))))
                     ((symbol-function 'dape--current-stack-frame)
                      (lambda (conn) (list :id 1 :name (symbol-name conn))))
                     ((symbol-function 'dape--stack-trace)
                      (lambda (conn _thread _limit callback) (push conn requests) (setq stack-reply callback)))
                     ((symbol-function 'dape--scopes) (lambda (_conn _frame callback) (funcall callback)))
                     ((symbol-function 'run-at-time)
                      (lambda (_seconds _repeat function &rest args)
                        (let ((timer (funcall native-timer 3600 nil #'ignore)))
                          (push (kargu-dape-test--make-alarm :timer timer :function function :args args) timers)
                          timer))))
             ,@body)
         (dolist (task (copy-sequence kargu-async--pending))
           (kargu-async-cancel-owner (kargu-async-task-owner task)))
         (dolist (alarm timers) (cancel-timer (kargu-dape-test--alarm-timer alarm)))))))

(defun kargu-dape-test--action-clean-p (timers)
  "Return non-nil when task resources and every registration in TIMERS closed."
  (and (null kargu-async--pending) (null kargu-dape-event-hook)
       (seq-every-p (lambda (alarm) (not (memq (kargu-dape-test--alarm-timer alarm) timer-list))) timers)))

(ert-deftest kargu-dape-execution-foreign-hooks-and-events-cannot-stop-test ()
  "Old stopped state and foreign events cannot complete or redirect an action."
  (kargu-dape-test--with-action
    (kargu-dape--start-action 'local #'ignore (lambda (text) (push text results)) :name "continue" :timeout 30)
    (run-hooks 'dape-stopped-hook 'dape-active-mode-off-hook)
    (dolist (event '(initialized stopped continued exited terminated))
      (kargu-dape--observe-event 'foreign event nil))
    (kargu-dape-test--fire-alarm timers #'kargu-dape--tick-action-wait)
    (should-not requests)
    (should-not results)
    (setq selected 'foreign)
    (with-temp-buffer
      (setq-local kargu--session-id "foreign-session")
      (setq-local kargu-permission--override-root temporary-file-directory)
      (kargu-dape--observe-event 'local 'stopped nil)
      (run-hook-with-args 'kargu-dape-event-hook 'local 'stopped)
      (should (equal requests '(local)))
      (funcall stack-reply)
      (funcall stack-reply))
    (should (= (length results) 1))
    (should (string-search "DEBUGGER PAUSED" (car results)))
    (should (string-search "local" (car results)))
    (should-not (string-search "foreign" (car results)))
    (should (kargu-dape-test--action-clean-p timers))))

(ert-deftest kargu-dape-execution-owned-exit-survives-other-session-test ()
  "An owned exit finishes even while a foreign adapter keeps global mode active."
  (dolist (event '(exited terminated))
    (kargu-dape-test--with-action
      (kargu-dape--start-action 'local #'ignore (lambda (text) (push text results)) :name "continue" :timeout 30)
      (setq connections '(foreign))
      (kargu-dape--observe-event 'local event nil)
      (kargu-dape--observe-event 'local event nil)
      (should (= (length results) 1))
      (should (string-search "PROGRAM EXITED" (car results)))
      (should (kargu-dape-test--action-clean-p timers)))))

(ert-deftest kargu-dape-execution-transport-loss-never-adopts-replacement-test ()
  "A lost adapter is unavailable, not a foreign session's stop or exit report."
  (kargu-dape-test--with-action
    (kargu-dape--start-action 'local #'ignore (lambda (text) (push text results)) :name "continue" :timeout 30)
    (setq connections '(replacement foreign) selected 'replacement)
    (kargu-dape-test--fire-alarm timers #'kargu-dape--tick-action-wait)
    (kargu-dape--observe-event 'replacement 'stopped nil)
    (should (= (length results) 1))
    (should (string-search "Captured debug adapter disconnected" (car results)))
    (should-not requests)
    (should (kargu-dape-test--action-clean-p timers))))

(ert-deftest kargu-dape-execution-reassigned-origin-rejects-late-stop-test ()
  "Project, session and buffer replacement prevent collection after a late stop."
  (dolist (change '(root session closed))
    (kargu-dape-test--with-action
      (kargu-dape--start-action 'local #'ignore (lambda (text) (push text results)) :name "step" :timeout 10)
      (pcase change
        ('root (setq-local kargu-permission--override-root temporary-file-directory))
        ('session (setq-local kargu--session-id "replacement"))
        ('closed (kill-buffer origin)))
      (with-temp-buffer (kargu-dape--observe-event 'local 'stopped nil))
      (should-not requests)
      (should (= (length results) 1))
      (should (string-prefix-p "ERROR:" (car results)))
      (should (kargu-dape-test--action-clean-p timers)))))

(ert-deftest kargu-dape-execution-invalid-context-never-reports-paused-test ()
  "Invalidation during stack collection cannot publish a successful pause report."
  (dolist (change '(root session connection continued restopped))
    (kargu-dape-test--with-action
      (kargu-dape--start-action 'local #'ignore (lambda (text) (push text results)) :name "step" :timeout 10)
      (kargu-dape--observe-event 'local 'stopped nil)
      (pcase change
        ('root (setq-local kargu-permission--override-root temporary-file-directory))
        ('session (setq-local kargu--session-id "replacement"))
        ('connection (setq connections '(replacement)))
        ('continued (setq paused nil))
        ('restopped
         (kargu-dape--observe-event 'local 'continued nil)
         (kargu-dape--observe-event 'local 'stopped nil)))
      (funcall stack-reply)
      (funcall stack-reply)
      (should (= (length results) 1))
      (should (string-prefix-p "ERROR:" (car results)))
      (should-not (string-search "DEBUGGER PAUSED" (car results)))
      (should (kargu-dape-test--action-clean-p timers)))))

(ert-deftest kargu-dape-execution-cancel-owner-cleans-every-stage-test ()
  "Stop removes all timers/listeners and suppresses replies in either stage."
  (dolist (reporting '(nil t))
    (kargu-dape-test--with-action
      (kargu-dape--start-action 'local #'ignore (lambda (text) (push text results)) :name "step" :timeout 10)
      (when reporting (kargu-dape--observe-event 'local 'stopped nil))
      (kargu-async-cancel-owner kargu--loop-run)
      (when reporting (funcall stack-reply))
      (kargu-dape-test--fire-alarm timers #'kargu-dape--tick-action-wait)
      (kargu-dape-test--fire-alarm timers #'kargu-dape--action-deadline)
      (should-not results)
      (should (kargu-dape-test--action-clean-p timers)))))

(ert-deftest kargu-dape-execution-replaced-run-does-not-leak-poll-test ()
  "Replacing a run without explicit cancellation is caught by the poll guardian."
  (kargu-dape-test--with-action
    (let ((task (kargu-dape--start-action 'local #'ignore (lambda (text) (push text results))
                                        :name "step" :timeout 10)))
      (setq kargu--loop-run (list :state 'tools))
      (kargu-dape-test--fire-alarm timers #'kargu-dape--tick-action-wait)
      (should (eq (kargu-async-task-state task) :cancelled))
      (should-not results)
      (should (kargu-dape-test--action-clean-p timers)))))

(ert-deftest kargu-dape-execution-deadline-distinguishes-reporting-test ()
  "An action timeout reports running only before an owned stop begins collection."
  (dolist (reporting '(nil t))
    (kargu-dape-test--with-action
      (kargu-dape--start-action 'local #'ignore (lambda (text) (push text results)) :name "continue" :timeout 30)
      (when reporting (kargu-dape--observe-event 'local 'stopped nil))
      (kargu-dape-test--fire-alarm timers #'kargu-dape--action-deadline)
      (if reporting
          (progn (should-not results) (funcall stack-reply))
        (should (string-search "STILL RUNNING" (car results))))
      (should (= (length results) 1))
      (should (kargu-dape-test--action-clean-p timers)))))

(ert-deftest kargu-dape-execution-exit-during-report-cancels-child-test ()
  "An owned exit wins once and cancels pending stack collection."
  (kargu-dape-test--with-action
    (kargu-dape--start-action 'local #'ignore (lambda (text) (push text results)) :name "step" :timeout 10)
    (kargu-dape--observe-event 'local 'stopped nil)
    (kargu-dape--observe-event 'local 'exited nil)
    (funcall stack-reply)
    (should (= (length results) 1))
    (should (string-search "PROGRAM EXITED" (car results)))
    (should (kargu-dape-test--action-clean-p timers))))

(ert-deftest kargu-dape-execution-refuses-nonowned-adapter-before-command-test ()
  "A connection absent at admission cannot run an execution command."
  (kargu-dape-test--with-action
    (let ((called nil))
      (setq connections '(foreign))
      (kargu-dape--start-action 'local (lambda (_) (setq called t)) (lambda (text) (push text results))
                                :name "step" :timeout 10)
      (should-not called)
      (should (string-prefix-p "ERROR:" (car results)))
      (should (kargu-dape-test--action-clean-p timers)))))

(ert-deftest kargu-dape-execution-dispatch-observer-preserves-state-test ()
  "Notification observers run after Dape and cannot corrupt caller match data."
  (let ((kargu-dape-event-hook nil) (updated nil) seen
        (kargu-dape--event-generations (make-hash-table :test #'eq :weakness 'key)))
    (cl-letf (((symbol-function 'dape-handle-event)
               (lambda (&rest _) (setq updated t))))
      (unwind-protect
          (progn
            (advice-add 'dape-handle-event :after #'kargu-dape--observe-event)
            (add-hook 'kargu-dape-event-hook
                      (lambda (conn event) (push (list conn event updated) seen)
                        (string-match "foreign" "foreign")))
            (string-match "caller" "caller")
            (let ((matches (match-data t)))
              (dape-handle-event 'local 'stopped nil)
              (should (equal matches (match-data t))))
            (should (equal seen '((local stopped t)))))
        (advice-remove 'dape-handle-event #'kargu-dape--observe-event)))))

(ert-deftest kargu-dape-execution-startup-failure-cleans-partial-resources-test ()
  "Command and partial timer setup errors both close every acquired resource."
  (dolist (failure '(command timer))
    (kargu-dape-test--with-action
      (let ((allocate (symbol-function 'run-at-time)))
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (seconds repeat function &rest args)
                     (when (and (eq failure 'timer) (eq function #'kargu-dape--action-deadline))
                       (error "Timer creation failed"))
                     (apply allocate seconds repeat function args))))
          (kargu-dape--start-action
           'local (lambda (_) (when (eq failure 'command) (error "Execution command failed")))
           (lambda (text) (push text results)) :name "step" :timeout 10)))
      (should (= (length results) 1))
      (should (string-prefix-p "ERROR:" (car results)))
      (should (kargu-dape-test--action-clean-p timers)))))

(ert-deftest kargu-dape-execution-listener-failure-does-not-stop-other-owners-test ()
  "One failing notification consumer cannot break the dispatcher or another task."
  (let ((kargu-dape-event-hook nil)
        (kargu-dape--event-generations (make-hash-table :test #'eq :weakness 'key))
        (received 0) (logs nil))
    (add-hook 'kargu-dape-event-hook (lambda (&rest _) (cl-incf received)))
    (add-hook 'kargu-dape-event-hook (lambda (&rest _) (error "Consumer failed")))
    (cl-letf (((symbol-function 'kargu-log) (lambda (&rest args) (push args logs))))
      (kargu-dape--observe-event 'local 'stopped nil))
    (should (= received 1))
    (should (= (length logs) 1))
    (should (= (kargu-dape-event-generation 'local) 1))
    (should (= (kargu-dape-event-generation 'foreign) 0))))

(provide 'tests/test-dape-execution)
;;; test-dape-execution.el ends here
