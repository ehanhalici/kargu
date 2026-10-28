;;; test-native-edit-transaction.el --- Issued editor transaction pipe -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Exercise the actual shared native gate and journal before an editor write.
;; Bounded receipt verification streams observations to `edit/receipt` and commits
;; a durable receipt digest.  Only the verified native outcome establishes apply.

;;; Code:

(require 'tests/test-native-edit-prepare)
(require 'tests/test-native-edit-document)
(require 'kargu/bridge/edit/activity)

(defun kargu-edit-transaction-test--call (artifact method arguments)
  "Call METHOD with ARGUMENTS under ARTIFACT's original scope in a test."
  (let ((reply (kargu-bridge-test--call
                (kargu-bridge-edit-artifact-connection artifact) method
                (kargu-bridge--object "scope" (kargu-bridge-edit-artifact-scope artifact)
                                      "arguments" arguments))))
    (should-not (cadr reply))
    (car reply)))

(defun kargu-edit-transaction-test--read-proposal (artifact)
  "Read ARTIFACT's complete immutable proposal, including tiny-frame pages."
  (let ((offset 0) (text "") complete)
    (while (not complete)
      (let (page failure received)
        (kargu-bridge-edit-read artifact "proposed" offset
                                (lambda (value error-data)
                                  (setq page value failure error-data received t)))
        (kargu-bridge-test--wait (lambda () received))
        (should-not failure)
        (setq text (concat text (gethash "text" page))
              offset (gethash "next_offset" page)
              complete (eq (gethash "complete" page) t))))
    text))

(defun kargu-edit-transaction-test--issued-crlf-save (text)
  "Write TEXT through real issuance, native receipt and CRLF editor save."
  (kargu-bridge-test--with-core
   (kargu-edit-document-test--with-file "old\r\n"
					(let* ((app (kargu-application-create))
					       (journal (make-temp-file "kargu-edit-journal-" t))
					       (snapshot (kargu-bridge-edit-document-capture buffer))
					       (arguments (kargu-edit-prepare-test--arguments directory text))
					       task artifact failure finished)
					  (unwind-protect
					      (progn
						(set-file-modes journal #o700)
						(puthash "path" "source" (gethash "intent" arguments))
						(setq task (kargu-bridge-edit-prepare
							    app arguments (list (cons "new" text))
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
							  "witness" (kargu-bridge-edit-document-witness snapshot 0)))))
						  (should (equal (gethash "state" preflight) "preflighted"))
						  (should (equal (buffer-string) "old\n"))
						  (let ((proposal (kargu-edit-transaction-test--read-proposal artifact)))
                  (let (activity result settled)
						      (setq activity
							    (kargu-bridge-edit-activity-start
							     artifact :edit-id edit :revision revision :buffer buffer
							     :preflight-digest (gethash "preflight_digest" (gethash "preflight" preflight))
							     :journal-directory journal
							     :handler (lambda (live-p)
									(should (= (length (directory-files journal nil
													    (rx string-start (not (any "."))))) 1))
									(kargu-bridge-edit-document-replace
									 snapshot proposal :save t :check-issued live-p))
							     :callback (lambda (value error-data)
									 (setq result value failure error-data settled t))))
						      (kargu-bridge-test--wait (lambda () settled))
						      (should-not failure)
						      (should (eq (kargu-bridge-edit-activity-state activity) :finished))
						      (should-not kargu-bridge-edit-activity--active)
						      (let ((change (plist-get result :observation))
							    (terminal (plist-get result :native)))
							(should-not (kargu-bridge-edit-document-change-failure change))
							(should (equal (kargu-bridge-edit-document-text
									(kargu-bridge-edit-document-change-after change)) text))
							(should (eq (gethash "journal_committed" terminal) t))
							(should (equal (gethash "outcome" (gethash "receipt" terminal)) "applied_full"))))))
						(should (equal (with-temp-buffer
								 (set-buffer-multibyte nil)
								 (insert-file-contents-literally file) (buffer-string))
							       (encode-coding-string (replace-regexp-in-string (rx "\n") "\r\n" text t t) 'utf-8-unix))))
					    (when task (kargu-async-cancel task))
					    (when artifact (kargu-bridge-edit-release artifact))
					    (delete-directory journal t))))))

(ert-deftest kargu-native-edit-transaction-issued-crlf-save-real-pipe-test ()
  (kargu-edit-transaction-test--issued-crlf-save "new 🦀\n"))

(ert-deftest kargu-native-edit-transaction-tiny-frames-stream-real-receipt-test ()
  "Exercise negotiated 1 KiB edit frames independently of catalog hydration."
  (let ((kargu-bridge--max-frame 1024))
    ;; The unrelated unpaged provider/catalog response exceeds this frame size.
    ;; Keep real native handshake/read scope; isolate only provider hydration.
    (cl-letf (((symbol-function 'kargu-bridge--start-finish)
               (lambda (connection callback failure)
                 (kargu-bridge--start-ready connection callback failure))))
      (kargu-edit-transaction-test--issued-crlf-save
       (apply #'concat (make-list 400 "🦀\\\"\n"))))))

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
