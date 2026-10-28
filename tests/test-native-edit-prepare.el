;;; test-native-edit-prepare.el --- Real pipe edit preparation transport -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Synthetic text crosses bounded frames.  Preparation has no write authority.

;;; Code:

(require 'ert)
(require 'tests/test-bridge)
(require 'kargu/bridge/edit)

(defun kargu-edit-prepare-test--arguments (root text)
  "Build native write metadata for ROOT and decoded TEXT."
  (kargu-bridge--object
   "origin_id" "editor_source_12345678-1234-4234-8234-123456789abc"
   "root" root "mode" "agent" "live" :json-null
   "intent" (kargu-bridge--object "kind" "write" "path" "target" "new_bytes" (string-bytes text))
   "config_revision" 0 "policy_revision" 0 "review_mode" "auto" "save_policy" "save"))

(ert-deftest kargu-native-edit-prepare-detaches-parts-pumps-bounded-frames-and-keeps-original-test ()
  "Mutable inputs, Unicode byte boundaries and heartbeat survive a held ACK."
  (kargu-bridge-test--with-core
    (let* ((app (kargu-application-create))
           (root (make-temp-file "kargu-native-edit-" t))
           (text (apply #'concat (make-list 16000 "é🦀\n\"\\")))
           (expected (copy-sequence text))
           (arguments (kargu-edit-prepare-test--arguments root text))
           (call (symbol-function 'kargu-bridge-call))
           (appends 0) held task artifact failure done)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-bridge-call)
                     (lambda (connection method params callback &rest options)
                       (when (equal method "edit/append")
                         (cl-incf appends)
                         (should (<= (string-bytes (gethash "text" (gethash "arguments" params))) 32768)))
                       (apply call connection method params
                              (if (and (equal method "edit/append") (= appends 1))
                                  (lambda (value error-data) (setq held (lambda () (funcall callback value error-data))))
                                callback) options))))
            (setq task (kargu-bridge-edit-prepare
                        app arguments (list (cons "new" text))
                        (lambda (value error-data) (setq artifact value failure error-data done t))))
            ;; These are caller-owned inputs, detached before startup/first ACK.
            (aset text 0 ?X)
            (puthash "mode" "ask" arguments)
            (kargu-bridge-test--wait (lambda () held))
            (should (= appends 1))
            (should (equal (gethash "status" (car (kargu-bridge-test--call conn "ping" (kargu-bridge--object)))) "ok"))
            (should (= appends 1))
            (funcall held)
            (kargu-bridge-test--wait (lambda () done))
            (should-not failure)
            (should (kargu-bridge-edit-artifact-p artifact))
            (should-not (kargu-bridge-edit-artifact-released artifact))
            (should (eq (gethash "applied" (kargu-bridge-edit-artifact-descriptor artifact)) :json-false))
            (let ((offset 0) (captured "") complete)
              (while (not complete)
                (let (page error-data received)
                  (kargu-bridge-edit-read artifact "proposed" offset
                                          (lambda (value failure) (setq page value error-data failure received t)))
                  (kargu-bridge-test--wait (lambda () received))
                  (should-not error-data)
                  (should (= (gethash "offset" page) offset))
                  (setq captured (concat captured (gethash "text" page))
                        offset (gethash "next_offset" page)
                        complete (eq (gethash "complete" page) t))))
              (should (equal captured expected)))
            (should (= (aref text 0) ?X))
            (should-not (file-exists-p (expand-file-name "target" root)))
            (kargu-bridge-edit-release artifact)
            (should (kargu-bridge-edit-artifact-released artifact)))
        (when task (kargu-async-cancel task))
        (when artifact (kargu-bridge-edit-release artifact))
        (delete-directory root t)))))

(ert-deftest kargu-native-edit-prepare-cancelled-late-allocation-is-aborted-test ()
  "A cancelled begin callback releases its late ticket without delivering it."
  (kargu-bridge-test--with-core
    (let* ((app (kargu-application-create))
           (root (make-temp-file "kargu-native-edit-late-" t))
           (call (symbol-function 'kargu-bridge-call)) held task ticket scope aborted delivered)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-bridge-call)
                     (lambda (connection method params callback &rest options)
                       (apply call connection method params
                              (cond
                               ((equal method "edit/begin")
                                (lambda (value failure)
                                  (setq ticket (gethash "preparation_id" value)
                                        scope (gethash "scope" params)
                                        held (lambda () (funcall callback value failure)))))
                               ((equal method "edit/abort")
                                (lambda (value failure) (setq aborted t) (funcall callback value failure)))
                               (t callback)) options))))
            (setq task (kargu-bridge-edit-prepare app (kargu-edit-prepare-test--arguments root "")
                                                  '(("new" . "")) (lambda (&rest _) (setq delivered t))))
            (kargu-bridge-test--wait (lambda () held))
            (kargu-async-cancel task)
            (funcall held)
            (kargu-bridge-test--wait (lambda () aborted))
            (should-not delivered)
            (should-not (kargu-async-task-timer task))
            (let ((reply (kargu-bridge-test--call
                          conn "edit/prepare"
                          (kargu-bridge--object "scope" scope "arguments"
                                                (kargu-bridge--object "origin_id" "editor_source_12345678-1234-4234-8234-123456789abc"
                                                                      "preparation_id" ticket)))))
              (should (equal (gethash "status" (gethash "data" (cadr reply))) "stale_owner"))))
        (when task (kargu-async-cancel task))
        (delete-directory root t)))))

(ert-deftest kargu-native-edit-prepare-stale-capture-cannot-send-next-part-or-prepare-test ()
  "A changed document guard revokes the ticket at the next ACK boundary."
  (kargu-bridge-test--with-core
    (let* ((app (kargu-application-create))
           (root (make-temp-file "kargu-native-edit-stale-" t))
           (text (make-string 70000 ?x)) (valid t)
           (call (symbol-function 'kargu-bridge-call)) held task (appends 0) prepared aborted failure done)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-bridge-call)
                     (lambda (connection method params callback &rest options)
                       (when (equal method "edit/append") (cl-incf appends))
                       (when (equal method "edit/prepare") (setq prepared t))
                       (apply call connection method params
                              (cond
                               ((equal method "edit/append")
                                (lambda (value error-data) (setq held (lambda () (funcall callback value error-data)))))
                               ((equal method "edit/abort")
                                (lambda (value error-data) (setq aborted t) (funcall callback value error-data)))
                               (t callback)) options))))
            (setq task (kargu-bridge-edit-prepare
                        app (kargu-edit-prepare-test--arguments root text) (list (cons "new" text))
                        (lambda (_value error-data) (setq failure error-data done t)) :valid-p (lambda () valid)))
            (kargu-bridge-test--wait (lambda () held))
            (setq valid nil)
            (funcall held)
            (kargu-bridge-test--wait (lambda () (and done aborted)))
            (should failure) (should (= appends 1)) (should-not prepared)
            (should-not (file-exists-p (expand-file-name "target" root))))
        (when task (kargu-async-cancel task))
        (delete-directory root t)))))

(ert-deftest kargu-native-edit-prepare-missing-capability-does-not-create-owner-or-read-files-test ()
  "An older core reports unavailable without acquiring a lease or local fallback."
  (let (failure)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback)
                 (funcall callback (kargu-bridge--connection-create :state 'ready :capabilities []) nil) #'ignore))
              ((symbol-function 'kargu-bridge-application-ensure) (lambda (&rest _) (ert-fail "No lease")))
              ((symbol-function 'insert-file-contents) (lambda (&rest _) (ert-fail "No local file fallback"))))
      (let ((task (kargu-bridge-edit-prepare (kargu-application-create)
                                            (kargu-edit-prepare-test--arguments "/synthetic" "")
                                            '(("new" . "")) (lambda (_value error-data) (setq failure error-data)))))
        (should-not (kargu-async-pending-p task))
        (should (equal (gethash "status" (gethash "data" failure)) "unsupported_edit_preparation"))))))

(ert-deftest kargu-native-edit-prepare-oversized-text-refuses-before-copy-or-startup-test ()
  "Oversized caller text never enters the UTF-8 copy or native startup path."
  (let ((text (make-string (1+ kargu-bridge-edit--text-bytes) ?x)) failure)
    (cl-letf (((symbol-function 'kargu-bridge-ensure) (lambda (&rest _) (ert-fail "No startup")))
              ((symbol-function 'encode-coding-string) (lambda (&rest _) (ert-fail "No oversized encode"))))
      (let ((task (kargu-bridge-edit-prepare
                   (kargu-application-create) (kargu-edit-prepare-test--arguments "/synthetic" "")
                   (list (cons "new" text)) (lambda (_value error-data) (setq failure error-data)))))
        (should-not (kargu-async-pending-p task))
        (should (equal (gethash "status" (gethash "data" failure)) "invalid_edit_upload"))
        (should (= (aref text 0) ?x))))))

(provide 'tests/test-native-edit-prepare)
;;; test-native-edit-prepare.el ends here
