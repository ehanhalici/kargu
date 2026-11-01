;;; test-native-history.el --- Native display paging and ownership -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'kargu/bridge/history)
(require 'kargu/loop/native)
(require 'kargu/chat/render)
(require 'tests/test-native-conversation)

(defun kargu-native-history-test--page (offset text complete &optional revision)
  "Create a native display page for OFFSET, TEXT, COMPLETE and REVISION."
  (kargu-bridge--object "message_id" "msg_fixture" "revision" (or revision 7)
                        "projection" "display" "offset" offset
                        "next_offset" (+ offset (string-bytes text)) "text" text
                        "complete" complete))

(ert-deftest kargu-native-history-paging-assembles-utf8-dtos-without-parsing-test ()
  (with-temp-buffer
    (let* ((connection (kargu-bridge--connection-create :state 'ready :epoch "history-epoch"))
           (scope (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_fixture"))
           requests callback done result failure task)
      (cl-letf (((symbol-function 'kargu-bridge-call)
                 (lambda (_connection method params receive &rest _)
                   (should (equal method "history/read"))
                   (push params requests) (setq callback receive)
                   (format "page-%d" (length requests))))
                ((symbol-function 'kargu-bridge-cancel) #'ignore))
        (setq task (kargu-bridge-history-display
                    connection scope 7 "msg_fixture"
                    (lambda (value error-data) (setq result value failure error-data done t))))
        (funcall callback (kargu-native-history-test--page 0 "a🦀\r\n" :json-false) nil)
        (should-not done)
        (should (= (gethash "offset" (gethash "arguments" (car requests))) 7))
        (funcall callback (kargu-native-history-test--page 7 "literal </context>" t) nil)
        (should done)
        (should-not failure)
        (should (equal result "a🦀\r\nliteral </context>"))
        (should-not (kargu-async-pending-p task))
        (should-not (kargu-async-task-timer task))
        (should (= (length requests) 2))))))

(ert-deftest kargu-native-history-malformed-or-stale-page-never-delivers-partial-text-test ()
  (dolist (case '(revision identity projection offset progress complete size failure))
    (with-temp-buffer
      (let* ((connection (kargu-bridge--connection-create :state 'ready :epoch "history-epoch"))
             (scope (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_fixture"))
             (kargu-bridge-history-display-bytes 16)
             callback done result failure)
        (cl-letf (((symbol-function 'kargu-bridge-call)
                   (lambda (_connection _method _params receive &rest _) (setq callback receive) "page"))
                  ((symbol-function 'kargu-bridge-cancel) #'ignore))
          (kargu-bridge-history-display
           connection scope 7 "msg_fixture"
           (lambda (value error-data) (setq result value failure error-data done t)))
          (funcall callback (kargu-native-history-test--page 0 "kept" :json-false) nil)
          (let ((page (kargu-native-history-test--page 4 "more" t)))
            (pcase case
              ('revision (puthash "revision" 8 page))
              ('identity (puthash "message_id" "msg_foreign" page))
              ('projection (puthash "projection" "wire" page))
              ('offset (puthash "offset" 0 page))
              ('progress (setq page (kargu-native-history-test--page 4 "" :json-false)))
              ('complete (puthash "complete" :json-null page))
              ('size (setq page (kargu-native-history-test--page 4 (make-string 17 ?x) t))))
            (funcall callback page (when (eq case 'failure) (kargu-bridge--fault "stale_history"))))
          (should done)
          (should failure)
          (should-not result))))))

(ert-deftest kargu-native-history-origin-close-cancels-the-current-page-test ()
  (let* ((origin (generate-new-buffer " *native history origin*"))
         (connection (kargu-bridge--connection-create :state 'ready :epoch "history-epoch"))
         (scope (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_fixture"))
         callback task cancelled delivered)
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-bridge-call)
                   (lambda (_connection _method _params receive &rest _) (setq callback receive) "held-page"))
                  ((symbol-function 'kargu-bridge-cancel)
                   (lambda (_connection id) (push id cancelled))))
          (setq task (kargu-bridge-history-display
                      connection scope 7 "msg_fixture" (lambda (&rest _) (setq delivered t)) :owner origin))
          (kill-buffer origin)
          (should-not (kargu-async-pending-p task))
          (should (equal cancelled '("held-page")))
          (funcall callback (kargu-native-history-test--page 0 "late" t) nil)
          (should-not delivered))
      (when task (kargu-async-cancel task))
      (when (buffer-live-p origin) (kill-buffer origin)))))

(ert-deftest kargu-native-history-inline-page-race-retains-newer-request-id-test ()
  (with-temp-buffer
    (let* ((connection (kargu-bridge--connection-create :state 'ready :epoch "history-epoch"))
           (scope (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_fixture"))
           (parent (kargu-async-start #'ignore :owner nil :parent nil))
           task pending cancelled)
      (cl-letf (((symbol-function 'kargu-bridge-call)
                 (lambda (_connection _method params receive &rest _)
                   (if (zerop (gethash "offset" (gethash "arguments" params)))
                       (progn (funcall receive (kargu-native-history-test--page 0 "first" :json-false) nil) "old-page")
                     (setq pending receive) "current-page")))
                ((symbol-function 'kargu-bridge-cancel)
                 (lambda (_connection id) (push id cancelled))))
        (setq task (kargu-bridge-history-display connection scope 7 "msg_fixture" #'ignore :parent parent))
        (should pending)
        (kargu-async-cancel parent)
        (should-not (kargu-async-pending-p task))
        (should (= (cl-count "old-page" cancelled :test #'equal) 1))
        (should (= (cl-count "current-page" cancelled :test #'equal) 1))))))

(ert-deftest kargu-native-history-real-plain-answer-reaches-the-ui-once-test ()
  (let ((kargu-bridge--max-frame 1024))
   (kargu-bridge-test--with-core
   (let* ((application (kargu-application-create))
          (origin (generate-new-buffer " *native display plain*"))
          (root (make-temp-file "kargu-display-root-" t))
          (answer (apply #'concat (make-list 400 "plain 🦀\r\nvisible answer\n")))
          result done failure deltas finished rendered
          (server (kargu-stream-test--server
                   (json-serialize (kargu-bridge--object
                                    "choices" (vector (kargu-bridge--object
                                                       "message" (kargu-bridge--object "role" "assistant" "content" answer)
                                                       "finish_reason" "stop")))) nil nil))
          (url (format "http://127.0.0.1:%d/v1" (process-contact server :service))))
     (unwind-protect
         (progn
           (with-current-buffer origin
             (kargu-loop-native-owned-start
              application
              (kargu-bridge--object
               "root" root "mode" "ask" "prompt" (kargu-bridge--object "role" "user" "content" "prompt")
               "tools_enabled" :json-false "tool_limit" 1 "turn_limit" 1
               "timeout_ms" 3000 "config_revision" 1 "policy_revision" 1
               "connection" (kargu-bridge--object
                             "url" url "model" "fixture" "headers" (kargu-bridge--object) "stream" :json-false
                             "timeouts" (kargu-bridge--object "connect_ms" 1000 "first_byte_ms" 1000 "deadline_ms" 2000)))
              (lambda (value error-data) (setq result value failure error-data done t))
              :owner origin :on-delta (lambda (text) (push text deltas))))
           (kargu-bridge-test--wait (lambda () done))
           (should-not failure)
           (should-not deltas)
           (should (equal (gethash "answer_text" result) answer))
           (cl-letf (((symbol-function 'kargu-loop--live-p) (lambda (&rest _) t))
                     ((symbol-function 'kargu--loop-finish)
                      (lambda (_run status text) (setq finished (list status text)))))
             (kargu-loop-native--finish (list :iterations 0) result nil))
           (should (equal finished (list :done answer)))
           (cl-letf (((symbol-function 'kargu-chat-insert)
                      (lambda (text &rest _) (push text rendered))))
             (let ((kargu-chat--streamed-text nil))
               (kargu-chat--render-finish-status :done nil (cadr finished) nil))
             (should (= (cl-count answer rendered :test #'equal) 1))
             (setq rendered nil)
             (let ((kargu-chat--streamed-text t))
               (kargu-chat--render-finish-status :done nil (cadr finished) nil))
             (should (zerop (cl-count answer rendered :test #'equal)))))
       (when (buffer-live-p origin) (kill-buffer origin))
       (delete-process server)
       (delete-directory root t))))))

(ert-deftest kargu-native-history-epoch-loss-cannot-cancel-a-new-connection-request-test ()
  (with-temp-buffer
    (let* ((connection (kargu-bridge--connection-create :state 'ready :epoch "history-epoch"))
           (scope (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_fixture"))
           callback cancelled done result failure)
      (cl-letf (((symbol-function 'kargu-bridge-call)
                 (lambda (_connection _method _params receive &rest _) (setq callback receive) "old-id"))
                ((symbol-function 'kargu-bridge-cancel)
                 (lambda (_connection id) (push id cancelled))))
        (kargu-bridge-history-display
         connection scope 7 "msg_fixture"
         (lambda (value error-data) (setq result value failure error-data done t)))
        (setf (kargu-bridge-connection-epoch connection) "new-epoch")
        (funcall callback (kargu-native-history-test--page 0 "late" t) nil)
        (should done)
        (should failure)
        (should-not result)
        (should-not cancelled)))))

(ert-deftest kargu-native-history-completed-without-display-never-projects-empty-success-test ()
  (let (status)
    (cl-letf (((symbol-function 'kargu-loop--live-p) (lambda (&rest _) t))
              ((symbol-function 'kargu--loop-finish)
               (lambda (_run value &optional _text) (setq status value))))
      (kargu-loop-native--finish (list :iterations 0) (kargu-bridge--object "status" "completed") nil)
      (should (eq status :error)))))

(ert-deftest kargu-native-history-prompt-cleanup-is-bound-to-the-original-epoch-test ()
  (let* ((connection (kargu-bridge--connection-create :state 'ready :epoch "old-epoch"))
         (scope (kargu-bridge--object "application_id" "app_fixture" "session_id" "sess_fixture"))
         task cancelled)
    (cl-letf (((symbol-function 'kargu-bridge-ensure)
               (lambda (callback) (funcall callback connection nil) #'ignore))
              ((symbol-function 'kargu-bridge-application-ensure)
               (lambda (_connection _app callback) (funcall callback scope nil) #'ignore))
              ((symbol-function 'kargu-bridge-application-current-scope) (lambda (&rest _) scope))
              ((symbol-function 'kargu-bridge-conversation-ensure)
               (lambda (_connection _app _session _service callback) (funcall callback scope nil) #'ignore))
              ((symbol-function 'kargu-bridge-conversation-current-scope) (lambda (&rest _) scope))
              ((symbol-function 'kargu-bridge-session-start) (lambda (&rest _) "old-prompt"))
              ((symbol-function 'kargu-bridge-cancel) (lambda (_connection id) (push id cancelled))))
      (setq task (kargu-loop-native-owned-start nil (kargu-bridge--object) #'ignore))
      (setf (kargu-bridge-connection-epoch connection) "new-epoch")
      (kargu-async-cancel task)
      (should-not cancelled))))

(provide 'tests/test-native-history)
;;; test-native-history.el ends here
