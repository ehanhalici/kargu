;;; test-native-edit-batch.el --- Production batch execution pipe tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Real pipe tests for `kargu/bridge/edit/batch`:
;; - single-file replace and write transactions
;; - multi-file patch batch with real hunk counts
;; - native rollback and foreign-modification conflict protection

;;; Code:

(require 'ert)
(require 'kargu)
(require 'tests/test-helpers)
(require 'tests/test-bridge)
(require 'kargu/core)
(require 'kargu/permission)
(require 'kargu/tools/diff)
(require 'kargu/tools/diff/context)
(require 'kargu/tools/diff/track)
(require 'kargu/bridge/edit)
(require 'kargu/bridge/edit/batch)
(require 'kargu/bridge/edit/document)

(defvar kargu-permission--override-root)
(defvar kargu-diff-review-mode)
(declare-function kargu-test-mode "tests/test-helpers" (mode))
(declare-function kargu-diff--edit-file-tool "kargu/tools/diff" (args &optional callback))
(declare-function kargu-diff--write-file-tool "kargu/tools/diff" (args &optional callback))
(declare-function kargu-diff--apply-patch-tool "kargu/tools/diff" (args &optional callback))
(declare-function kargu-diff-submit-edit "kargu/tools/diff" (request))
(declare-function kargu-diff-rollback "kargu/tools/diff/track" (file-path &optional single-step service &rest options))

(defmacro kargu-native-edit-test--with-core (&rest body)
  "Run BODY with a real core and an isolated persistent journal directory."
  (declare (indent 0) (debug t))
  `(let ((kargu-bridge-edit-batch-journal-directory (make-temp-file "kargu-batch-journals-" t))
         (kargu-diff-native-edit-enabled t)
         (kargu-diff-review-mode 'auto) (kargu-diff-auto-save t)
         (existing-buffers (buffer-list)))
     (unwind-protect
         (kargu-bridge-test--with-core
          (kargu-test-mode 'agent)
          ,@body)
       (dolist (buffer (buffer-list))
         (when (and (not (memq buffer existing-buffers)) (buffer-file-name buffer))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory kargu-bridge-edit-batch-journal-directory t))))

(defun kargu-native-edit-test--await (start)
  "Run asynchronous START and wait in the test event loop with a deadline."
  (let (done value failure)
    (funcall start (lambda (result error-data) (setq done t value result failure error-data)))
    (kargu-bridge-test--wait (lambda () done))
    (should-not failure)
    value))

(defun kargu-native-edit-test--execute (spec)
  "Await SPEC only in this test helper; production returns its task."
  (kargu-native-edit-test--await
   (lambda (callback) (kargu-bridge-edit-batch-execute spec callback))))

(defun kargu-native-edit-test--tool (function arguments)
  "Await tool FUNCTION with ARGUMENTS through its asynchronous contract."
  (kargu-native-edit-test--await
   (lambda (callback)
     (let ((done (lambda (result) (funcall callback result nil))))
       (if (eq function #'kargu-diff-submit-edit)
           (funcall function (kargu-edit-request-create :path (kargu-edit-request-path arguments)
							:content (kargu-edit-request-content arguments) :callback done))
         (funcall function arguments done))))))

(ert-deftest kargu-native-edit-batch-replace-real-pipe-test ()
  "Execute an atomic single-file replace transaction through the real native pipe."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-batch-replace-" t))
          (file (expand-file-name "test.txt" root))
          (initial "line 1\nold target line\nline 3\n")
          (expected "line 1\nnew replaced line\nline 3\n"))
     (unwind-protect
         (progn
           (write-region initial nil file nil 'silent)
           (let ((res (kargu-native-edit-test--execute
                       (list :intent :replace
                             :root root :path file
                             :old "old target line\n"
                             :new "new replaced line\n"
                             :save-policy 'save
                             :review-mode 'auto))))
             (should (eq (plist-get res :status) :applied-full))
             (should (equal (plist-get res :file) file))
             (should (= (plist-get res :files-applied) 1))
             (should-not (integerp (plist-get res :hunks-applied)))
             (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                            expected))))
       (delete-directory root t)))))

(ert-deftest kargu-native-edit-batch-write-real-pipe-test ()
  "Execute a full write transaction through the real native pipe."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-batch-write-" t))
          (file (expand-file-name "created.txt" root))
          (content "hello from native write\nline 2\n"))
     (unwind-protect
         (let ((res (kargu-native-edit-test--execute
                     (list :intent :write
                           :root root :path file
                           :content content
                           :save-policy 'save
                           :review-mode 'auto))))
           (should (eq (plist-get res :status) :applied-full))
           (should (= (plist-get res :files-applied) 1))
           (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                          content)))
       (delete-directory root t)))))

(ert-deftest kargu-native-edit-batch-patch-and-rollback-real-pipe-test ()
  "Apply multi-file patch batch and verify inverse rollback and conflict detection."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-batch-patch-" t))
          (file-a (expand-file-name "file_a.txt" root))
          (file-b (expand-file-name "file_b.txt" root))
          (file-c (expand-file-name "file_c.txt" root))
          (patch (concat "--- a/file_a.txt\n+++ b/file_a.txt\n@@ -1 +1 @@\n-alpha\n+ALPHA\n"
                         "--- /dev/null\n+++ b/file_b.txt\n@@ -0,0 +1 @@\n+bravo\n"
                         "--- a/file_c.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-charlie\n")))
     (unwind-protect
         (progn
           (write-region "alpha\n" nil file-a nil 'silent)
           (write-region "charlie\n" nil file-c nil 'silent)
           ;; 1. Apply multi-file patch batch
           (let ((res (kargu-native-edit-test--execute
                       (list :intent :patch
                             :root root
                             :patch patch
                             :save-policy 'save
                             :review-mode 'auto))))
             (should (eq (plist-get res :status) :applied-full))
             (should (= (plist-get res :files-total) 3))
             (should (= (plist-get res :files-applied) 3))
             (should (= (plist-get res :hunks-applied) 3))
             (should (equal (with-temp-buffer (insert-file-contents file-a) (buffer-string)) "ALPHA\n"))
             (should (equal (with-temp-buffer (insert-file-contents file-b) (buffer-string)) "bravo\n"))
             (should-not (file-exists-p file-c)))
           ;; 2. Roll back applied batch
           (let ((rb-res (kargu-native-edit-test--execute
                          (list :intent :rollback
                                :root root
                                :save-policy 'save
                                :review-mode 'auto))))
             (should (eq (plist-get rb-res :status) :applied-full))
             (should (= (plist-get rb-res :files-applied) 3))
             (should (equal (with-temp-buffer (insert-file-contents file-a) (buffer-string)) "alpha\n"))
             (should-not (file-exists-p file-b))
             (should (equal (with-temp-buffer (insert-file-contents file-c) (buffer-string)) "charlie\n"))))
       (delete-directory root t)))))

(ert-deftest kargu-native-edit-file-tool-consumer-test ()
  "Execute `edit_file' tool via native bridge and verify typed outcome and disk save."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-tool-edit-" t))
          (file (expand-file-name "hello.txt" root))
          (kargu-permission--override-root root)
          (kargu-diff-review-mode 'auto)
          (_ (kargu-test-mode 'agent)))
     (unwind-protect
         (progn
           (write-region "Hello world!\n" nil file nil 'silent)
           (let ((res (kargu-native-edit-test--tool #'kargu-diff--edit-file-tool
						    `(("file_path" . ,file)
						      ("old_string" . "world")
						      ("new_string" . "native agentic kargu")))))
             (should (stringp res))
             (should (string-search "APPLIED" res))
             (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                            "Hello native agentic kargu!\n"))))
       (delete-directory root t)))))

(ert-deftest kargu-native-write-file-tool-consumer-test ()
  "Execute `write_file' tool via native bridge and verify disk save."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-tool-write-" t))
          (file (expand-file-name "created.txt" root))
          (kargu-permission--override-root root)
          (kargu-diff-review-mode 'auto)
          (_ (kargu-test-mode 'agent)))
     (unwind-protect
         (let ((res (kargu-native-edit-test--tool #'kargu-diff--write-file-tool
						  `(("file_path" . ,file)
						    ("contents" . "brand new file written natively\n")))))
           (should (stringp res))
           (should (string-search "APPLIED" res))
           (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                          "brand new file written natively\n")))
       (delete-directory root t)))))

(ert-deftest kargu-native-apply-patch-tool-consumer-test ()
  "Execute `apply_patch' tool via native bridge and verify batch summary and hunk counts."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-tool-patch-" t))
          (file-a (expand-file-name "mod.txt" root))
          (file-b (expand-file-name "del.txt" root))
          (kargu-permission--override-root root)
          (kargu-diff-review-mode 'auto)
          (_ (kargu-test-mode 'agent))
          (patch (concat "--- a/mod.txt\n+++ b/mod.txt\n@@ -1 +1 @@\n-old line\n+new line\n"
                         "--- a/del.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-remove me\n"
                         "--- /dev/null\n+++ b/add.txt\n@@ -0,0 +1 @@\n+added line\n")))
     (unwind-protect
         (progn
           (write-region "old line\n" nil file-a nil 'silent)
           (write-region "remove me\n" nil file-b nil 'silent)
           (let ((res (kargu-native-edit-test--tool #'kargu-diff--apply-patch-tool `(("patch" . ,patch)))))
             (should (stringp res))
             (should (string-search "Patch successfully applied" res))
             (should (string-search "3 file(s)" res))
             (should (string-search "3/3 hunks applied" res))
             (should (equal (with-temp-buffer (insert-file-contents file-a) (buffer-string)) "new line\n"))
             (should-not (file-exists-p file-b))
             (should (equal (with-temp-buffer (insert-file-contents (expand-file-name "add.txt" root)) (buffer-string)) "added line\n"))))
       (delete-directory root t)))))

(ert-deftest kargu-native-diff-rollback-consumer-test ()
  "Verify `kargu-diff-rollback' rolls back a natively applied edit."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-tool-rollback-" t))
          (file (expand-file-name "rolled.txt" root))
          (kargu-permission--override-root root)
          (kargu-diff-review-mode 'auto)
          (_ (kargu-test-mode 'agent)))
     (unwind-protect
         (progn
           (write-region "initial baseline\n" nil file nil 'silent)
           ;; 1. Edit file
           (let ((res (kargu-native-edit-test--tool #'kargu-diff--edit-file-tool
						    `(("file_path" . ,file)
						      ("old_string" . "initial baseline\n")
						      ("new_string" . "mutated content\n")))))
             (should (string-search "APPLIED" res))
             (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                            "mutated content\n")))
           ;; 2. Roll back via kargu-diff-rollback
           (let ((rolled (progn (kargu-native-edit-test--await
                                 (lambda (done) (kargu-diff-rollback file nil nil :callback
                                                                     (lambda (result) (funcall done result nil))))) file)))
             (should (equal rolled file))
             (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                            "initial baseline\n"))))
       (delete-directory root t)))))

(ert-deftest kargu-native-lsp-symbol-edit-consumer-test ()
  "Verify LSP edit submission routes through native bridge."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-tool-lsp-" t))
          (file (expand-file-name "module.py" root))
          (kargu-permission--override-root root)
          (kargu-diff-review-mode 'auto)
          (_ (kargu-test-mode 'agent)))
     (unwind-protect
         (progn
           (write-region "def foo():\n    return 1\n" nil file nil 'silent)
           (let* ((req (kargu-edit-request-create
                        :path file
                        :content "def foo():\n    return 42\n"))
                  (res (kargu-native-edit-test--tool #'kargu-diff-submit-edit req)))
             (should (stringp res))
             (should (string-search "APPLIED" res))
             (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                            "def foo():\n    return 42\n"))))
       (delete-directory root t)))))

(ert-deftest kargu-native-revised-review-real-pipe-test ()
  "Verify revised Ediff review: edit/revise bumps revision and updates proposal."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-batch-revise-" t))
          (file (expand-file-name "review_file.txt" root))
          (app (kargu-application-context))
          (origin (kargu-bridge-edit-batch--random-origin))
          (rel (file-relative-name file root))
          (orig-content "def calculate():\n    return 41\n")
          (proposed "def calculate():\n    return 42\n")
          (user-revised "def calculate():\n    return 100  # revised by human in review\n"))
     (unwind-protect
         (progn
           (write-region orig-content nil file nil 'silent)
           ;; 1. Prepare replace proposal
           (let* ((args (kargu-bridge--object
                         "origin_id" origin "root" root "mode" "agent" "live" :json-null
                         "intent" (kargu-bridge--object "kind" "replace" "path" rel
                                                        "old_bytes" (string-bytes orig-content)
                                                        "new_bytes" (string-bytes proposed))
                         "config_revision" 0 "policy_revision" 0
                         "review_mode" "blocking"
                         "save_policy" "save"))
                  (parts (list (cons "old" orig-content) (cons "new" proposed)))
                  artifact)
             (kargu-bridge-edit-prepare
              app args parts
              (lambda (art err)
                (if err (error "Prepare failed: %s" err)
                  (setq artifact art))))
             (kargu-bridge-test--wait (lambda () artifact))
             ;; 2. Authorize -> state is "review" because review_mode is blocking
             (let (auth-val auth-done)
               (kargu-bridge-edit-authorize
                artifact 'available
                (lambda (val err)
                  (if err (error "Authorize failed: %s" err)
                    (setq auth-val val auth-done t))))
               (kargu-bridge-test--wait (lambda () auth-done))
               (should (equal (gethash "state" auth-val) "review"))
               (let ((edit-id (gethash "edit_id" auth-val))
                     (rev1 (gethash "revision" auth-val)))
                 (should (= rev1 1))
                 ;; 3. User edits proposal text in review UI -> calls edit/revise!
                 (let (rev-val rev-done)
                   (kargu-bridge-edit-revise
                    artifact :edit-id edit-id :revision rev1 :file-index 0 :new-text user-revised
                    :callback                      (lambda (val err)
						     (if err (error "Revise failed: %s" err)
						       (setq rev-val val rev-done t))))
                   (kargu-bridge-test--wait (lambda () rev-done))
                   (let ((rev2 (gethash "revision" rev-val)))
                     ;; Revision bumped to 2!
                     (should (= rev2 2))
                     ;; 4. Accept revision 2
                     (let (dec-done)
                       (kargu-bridge-edit-decision
                        artifact :edit-id edit-id :revision rev2 :decision 'accept
                        :callback                          (lambda (_val err)
							     (if err (error "Decision failed: %s" err)
							       (setq dec-done t))))
                       (kargu-bridge-test--wait (lambda () dec-done)))
                     ;; 5. Preflight under revision 2
                     (let* ((buf (find-file-noselect file))
                            (doc (kargu-bridge-edit-document-capture buf))
                            (witness (kargu-bridge-edit-document-witness doc 0))
                            pf-val pf-done)
                       (kargu-bridge-edit-preflight
                        artifact :edit-id edit-id :revision rev2 :witness witness
                        :callback                          (lambda (val err)
							     (if err (error "Preflight failed: %s" err)
							       (setq pf-val val pf-done t))))
                       (kargu-bridge-test--wait (lambda () pf-done))
                       ;; 6. Execute issued transaction and verify revised content is written!
                       (let* ((digest (gethash "preflight_digest" (gethash "preflight" pf-val)))
                              (jdir (make-temp-file "kargu-native-review-journal-" t))
                              act-done)
                         (kargu-bridge-edit-activity-start
                          artifact
                          :edit-id edit-id
                          :revision rev2
                          :preflight-digest digest
                          :journal-directory jdir
                          :handler (lambda (live-p)
                                     (kargu-bridge-edit-document-replace
                                      doc user-revised :save t :check-issued live-p))
                          :callback (lambda (_res err)
                                      (if err (error "Activity failed: %s" err)
                                        (setq act-done t))))
                         (kargu-bridge-test--wait (lambda () act-done))
                         (delete-directory jdir t)
                         (kargu-bridge-edit-release artifact)
                         (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                                        user-revised))))))))))
       (delete-directory root t)))))


(ert-deftest kargu-native-edit-batch-buffer-only-rollback-owned-dirty-test ()
  "Undo an owned dirty document without saving or treating it as foreign."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-dirty-undo-" t))
          (path (expand-file-name "file.txt" root)))
     (unwind-protect
         (progn
           (write-region "old\n" nil path nil 'silent)
           (let ((result (kargu-native-edit-test--execute
                          (list :intent :write :root root :path path :content "new\n"
                                :save-policy 'buffer_only))))
             (should (eq (plist-get result :status) :applied-full))
             (should-not (plist-get result :saved))
             (should (buffer-modified-p (find-buffer-visiting path))))
           (should (eq (plist-get (kargu-native-edit-test--execute
                                   (list :intent :rollback :root root :save-policy 'buffer_only))
                                  :status) :applied-full))
           (with-current-buffer (find-buffer-visiting path)
             (should (equal (buffer-string) "old\n"))
             (should-not (buffer-modified-p)))
           (should (equal (with-temp-buffer (insert-file-contents path) (buffer-string)) "old\n")))
       (delete-directory root t)))))

(ert-deftest kargu-native-edit-batch-consecutive-undo-consumes-history-test ()
  "Two undos restore initial content; their own writes never become redo entries."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-consecutive-undo-" t))
          (path (expand-file-name "file.txt" root)))
     (unwind-protect
         (progn
           (write-region "initial\n" nil path nil 'silent)
           (dolist (body '("first\n" "second\n"))
             (should (eq (plist-get (kargu-native-edit-test--execute
                                     (list :intent :write :root root :path path :content body))
                                    :status) :applied-full)))
           (dolist (expected '("first\n" "initial\n"))
             (should (eq (plist-get (kargu-native-edit-test--execute
                                     (list :intent :rollback :root root)) :status) :applied-full))
             (should (equal (with-temp-buffer (insert-file-contents path) (buffer-string)) expected)))
           (let (done failure)
             (kargu-bridge-edit-batch-execute
              (list :intent :rollback :root root)
              (lambda (_value error-data) (setq done t failure error-data)))
             (kargu-bridge-test--wait (lambda () done))
             (should failure))
           (should (>= (length (directory-files kargu-bridge-edit-batch-journal-directory
                                                nil directory-files-no-dot-files-regexp)) 4)))
       (delete-directory root t)))))

(ert-deftest kargu-native-edit-batch-foreign-before-rollback-test ()
  "A real disk change before rollback preparation must survive unchanged."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-foreign-undo-" t))
          (path (expand-file-name "file.txt" root)))
     (unwind-protect
         (progn
           (write-region "initial\n" nil path nil 'silent)
           (kargu-native-edit-test--execute (list :intent :write :root root :path path :content "owned\n"))
           (write-region "foreign owner\n" nil path nil 'silent)
           (let (done failure)
             (kargu-bridge-edit-batch-execute
              (list :intent :rollback :root root)
              (lambda (_value error-data) (setq done t failure error-data)))
             (kargu-bridge-test--wait (lambda () done))
             (should failure))
           (should (equal (with-temp-buffer (insert-file-contents path) (buffer-string)) "foreign owner\n")))
       (delete-directory root t)))))

(ert-deftest kargu-native-edit-batch-checks-every-document-before-first-write-test ()
  "A stale second buffer prevents the first file from being written."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-batch-stale-" t))
          (first (expand-file-name "first.txt" root))
          (second (expand-file-name "second.txt" root))
          (apply-function (symbol-function 'kargu-bridge-edit-batch--apply)))
     (unwind-protect
         (progn
           (write-region "old\n" nil first nil 'silent)
           (write-region "old\n" nil second nil 'silent)
           (cl-letf (((symbol-function 'kargu-bridge-edit-batch--apply)
                      (lambda (files live-p)
                        (with-current-buffer (find-buffer-visiting second)
                          (goto-char (point-max)) (insert "foreign buffer change"))
                        (funcall apply-function files live-p))))
             (let (done)
               (kargu-bridge-edit-batch-execute
                (list :intent :patch :root root
                      :patch (concat "--- a/first.txt\n+++ b/first.txt\n@@ -1 +1 @@\n-old\n+new\n"
                                     "--- a/second.txt\n+++ b/second.txt\n@@ -1 +1 @@\n-old\n+new\n"))
                (lambda (_result _failure) (setq done t)))
               (kargu-bridge-test--wait (lambda () done))))
           (should (equal (with-temp-buffer (insert-file-contents first) (buffer-string)) "old\n"))
           (should (equal (with-temp-buffer (insert-file-contents second) (buffer-string)) "old\n")))
       (delete-directory root t)))))

(ert-deftest kargu-native-edit-batch-small-frame-pages-all-targets-test ()
  "Read multiple native metadata pages before mutating any file."
  (let ((kargu-bridge--max-frame 4096))
    (cl-letf (((symbol-function 'kargu-bridge--start-finish)
               (lambda (connection callback failure)
                 (kargu-bridge--start-ready connection callback failure))))
      (kargu-native-edit-test--with-core
       (let ((root (make-temp-file "kargu-paged-batch-" t)) (patch ""))
         (unwind-protect
             (progn
               (dotimes (index 8)
                 (write-region "old\n" nil (expand-file-name (format "file%d.txt" index) root) nil 'silent)
                 (setq patch (concat patch (format "--- a/file%d.txt\n+++ b/file%d.txt\n@@ -1 +1 @@\n-old\n+new\n" index index))))
               (let ((result (kargu-native-edit-test--execute (list :intent :patch :root root :patch patch))))
                 (should (eq (plist-get result :status) :applied-full))
                 (should (= (plist-get result :files-applied) 8)))
               (dotimes (index 8)
                 (should (equal (with-temp-buffer
                                  (insert-file-contents (expand-file-name (format "file%d.txt" index) root))
                                  (buffer-string)) "new\n"))))
           (delete-directory root t)))))))

(ert-deftest kargu-native-edit-selection-never-falls-back-test ()
  "An unavailable selected native writer cannot enter legacy staging."
  (let ((kargu-diff-native-edit-enabled t) legacy-entered done result)
    (kargu-test-mode 'agent)
    (cl-letf (((symbol-function 'kargu-diff-apply-replace)
               (lambda (&rest _) (setq legacy-entered t)))
              ((symbol-function 'kargu-bridge-edit-batch-execute)
               (lambda (_spec callback)
                 (let ((task (kargu-async-start #'ignore)))
                   (funcall callback nil "native unavailable")
                   (kargu-async-cancel task) task))))
      (kargu-diff--edit-file-tool
       '(("file_path" . "test.txt") ("old_string" . "old") ("new_string" . "new"))
       (lambda (value) (setq done t result value))))
    (should done) (should-not legacy-entered)
    (should (string-search "native unavailable" result))))


(ert-deftest kargu-native-edit-batch-review-covers-every-file-and-revision-test ()
  "All files are reviewed before writing, including a human revision of file two."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-batch-reviewed-" t))
          (first (expand-file-name "first.txt" root))
          (second (expand-file-name "second.txt" root))
          (review-function (symbol-function 'kargu-bridge-edit-batch-review))
          (screens 0))
     (unwind-protect
         (progn
           (write-region "old\n" nil first nil 'silent)
           (write-region "old\n" nil second nil 'silent)
           (cl-letf (((symbol-function 'kargu-bridge-edit-batch-review)
                      (lambda (&rest arguments)
                        (let ((noninteractive nil)) (apply review-function arguments))))
                     ((symbol-function 'ediff-buffers)
                      (lambda (_base shadow &rest _)
                        (cl-incf screens)
                        (should (equal (with-temp-buffer (insert-file-contents first) (buffer-string)) "old\n"))
                        (when (= screens 2)
                          (with-current-buffer shadow (erase-buffer) (insert "human revision\n")))
                        (let ((control (generate-new-buffer " *kargu-test-review*")))
                          (run-at-time 0 nil
                                       (lambda ()
                                         (with-current-buffer control (run-hooks 'ediff-quit-hook))
                                         (when (buffer-live-p control) (kill-buffer control))))
                          control))))
             (let ((result (kargu-native-edit-test--execute
                            (list :intent :patch :root root :review-mode 'blocking
                                  :patch (concat "--- a/first.txt\n+++ b/first.txt\n@@ -1 +1 @@\n-old\n+new\n"
                                                 "--- a/second.txt\n+++ b/second.txt\n@@ -1 +1 @@\n-old\n+new\n")))))
               (should (eq (plist-get result :status) :applied-full))
               (should-not (integerp (plist-get result :hunks-applied)))))
           (should (= screens 2))
           (should (equal (with-temp-buffer (insert-file-contents first) (buffer-string)) "new\n"))
           (should (equal (with-temp-buffer (insert-file-contents second) (buffer-string)) "human revision\n")))
       (delete-directory root t)))))

(ert-deftest kargu-native-edit-batch-mode-cycle-revokes-delayed-continuation-test ()
  "Returning to Agent mode never revives a preparation from an older mode revision."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-edit-mode-cycle-" t))
          (path (expand-file-name "file.txt" root)) held task done failure)
     (unwind-protect
         (progn
           (write-region "old\n" nil path nil 'silent)
           (cl-letf (((symbol-function 'kargu-bridge-edit-authorize)
                      (lambda (_artifact _presenter callback) (setq held callback))))
             (setq task (kargu-bridge-edit-batch-execute
                         (list :intent :write :root root :path path :content "new\n")
                         (lambda (_value error-data) (setq done t failure error-data))))
             (kargu-bridge-test--wait (lambda () held))
             (kargu-test-mode 'ask) (kargu-test-mode 'agent)
             (funcall held nil nil)
             (should done) (should failure)
             (should (eq (kargu-async-task-state task) :done)))
           (should (equal (with-temp-buffer (insert-file-contents path) (buffer-string)) "old\n")))
       (delete-directory root t)))))

(ert-deftest kargu-native-edit-batch-does-not-trust-target-parent-test ()
  "Without a project root the target directory never becomes an authorization root."
  (kargu-test-mode 'agent)
  (let (prepared failure)
    (cl-letf (((symbol-function 'kargu-permission-project-root) (lambda (&optional _) nil))
              ((symbol-function 'kargu-bridge-edit-prepare) (lambda (&rest _) (setq prepared t))))
      (kargu-bridge-edit-batch-execute
       (list :intent :write :path "/tmp/foreign/file.txt" :content "forbidden")
       (lambda (_value error-data) (setq failure error-data))))
    (should failure) (should-not prepared)))

(ert-deftest kargu-native-edit-batch-targeted-rollback-keeps-other-file-test ()
  "Per-file undo targets its edit identity and consumes only that file's snapshot."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-targeted-undo-" t))
          (first (expand-file-name "first.txt" root))
          (second (expand-file-name "second.txt" root)))
     (unwind-protect
         (progn
           (write-region "old\n" nil first nil 'silent)
           (write-region "old\n" nil second nil 'silent)
           (let* ((result (kargu-native-edit-test--execute
                           (list :intent :patch :root root
                                 :patch (concat "--- a/first.txt\n+++ b/first.txt\n@@ -1 +1 @@\n-old\n+new\n"
                                                "--- a/second.txt\n+++ b/second.txt\n@@ -1 +1 @@\n-old\n+new\n"))))
                  (edit (plist-get result :edit-id)))
             (should (eq (plist-get (kargu-native-edit-test--execute
                                     (list :intent :rollback :root root :path first :target-edit-id edit))
                                    :status) :applied-full))
             (should (equal (with-temp-buffer (insert-file-contents first) (buffer-string)) "old\n"))
             (should (equal (with-temp-buffer (insert-file-contents second) (buffer-string)) "new\n"))
             (should (eq (plist-get (kargu-native-edit-test--execute
                                     (list :intent :rollback :root root :target-edit-id edit))
                                    :status) :applied-full))
             (should (equal (with-temp-buffer (insert-file-contents second) (buffer-string)) "old\n"))))
       (delete-directory root t)))))

(ert-deftest kargu-native-edit-batch-save-hook-final-body-rollback-test ()
  "Rollback bases its inverse on actual saved hook output, rather than proposal text."
  (kargu-native-edit-test--with-core
   (let* ((root (make-temp-file "kargu-hook-undo-" t))
          (path (expand-file-name "file.txt" root))
          (hook (lambda () (goto-char (point-max)) (insert "hook output\n"))))
     (unwind-protect
         (progn
           (write-region "old\n" nil path nil 'silent)
           (with-current-buffer (find-file-noselect path) (add-hook 'before-save-hook hook nil t))
           (let ((result (kargu-native-edit-test--execute
                          (list :intent :write :root root :path path :content "new\n"))))
             (should (eq (plist-get result :status) :applied-full))
             (should (plist-get (car (plist-get result :files)) :hook-transformed))
              (should (plist-get result :hook-transformed)))
           (with-current-buffer (find-buffer-visiting path) (remove-hook 'before-save-hook hook t))
           (should (eq (plist-get (kargu-native-edit-test--execute
                                   (list :intent :rollback :root root)) :status) :applied-full))
           (should (equal (with-temp-buffer (insert-file-contents path) (buffer-string)) "old\n")))
       (delete-directory root t)))))


(ert-deftest kargu-native-edit-plan-consumer-preserves-unknown-counts-test ()
  "Plan metadata uses the same native port and keeps unmeasured counts explicit."
  (kargu-native-edit-test--with-core
    (let* ((root (make-temp-file "kargu-native-plan-" t))
           (kargu-permission--override-root root)
           (path (expand-file-name "file.txt" root))
           (service (kargu-edit-service-create :root root :review-mode 'auto)))
      (unwind-protect
          (progn
            (write-region "old\n" nil path nil 'silent)
            (let* ((plan (kargu-edit-plan-create
                          :path path :kind :block :proposed-content "new\n"
                          :metadata (list :old-string "old\n" :new-string "new\n")))
                   (result (kargu-native-edit-test--await
                            (lambda (callback)
                              (kargu-diff-submit-plan
                               service plan :callback
                               (lambda (value) (funcall callback value nil))))))
                   (outcome (kargu-result-value result)))
              (should outcome)
              (should (eq (kargu-edit-outcome-status outcome) :applied))
              (should (eq (kargu-edit-outcome-hunks-applied outcome) :json-null))
              (should (equal (with-temp-buffer (insert-file-contents path) (buffer-string)) "new\n"))))
        (kargu-edit-service-close service)
        (delete-directory root t)))))


(ert-deftest kargu-native-edit-consumer-bounds-passive-undo-references-test ()
  "Editing distinct paths cannot accumulate unlimited native UI history rows."
  (let* ((root (kargu-test-scratch-root))
         (service (kargu-edit-service-create :root root :review-mode 'auto)))
    (dotimes (index 24)
      (kargu-diff-native--project
       service (list :intent :write)
       (list :rollback-available t :edit-id (format "edit-%d" index) :root root
             :files (list (list :path (expand-file-name (format "file-%d" index) root) :status :applied)))))
    (should (= (length (kargu-edit-service-native-edits service)) 16))
    (should (= (hash-table-count (kargu-edit-service-snapshots service)) 16))
    (should-not (gethash (expand-file-name "file-0" root) (kargu-edit-service-snapshots service)))
    (should (gethash (expand-file-name "file-23" root) (kargu-edit-service-snapshots service)))))


(ert-deftest kargu-native-edit-batch-stale-rollback-releases-and-replies-test ()
  "A late stale rollback preparation releases its ticket and fails immediately."
  (let ((connection (kargu-bridge--connection-create :state 'ready)) done failure released)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (funcall callback connection nil)))
              ((symbol-function 'kargu-bridge-application-ensure)
               (lambda (_connection _app callback)
                 (funcall callback (kargu-bridge--object "application_id" "app" "session_id" "session") nil)))
              ((symbol-function 'kargu-bridge-edit--current-p) (lambda (_) nil))
              ((symbol-function 'kargu-bridge-call)
               (lambda (_connection method _params callback &rest _)
                 (if (equal method "edit/abort") (setq released t)
                   (funcall callback (kargu-bridge--object "preparation_id" "preparation"
                                                          "descriptor" (kargu-bridge--object)) nil)))))
      (let ((task (kargu-bridge-edit-rollback
                   (kargu-application-context) (kargu-bridge--object "origin_id" "source")
                   :callback (lambda (_value error-data) (setq done t failure error-data)))))
        (should (eq (kargu-async-task-state task) :done))
        (should done) (should failure) (should released)
        (should (string-search "native unavailable"
                               (kargu-diff-native-describe
                                (list :status :error :message "native unavailable"))))))))

(provide 'tests/test-native-edit-batch)
;;; test-native-edit-batch.el ends here
