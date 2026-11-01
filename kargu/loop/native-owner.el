;;; native-owner.el --- Owned native agent startup and cancellation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Bind one prompt to its captured editor application and execution lifetime.
;; Reverse run scopes are observations; cancellation uses the prompt request ID.

;;; Code:

(require 'cl-lib)
(require 'kargu/async)
(require 'kargu/bridge/application)
(require 'kargu/bridge/conversation)
(require 'kargu/bridge/session)

(defun kargu-loop-native-owned--issue
    (task application session connection arguments owner on-delta on-event scope failure)
  "Issue TASK's captured ARGUMENTS only under the current native SCOPE.
APPLICATION, SESSION, CONNECTION and OWNER remain captured through delivery.
FAILURE rejects startup.  ON-DELTA and ON-EVENT observe this task alone."
  (cond
   (failure (kargu-async-finish task nil failure))
   ((not (kargu-bridge-application-scope-equal-p
          scope (kargu-bridge-conversation-current-scope application session connection)))
    (kargu-async-finish task nil "Native application lease changed"))
   (t
    (let ((id (kargu-bridge-session-start
               connection scope arguments
               (lambda (result error-data)
                 (kargu-async-finish task result error-data))
               :owner owner
               :on-delta (when on-delta (kargu-async-wrap task on-delta))
               :on-event (when on-event (kargu-async-wrap task on-event)))))
      (when id
        (kargu-async-add-cleanup
         task (lambda () (kargu-bridge-cancel connection id))))))))

(defun kargu-loop-native-owned--application
    (task application session connection arguments owner on-delta on-event scope failure)
  "Acquire SESSION's conversation after APPLICATION's service SCOPE is ready.
Retain TASK, CONNECTION, ARGUMENTS, OWNER, ON-DELTA and ON-EVENT
through FAILURE."
  (cond
   (failure (kargu-async-finish task nil failure))
   ((not (kargu-bridge-application-scope-equal-p
          scope (kargu-bridge-application-current-scope application connection)))
    (kargu-async-finish task nil "Native application lease changed"))
   (t
    (kargu-async-add-cleanup
     task (kargu-bridge-conversation-ensure
           connection application session scope
           (kargu-async-wrap
            task (lambda (conversation error-data)
                   (kargu-loop-native-owned--issue
                    task application session connection arguments owner on-delta on-event
                    conversation error-data))))))))

(defun kargu-loop-native-owned--ready
    (task application session arguments owner on-delta on-event connection failure)
  "Acquire APPLICATION's scope on CONNECTION for TASK's ARGUMENTS.
FAILURE rejects startup.  SESSION, OWNER, ON-DELTA and ON-EVENT remain captured."
  (if failure
      (kargu-async-finish task nil failure)
    (kargu-async-add-cleanup
     task
     (kargu-bridge-application-ensure
      connection application
      (kargu-async-wrap
       task (lambda (scope error-data)
              (kargu-loop-native-owned--application
               task application session connection arguments owner on-delta on-event
               scope error-data)))))))

(cl-defun kargu-loop-native-owned-start
    (application arguments callback &key parent owner session valid-p on-delta on-event)
  "Start captured ARGUMENTS for APPLICATION and deliver CALLBACK once.
PARENT, OWNER and SESSION bind startup and delivery.
VALID-P rejects retired resources.
ON-DELTA and ON-EVENT observe only this task's native request."
  (let* ((origin (or owner (current-buffer)))
         (session (or session (kargu-session-context origin)))
         (arguments (kargu-bridge--decode
                     (json-serialize arguments :null-object :json-null
                                               :false-object :json-false)))
         (task (kargu-async-start callback :parent parent :owner nil
                                  :buffer origin
                                  :valid-p (lambda ()
                                             (and (buffer-live-p origin)
                                                  (eq session (kargu-session-context origin))
                                                  (not (kargu-session-native-retired session))
                                                  (or (null valid-p) (funcall valid-p))))
                                  :timeout 120)))
    (funcall
     (kargu-async-wrap
      task (lambda ()
             (kargu-async-add-cleanup
              task
              (kargu-bridge-ensure
               (kargu-async-wrap
                task (lambda (connection failure)
                       (kargu-loop-native-owned--ready
                        task application session arguments owner on-delta on-event
                        connection failure))))))))
    task))

(provide 'kargu/loop/native-owner)
;;; native-owner.el ends here
