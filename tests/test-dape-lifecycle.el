;;; test-dape-lifecycle.el --- Scoped debugger closing tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Use real JSONRPC process connections but offline DAP replies.  Native
;; waiting/global shutdown functions must never run on the owned path.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'kargu/tools/dape)

(defun kargu-dape-lifecycle-test--connection (root &optional parent)
  "Create a real pipe adapter in ROOT, optionally attached to PARENT."
  (let* ((process (make-process :name "kargu-lifecycle-fixture"
                                :command (list (executable-find "cat"))
                                :connection-type 'pipe :noquery t))
         (connection (dape-connection
                      :name (make-temp-name "kargu-close-") :process process
                      :config (list 'command-cwd root :cwd root)
                      :parent parent :server-process nil :stderr-buffer nil
                      :events-buffer-config '(:size 0)
                      :on-shutdown (lambda (_) (error "Native shutdown must be replaced")))))
    connection))

(defun kargu-dape-lifecycle-test--dispose (connection)
  "Release fixture CONNECTION without invoking native Dape shutdown."
  (if-let* ((resource (kargu-dape-resource connection)))
      (kargu-dape-resource-stop resource)
    (setf (jsonrpc--on-shutdown connection) #'ignore)
    (let ((buffers (list (process-buffer (jsonrpc--process connection))
                         (process-get (jsonrpc--process connection) 'jsonrpc-stderr)
                         (jsonrpc-events-buffer connection))))
      (delete-process (jsonrpc--process connection))
      (dolist (buffer buffers) (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defmacro kargu-dape-lifecycle-test--with-adapters (&rest body)
  "Run BODY with `owned', `child' and `foreign' in separate real projects."
  (declare (indent 0))
  `(kargu-test-with-git-repo nil
     (let* ((other (make-temp-file "kargu-close-foreign-" t))
            (owned (kargu-dape-lifecycle-test--connection repo))
            (child (kargu-dape-lifecycle-test--connection repo owned))
            (foreign (kargu-dape-lifecycle-test--connection other))
            (dape--connections (list owned foreign))
            (dape--connection-selected foreign)
            (dape--request-blocking t))
       (setf (dape--children owned) (list child foreign))
       (unwind-protect
           (cl-letf (((symbol-function 'dape-quit) (lambda () (error "Global quit forbidden")))
                     ((symbol-function 'dape-disconnect-quit)
                      (lambda (&rest _) (error "Global disconnect forbidden")))
                     ((symbol-function 'dape--shutdown)
                      (lambda (&rest _) (error "Blocking shutdown forbidden")))
                     ((symbol-function 'sleep-for) (lambda (&rest _) (error "Sleep forbidden")))
                     ((symbol-function 'accept-process-output)
                      (lambda (&rest _) (error "Blocking wait forbidden")))
                     ((symbol-function 'dape--stack-frame-cleanup)
                      (lambda () (error "Foreign stack cleanup forbidden"))))
             ,@body)
         (dolist (connection (list child owned foreign))
           (kargu-dape-lifecycle-test--dispose connection))
         (delete-directory other t)))))

(ert-deftest kargu-dape-close-is-asynchronous-and-project-scoped-test ()
  "Detach only the captured adapter and children, preserving foreign UI."
  (kargu-dape-lifecycle-test--with-adapters
    (let (requests replies results)
      (cl-letf (((symbol-function 'dape-request)
                 (lambda (connection command arguments callback)
                   (should-not dape--request-blocking)
                   (push (list connection command arguments) requests)
                   (push callback replies))))
        (let* ((task (kargu-dape-close :connection owned :action :disconnect :root repo
                                      :callback (lambda (text) (push text results))))
               (buffers (append (kargu-dape-resource-buffers (kargu-dape-resource owned))
                                (kargu-dape-resource-buffers (kargu-dape-resource child)))))
          (should (kargu-async-pending-p task))
          (should-not results)
          (should (= (length requests) 2))
          (should (cl-every (lambda (request)
                              (and (eq (cadr request) :disconnect)
                                   (eq (plist-get (caddr request) :terminateDebuggee) :json-false)))
                            requests))
          (dolist (reply replies) (funcall reply nil nil) (funcall reply nil nil))
          (should (= (length results) 1))
          (should-not (string-prefix-p "ERROR:" (car results)))
          (should-not (process-live-p (jsonrpc--process owned)))
          (should-not (process-live-p (jsonrpc--process child)))
          (should (process-live-p (jsonrpc--process foreign)))
          (should (eq dape--connection-selected foreign))
          (should (equal dape--connections (list foreign)))
          (should (cl-every (lambda (buffer) (not (buffer-live-p buffer))) buffers))
          (should-not (kargu-async-pending-p task)))))))

(ert-deftest kargu-dape-close-fallback-is-single-use-test ()
  "Failed terminate falls back once; stale terminate callbacks cannot restart it."
  (kargu-dape-lifecycle-test--with-adapters
    (setf (dape--children owned) nil)
    (let (terminate disconnect results (disconnects 0))
      (cl-letf (((symbol-function 'dape--capable-p) (lambda (&rest _) t))
                ((symbol-function 'dape-request)
                 (lambda (_connection command _arguments callback)
                   (pcase command
                     (:terminate (setq terminate callback))
                     (:disconnect (cl-incf disconnects) (setq disconnect callback))))))
        (kargu-dape-close :connection owned :action :kill :root repo
                          :callback (lambda (text) (push text results)))
        (funcall terminate nil "Unsupported")
        (funcall terminate nil "Duplicate")
        (should (= disconnects 1))
        (funcall disconnect nil nil)
        (funcall terminate nil nil)
        (funcall disconnect nil nil)
        (should (= (length results) 1))
        (should (process-live-p (jsonrpc--process foreign)))))))

(ert-deftest kargu-dape-close-deadline-and-stop-release-owned-resources-test ()
  "Deadline reports once; Stop is silent, and both release only owned transports."
  (dolist (case '(deadline stop))
    (kargu-dape-lifecycle-test--with-adapters
      (let (replies results)
        (cl-letf (((symbol-function 'dape-request)
                   (lambda (_connection _command _arguments callback) (push callback replies))))
          (let ((task (kargu-dape-close :connection owned :action :quit :root repo
                                       :callback (lambda (text) (push text results)))))
            (pcase case
              ('deadline (kargu-async-finish task nil "Request timed out"))
              ('stop (kargu-async-cancel task)))
            (dolist (reply replies) (funcall reply nil nil))
            (should (= (length results) (if (eq case 'deadline) 1 0)))
            (should-not (process-live-p (jsonrpc--process owned)))
            (should-not (process-live-p (jsonrpc--process child)))
            (should (process-live-p (jsonrpc--process foreign)))
            (should-not (kargu-dape-project-connections repo))))))))

(ert-deftest kargu-dape-close-terminal-event-does-not-call-native-shutdown-test ()
  "A managed adapter's terminated event does not enter Dape's blocking handler."
  (kargu-dape-lifecycle-test--with-adapters
    (kargu-dape-adopt owned)
    (kargu-dape-adopt child)
    (funcall (jsonrpc--notification-dispatcher owned) owned 'terminated nil)
    (should-not (process-live-p (jsonrpc--process owned)))
    (should-not (process-live-p (jsonrpc--process child)))
    (should (process-live-p (jsonrpc--process foreign)))
    (should (eq dape--connection-selected foreign))
    (should-not (memq owned dape--connections))))

(ert-deftest kargu-dape-close-rejects-foreign-connection-before-adoption-test ()
  "Project admission refuses a foreign adapter before changing its callbacks."
  (kargu-dape-lifecycle-test--with-adapters
    (let ((shutdown (jsonrpc--on-shutdown foreign)))
      (should-error (kargu-dape-close :connection foreign :action :quit :root repo
                                      :callback #'ignore) :type 'user-error)
      (should (eq shutdown (jsonrpc--on-shutdown foreign)))
      (should-not (kargu-dape-resource foreign)))))

(ert-deftest kargu-dape-close-completion-observes-all-resources-released-test ()
  "The callback runs after parent/child cleanup, not from an intermediate phase."
  (kargu-dape-lifecycle-test--with-adapters
    (let (replies finished)
      (cl-letf (((symbol-function 'dape-request)
                 (lambda (_connection _command _arguments callback) (push callback replies))))
        (kargu-dape-close
         :connection owned :action :disconnect :root repo
         :callback (lambda (_text)
                     (dolist (connection (list owned child))
                       (let ((resource (kargu-dape-resource connection)))
                         (should (eq (kargu-dape-resource-phase resource) :closed))
                         (should-not (process-live-p (jsonrpc--process connection)))
                         (should (cl-every (lambda (buffer) (not (buffer-live-p buffer)))
                                           (kargu-dape-resource-buffers resource)))))
                     (setq finished t)))
        ;; Parent death recursively releases its adopted children.
        (kargu-dape-resource-stop (kargu-dape-resource owned))
        (dolist (reply replies) (funcall reply nil nil))
        (should finished)))))

(ert-deftest kargu-dape-close-pins-stderr-pipes-before-waiting-test ()
  "An unrelated process attached to an old transport buffer is never killed."
  (kargu-dape-lifecycle-test--with-adapters
    (let* ((resource (kargu-dape-adopt owned))
           (old-buffer (process-buffer (jsonrpc--process owned)))
           (foreign-pipe (make-pipe-process :name "kargu-foreign-pipe"
                                            :buffer old-buffer :noquery t)))
      (unwind-protect
          (progn
            (kargu-dape-resource-stop resource)
            (should (process-live-p foreign-pipe))
            (should (buffer-live-p old-buffer)))
        (delete-process foreign-pipe)
        (when (buffer-live-p old-buffer) (kill-buffer old-buffer))))))

(ert-deftest kargu-dape-close-releases-captured-server-and-stderr-test ()
  "Force closing releases its server and stderr, never another adapter's process."
  (kargu-dape-lifecycle-test--with-adapters
    (let* ((stderr (generate-new-buffer " *kargu-server-stderr*"))
           (pipe (make-pipe-process :name "kargu-owned-stderr" :buffer stderr :noquery t))
           (server (make-process :name "kargu-owned-server" :noquery t
                                  :command (list (executable-find "cat"))
                                  :connection-type 'pipe)))
      (unwind-protect
          (cl-letf (((symbol-function 'dape-request) (lambda (&rest _) nil)))
            (setf (dape--server-process owned) server (dape--stderr-buffer owned) stderr)
            (process-put server 'stderr-pipe stderr)
            (let ((task (kargu-dape-close :connection owned :action :quit :root repo :callback #'ignore)))
              (kargu-async-cancel task)
              (should-not (process-live-p server))
              (should-not (process-live-p pipe))
              (should-not (buffer-live-p stderr))
              (should (process-live-p (jsonrpc--process foreign)))))
        (when (process-live-p server) (delete-process server))
        (when (process-live-p pipe) (delete-process pipe))
        (when (buffer-live-p stderr) (kill-buffer stderr))))))

(ert-deftest kargu-dape-close-owner-replacement-cancels-without-publishing-test ()
  "Retiring the origin cancels a pending close; late replies publish nothing."
  (kargu-dape-lifecycle-test--with-adapters
    (let (results replies)
      (cl-letf (((symbol-function 'dape-request)
                 (lambda (_connection _command _arguments callback) (push callback replies))))
        (let ((task (kargu-dape-close :connection owned :action :disconnect :root repo
                                     :callback (lambda (text) (push text results)))))
          (kargu-session-clear)
          (dolist (reply replies) (funcall reply nil nil))
          (should-not results)
          (should-not (kargu-async-pending-p task))
          (should-not (process-live-p (jsonrpc--process owned)))
          (should (process-live-p (jsonrpc--process foreign))))))))

(ert-deftest kargu-dape-close-ignores-late-sentinels-and-terminal-events-test ()
  "Duplicate native sentinel or terminal notifications cannot repeat cleanup."
  (kargu-dape-lifecycle-test--with-adapters
    (kargu-dape-adopt owned)
    (kargu-dape-adopt child)
    (let ((dispatcher (jsonrpc--notification-dispatcher owned))
          (process (jsonrpc--process owned)))
      (kargu-dape-resource-stop (kargu-dape-resource owned))
      (let ((generation (kargu-dape-event-generation owned)))
        (funcall (process-sentinel process) process "late\n")
        (funcall dispatcher owned 'terminated nil)
        (funcall dispatcher owned 'exited '(:exitCode 0))
        (should (= generation (kargu-dape-event-generation owned)))))))

(ert-deftest kargu-dape-close-cancels-native-jsonrpc-request-timers-test ()
  "Real Dape requests remain asynchronous and their timers drain on Stop."
  (kargu-dape-lifecycle-test--with-adapters
    (let* ((task (kargu-dape-close :connection owned :action :disconnect :root repo
                                  :callback #'ignore))
           (timers (delq nil (mapcar (lambda (continuation) (nth 4 continuation))
                                     (jsonrpc--continuations owned)))))
      (should (kargu-async-pending-p task))
      (should timers)
      (kargu-async-cancel task)
      (should (cl-every (lambda (timer) (not (memq timer timer-list))) timers))
      (should (eq (kargu-dape-resource-phase (kargu-dape-resource owned)) :closed)))))

(ert-deftest kargu-dape-close-owns-native-private-shutdown-without-affecting-foreign-test ()
  "Protocol failure shutdown bypasses the waiting helper only for adopted adapters."
  (kargu-dape-lifecycle-test--with-adapters
    (let (called)
      (kargu-dape-adopt owned)
      (kargu-dape-resource--shutdown-owned
       (lambda (_connection) (error "Owned shutdown reached blocking path")) owned)
      (kargu-dape-resource--shutdown-owned
       (lambda (connection) (setq called connection)) foreign)
      (should (eq called foreign))
      (should-not (process-live-p (jsonrpc--process owned)))
      (should (process-live-p (jsonrpc--process foreign))))))

(provide 'tests/test-dape-lifecycle)
;;; test-dape-lifecycle.el ends here
