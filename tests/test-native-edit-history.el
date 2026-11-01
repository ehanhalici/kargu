;;; test-native-edit-history.el --- Native metadata lease and paging tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Transport regressions for actual edit/history consumers. Rust retains the
;; change selection, undo eligibility and exact verification identities.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'kargu/bridge/edit/history)
(require 'tests/test-native-edit-batch)

(defmacro kargu-edit-history-test--with-lease (&rest body)
  "Run BODY with a synthetic ready application lease."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (let* ((connection (kargu-bridge--connection-create
                         :state 'ready :epoch "edit-history-epoch" :capabilities ["edit_history"]))
            (scope (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_fixture"))
            (application (kargu-application-create)))
       (puthash :native-core
                (kargu-bridge-application--make :connection connection :scope scope :state :ready)
                (kargu-application-services application))
       ,@body)))

(defun kargu-edit-history-test--page (offset rows complete &optional revision)
  "Build a metadata page at OFFSET with ROWS, COMPLETE and REVISION."
  (kargu-bridge--object "offset" offset "files" (vconcat rows)
                        "next_offset" (+ offset (length rows))
                        "complete" complete "revision" (or revision 7)))

(ert-deftest kargu-edit-history-paging-detaches-requests-and-retains-native-dtos-test ()
  (dolist (action '(list files changes))
    (kargu-edit-history-test--with-lease
      (let ((service (copy-sequence "edit_service_fixture"))
            (edit (copy-sequence "editor_edit_fixture"))
            (row-a (kargu-bridge--object "edit_id" "opaque-a"))
            (row-b (kargu-bridge--object "edit_id" "opaque-b"))
            callback requests done result failure)
        (cl-letf (((symbol-function 'kargu-bridge-call)
                   (lambda (_connection method params receive &rest _)
                     (should (equal method "edit/history"))
                     (push params requests) (setq callback receive) "page"))
                  ((symbol-function 'kargu-bridge-cancel) #'ignore))
          (let ((receive (lambda (value error-data) (setq result value failure error-data done t))))
            (if (eq action 'changes)
                (kargu-bridge-edit-history-changes
                 application :service-id service :pending-only t :callback receive)
              (kargu-bridge-edit-history
               application :service-id service :edit-id (when (eq action 'files) edit)
               :revision (when (eq action 'files) 7) :callback receive)))
          (aset service 0 ?X)
          (aset edit 0 ?X)
          (funcall callback (kargu-edit-history-test--page 0 (list row-a) :json-false) nil)
          (should-not done)
          (let ((first (gethash "arguments" (cadr requests)))
                (next (gethash "arguments" (car requests))))
            (should (equal (gethash "service_id" first) "edit_service_fixture"))
            (should (equal (gethash "action" first) (symbol-name action)))
            (should (= (gethash "offset" first) 0))
            (should (= (gethash "offset" next) 1))
            (should (= (gethash "revision" next) 7))
            (when (eq action 'files)
              (should (equal (gethash "edit_id" next) "editor_edit_fixture")))
            (when (eq action 'changes) (should (eq (gethash "pending_only" next) t))))
          (funcall callback (kargu-edit-history-test--page 1 (list row-b) t) nil)
          (should done)
          (should-not failure)
          (should (equal (plist-get result :rows) (list row-a row-b)))
          (should (eq (car (plist-get result :rows)) row-a))
          (should (equal (plist-get result :epoch) "edit-history-epoch")))))))

(ert-deftest kargu-edit-history-epoch-loss-never-cancels-reused-request-id-test ()
  (dolist (transition '(cancel reply))
    (kargu-edit-history-test--with-lease
      (let (callback task failure delivered cancelled)
        (cl-letf (((symbol-function 'kargu-bridge-call)
                   (lambda (_connection _method _params receive &rest _) (setq callback receive) "reused-id"))
                  ((symbol-function 'kargu-bridge-cancel)
                   (lambda (_connection id) (push id cancelled))))
          (setq task (kargu-bridge-edit-history
                      application :callback (lambda (_value error-data) (setq failure error-data delivered t))))
          (setf (kargu-bridge-connection-epoch connection) "replacement-epoch")
          (if (eq transition 'cancel)
              (progn (kargu-async-cancel task) (should-not delivered))
            (funcall callback (kargu-edit-history-test--page 0 nil t) nil)
            (should delivered)
            (should failure))
          (should-not (kargu-async-pending-p task))
          (should-not cancelled))))))

(ert-deftest kargu-edit-history-inline-pages-retain-only-current-cancellation-test ()
  (kargu-edit-history-test--with-lease
    (let ((parent (kargu-async-start #'ignore :parent nil :owner nil))
          task callback cancelled)
      (cl-letf (((symbol-function 'kargu-bridge-call)
                 (lambda (_connection _method params receive &rest _)
                   (if (zerop (gethash "offset" (gethash "arguments" params)))
                       (progn
                         (funcall receive (kargu-edit-history-test--page 0 (list 'opaque) :json-false) nil)
                         "old-page")
                     (setq callback receive) "current-page")))
                ((symbol-function 'kargu-bridge-cancel)
                 (lambda (_connection id) (push id cancelled))))
        (setq task (kargu-bridge-edit-history application :parent parent :callback #'ignore))
        (should callback)
        (kargu-async-cancel parent)
        (should-not (kargu-async-pending-p task))
        (should (= (cl-count "old-page" cancelled :test #'equal) 1))
        (should (= (cl-count "current-page" cancelled :test #'equal) 1))))))

(ert-deftest kargu-edit-history-malformed-pages-never-publish-partial-rows-test ()
  (dolist (case '(revision offset progress bound complete))
    (kargu-edit-history-test--with-lease
      (let (callback done result failure)
        (cl-letf (((symbol-function 'kargu-bridge-call)
                   (lambda (_connection _method _params receive &rest _) (setq callback receive) "page"))
                  ((symbol-function 'kargu-bridge-cancel) #'ignore))
          (kargu-bridge-edit-history
           application :callback (lambda (value error-data) (setq result value failure error-data done t)))
          (funcall callback (kargu-edit-history-test--page 0 (list 'first) :json-false) nil)
          (let ((page (kargu-edit-history-test--page 1 (list 'second) t)))
            (pcase case
              ('revision (puthash "revision" 8 page))
              ('offset (puthash "offset" 0 page))
              ('progress (setq page (kargu-edit-history-test--page 1 nil :json-false)))
              ('bound (setq page (kargu-edit-history-test--page 1 (make-list 16 'too-many) t)))
              ('complete (puthash "complete" :json-null page)))
            (funcall callback page nil))
          (should done)
          (should failure)
          (should-not result))))))

(ert-deftest kargu-edit-history-scope-loss-never-adopts-the-new-service-session-test ()
  (kargu-edit-history-test--with-lease
    (let (callback failure result)
      (cl-letf (((symbol-function 'kargu-bridge-call)
                 (lambda (_connection _method _params receive &rest _) (setq callback receive) "page"))
                ((symbol-function 'kargu-bridge-cancel) #'ignore))
        (kargu-bridge-edit-history-changes
         application :callback (lambda (value error-data) (setq result value failure error-data)))
        (puthash "session_id" "sess_replacement" scope)
        (funcall callback (kargu-edit-history-test--page 0 nil t) nil)
        (should failure)
        (should-not result)))))

(ert-deftest kargu-edit-history-no-lease-never-starts-a-core-test ()
  (with-temp-buffer
    (let ((application (kargu-application-create)) done failure)
      (cl-letf (((symbol-function 'kargu-bridge-call)
                 (lambda (&rest _) (ert-fail "Missing lease sent an RPC")))
                ((symbol-function 'kargu-bridge-ensure)
                 (lambda (&rest _) (ert-fail "History started a core"))))
        (kargu-bridge-edit-history-changes
         application :callback (lambda (_value error-data) (setq failure error-data done t)))
        (should done)
        (should failure)))))

(ert-deftest kargu-edit-history-path-reader-never-adopts-a-replacement-epoch-test ()
  (kargu-edit-history-test--with-lease
    (let (callback result failure (calls 0))
      (cl-letf (((symbol-function 'kargu-bridge-edit-history)
                 (lambda (_application &rest options)
                   (cl-incf calls)
                   (setq callback (plist-get options :callback)))))
        (kargu-bridge-edit-history-paths
         application (lambda (value error-data) (setq result value failure error-data)))
        (setf (kargu-bridge-connection-epoch connection) "replacement-epoch")
        (funcall callback
                 (list :connection connection :scope scope :epoch "edit-history-epoch"
                       :revision 7 :rows (list (kargu-bridge--object "edit_id" "opaque"))) nil)
        (should failure)
        (should-not result)
        (should (= calls 1))))))

(ert-deftest kargu-edit-history-real-receipts-project-and-consume-only-the-owned-service-test ()
  (kargu-native-edit-test--with-core
    (let* ((root (make-temp-file "kargu-change-reader-" t))
           (application (kargu-application-create))
           (first (expand-file-name "first.txt" root))
           (second (expand-file-name "second.txt" root))
           (service-a (concat "edit_service_" (kargu-random-uuid)))
           (service-b (concat "edit_service_" (kargu-random-uuid))))
      (unwind-protect
          (progn
            (dolist (entry (list (cons first service-a) (cons second service-b)))
              (let ((result (kargu-native-edit-test--execute
                             (list :application application :service-id (cdr entry)
                                   :intent :write :root root :path (car entry) :content "new 🦀\n"
                                   :review-mode 'auto :save-policy 'save))))
                (should (eq (plist-get result :status) :applied-full))))
            (let* ((changes (kargu-native-edit-test--await
                             (lambda (receive)
                               (kargu-bridge-edit-history-changes
                                application :service-id service-a :pending-only t :callback receive))))
                   (rows (plist-get changes :rows))
                   (row (car rows))
                   (paths (kargu-native-edit-test--await
                           (lambda (receive)
                             (kargu-bridge-edit-history-paths application receive service-a)))))
              (should (= (length rows) 1))
              (should (equal (gethash "path" row) "first.txt"))
              (should (eq (gethash "saved" row) t))
              (should (equal paths (list first)))
              (let ((reply (kargu-native-edit-test--await
                            (lambda (receive)
                              (kargu-bridge-edit-history-consume
                               application :service-id service-a :edit-id (gethash "edit_id" row)
                               :edit-revision (gethash "edit_revision" row)
                               :file (gethash "file" row) :final-hash (gethash "final_hash" row)
                               :callback receive)))))
                (should (eq (gethash "consumed" reply) t))))
            (dolist (service (list service-a service-b))
              (let ((changes (kargu-native-edit-test--await
                              (lambda (receive)
                                (kargu-bridge-edit-history-changes
                                 application :service-id service :pending-only t :callback receive)))))
                (should (= (length (plist-get changes :rows)) (if (equal service service-a) 0 1))))))
        (delete-directory root t)))))

(ert-deftest kargu-edit-history-close-epoch-loss-never-cancels-a-replacement-request-test ()
  (dolist (transition '(cancel reply))
    (kargu-edit-history-test--with-lease
      (let (callback task result failure delivered cancelled)
        (cl-letf (((symbol-function 'kargu-bridge-call)
                   (lambda (_connection _method _params receive &rest _) (setq callback receive) "reused-id"))
                  ((symbol-function 'kargu-bridge-cancel)
                   (lambda (_connection id) (push id cancelled))))
          (setq task (kargu-bridge-edit-history-close-service
                      application "edit_service_fixture"
                      (lambda (value error-data) (setq result value failure error-data delivered t))))
          (setf (kargu-bridge-connection-epoch connection) "replacement-epoch")
          (if (eq transition 'cancel)
              (progn (kargu-async-cancel task) (should-not delivered))
            (funcall callback (kargu-bridge--object "closed" t "drained" t) nil)
            (should delivered)
            (should failure)
            (should-not result))
          (should-not (kargu-async-pending-p task))
          (should-not cancelled))))))

(ert-deftest kargu-edit-history-close-stale-scope-does-not-publish-drained-test ()
  (kargu-edit-history-test--with-lease
    (let (callback failure result)
      (cl-letf (((symbol-function 'kargu-bridge-call)
                 (lambda (_connection _method _params receive &rest _) (setq callback receive) "close"))
                ((symbol-function 'kargu-bridge-cancel) #'ignore))
        (kargu-bridge-edit-history-close-service
         application "edit_service_fixture"
         (lambda (value error-data) (setq result value failure error-data)))
        (puthash "session_id" "sess_replacement" scope)
        (funcall callback (kargu-bridge--object "closed" t "drained" t) nil)
        (should failure)
        (should-not result)))))

(ert-deftest kargu-edit-history-close-poll-retains-its-original-epoch-test ()
  (kargu-edit-history-test--with-lease
    (let ((schedule (symbol-function 'run-at-time))
          (cancel-timer-function (symbol-function 'cancel-timer))
          (calls 0) poll done failure cancelled)
      (cl-letf (((symbol-function 'kargu-bridge-call)
                 (lambda (_connection _method _params receive &rest _)
                   (cl-incf calls)
                   (funcall receive (kargu-bridge--object "closed" t "drained" :json-false) nil)
                   "completed-close"))
                ((symbol-function 'kargu-bridge-cancel)
                 (lambda (_connection id) (push id cancelled)))
                ((symbol-function 'run-at-time)
                 (lambda (delay repeat callback &rest arguments)
                   (if (equal delay 0.1)
                       (progn (setq poll (lambda () (apply callback arguments))) 'poll-timer)
                     (apply schedule delay repeat callback arguments))))
                ((symbol-function 'cancel-timer)
                 (lambda (timer) (unless (eq timer 'poll-timer) (funcall cancel-timer-function timer)))))
        (kargu-bridge-edit-history-close-service
         application "edit_service_fixture"
         (lambda (_value error-data) (setq done t failure error-data)))
        (should poll)
        (should-not done)
        (setf (kargu-bridge-connection-epoch connection) "replacement-epoch")
        (funcall poll)
        (should done)
        (should failure)
        (should (= calls 1))
        (should-not cancelled)))))

(ert-deftest kargu-edit-history-native-reference-consumption-waits-for-rust-ack-test ()
  (dolist (outcome '(accepted refused failed newer))
    (let* ((service (kargu-edit-service-create))
           (path (expand-file-name "reference.txt" default-directory))
           (identity (list :native t :application (kargu-application-create)
                           :edit-id "opaque-edit" :edit-revision 19 :file-index 1 :final-hash "opaque-hash"
                           :service-id "opaque-service"))
           (changes (kargu-edit-service-changes service)) callback)
      (puthash path identity changes)
      (cl-letf (((symbol-function 'kargu-bridge-edit-history-consume)
                 (lambda (application &rest options)
                   (should (eq application (plist-get identity :application)))
                   (should (= (plist-get options :file) 1))
                   (should (= (plist-get options :edit-revision) 19))
                   (setq callback (plist-get options :callback)))))
        (kargu-diff-consume-change (kargu-diff--make-change :path path :identity identity) service)
        (should (eq (gethash path changes) identity))
        (when (eq outcome 'newer) (puthash path 'newer-reference changes))
        (funcall callback (kargu-bridge--object "consumed" (if (eq outcome 'refused) :json-false t))
                 (when (eq outcome 'failed) (kargu-bridge--fault "unavailable")))
        (pcase outcome
          ('accepted (should-not (gethash path changes)))
          ('newer (should (eq (gethash path changes) 'newer-reference)))
          (_ (should (eq (gethash path changes) identity))))))))

(ert-deftest kargu-edit-history-undo-reanchor-rejects-old-proof-real-pipe-test ()
  "Restoring the same content reopens debt under a new publication identity."
  (kargu-native-edit-test--with-core
    (let* ((root (make-temp-file "kargu-undo-proof-" t))
           (path (expand-file-name "file.txt" root))
           (application (kargu-application-create))
           (service (kargu-edit-service-create :root root :review-mode 'auto))
           first old-reference)
      (unwind-protect
          (cl-labels
              ((execute (content)
                 (kargu-native-edit-test--await
                  (lambda (receive)
                    (kargu-diff-native-execute
                     (list :intent :write :application application :root root
                           :path path :content content :save-policy 'save)
                     (lambda (value) (funcall receive value nil)) service))))
               (consume (identity)
                 (kargu-native-edit-test--await
                  (lambda (receive)
                    (kargu-bridge-edit-history-consume
                     application :service-id (plist-get identity :service-id)
                     :edit-id (plist-get identity :edit-id)
                     :edit-revision (plist-get identity :edit-revision)
                     :file (plist-get identity :file-index)
                     :final-hash (plist-get identity :final-hash) :callback receive))))
               (rollback ()
                 (kargu-native-edit-test--await
                  (lambda (receive)
                    (kargu-diff-native-rollback
                     path :single-step t :service service
                     :callback (lambda (value) (funcall receive value nil)))))))
            (write-region "base\n" nil path nil 'silent)
            (setq first (execute "first 🦀\n")
                  old-reference (gethash path (kargu-edit-service-changes service)))
            (should (integerp (plist-get first :edit-revision)))
            (should (= (plist-get first :edit-revision) (plist-get old-reference :edit-revision)))
            ;; Even a previously consumed edit needs new evidence after undo.
            (should (eq (gethash "consumed" (consume old-reference)) t))
            (execute "second\n")
            (let ((result (rollback)))
              (should (eq (plist-get result :status) :applied-full))
              (should-not (plist-get result :change-projection-failure)))
            (let ((current (gethash path (kargu-edit-service-changes service))))
              (should current)
              (should (equal (plist-get current :edit-id) (plist-get old-reference :edit-id)))
              (should (equal (plist-get current :final-hash) (plist-get old-reference :final-hash)))
              (should (> (plist-get current :edit-revision) (plist-get old-reference :edit-revision)))
              (should-not (eq (gethash "consumed" (consume old-reference)) t))
              (should (eq (gethash "consumed" (consume current)) t)))
            (should (eq (plist-get (rollback) :status) :applied-full))
            (should-not (gethash path (kargu-edit-service-changes service)))
            (should (equal (with-temp-buffer (insert-file-contents path) (buffer-string)) "base\n")))
        (delete-directory root t)))))

(ert-deftest kargu-edit-history-undo-body-eviction-keeps-debt-real-pipe-test ()
  "Undo body retention cannot decide whether modified content needs evidence."
  (kargu-native-edit-test--with-core
    (let* ((root (make-temp-file "kargu-undo-retention-" t))
           (path (expand-file-name "file.txt" root))
           (application (kargu-application-create))
           (service (kargu-edit-service-create :root root :review-mode 'auto)))
      (unwind-protect
          (progn
            (write-region "base\n" nil path nil 'silent)
            (dotimes (index 17)
              (let ((result (kargu-native-edit-test--await
                             (lambda (receive)
                               (kargu-diff-native-execute
                                (list :intent :write :application application :root root :path path
                                      :content (format "edit-%d\n" index) :save-policy 'save)
                                (lambda (value) (funcall receive value nil)) service)))))
                (should (eq (plist-get result :status) :applied-full))))
            (dotimes (_ 16)
              (let ((result (kargu-native-edit-test--await
                             (lambda (receive)
                               (kargu-diff-native-rollback
                                path :single-step t :service service
                                :callback (lambda (value) (funcall receive value nil)))))))
                (should (eq (plist-get result :status) :applied-full))
                (should-not (plist-get result :change-projection-failure))))
            (should (equal (with-temp-buffer (insert-file-contents path) (buffer-string)) "edit-0\n"))
            (should-not (gethash path (kargu-edit-service-snapshots service)))
            (let* ((reference (gethash path (kargu-edit-service-changes service)))
                   (pending (kargu-native-edit-test--await
                             (lambda (receive)
                               (kargu-bridge-edit-history-changes
                                application :service-id (kargu-edit-service-native-id service)
                                :pending-only t :callback receive))))
                   (row (car (plist-get pending :rows))))
              (should reference)
              (should (member path (kargu-edit-service-run-modified-files service)))
              (should (= (length (plist-get pending :rows)) 1))
              (should (eq (gethash "verification_pending" row) t))
              (should (equal (gethash "edit_id" row) (plist-get reference :edit-id)))
              (should (= (gethash "edit_revision" row) (plist-get reference :edit-revision)))))
        (delete-directory root t)))))

(ert-deftest kargu-edit-history-service-close-keeps-resources-until-drain-test ()
  (kargu-edit-history-test--with-lease
    (let* ((service (kargu-edit-service-create))
           (buffer (generate-new-buffer " *close-owned*"))
           (directory (make-temp-file "kargu-close-owned-" t))
           (lease (kargu-bridge-edit-history-capture-lease application connection scope))
           (calls 0) (delivered 0) callback task)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-bridge-call)
                     (lambda (_connection _method params receive &rest _)
                       (should (equal (gethash "action" (gethash "arguments" params)) "close_service"))
                       (cl-incf calls) (setq callback receive) (format "close-%d" calls)))
                    ((symbol-function 'kargu-bridge-cancel) #'ignore))
            (setf (kargu-edit-service-native-application service) application
                  (kargu-edit-service-native-id service) "edit_service_fixture"
                  (kargu-edit-service-native-lease service) lease)
            (kargu-edit-service-register-buffer service buffer)
            (kargu-edit-service-register-temp-dir service directory)
            (setq task (kargu-edit-service-close
                        service (lambda (_value failure) (should-not failure) (cl-incf delivered))))
            (should (eq task (kargu-edit-service-close
                              service (lambda (_value failure) (should-not failure) (cl-incf delivered)))))
            (should (kargu-edit-service-closed-p service))
            (should-not (kargu-edit-service-drained service))
            (should (buffer-live-p buffer))
            (should (file-directory-p directory))
            (should (= calls 1))
            (funcall callback (kargu-bridge--object "closed" t "drained" :json-false) nil)
            (should-not (kargu-edit-service-drained service))
            (should (buffer-live-p buffer))
            (kargu-bridge-test--wait (lambda () (= calls 2)))
            (funcall callback (kargu-bridge--object "closed" t "drained" t) nil)
            (should (kargu-edit-service-drained service))
            (should-not (buffer-live-p buffer))
            (should-not (file-directory-p directory))
            (should (= delivered 2)))
        (when (kargu-async-pending-p task) (kargu-async-cancel task))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when (file-directory-p directory) (delete-directory directory t))))))

(ert-deftest kargu-edit-history-service-close-never-adopts-a-new-epoch-test ()
  (kargu-edit-history-test--with-lease
    (let* ((service (kargu-edit-service-create))
           (buffer (generate-new-buffer " *close-stale-owned*"))
           (lease (kargu-bridge-edit-history-capture-lease application connection scope)) failure)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-bridge-call)
                     (lambda (&rest _) (ert-fail "Old service closed the replacement core")))
                    ((symbol-function 'kargu-bridge-ensure)
                     (lambda (&rest _) (ert-fail "Close acquired a new core"))))
            (setf (kargu-edit-service-native-application service) application
                  (kargu-edit-service-native-id service) "edit_service_fixture"
                  (kargu-edit-service-native-lease service) lease
                  (kargu-bridge-connection-epoch connection) "replacement")
            (kargu-edit-service-register-buffer service buffer)
            (kargu-edit-service-close service (lambda (_value fault) (setq failure fault)))
            (should failure)
            (should (kargu-edit-service-closed-p service))
            (should-not (kargu-edit-service-drained service))
            (should (buffer-live-p buffer))
            (should (kargu-edit-service-close-failure service)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest kargu-edit-history-public-close-during-issued-write-real-pipe-test ()
  (kargu-native-edit-test--with-core
    (let* ((root (make-temp-file "kargu-issued-close-" t))
           (path (expand-file-name "file.txt" root))
           (service (kargu-edit-service-create :root root :review-mode 'auto))
           (owned (generate-new-buffer " *issued-close-owned*"))
           (call (symbol-function 'kargu-bridge-call))
           source closing done failure saw-draining)
      (unwind-protect
          (progn
            (write-region "base\n" nil path nil 'silent)
            (setq source (find-file-noselect path))
            (kargu-edit-service-register-buffer service owned)
            (with-current-buffer source
              (add-hook 'after-change-functions
                        (lambda (&rest _)
                          (unless closing
                            (setq closing t)
                            (should (kargu-edit-service-native-lease service))
                            (kargu-edit-service-close
                             service (lambda (_value fault) (setq done t failure fault)))
                            (should (buffer-live-p owned))
                            (should-not (kargu-edit-service-drained service)))) nil t))
            (cl-letf (((symbol-function 'kargu-bridge-call)
                       (lambda (connection method params receive &rest options)
                         (if (and (equal method "edit/history")
                                  (equal (gethash "action" (gethash "arguments" params)) "close_service"))
                             (apply call connection method params
                                    (lambda (value fault)
                                      (when (and (hash-table-p value) (eq (gethash "drained" value) :json-false))
                                        (setq saw-draining t)
                                        (should (buffer-live-p owned)))
                                      (funcall receive value fault)) options)
                           (apply call connection method params receive options)))))
              (kargu-diff-native-execute
               (list :intent :write :root root :path path :content "changed\n" :save-policy 'save)
               #'ignore service)
              (kargu-bridge-test--wait (lambda () done)))
            (should closing)
            (should-not failure)
            (should saw-draining)
            (should (kargu-edit-service-drained service))
            (should-not (buffer-live-p owned))
            (should-not kargu-bridge-edit-activity--active))
        (when (buffer-live-p owned) (kill-buffer owned))
        (delete-directory root t)))))

(ert-deftest kargu-edit-history-old-service-cannot-edit-a-replacement-core-test ()
  (kargu-edit-history-test--with-lease
    (let ((service (kargu-edit-service-create)))
      (setf (kargu-edit-service-native-application service) application
            (kargu-edit-service-native-lease service)
            (kargu-bridge-edit-history-capture-lease application connection scope)
            (kargu-bridge-connection-epoch connection) "replacement")
      (cl-letf (((symbol-function 'kargu-bridge-edit-batch-execute)
                 (lambda (&rest _) (ert-fail "Old service started a new preparation")))
                ((symbol-function 'kargu-bridge-ensure)
                 (lambda (&rest _) (ert-fail "Old service acquired a new core"))))
        (should-error (kargu-diff-native-execute (list :intent :write :path "unused") #'ignore service))))))

(ert-deftest kargu-edit-history-lifetime-lease-blocks-all-ports-after-reconnect-test ()
  (kargu-edit-history-test--with-lease
    (let ((lease (kargu-bridge-edit-history-capture-lease application connection scope))
          (calls 0) failures)
      (setf (kargu-bridge-connection-epoch connection) "replacement")
      (cl-labels ((receive (_value failure) (push failure failures)))
        (cl-letf (((symbol-function 'kargu-bridge-call)
                   (lambda (&rest _) (cl-incf calls))))
          (kargu-bridge-edit-history application :lease lease :callback #'receive)
          (kargu-bridge-edit-history application :lease lease :edit-id "same-edit" :revision 1 :callback #'receive)
          (kargu-bridge-edit-history-changes application :lease lease :callback #'receive)
          (kargu-bridge-edit-history-paths application #'receive "same-service" lease)
          (kargu-bridge-edit-history-consume application :lease lease :edit-id "same-edit"
                                             :edit-revision 1 :file 0 :callback #'receive)
          (kargu-bridge-edit-history-reset application :lease lease :callback #'receive)))
      (should (= calls 0))
      (should (= (length failures) 6))
      (should (cl-every #'identity failures)))))

(ert-deftest kargu-edit-history-native-consume-cannot-adopt-a-new-core-test ()
  (kargu-edit-history-test--with-lease
    (let* ((lease (kargu-bridge-edit-history-capture-lease application connection scope))
           (service (kargu-edit-service-create))
           (path (expand-file-name "same-path" default-directory))
           (reference (list :native t :application application :lease lease
                            :service-id "same-service" :edit-id "same-edit" :edit-revision 1
                            :file-index 0 :final-hash "same-hash"))
           (calls 0))
      (setf (kargu-edit-service-native-lease service) lease)
      (puthash path reference (kargu-edit-service-changes service))
      (setf (kargu-bridge-connection-epoch connection) "replacement")
      (cl-letf (((symbol-function 'kargu-bridge-call)
                 (lambda (_connection _method _params callback &rest _)
                   (cl-incf calls) (funcall callback (kargu-bridge--object "consumed" t) nil))))
        (kargu-diff-consume-change (kargu-diff--make-change :path path :identity reference) service))
      (should (= calls 0))
      (should (eq reference (gethash path (kargu-edit-service-changes service)))))))

(ert-deftest kargu-edit-history-native-consume-keeps-reference-after-stale-ack-test ()
  (dolist (transition '(epoch scope))
    (kargu-edit-history-test--with-lease
      (let* ((lease (kargu-bridge-edit-history-capture-lease application connection scope))
             (service (kargu-edit-service-create))
             (path (expand-file-name "same-path" default-directory))
             (reference (list :native t :application application :lease lease
                              :service-id "same-service" :edit-id "same-edit" :edit-revision 1
                              :file-index 0 :final-hash "same-hash")) held)
        (puthash path reference (kargu-edit-service-changes service))
        (cl-letf (((symbol-function 'kargu-bridge-call)
                   (lambda (_connection _method _params callback &rest _) (setq held callback) "reused-id")))
          (kargu-diff-consume-change (kargu-diff--make-change :path path :identity reference) service))
        (should held)
        (if (eq transition 'epoch)
            (setf (kargu-bridge-connection-epoch connection) "replacement"
                  (plist-get lease :epoch) "replacement")
          (puthash "session_id" "replacement" scope)
          (puthash "session_id" "replacement" (plist-get lease :scope)))
        ;; Caller mutation cannot rewrite the request's already captured lease.
        (funcall held (kargu-bridge--object "consumed" t) nil)
        (should (eq reference (gethash path (kargu-edit-service-changes service))))))))

(provide 'tests/test-native-edit-history)
;;; test-native-edit-history.el ends here
