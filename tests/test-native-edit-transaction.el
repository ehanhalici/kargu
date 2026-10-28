;;; test-native-edit-transaction.el --- Issued editor transaction pipe -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exercise the actual shared native gate and journal before an editor write.
;; Until positive receipts are implemented the only honest terminal report for
;; this controlled external effect is outcome_unknown, never applied success.

;;; Code:

(require 'tests/test-native-edit-prepare)
(require 'tests/test-native-edit-document)

(defun kargu-edit-transaction-test--call (artifact method arguments)
  "Call METHOD with ARGUMENTS under ARTIFACT's original scope in a test."
  (let ((reply (kargu-bridge-test--call
                (kargu-bridge-edit-artifact-connection artifact) method
                (kargu-bridge--object "scope" (kargu-bridge-edit-artifact-scope artifact)
                                      "arguments" arguments))))
    (should-not (cadr reply))
    (car reply)))

(ert-deftest kargu-native-edit-transaction-issued-crlf-save-real-pipe-test ()
  "Native preflight accepts real editor nanoseconds, then journal precedes IO."
  (kargu-bridge-test--with-core
    (kargu-edit-document-test--with-file "old\r\n"
      (let* ((app (kargu-application-create))
             (journal (make-temp-file "kargu-edit-journal-" t))
             (snapshot (kargu-bridge-edit-document-capture buffer))
             (arguments (kargu-edit-prepare-test--arguments directory "new 🦀\n"))
             task artifact failure finished)
        (unwind-protect
            (progn
              (set-file-modes journal #o700)
              (puthash "path" "source" (gethash "intent" arguments))
              (setq task (kargu-bridge-edit-prepare
                          app arguments '(("new" . "new 🦀\n"))
                          (lambda (value error-data)
                            (setq artifact value failure error-data finished t))))
              (kargu-bridge-test--wait (lambda () finished))
              (should-not failure)
              (let* ((origin (kargu-bridge-edit-artifact-origin artifact))
                     (authorization
                      (kargu-edit-transaction-test--call
                       artifact "edit/authorize"
                       (kargu-bridge--object "origin_id" origin "preparation_id"
                                             (kargu-bridge-edit-artifact-id artifact)
                                             "presenter" "missing")))
                     (edit (gethash "edit_id" authorization))
                     (revision (gethash "revision" authorization))
                     (preflight
                      (kargu-edit-transaction-test--call
                       artifact "edit/preflight"
                       (kargu-bridge--object
                        "origin_id" origin "edit_id" edit "revision" revision
                        "witness" (kargu-bridge-edit-document-witness snapshot 0))))
                     (issued
                      (kargu-edit-transaction-test--call
                       artifact "edit/issue"
                       (kargu-bridge--object "origin_id" origin "edit_id" edit "revision" revision
                                             "journal_directory" journal))))
                (should (equal (gethash "state" preflight) "preflighted"))
                (should (equal (gethash "state" issued) "issued"))
                (should (gethash "issued_token" issued))
                (should (= (length (directory-files journal nil (rx string-start (not (any "."))))) 1))
                (should (equal (buffer-string) "old\n"))
                (let (page received)
                  (kargu-bridge-edit-read artifact "proposed" 0
                                          (lambda (value error-data)
                                            (setq page value failure error-data received t)))
                  (kargu-bridge-test--wait (lambda () received))
                  (should-not failure)
                  (let ((change
                         (kargu-bridge-edit-document-replace
                          snapshot (gethash "text" page) :save t
                          :check-issued (lambda () (equal (gethash "state" issued) "issued")))))
                    (should-not (kargu-bridge-edit-document-change-failure change))
                    (should (equal (kargu-bridge-edit-document-text
                                    (kargu-bridge-edit-document-change-after change)) "new 🦀\n"))))
                (let ((terminal
                       (kargu-edit-transaction-test--call
                        artifact "edit/quiescent"
                        (kargu-bridge--object "origin_id" origin "edit_id" edit "revision" revision
                                              "issued_token" (gethash "issued_token" issued)
                                              "effect" "outcome_unknown"))))
                  (should (eq (gethash "journal_committed" terminal) t))
                  (should (equal (gethash "effect" terminal) "outcome_unknown"))))
              (should (equal (with-temp-buffer
                               (set-buffer-multibyte nil)
                               (insert-file-contents-literally file) (buffer-string))
                             (encode-coding-string "new 🦀\r\n" 'utf-8-unix))))
          (when task (kargu-async-cancel task))
          (when artifact (kargu-bridge-edit-release artifact))
          (delete-directory journal t))))))

(ert-deftest kargu-native-edit-transaction-stale-clean-buffer-hash-is-rejected-real-pipe-test ()
  "Equal byte counts and an unchanged tick cannot bless stale editor contents."
  (kargu-bridge-test--with-core
    (kargu-edit-document-test--with-file "old\n"
      (let* ((app (kargu-application-create))
             (arguments (kargu-edit-prepare-test--arguments directory "new\n"))
             task artifact failure finished)
        (unwind-protect
            (progn
              (write-region "alt\n" nil file nil 'silent)
              ;; Capture the old clean buffer against the new real disk version.
              (let ((snapshot (kargu-bridge-edit-document-capture buffer)))
                (should-not (kargu-bridge-edit-document-dirty snapshot))
                (puthash "path" "source" (gethash "intent" arguments))
                (setq task (kargu-bridge-edit-prepare
                            app arguments '(("new" . "new\n"))
                            (lambda (value error-data)
                              (setq artifact value failure error-data finished t))))
                (kargu-bridge-test--wait (lambda () finished))
                (should-not failure)
                (let* ((origin (kargu-bridge-edit-artifact-origin artifact))
                       (authorization
                        (kargu-edit-transaction-test--call
                         artifact "edit/authorize"
                         (kargu-bridge--object "origin_id" origin "preparation_id"
                                               (kargu-bridge-edit-artifact-id artifact)
                                               "presenter" "missing")))
                       (reply (kargu-bridge-test--call
                               conn "edit/preflight"
                               (kargu-bridge--object
                                "scope" (kargu-bridge-edit-artifact-scope artifact)
                                "arguments" (kargu-bridge--object
                                             "origin_id" origin "edit_id" (gethash "edit_id" authorization)
                                             "revision" (gethash "revision" authorization)
                                             "witness" (kargu-bridge-edit-document-witness snapshot 0))))))
                  (should-not (car reply))
                  (should (equal (gethash "status" (gethash "data" (cadr reply))) "conflict")))
                (should (equal (buffer-string) "old\n"))
                (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "alt\n"))))
          (when task (kargu-async-cancel task))
          (when artifact (kargu-bridge-edit-release artifact)))))))

(provide 'tests/test-native-edit-transaction)
;;; test-native-edit-transaction.el ends here
