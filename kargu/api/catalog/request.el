;;; request.el --- Owned catalog connection and native GET -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Capture published configuration, resolve credentials through the existing
;; cancellable editor port, then submit one GET to Rust.  No HTTP/auth engine
;; or synchronous auth-source lookup lives here.  Catalog discovery deliberately
;; survives an agent Stop or a provider selection change, not its origin closing.

;;; Code:

(require 'kargu/config/connection)
(require 'kargu/api/request)
(require 'kargu/api/transport)

(defun kargu-catalog-request--url (provider api-base)
  "Capture PROVIDER's models URL from published API-BASE and registry data."
  (let* ((default-api (kargu-provider-api provider))
         (dedicated (kargu-provider-models-api provider))
         (custom (and (kargu-nonempty api-base) default-api
                      (not (equal (kargu--strip-trailing-slashes api-base)
                                  (kargu--strip-trailing-slashes default-api)))))
         (path (kargu-provider-native-models-path provider api-base)))
    (cond
     ((and (not custom) dedicated) dedicated)
     ((and custom (string-suffix-p "/models" api-base)) api-base)
     (path (concat api-base path))
     ((string-suffix-p "/models" api-base) api-base)
     (t (concat api-base "/models")))))

(defun kargu-catalog-request--bind-origin (task)
  "Cancel TASK and its children when its captured origin closes or changes mode."
  (let* ((origin (kargu-async-task-buffer task))
         (session (kargu-session-context origin))
         (cancel (lambda () (kargu-async-cancel task))))
    (setf (kargu-async-task-valid-p task)
          (lambda () (and (buffer-live-p origin)
                          (eq session (kargu-session-context origin)))))
    (with-current-buffer origin
      (add-hook 'kill-buffer-hook cancel nil t)
      (add-hook 'change-major-mode-hook cancel nil t))
    (kargu-async-add-cleanup
     task (lambda ()
            (when (buffer-live-p origin)
              (with-current-buffer origin
                (remove-hook 'kill-buffer-hook cancel t)
                (remove-hook 'change-major-mode-hook cancel t)))))))

(cl-defun kargu-catalog-request--send (task snapshot &key url provider auth callback app)
  "Submit TASK's captured URL, PROVIDER, AUTH and CALLBACK for APP using SNAPSHOT."
  (kargu-async-add-cleanup
   task (lambda ()
          (when-let* ((key (kargu-aget auth "key")))
            (when (stringp key) (clear-string key)))
          (kargu-connection-snapshot-wipe snapshot)))
  (let ((request
         (kargu-transport-request
          'get url :auth auth :model-catalog t :application app :provider provider
          :wire (kargu-connection-setting :wire snapshot)
          :as 'string :timeout (when-let* ((deadline (kargu-async-task-deadline task)))
                                (max 0.001 (- deadline (float-time))))
          :then (kargu-application-wrap app (kargu-async-wrap task callback))
          :else (kargu-application-wrap
                 app (kargu-async-wrap
                      task (lambda (failure)
                             (kargu-async-finish task nil (kargu-result-err-message failure))))))))
    (kargu-async-add-cleanup task (lambda () (kargu-transport-cancel request)))))

(cl-defun kargu-catalog-request--resolved (task result &key url provider public auth callback app)
  "Advance TASK after credential RESULT.
Retain captured URL, PROVIDER, PUBLIC, AUTH, CALLBACK and APP."
  (if (kargu-err-p result)
      (kargu-async-finish task nil "No API key or valid connection for model catalog")
    (let ((snapshot (kargu-result-value result)))
      (unless public
        (setcdr (assoc "key" auth) (or (kargu-connection-snapshot-secret snapshot) :json-null)))
      (kargu-catalog-request--send
       task snapshot :url url :provider provider :auth auth :callback callback :app app))))

(defun kargu-catalog-request-start (task provider callback)
  "Resolve TASK's PROVIDER and deliver a native canonical body to CALLBACK.
Use already-published config; explicit UI/config refresh owns disk reads.
Only the exact declared public URL skips credentials.  Capture wire/header
bindings before yielding, independently of a bound chat connection."
  (let* ((kargu-connection--bound nil)
         (app (kargu-application-context))
         (url (kargu-catalog-request--url provider (kargu--api-base provider)))
         (public (kargu-provider-public-models-p provider url))
         (auth (kargu-config-copy (kargu-api-auth-intent nil provider)))
         (settings (list :wire (kargu-config-copy
                                (kargu-provider-format-record (kargu-provider-format provider))))))
    (kargu-catalog-request--bind-origin task)
    (kargu-connection-resolve-async
     provider "" :parent task :owner nil :origin (kargu-async-task-buffer task)
     :settings settings :capabilities nil :public public
     :callback (kargu-application-wrap
                app (kargu-async-wrap
                     task (lambda (result)
                            (kargu-catalog-request--resolved
                             task result :url url :provider provider :public public
                             :auth auth :callback callback :app app)))))))

(provide 'kargu/api/catalog/request)
;;; request.el ends here
