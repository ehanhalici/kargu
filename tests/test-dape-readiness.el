;;; test-dape-readiness.el --- Owned debugger readiness waits -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; No adapter or compiler is started.  Real timers are fired explicitly.

;;; Code:

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)

(cl-defstruct (kargu-dape-test--readiness-alarm (:constructor kargu-dape-test--readiness-alarm))
  "A manually fired real timer registration."
  timer function args)

(defmacro kargu-dape-test--with-readiness (&rest body)
  "Run BODY in an isolated origin with fake adapter states and timer alarms."
  (declare (indent 0))
  `(with-temp-buffer
     (let* ((origin (current-buffer))
            (source (generate-new-buffer " *kargu-readiness-source*"))
            (root (kargu-permission-project-root))
            (kargu--loop-run nil) (kargu-async--pending nil)
            (kargu-dape-event-hook nil) (dape-start-hook nil) (dape-stopped-hook nil)
            (connections '(local)) (ready nil) (configs nil) (parents nil)
            (alarms nil) (results nil) (native-timer (symbol-function 'run-at-time)))
       (ignore origin source root connections ready configs parents alarms results)
       (setq-local kargu--session-id "readiness-session")
       (with-current-buffer source (setq buffer-file-name (expand-file-name "main.el" root)))
       (unwind-protect
           (cl-letf (((symbol-function 'kargu-dape--raw-connection) (lambda () (car connections)))
                     ((symbol-function 'kargu-dape-project-connections)
                      (lambda (&optional requested-root)
                        (seq-filter
                         (lambda (conn)
                           (let ((dir (plist-get (cdr (assq conn configs)) 'command-cwd)))
                             (or (null dir) (kargu-permission-within-project-p dir (or requested-root root)))))
                         connections)))
                     ((symbol-function 'kargu-dape-source-buffer) (lambda (&optional _) source))
                     ((symbol-function 'kargu-dape-inspection-thread) (lambda (conn) (memq conn ready)))
                     ((symbol-function 'dape--config) (lambda (conn) (cdr (assq conn configs))))
                     ((symbol-function 'dape--parent) (lambda (conn) (cdr (assq conn parents))))
                     ((symbol-function 'run-at-time)
                      (lambda (_seconds _repeat function &rest args)
                        (let ((timer (funcall native-timer 3600 nil #'ignore)))
                          (push (kargu-dape-test--readiness-alarm :timer timer :function function :args args) alarms)
                          timer))))
             ,@body)
         (dolist (task (copy-sequence kargu-async--pending))
           (kargu-async-cancel-owner (kargu-async-task-owner task)))
         (dolist (alarm alarms) (cancel-timer (kargu-dape-test--readiness-alarm-timer alarm)))
         (when (buffer-live-p source) (kill-buffer source))))))

(ert-deftest kargu-dape-readiness-global-stop-cannot-complete-test ()
  "A global UI stop without a ready owned adapter cannot resume the chat."
  (kargu-dape-test--with-readiness
   (kargu-dape-ensure-session (lambda () (push :ready results)))
   (run-hooks 'dape-start-hook 'dape-stopped-hook)
   (should-not results)))

(ert-deftest kargu-dape-readiness-stop-before-run-preserves-draft-test ()
  "Stop cancels pre-run debugger waiting instead of leaving a live callback."
  (kargu-dape-test--with-readiness
   (insert "unsent draft")
   (let ((task (kargu-dape-ensure-session (lambda () (push :ready results)))))
     (kargu-chat-stop)
     (setq ready '(local))
     (kargu-dape--observe-event 'local 'stopped nil)
     (should (eq (kargu-async-task-state task) :cancelled))
     (should-not results)
     (should (equal (buffer-string) "unsent draft")))))

(defun kargu-dape-test--fire-readiness (alarms function)
  "Fire the recorded FUNCTION in ALARMS without waiting."
  (let ((alarm (seq-find (lambda (item) (eq function (kargu-dape-test--readiness-alarm-function item))) alarms)))
    (should alarm)
    (apply function (kargu-dape-test--readiness-alarm-args alarm))))

(defun kargu-dape-test--readiness-clean-p (alarms)
  "Return non-nil when this wait and all ALARMS have released their resources."
  (and (null kargu-async--pending) (null kargu-dape-event-hook)
       (null kargu-dape--readiness-wait)
       (seq-every-p (lambda (alarm) (not (memq (kargu-dape-test--readiness-alarm-timer alarm) timer-list))) alarms)))

(ert-deftest kargu-dape-readiness-owned-event-resumes-origin-once-test ()
  "An owned stop resumes only in the origin, after cleanup, exactly once."
  (kargu-dape-test--with-readiness
   (kargu-dape-ensure-session
    (lambda ()
      (should (eq (current-buffer) origin))
      (should (kargu-dape-test--readiness-clean-p alarms))
      (push :ready results)))
   (with-temp-buffer
     (setq-local kargu--session-id "foreign")
     (kargu-dape--observe-event 'foreign 'stopped nil)
     (should-not results)
     (kargu-dape--observe-event 'local 'stopped nil)
     (should-not results)
     (setq ready '(local))
     (kargu-dape--observe-event 'local 'thread nil)
     (kargu-dape--observe-event 'local 'stopped nil))
   (kargu-dape-test--fire-readiness alarms #'kargu-dape--readiness-expired)
   (should (equal results '(:ready)))))

(ert-deftest kargu-dape-readiness-stale-origins-are-cancelled-silently-test ()
  "Changes to source, root, session, mode or run owner silence old waits."
  (dolist (change '(source root session mode owner origin file))
    (kargu-dape-test--with-readiness
     (let ((task (kargu-dape-ensure-session
                  (lambda () (push :ready results)) (lambda (_) (push :error results)))))
       (pcase change
         ('source (kill-buffer source))
         ('root (setq-local kargu-permission--override-root temporary-file-directory))
         ('session (setq-local kargu--session-id "replacement"))
         ('mode (kargu-test-mode (if (eq (kargu-state-mode) 'ask) 'plan 'ask)))
         ('owner (setq kargu--loop-run (list :state 'tools)))
         ('origin (kill-buffer origin))
         ('file (with-current-buffer source (setq buffer-file-name "renamed.el"))))
       (setq ready '(local))
       (kargu-dape-test--fire-readiness alarms #'kargu-dape--poll-readiness)
       (kargu-dape-test--fire-readiness alarms #'kargu-dape--readiness-expired)
       (should (eq (kargu-async-task-state task) :cancelled))
       (should-not results)
       (should (kargu-dape-test--readiness-clean-p alarms))))))

(ert-deftest kargu-dape-readiness-new-launch-matches-only-tagged-root-test ()
  "A launch token cannot adopt untagged, child or foreign project adapters."
  (kargu-dape-test--with-readiness
   (setq connections nil)
   (let ((token nil))
     (kargu-dape-wait-for-session (lambda () (push :ready results)) :source source
                                  :launch (lambda (value) (setq token value)))
     (setq configs `((wrong kargu--launch-token ,(make-symbol "wrong"))
                     (child kargu--launch-token ,token)
                     (foreign command-cwd ,(expand-file-name "../foreign" root) kargu--launch-token ,token)))
     (setq parents '((child . wrong)) connections '(wrong child foreign) ready connections)
     (dolist (conn connections) (kargu-dape--observe-event conn 'stopped nil))
     (kargu-dape-test--fire-readiness alarms #'kargu-dape--poll-readiness)
     (should-not results)
     (push (list 'local 'kargu--launch-token token) configs)
     (push 'local connections)
     (push 'local ready)
     (kargu-dape--observe-event 'local 'stopped nil)
     (should (equal results '(:ready)))
     (should (kargu-dape-test--readiness-clean-p alarms)))))

(ert-deftest kargu-dape-readiness-early-event-is-not-missed-test ()
  "Listeners exist before launch and handle a stop before launch returns."
  (kargu-dape-test--with-readiness
   (setq connections nil)
   (kargu-dape-wait-for-session
    (lambda () (push :ready results)) :on-cancel (lambda (_) (push :error results))
    :launch (lambda (token)
              (should kargu-dape-event-hook)
              (setq connections '(local) ready '(local) configs `((local kargu--launch-token ,token)))
              (kargu-dape--observe-event 'local 'stopped nil)
               (error "Producer failure after delivery")))
   (should (equal results '(:ready)))
   (should (kargu-dape-test--readiness-clean-p alarms))))

(ert-deftest kargu-dape-readiness-missing-token-times-out-test ()
  "A transformer that drops metadata cannot turn another ready adapter into ours."
  (kargu-dape-test--with-readiness
   (setq connections nil)
   (kargu-dape-wait-for-session
    (lambda () (push :ready results)) :on-cancel (lambda (reason) (push reason results))
    :launch (lambda (_) (setq connections '(local) ready '(local))))
   (kargu-dape-test--fire-readiness alarms #'kargu-dape--readiness-expired)
   (should (= (length results) 1))
   (should (string-search "timed out" (car results)))
   (should (kargu-dape-test--readiness-clean-p alarms))))

(ert-deftest kargu-dape-readiness-ambiguous-token-is-an-error-test ()
  "Two tagged root adapters are refused rather than arbitrarily selected."
  (kargu-dape-test--with-readiness
   (setq connections nil)
   (kargu-dape-wait-for-session
    (lambda () (push :ready results)) :on-cancel (lambda (reason) (push reason results))
    :launch (lambda (token)
              (setq connections '(one two) ready connections
                    configs `((one kargu--launch-token ,token) (two kargu--launch-token ,token)))))
   (should (string-search "multiple root adapters" (car results)))
   (should (kargu-dape-test--readiness-clean-p alarms))))

(ert-deftest kargu-dape-readiness-bound-adapter-cannot-be-replaced-test ()
  "Replacing or exiting the captured connection cannot adopt a new adapter."
  (dolist (event '(replacement exited terminated))
    (kargu-dape-test--with-readiness
     (kargu-dape-ensure-session (lambda () (push :ready results)) (lambda (reason) (push reason results)))
     (setq connections '(replacement) ready connections)
     (if (eq event 'replacement)
         (kargu-dape-test--fire-readiness alarms #'kargu-dape--poll-readiness)
       (kargu-dape--observe-event 'local event nil))
     (should (= (length results) 1))
     (should (stringp (car results)))
     (should (kargu-dape-test--readiness-clean-p alarms)))))

(ert-deftest kargu-dape-readiness-new-wait-replaces-only-old-origin-wait-test ()
  "A new request replaces its origin's waiter, not other ownerless tasks."
  (kargu-dape-test--with-readiness
   (let* ((unrelated (kargu-async-start (lambda (&rest _) (ert-fail "Unrelated delivery"))))
          (first (kargu-dape-ensure-session (lambda () (push :old results))))
          (second (kargu-dape-ensure-session (lambda () (push :new results)))))
     (should (eq (kargu-async-task-state first) :cancelled))
     (should (kargu-async-pending-p unrelated))
     (should (kargu-async-pending-p second))
     (setq ready '(local))
     (kargu-dape--observe-event 'local 'stopped nil)
     (should (equal results '(:new)))
     (kargu-async-cancel unrelated)
     (should (kargu-dape-test--readiness-clean-p alarms)))))

(ert-deftest kargu-dape-readiness-partial-timer-failure-cleans-up-test ()
  "Each timer registration can fail without leaking hooks or pending tasks."
  (dolist (fail-at '(1 2))
    (kargu-dape-test--with-readiness
     (let ((register (symbol-function 'run-at-time)) (calls 0))
       (cl-letf (((symbol-function 'run-at-time)
                  (lambda (&rest args)
                    (if (= (cl-incf calls) fail-at) (error "Timer startup failed")
                      (apply register args)))))
         (kargu-dape-ensure-session (lambda () (push :ready results)) (lambda (reason) (push reason results)))
         (should (= (length results) 1))
         (should (string-search "Timer startup failed" (car results)))
         (should (kargu-dape-test--readiness-clean-p alarms)))))))

(ert-deftest kargu-dape-readiness-consumer-failure-cannot-leak-or-deliver-twice-test ()
  "A failing readiness consumer runs after cleanup and is never retried."
  (kargu-dape-test--with-readiness
   (kargu-dape-ensure-session (lambda () (push :ready results) (error "Consumer failed")))
   (setq ready '(local))
   (kargu-dape--observe-event 'local 'stopped nil)
   (kargu-dape--observe-event 'local 'stopped nil)
   (should (equal results '(:ready)))
   (should (kargu-dape-test--readiness-clean-p alarms))))

(ert-deftest kargu-dape-readiness-token-survives-launch-without-wire-leak-test ()
  "The public launch path preserves token identity without changing DAP arguments."
  (kargu-dape-test--with-readiness
   (setq connections nil)
   (let* ((original (list 'command "unused" :program "main"))
          (dape-configs (list (cons 'demo original))))
     (cl-letf (((symbol-function 'kargu-dape-selected-config) (lambda () 'demo))
               ((symbol-function 'dape)
                (lambda (config)
                  (should (eq (current-buffer) source))
                  (should (plist-get config 'kargu--launch-token))
                  (setq connections '(local) ready '(local) configs (list (cons 'local (copy-tree config))))
                  (let ((arguments (dape--launch-or-attach-arguments 'local)))
                    (should-not (plist-member arguments 'kargu--launch-token))
                    (should (plist-get arguments :stopOnEntry))
                    (should (equal (plist-get arguments :program) "main")))
                  (kargu-dape--observe-event 'local 'stopped nil))))
       (kargu-dape-ensure-session
        (lambda () (should (eq (current-buffer) origin)) (push :ready results)))
       (should (equal results '(:ready)))
       (should-not (plist-member original 'kargu--launch-token))
       (should-not (plist-member original :stopOnEntry))
       (should (kargu-dape-test--readiness-clean-p alarms))))))

(ert-deftest kargu-dape-readiness-parent-cancellation-cleans-child-test ()
  "Cancellation of the parent owns the wait even before a loop run exists."
  (kargu-dape-test--with-readiness
   (let* ((parent (kargu-async-start (lambda (&rest _) (ert-fail "Parent delivery"))))
          (kargu-async--current-task parent)
          (child (kargu-dape-ensure-session (lambda () (push :ready results)))))
     (kargu-async-cancel parent)
     (setq ready '(local))
     (kargu-dape--observe-event 'local 'stopped nil)
     (should (eq (kargu-async-task-state child) :cancelled))
     (should-not results)
     (should (kargu-dape-test--readiness-clean-p alarms)))))

(ert-deftest kargu-dape-readiness-reentrant-consumer-keeps-new-resources-test ()
  "Finishing an old waiter cannot remove a consumer's newly created waiter."
  (kargu-dape-test--with-readiness
   (kargu-dape-ensure-session
    (lambda ()
      (push :old results)
      (setq ready nil)
      (kargu-dape-ensure-session (lambda () (push :new results)))))
   (setq ready '(local))
   (kargu-dape--observe-event 'local 'stopped nil)
   (should (equal results '(:old)))
   (should kargu-dape--readiness-wait)
   (should (= (length kargu-async--pending) 1))
   (setq ready '(local))
   (kargu-dape--observe-event 'local 'stopped nil)
   (should (equal results '(:new :old)))
   (should (kargu-dape-test--readiness-clean-p alarms))))

(ert-deftest kargu-dape-readiness-preserves-editor-state-test ()
  "Event and timer paths preserve point, narrowing and match data."
  (kargu-dape-test--with-readiness
   (insert "editor state\n")
   (narrow-to-region 2 9)
   (goto-char 5)
   (string-match "state" "editor state")
   (let ((matches (match-data t)))
     (kargu-dape-ensure-session (lambda () (push :ready results)))
     (kargu-dape-test--fire-readiness alarms #'kargu-dape--poll-readiness)
     (setq ready '(local))
     (kargu-dape--observe-event 'local 'stopped nil)
     (should (equal matches (match-data t))))
   (should (= (point) 5))
   (should (= (point-min) 2))
   (should (= (point-max) 9))))

(provide 'tests/test-dape-readiness)
;;; test-dape-readiness.el ends here
