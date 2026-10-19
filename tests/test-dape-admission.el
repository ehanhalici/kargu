;;; test-dape-admission.el --- Paused thread inspection ownership -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Real request helpers mutate only private inspection data before delivery.

;;; Code:

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)

(defmacro kargu-dape-test--with-admission (&rest body)
  "Run BODY with mutable live threads and deferred protocol replies."
  (declare (indent 0))
  `(with-temp-buffer
     (let* ((frame (list :id 11 :name "main"))
            (thread (list :id 1 :status 'stopped :stackFrames (list frame)))
            (other (list :id 2 :status 'stopped))
            (threads (list thread other)) (selected-id 1) (stack-id 11)
            (kargu--loop-run (list :state 'tools)) (kargu-async--pending nil)
            (kargu-dape-event-hook nil)
            (kargu-dape--watches (make-hash-table :test #'eq :weakness 'key))
            (kargu-dape--event-generations (make-hash-table :test #'eq :weakness 'key))
            (replies nil) (requests nil) (results nil))
       (ignore frame thread other threads selected-id stack-id replies requests results)
       (unwind-protect
           (cl-letf (((symbol-function 'kargu-dape--raw-connection) (lambda () 'local))
                     ((symbol-function 'kargu-dape-project-connections) (lambda (&optional _) '(local)))
                     ((symbol-function 'dape--thread-id) (lambda (_) selected-id))
                     ((symbol-function 'dape--stack-id) (lambda (_) stack-id))
                     ((symbol-function 'dape--threads) (lambda (_) threads))
                     ((symbol-function 'dape--stopped-threads)
                      (lambda (_) (seq-filter (lambda (th) (eq (plist-get th :status) 'stopped)) threads)))
                     ((symbol-function 'dape--current-thread)
                      (lambda (_) (seq-find (lambda (th) (equal selected-id (plist-get th :id))) threads)))
                     ((symbol-function 'dape--current-stack-frame) (lambda (_) frame))
                     ((symbol-function 'dape--stack-trace)
                      (lambda (_conn work _limit callback)
                        (push :stack requests)
                        (push (lambda ()
                                (plist-put work :stackFrames (list (list :id 11 :name "fresh")))
                                (funcall callback)) replies)))
                     ((symbol-function 'dape--scopes)
                      (lambda (_conn work callback)
                        (push :scopes requests)
                        (push (lambda ()
                                (plist-put work :scopes (list (list :name "Locals" :variablesReference 1)))
                                (funcall callback)) replies)))
                     ((symbol-function 'dape--variables)
                      (lambda (_conn work callback)
                        (push :variables requests)
                        (push (lambda ()
                                (plist-put work :variables (list (list :name "x" :value "fresh")))
                                (funcall callback)) replies))))
             ,@body)
         (kargu-async-cancel-owner kargu--loop-run)))))

(ert-deftest kargu-dape-admission-running-selection-is-not-ready-test ()
  "A different paused thread does not authorize a running selected thread."
  (kargu-dape-test--with-admission
    (plist-put thread :status 'running)
    (should-not (kargu-dape-ready-p))
    (should (stringp (kargu-dape--connection)))
    (should-error (kargu-dape-capture-selection 'local))))

(ert-deftest kargu-dape-admission-missing-selection-does-not-fallback-test ()
  "An explicit missing thread is not replaced by an arbitrary stopped one."
  (kargu-dape-test--with-admission
    (setq selected-id 9)
    (should-error (kargu-dape-capture-selection 'local))))

(ert-deftest kargu-dape-admission-thread-event-invalidates-pending-read-test ()
  "Even a different thread event on this adapter invalidates old reads."
  (kargu-dape-test--with-admission
    (kargu-dape-get-context (lambda (text) (push text results)))
    (kargu-dape--observe-event 'local 'thread '(:threadId 2 :reason "started"))
    (funcall (pop replies))
    (should (equal requests '(:stack)))
    (should (string-prefix-p "ERROR:" (car results)))))

(ert-deftest kargu-dape-admission-late-stack-cannot-mutate-live-thread-test ()
  "A cancelled stack reply mutates its private working copy, never live data."
  (kargu-dape-test--with-admission
    (let ((before (copy-tree thread t)))
      (kargu-dape-get-context (lambda (text) (push text results)))
      (kargu-async-cancel-owner kargu--loop-run)
      (funcall (pop replies))
      (should-not results)
      (should (equal thread before)))))

(ert-deftest kargu-dape-admission-all-inspections-refuse-running-thread-test ()
  "Policy, snapshots and direct calls share the selected-thread admission."
  (kargu-dape-test--with-admission
    (plist-put thread :status 'running)
    (should (kargu-dape-tool-refusal "debug_get_context"))
    (should-not (kargu-dape-tool-refusal "debug_threads"))
    (should (string-prefix-p "ERROR:" (kargu-dape-context-snapshot)))
    (dolist (start (list #'kargu-dape-get-context
                         (lambda (done) (kargu-dape-stack 12 done))
                         (lambda (done) (kargu-dape-scope nil done))
                         (lambda (done) (kargu-dape-eval-expression "x" "watch" done))
                         (lambda (done) (kargu-dape-watch "x" nil done))
                         (lambda (done) (kargu-dape-up 1 done))))
      (funcall start (lambda (text) (push text results))))
    (should (= (length results) 6))
    (should (seq-every-p (lambda (text) (string-prefix-p "ERROR:" text)) results))
    (should-not requests)))

(ert-deftest kargu-dape-admission-unspecified-selection-and-large-id-test ()
  "Only no selection may default; numeric identities are compared by value."
  (kargu-dape-test--with-admission
    (setq selected-id nil)
    (should (eq (kargu-dape-inspection-thread 'local) thread))
    (plist-put thread :id (string-to-number "100000000000000000001"))
    (setq selected-id (string-to-number "100000000000000000001"))
    (should (eq (kargu-dape-inspection-thread 'local) thread))
    (plist-put thread :status 'running)
    (should-not (kargu-dape-inspection-thread 'local))
    (setq selected-id nil)
    (should (eq (kargu-dape-inspection-thread 'local) other))))

(ert-deftest kargu-dape-admission-status-change-at-every-stage-test ()
  "Even without a notification, every callback checks the exact live thread."
  (dolist (stage '(1 2 3))
    (kargu-dape-test--with-admission
      (kargu-dape-get-context (lambda (text) (push text results)))
      (dotimes (_ (1- stage)) (funcall (pop replies)))
      (plist-put thread :status 'running)
      (let ((before (copy-tree thread t)) (reply (pop replies)))
        (funcall reply)
        (funcall reply)
        (should (equal thread before)))
      (should (= (length requests) stage))
      (should (= (length results) 1))
      (should (string-prefix-p "ERROR:" (car results)))
      (should-not kargu-async--pending))))

(ert-deftest kargu-dape-admission-cancellation-at-every-stage-test ()
  "Late stack, scope and variable helpers cannot write to the live cache."
  (dolist (stage '(1 2 3))
    (kargu-dape-test--with-admission
      (let ((before (copy-tree thread t)))
        (kargu-dape-get-context (lambda (text) (push text results)))
        (dotimes (_ (1- stage)) (funcall (pop replies)))
        (kargu-async-cancel-owner kargu--loop-run)
        (funcall (pop replies))
        (should-not results)
        (should (equal thread before))
        (should-not kargu-async--pending)))))

(ert-deftest kargu-dape-admission-replaced-thread-identity-is-rejected-test ()
  "A newly allocated thread with the same numeric ID cannot inherit a read."
  (kargu-dape-test--with-admission
    (kargu-dape-get-context (lambda (text) (push text results)))
    (setq threads (list (copy-tree thread t) other))
    (funcall (pop replies))
    (should (string-prefix-p "ERROR:" (car results)))
    (should (equal requests '(:stack)))))

(ert-deftest kargu-dape-admission-continue-stop-aba-is-rejected-test ()
  "Returning to stopped state does not restore an old inspection's authority."
  (kargu-dape-test--with-admission
    (kargu-dape-get-context (lambda (text) (push text results)))
    (kargu-dape--observe-event 'local 'continued '(:threadId 1 :allThreadsContinued :json-false))
    (kargu-dape--observe-event 'local 'stopped '(:threadId 1 :allThreadsStopped :json-false))
    (funcall (pop replies))
    (should (string-prefix-p "ERROR:" (car results)))
    (should (equal requests '(:stack)))))

(ert-deftest kargu-dape-admission-foreign-events-and-selection-do-not-redirect-test ()
  "A valid read is pinned despite unrelated adapter events and UI selection."
  (kargu-dape-test--with-admission
    (let ((before (copy-tree thread t)))
      (kargu-dape-get-context (lambda (text) (push text results)))
      (setq selected-id 2 stack-id nil)
      (kargu-dape--observe-event 'foreign 'thread '(:reason "exited"))
      (dotimes (_ 3) (funcall (pop replies)))
      (should (string-search "x = fresh" (car results)))
      (should (equal thread before))
      (should-not kargu-async--pending))))

(ert-deftest kargu-dape-admission-old-reply-cannot-poison-a-new-read-test ()
  "Old task data remains isolated after a new stop starts another inspection."
  (kargu-dape-test--with-admission
    (kargu-dape-get-context (lambda (text) (push text results)))
    (let ((old-reply (pop replies)))
      (kargu-async-cancel-owner kargu--loop-run)
      (kargu-dape--observe-event 'local 'stopped nil)
      (kargu-dape-get-context (lambda (text) (push text results)))
      (funcall old-reply)
      (should (eq (car (plist-get thread :stackFrames)) frame))
      (dotimes (_ 3) (funcall (pop replies)))
      (should (= (length results) 1))
      (should (string-search "fresh" (car results))))))

(ert-deftest kargu-dape-admission-watch-keeps-one-prepared-selection-test ()
  "All watched expressions keep the original frame after UI selection changes."
  (kargu-dape-test--with-admission
    (let ((evaluations nil))
      (cl-letf (((symbol-function 'dape--evaluate-expression)
                 (lambda (_conn id _expr _context callback)
                   (push id evaluations)
                   (setq selected-id 2 stack-id nil)
                   (funcall callback '(:result "value") nil))))
        (kargu-dape-watch-expressions 'local "first")
        (kargu-dape-watch-expressions 'local "second")
        (kargu-dape-watch nil nil (lambda (text) (push text results)))
        (funcall (pop replies))
        (should (equal evaluations '(11 11)))
        (should (equal requests '(:stack)))
        (should (= (length results) 1))
        (should (string-search "WATCH LIST: 2" (car results)))))))

(ert-deftest kargu-dape-admission-eval-invalidated-before-answer-test ()
  "An evaluated expression's old answer cannot be published after a thread exit."
  (kargu-dape-test--with-admission
    (let ((answer nil))
      (cl-letf (((symbol-function 'dape--evaluate-expression)
                 (lambda (_conn _id _expr _context callback) (setq answer callback))))
        (kargu-dape-eval-expression "x" "hover" (lambda (text) (push text results)))
        (funcall (pop replies))
        (kargu-dape--observe-event 'local 'thread '(:threadId 1 :reason "exited"))
        (funcall answer '(:result "stale") nil)
        (funcall answer '(:result "duplicate") nil)
        (should (= (length results) 1))
        (should (string-prefix-p "ERROR:" (car results)))))))

(ert-deftest kargu-dape-admission-real-helper-late-writes-are-private-test ()
  "Actual Dape stack/scopes/variables helpers cannot poison a live cache."
  (let ((stack (symbol-function 'dape--stack-trace))
        (scopes (symbol-function 'dape--scopes))
        (variables (symbol-function 'dape--variables)))
    (dolist (stage '(1 2 3))
      (kargu-dape-test--with-admission
        (let ((pending nil) (before (copy-tree thread t)))
          (cl-letf (((symbol-function 'dape--stack-trace) stack)
                    ((symbol-function 'dape--scopes) scopes)
                    ((symbol-function 'dape--variables) variables)
                    ((symbol-function 'dape--capable-p) (lambda (&rest _) nil))
                    ((symbol-function 'jsonrpc-running-p) (lambda (_) t))
                    ((symbol-function 'dape-request)
                     (lambda (_conn method _args &optional callback)
                       (push (cons method callback) pending))))
            (kargu-dape-get-context (lambda (text) (push text results)))
            (dotimes (index stage)
              (when (= index (1- stage)) (kargu-async-cancel-owner kargu--loop-run))
              (let* ((request (pop pending))
                     (body (pcase (car request)
                             (:stackTrace (list :stackFrames (vector (list :id 11 :name "fresh")) :totalFrames 1))
                             (:scopes (list :scopes (vector (list :name "Locals" :variablesReference 1))))
                             (:variables (list :variables (vector (list :name "x" :value "late")))))))
                (should request)
                (funcall (cdr request) body nil)))
            (should-not pending)
            (should-not results)
            (should (equal thread before))))))))

(ert-deftest kargu-dape-admission-empty-stack-refuses-evaluation-test ()
  "An empty refreshed stack must not turn a frame evaluation into global eval."
  (kargu-dape-test--with-admission
    (setq stack-id nil)
    (cl-letf (((symbol-function 'dape--stack-trace)
               (lambda (_conn _work _limit callback) (funcall callback)))
              ((symbol-function 'dape--evaluate-expression)
               (lambda (&rest _) (ert-fail "Unframed evaluation"))))
      (kargu-dape-eval-expression "x" "repl" (lambda (text) (push text results)))
      (should (string-search "No stack frame" (car results))))))

(ert-deftest kargu-dape-admission-duplicate-stage-does-not-start-more-work-test ()
  "Repeated stack/scope replies cannot launch the following request twice."
  (kargu-dape-test--with-admission
    (kargu-dape-get-context (lambda (text) (push text results)))
    (let ((stack (pop replies))) (funcall stack) (funcall stack))
    (should (equal requests '(:scopes :stack)))
    (let ((scopes (pop replies))) (funcall scopes) (funcall scopes))
    (should (equal requests '(:variables :scopes :stack)))
    (funcall (pop replies))
    (should (= (length results) 1))
    (should-not kargu-async--pending)))

(provide 'tests/test-dape-admission)
;;; test-dape-admission.el ends here
