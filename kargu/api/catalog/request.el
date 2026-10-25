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
(require 'kargu/bridge/catalog)

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

(cl-defun kargu-catalog-request--send (task snapshot &key url provider auth callback app connection)
  "Submit TASK's URL, PROVIDER, AUTH and CALLBACK for APP using SNAPSHOT.
CONNECTION pins the native epoch through credential resolution and GET."
  (kargu-async-add-cleanup
   task (lambda ()
          (when-let* ((key (kargu-aget auth "key")))
            (when (stringp key) (clear-string key)))
          (kargu-connection-snapshot-wipe snapshot)))
  (let ((request
         (kargu-transport-request
          'get url :auth auth :model-catalog t :application app :provider provider :connection connection
          :wire (kargu-connection-setting :wire snapshot)
          :as 'string :timeout (when-let* ((deadline (kargu-async-task-deadline task)))
                                (max 0.001 (- deadline (float-time))))
          :then (kargu-application-wrap app (kargu-async-wrap task callback))
          :else (kargu-application-wrap
                 app (kargu-async-wrap
                      task (lambda (failure)
                             (kargu-async-finish task nil (kargu-result-err-message failure))))))))
    (kargu-async-add-cleanup task (lambda () (kargu-transport-cancel request)))))

(cl-defun kargu-catalog-request--resolved (task result &key url provider public auth callback app connection)
  "Advance TASK after credential RESULT.
Retain URL, PROVIDER, PUBLIC, AUTH, CALLBACK, APP and CONNECTION."
  (if (kargu-err-p result)
      (kargu-async-finish task nil "No API key or valid connection for model catalog")
    (let ((snapshot (kargu-result-value result)))
      (unless public
        (setcdr (assoc "key" auth) (or (kargu-connection-snapshot-secret snapshot) :json-null)))
      (kargu-catalog-request--send
       task snapshot :url url :provider provider :auth auth :callback callback :app app :connection connection))))

(cl-defun kargu-catalog-request--targeted
    (task result failure connection &key provider base revision auth settings callback app)
  "Advance TASK after native RESULT/FAILURE on CONNECTION.
PROVIDER, BASE, REVISION, AUTH, SETTINGS, CALLBACK and APP are captured inputs."
  (let ((kargu-connection--bound nil))
    (cond
     (failure (kargu-async-finish task nil "Native catalog target unavailable; check/rebuild kargu-core"))
     ((not (kargu-bridge-catalog-current-p app connection))
      (kargu-async-finish task nil "Native catalog connection is no longer current"))
     ((not (and (hash-table-p result) (equal provider (gethash "provider" result))
                (equal revision (gethash "configuration_revision" result))
                (stringp (gethash "url" result))
                (member (gethash "authentication" result) '("public" "provider"))))
      (kargu-async-finish task nil "Invalid native catalog target"))
     ((not (and (= revision (kargu-config-revision)) (equal base (kargu--api-base provider))))
      (kargu-async-finish task nil "Catalog configuration changed during preparation"))
     (t
      (let ((url (copy-sequence (gethash "url" result)))
            (public (equal (gethash "authentication" result) "public")))
        (kargu-connection-resolve-async
         provider "" :parent task :owner nil :origin (kargu-async-task-buffer task)
         :settings settings :capabilities nil :public public
         :callback (kargu-application-wrap
                    app (kargu-async-wrap
                         task (lambda (value)
                                (kargu-catalog-request--resolved
                                 task value :url url :provider provider :public public :auth auth
                                 :callback callback :app app :connection connection))))))))))

(defun kargu-catalog-request-start (task provider callback)
  "Resolve TASK's PROVIDER and deliver a native canonical body to CALLBACK.
Use already-published config; explicit UI/config refresh owns disk reads.
Only the exact declared public URL skips credentials.  Capture wire/header
bindings before yielding, independently of a bound chat connection."
  (let* ((kargu-connection--bound nil)
         (app (kargu-application-context))
         (base (kargu-config-copy (kargu--api-base provider)))
         (revision (kargu-config-revision))
         (auth (kargu-config-copy (kargu-api-auth-intent nil provider)))
         (settings (list :wire (kargu-config-copy
                                (kargu-provider-format-record (kargu-provider-format provider))))))
    (kargu-catalog-request--bind-origin task)
    (kargu-bridge-catalog-target
     (kargu-bridge--object
      "provider" provider "configuration_revision" revision "api_base" base
      "default_api" (or (kargu-config-copy (kargu-provider-api provider)) :json-null)
      "models_api" (or (kargu-config-copy (kargu-provider-models-api provider)) :json-null)
      "models_auth" (kargu-providers-wire-object (plist-get (kargu-provider-get provider) :models-auth))
      "native_models" (kargu-providers-wire-object (plist-get (plist-get settings :wire) :native-models)))
     (kargu-application-wrap
      app (kargu-async-wrap task
                           (lambda (result failure connection)
                             (kargu-catalog-request--targeted
                              task result failure connection :provider provider :base base :revision revision
                              :auth auth :settings settings :callback callback :app app))))
     :parent task :application app)))

(provide 'kargu/api/catalog/request)
;;; request.el ends here
