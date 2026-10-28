;;; test-native-edit-patch.el --- Native supervised patch bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Native target discovery, named document upload and immutable batch pages.
;; No editor write or synchronous production wait is authorized by these handles.

;;; Code:

(require 'ert)
(require 'tests/test-native-edit-prepare)
(require 'kargu/bridge/edit/patch)

(defun kargu-edit-patch-test--arguments (root patch)
  "Build native ROOT/patch metadata for exact PATCH text."
  (let ((arguments (kargu-edit-prepare-test--arguments root "")))
    (puthash "intent" (kargu-bridge--object "kind" "patch" "patch_bytes" (string-bytes patch)) arguments)
    arguments))

(ert-deftest kargu-native-edit-patch-inspect-document-and-git-batch-real-pipe-test ()
  "The editor receives native targets and proposals without touching originals."
  (kargu-bridge-test--with-core
    (let* ((app (kargu-application-create))
           (root (make-temp-file "kargu-native-patch-" t))
           (file (expand-file-name "source" root))
           (patch "--- a/source\n+++ b/source\n@@ -1 +1 @@\n-old\n+new\n--- /dev/null\n+++ b/ö\n@@ -0,0 +1 @@\n+🦀\n")
           task artifact capture result failure finished)
      (unwind-protect
          (progn
            (write-region "old\n" nil file nil 'silent)
            ;; Obtain exact native stat evidence; its separate read-only handle is released.
            (let ((args (kargu-edit-prepare-test--arguments root "")))
              (puthash "path" "source" (gethash "intent" args))
              (setq task (kargu-bridge-edit-prepare app args '(("new" . ""))
                                                    (lambda (value error-data) (setq capture value failure error-data finished t))))
              (kargu-bridge-test--wait (lambda () finished))
              (should-not failure))
            (setq finished nil)
            (kargu-bridge-edit-release capture)
            (setq task (kargu-bridge-edit-patch-inspect
                        app (kargu-edit-patch-test--arguments root patch) patch
                        :callback (lambda (value error-data) (setq artifact value failure error-data finished t))))
            (kargu-bridge-test--wait (lambda () finished))
            (should-not failure)
            (should (eq (gethash "inspected" (kargu-bridge-edit-artifact-descriptor artifact)) t))
            (let (page received)
              (kargu-bridge-edit-patch-targets artifact 0
                                              (lambda (value error-data) (setq page value failure error-data received t)))
              (kargu-bridge-test--wait (lambda () received))
              (should-not failure)
              (should (equal (mapcar (lambda (file) (gethash "path" file)) (append (gethash "files" page) nil)) '("source" "ö"))))
            (setq finished nil)
            (let ((document (kargu-bridge--object
                             "id" "editor_document_12345678-1234-4234-8234-123456789abc"
                             "tick" 7 "bytes" 4 "coding" "utf-8-unix" "dirty" :json-false "read_only" :json-false
                             "disk" (gethash "disk" (kargu-bridge-edit-artifact-descriptor capture)))))
              (setq task (kargu-bridge-edit-patch-document
                          artifact "source" document :text "old\n"
                          :callback (lambda (value error-data) (setq result value failure error-data finished t))))
              (puthash "dirty" t document)
              (kargu-bridge-test--wait (lambda () finished))
              (should-not failure) (should (eq result artifact)))
            (setq finished nil)
            (setq task (kargu-bridge-edit-patch-prepare
                        artifact (lambda (value error-data) (setq result value failure error-data finished t))))
            (kargu-bridge-test--wait (lambda () finished))
            (should-not failure) (should (eq result artifact))
            (should (= (gethash "hunks_total" (kargu-bridge-edit-artifact-descriptor artifact)) 2))
            (let (page received)
              (kargu-bridge-edit-patch-files artifact 0 (lambda (value error-data) (setq page value failure error-data received t)))
              (kargu-bridge-test--wait (lambda () received))
              (should-not failure)
              (let ((views (gethash "files" page)))
                (should (equal (gethash "operation" (aref views 0)) "update"))
                (should (equal (gethash "operation" (aref views 1)) "add"))
                (should (= (gethash "tick" (gethash "document" (aref views 0))) 7))))
            (let (page received)
              (kargu-bridge-edit-patch-text artifact 1 "proposed" :offset 0
                                           :callback (lambda (value error-data) (setq page value failure error-data received t)))
              (kargu-bridge-test--wait (lambda () received))
              (should-not failure) (should (equal (gethash "text" page) "🦀\n")))
            (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "old\n"))
            (should-not (file-exists-p (expand-file-name "ö" root))))
        (when task (kargu-async-cancel task))
        (when artifact (kargu-bridge-edit-release artifact))
        (when capture (kargu-bridge-edit-release capture))
        (delete-directory root t)))))

(ert-deftest kargu-native-edit-patch-stale-document-ack-revokes-before-git-test ()
  "A stale document during upload cannot complete another native prepare."
  (kargu-bridge-test--with-core
    (let* ((app (kargu-application-create))
           (root (make-temp-file "kargu-native-patch-stale-" t))
           (patch "--- /dev/null\n+++ b/target\n@@ -0,0 +1 @@\n+new\n")
           (call (symbol-function 'kargu-bridge-call))
           (valid t) task artifact held finished failure prepared)
      (unwind-protect
          (progn
            (setq task (kargu-bridge-edit-patch-inspect
                        app (kargu-edit-patch-test--arguments root patch) patch
                        :callback (lambda (value error-data) (setq artifact value failure error-data finished t))))
            (kargu-bridge-test--wait (lambda () finished))
            (should-not failure) (setq finished nil)
            (cl-letf (((symbol-function 'kargu-bridge-call)
                       (lambda (connection method params callback &rest options)
                         (when (equal method "edit/prepare") (setq prepared t))
                         (apply call connection method params
                                (if (equal method "edit/append")
                                    (lambda (value error-data) (setq held (lambda () (funcall callback value error-data))))
                                  callback) options))))
              (setq task (kargu-bridge-edit-patch-document
                          artifact "target"
                          (kargu-bridge--object "id" "editor_document_12345678-1234-4234-8234-123456789abc" "tick" 1
                                                "bytes" 1 "coding" "utf-8-unix" "dirty" :json-false "read_only" :json-false
                                                "disk" (kargu-bridge--object "kind" "absent"))
                          :text "x" :valid-p (lambda () valid)
                          :callback (lambda (_value error-data) (setq failure error-data finished t))))
              (kargu-bridge-test--wait (lambda () held))
              (setq valid nil)
              (funcall held)
              (kargu-bridge-test--wait (lambda () finished)))
            (should failure) (should-not prepared)
            (should (kargu-bridge-edit-artifact-released artifact))
            (let (received error-data)
              (kargu-bridge-edit-patch-targets artifact 0 (lambda (_value failure) (setq received t error-data failure)))
              (should received) (should error-data))
            (should-not (file-exists-p (expand-file-name "target" root))))
        (when task (kargu-async-cancel task))
        (when artifact (kargu-bridge-edit-release artifact))
        (delete-directory root t)))))

(ert-deftest kargu-native-edit-patch-old-core-has-no-local-parser-or-owner-acquisition-test ()
  "The plain preparation capability does not imply native patch support."
  (let (failure)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback)
                 (funcall callback (kargu-bridge--connection-create :state 'ready :capabilities ["edit_preparation"]) nil)
                 #'ignore))
              ((symbol-function 'kargu-bridge-application-ensure) (lambda (&rest _) (ert-fail "No owner")))
              ((symbol-function 'kargu-diff--patch-parse) (lambda (&rest _) (ert-fail "No local parser"))))
      (let ((task (kargu-bridge-edit-patch-inspect
                   (kargu-application-create) (kargu-edit-patch-test--arguments "/synthetic" "") ""
                   :callback (lambda (_value error-data) (setq failure error-data)))))
        (should-not (kargu-async-pending-p task))
        (should (equal (gethash "status" (gethash "data" failure)) "unsupported_edit_preparation"))))))

(provide 'tests/test-native-edit-patch)
;;; test-native-edit-patch.el ends here
