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
(require 'kargu/bridge/session)

(defun kargu-loop-native-owned--issue
    (task application connection arguments owner on-delta on-event scope failure)
  "Issue TASK's captured ARGUMENTS only under the current native SCOPE.
APPLICATION, CONNECTION and OWNER remain captured through delivery; FAILURE
rejects startup.  ON-DELTA and ON-EVENT observe this task alone."
  (cond
   (failure (kargu-async-finish task nil failure))
   ((not (kargu-bridge-application-scope-equal-p
          scope (kargu-bridge-application-current-scope application connection)))
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

(defun kargu-loop-native-owned--ready
    (task application arguments owner on-delta on-event connection failure)
  "Acquire APPLICATION's scope on CONNECTION for TASK's ARGUMENTS.
FAILURE rejects startup.  OWNER, ON-DELTA and ON-EVENT remain captured."
  (if failure
      (kargu-async-finish task nil failure)
    (kargu-async-add-cleanup
     task
     (kargu-bridge-application-ensure
      connection application
      (kargu-async-wrap
       task (lambda (scope error-data)
              (kargu-loop-native-owned--issue
               task application connection arguments owner on-delta on-event
               scope error-data)))))))

(cl-defun kargu-loop-native-owned-start
    (application arguments callback &key parent owner valid-p on-delta on-event)
  "Start captured ARGUMENTS for APPLICATION and deliver CALLBACK once.
PARENT and OWNER bind startup and delivery.  VALID-P rejects retired resources.
ON-DELTA and ON-EVENT observe only this task's native request."
  (let* ((arguments (kargu-bridge--decode
                     (json-serialize arguments :null-object :json-null
                                               :false-object :json-false)))
         (task (kargu-async-start callback :parent parent :owner nil
                                  :buffer (or owner (current-buffer))
                                  :valid-p valid-p :timeout 120)))
    (funcall
     (kargu-async-wrap
      task (lambda ()
             (kargu-async-add-cleanup
              task
              (kargu-bridge-ensure
               (kargu-async-wrap
                task (lambda (connection failure)
                       (kargu-loop-native-owned--ready
                        task application arguments owner on-delta on-event
                        connection failure))))))))
    task))

(provide 'kargu/loop/native-owner)
;;; native-owner.el ends here
