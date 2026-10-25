;;; prepare.el --- Owned asynchronous connection admission -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Refresh config and resolve credentials under one cancellable owner.  The
;; captured selection must survive both yields before a connection is usable.

;;; Code:

(require 'kargu/config/connection)
(require 'kargu/api/request)
(require 'kargu/selection)
(require 'kargu/bridge/models)
(require 'kargu/models/projection)

(cl-defstruct (kargu-connection-preparation (:constructor kargu-connection-preparation-create))
  "One target's preparation state, owner identity and pending root task."
  task app origin session selection provider model public tuning metadata-ticket metadata-view (state :config))

(defun kargu-api-prepare--current-p (preparation)
  "Check PREPARATION's captured session and selection without disk access."
  (let ((origin (kargu-connection-preparation-origin preparation)))
    (and (buffer-live-p origin)
         (eq (kargu-connection-preparation-session preparation) (kargu-session-context origin))
         (eq (kargu-connection-preparation-selection preparation)
             (kargu-selection-context (kargu-session-context origin))))))

(defun kargu-api-prepare--resolved (preparation result)
  "Finish PREPARATION once with connection RESULT or an owner rejection."
  (if (kargu-api-prepare--current-p preparation)
      (kargu-async-finish (kargu-connection-preparation-task preparation) result)
    (when (kargu-ok-p result) (kargu-connection-snapshot-wipe (kargu-result-value result)))
    (kargu-async-finish (kargu-connection-preparation-task preparation)
			(kargu-err "Connection selection changed during preparation" :stale))))

(defun kargu-api-prepare--credentials (preparation result)
  "Advance PREPARATION after configuration and metadata RESULT barriers."
  (let ((task (kargu-connection-preparation-task preparation)))
    (cond
     ((kargu-err-p result) (kargu-async-finish task result))
     ((not (kargu-api-prepare--current-p preparation))
      (kargu-async-finish task (kargu-err "Connection owner changed during preparation" :stale)))
     (t
      (setf (kargu-connection-preparation-state preparation) :credential)
      (let* ((tuning (kargu-connection-preparation-tuning preparation))
             (kargu-temperature (plist-get tuning :temperature))
             (kargu-max-tokens (plist-get tuning :max-tokens))
             (kargu-thinking-budget (plist-get tuning :thinking-budget))
             (kargu-reasoning-effort (plist-get tuning :default-effort))
             (provider (or (kargu-connection-preparation-provider preparation) (kargu--provider-name)))
             (model (or (kargu-connection-preparation-model preparation) (kargu--model)))
             (settings (if-let* ((view (kargu-connection-preparation-metadata-view preparation)))
                           (kargu-api-connection-settings provider model view)
                         (kargu-api-connection-settings provider model))))
        (kargu-connection-resolve-async
         provider model :parent task :origin (kargu-connection-preparation-origin preparation)
         :settings settings :capabilities (list :tools (plist-get settings :tools))
         :public (kargu-connection-preparation-public preparation)
         :callback (lambda (value) (kargu-api-prepare--resolved preparation value))))))))

(defun kargu-api-prepare--configured (preparation result)
  "Await PREPARATION's captured metadata intent after configuration RESULT."
  (let ((task (kargu-connection-preparation-task preparation))
        (ticket (kargu-connection-preparation-metadata-ticket preparation)))
    (cond
     ((kargu-err-p result) (kargu-async-finish task result))
     ((not (kargu-api-prepare--current-p preparation))
      (kargu-async-finish task (kargu-err "Connection owner changed during preparation" :stale)))
     ((null ticket) (kargu-api-prepare--credentials preparation result))
     (t
      (setf (kargu-connection-preparation-state preparation) :metadata)
      (kargu-async-add-cleanup
       task
       (kargu-bridge-models-await
        ticket (kargu-application-wrap
                (kargu-connection-preparation-app preparation)
                (kargu-async-wrap task (lambda (view failure)
					 (if failure
					     (kargu-async-finish task (kargu-err "Native metadata publication unavailable" :metadata-unavailable))
					   (setf (kargu-connection-preparation-metadata-view preparation) view)
					   (kargu-api-prepare--credentials preparation result)))))))))))

(cl-defun kargu-api-prepare-connection (callback &key parent owner provider model public)
  "Prepare a connection for CALLBACK under PARENT and OWNER.
PROVIDER and MODEL override session defaults; PUBLIC is a verified catalog flag."
  (let* ((app (kargu-application-context))
         (preparation (kargu-connection-preparation-create
                       :app app :origin (current-buffer) :session (kargu-session-context)
                       :selection (kargu-selection-context) :provider provider :model model
                       :public public
                       :metadata-ticket (or (kargu-bridge-models-capture app)
                                            (kargu-bridge-models-observe app #'ignore))
                       :tuning (list :temperature kargu-temperature :max-tokens kargu-max-tokens
                                     :thinking-budget kargu-thinking-budget
                                     :default-effort kargu-reasoning-effort)))
         (task (kargu-async-start
                (kargu-application-wrap
                 app (lambda (value error)
                       (setf (kargu-connection-preparation-state preparation) :closed)
                       (funcall callback (or value (kargu-err error :connection-failed)))))
                :parent parent :owner owner :timeout kargu-config-worker-default-timeout)))
    (setf (kargu-connection-preparation-task preparation) task)
    (kargu-config-refresh-async
     (kargu-async-wrap task (lambda (result) (kargu-api-prepare--configured preparation result)))
     :parent task)
    task))

(provide 'kargu/api/prepare)
;;; prepare.el ends here
