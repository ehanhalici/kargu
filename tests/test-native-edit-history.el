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

(provide 'tests/test-native-edit-history)
;;; test-native-edit-history.el ends here
