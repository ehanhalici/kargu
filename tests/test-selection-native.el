;;; test-selection-native.el --- Native selection writer cutover -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The editor publishes only native acknowledgements.  Real-core cases use
;; the Rust conversation port; queue and refusal cases use explicit ports.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'tests/test-bridge)
(require 'kargu/selection)
(require 'kargu/bridge/selection)
(require 'kargu/chat)

(defmacro kargu-selection-native-test--with-core (&rest body)
  "Run BODY in a buffer whose selection port is the real Rust conversation."
  (declare (indent 0) (debug t))
  `(let ((binary (getenv "KARGU_CORE_TEST_BINARY")))
     (unless (and binary (file-executable-p binary))
       (ert-skip "A configured native test binary is required"))
     (let ((kargu-bridge-binary-path binary)
           (kargu-selection-port #'kargu-selection--native-port))
       (with-temp-buffer ,@body))))

(defun kargu-selection-native-test--commit (&rest arguments)
  "Apply `kargu-selection-update' to ARGUMENTS; return (SELECTION FAILURE)."
  (let (reply)
    (apply #'kargu-selection-update
           (append arguments (list :callback (lambda (selection failure)
                                               (setq reply (list selection failure))))))
    (kargu-bridge-test--wait (lambda () reply))
    reply))

(defun kargu-selection-native-test--native-view ()
  "Read the current session's committed selection directly from Rust."
  (let* ((application (kargu-application-context))
         (binding (gethash application (kargu-session-native-conversations (kargu-session-context))))
         (connection (kargu-bridge-conversation-connection binding))
         (reply (kargu-bridge-test--call
                 connection "session/selection"
                 (kargu-bridge-application--copy-scope (kargu-bridge-conversation-scope binding)))))
    (should-not (cadr reply))
    (car reply)))

(ert-deftest kargu-selection-native-commit-publishes-only-the-acknowledgement-test ()
  "The committed view changes after Rust acknowledges, in Rust's canonical form."
  (kargu-selection-native-test--with-core
    (let (reply events)
      (let ((kargu-state-change-hook (list (lambda (key _) (push key events)))))
        (should-not (kargu-selection-update
                     :provider "OpenAI" :model "gpt-x" :effort 'high
                     :callback (lambda (selection failure) (setq reply (list selection failure)))))
        (should-not (kargu-selection-provider))
        (should-not events)
        (kargu-bridge-test--wait (lambda () reply)))
      (should-not (cadr reply))
      (should (eq (car reply) (kargu-selection-context)))
      (should (equal (kargu-selection-provider) "openai"))
      (should (equal (kargu-selection-model) "gpt-x"))
      (should (eq (kargu-selection-effort) 'high))
      (should (equal (nreverse events) '(:provider :model :reasoning-effort)))
      (let ((native (kargu-selection-native-test--native-view)))
        (should (= (gethash "revision" native) 1))
        (should (equal (gethash "provider" (gethash "selection" native)) "openai"))))))

(ert-deftest kargu-selection-native-effort-states-round-trip-test ()
  "Inherited, explicitly disabled and named effort stay distinct through Rust."
  (kargu-selection-native-test--with-core
    (should-not (cadr (kargu-selection-native-test--commit :effort nil)))
    (should (null (kargu-selection-effort-value (kargu-selection-context))))
    (should-not (cadr (kargu-selection-native-test--commit :effort 'xhigh)))
    (should (eq (kargu-selection-effort-value (kargu-selection-context)) 'xhigh))
    (should-not (cadr (kargu-selection-native-test--commit :effort kargu-selection-default-effort)))
    (should (eq (kargu-selection-effort-value (kargu-selection-context))
                kargu-selection-default-effort))
    (should (equal (gethash "kind" (gethash "effort" (gethash "selection" (kargu-selection-native-test--native-view))))
                   "inherit"))))

(ert-deftest kargu-selection-native-refusal-keeps-the-committed-value-test ()
  "A value Rust rejects never appears locally and the next intent still works."
  (kargu-selection-native-test--with-core
    (should-not (cadr (kargu-selection-native-test--commit :provider "alpha" :model "a")))
    (let ((before (kargu-selection-context))
          (refused (kargu-selection-native-test--commit :model "contains\nnewline")))
      (should-not (car refused))
      (should (equal (gethash "status" (gethash "data" (cadr refused))) "invalid_params"))
      (should (eq before (kargu-selection-context))))
    (should-not (cadr (kargu-selection-native-test--commit :model "b")))
    (should (equal (kargu-selection-model) "b"))
    (should (equal (kargu-selection-provider) "alpha"))
    (should (= (gethash "revision" (kargu-selection-native-test--native-view)) 2))))

(ert-deftest kargu-selection-native-intents-are-serial-and-merge-from-acknowledgements-test ()
  "A second intent waits and merges its fields into the first acknowledgement."
  (with-temp-buffer
    (let* (pending sent
           (kargu-selection-port
            (lambda (_session desired callback)
              (push desired sent)
              (setq pending (lambda () (funcall callback desired nil))))))
      (kargu-selection-update :provider "p" :model "m")
      (kargu-selection-update :effort 'low)
      (should (= (length sent) 1))
      (should-not (kargu-selection-provider))
      (funcall pending)
      (should (equal (kargu-selection-model) "m"))
      (should (= (length sent) 2))
      (let ((second (car sent)))
        (should (equal (kargu-selection-provider-value second) "p"))
        (should (equal (kargu-selection-model-value second) "m"))
        (should (eq (kargu-selection-effort-value second) 'low)))
      (funcall pending)
      (should (eq (kargu-selection-effort) 'low)))))

(ert-deftest kargu-selection-native-port-failure-reports-without-local-write-test ()
  "A failing port leaves the value unchanged and reports through the callback."
  (with-temp-buffer
    (let ((kargu-selection-port (lambda (&rest _) (error "Port unavailable")))
          (before (kargu-selection-context)) reply)
      (kargu-selection-update :model "m" :callback (lambda (s f) (setq reply (list s f))))
      (should-not (car reply))
      (should (stringp (cadr reply)))
      (should (eq before (kargu-selection-context))))))

(defun kargu-selection-native-test--load (data)
  "Load alist DATA into the current chat and return its buffer or error."
  (kargu-test-await
   (lambda (done)
     (condition-case err
         (kargu-session-load data (current-buffer) default-directory
                             :callback (lambda (buffer error) (funcall done (or buffer error))))
       (error (funcall done (error-message-string err)))))
   10))

(ert-deftest kargu-selection-native-restore-seeds-through-rust-test ()
  "Restore commits its saved choice natively and refuses to publish a rejection."
  (kargu-selection-native-test--with-core
    (let ((kargu-session-auto-save nil) (kargu-state-before-mode-change-hook nil))
      (cl-letf (((symbol-function 'kargu-api-prefetch-models) #'ignore))
        (kargu-chat-mode))
      (let ((buffer (kargu-selection-native-test--load
                     '(("id" . "restored") ("mode" . "ask") ("provider" . "Restored")
                       ("model" . "kept") ("transcript" . "t\n") ("messages" . [])))))
        (should (bufferp buffer))
        (with-current-buffer buffer
          (should (equal (kargu-selection-provider) "restored"))
          (should (equal (kargu-selection-model) "kept"))
          (should (= (gethash "revision" (kargu-selection-native-test--native-view)) 1))
          (let* ((owner (kargu-session-context))
                 (result (kargu-selection-native-test--load
                          '(("id" . "bad") ("mode" . "ask") ("model" . "a\tb")
                            ("transcript" . "") ("messages" . [])))))
            (should (stringp result))
            (should (string-match-p "refused" result))
            (should (eq owner (kargu-session-context)))
            (should (equal (kargu-selection-model) "kept"))))))))

(provide 'tests/test-selection-native)
;;; test-selection-native.el ends here
