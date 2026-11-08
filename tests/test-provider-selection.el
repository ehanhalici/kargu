;;; test-provider-selection.el --- Owned config-backed provider picker -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Real XDG file -> bounded native read -> application publication -> provider UI.
;; Synthetic credentials only; provider discovery never calls an upstream API.

;;; Code:

(require 'ert)
(require 'tests/test-helpers)
(require 'tests/test-bridge)
(require 'kargu/chat/select)

(ert-deftest kargu-provider-selector-refreshes-real-xdg-file-before-opening-test ()
  "Cold menus and subsequent opens use current config, including custom IDs."
  (let* ((root (make-temp-file "kargu-provider-picker-" t))
         (file (expand-file-name "kargu/config.toml" root))
         (process-environment (copy-sequence process-environment))
         (kargu-api-key nil)
         (kargu-application--bound (kargu-application-create))
         candidates notes request messages)
    (unwind-protect
        (progn
          (setenv "XDG_CONFIG_HOME" root)
          (make-directory (file-name-directory file) t)
          (write-region
           "[providers.openrouter]\napikey = 'synthetic-picker-secret'\n[providers.private-gateway]\napi = 'https://example.invalid/v1'\napikey = 'synthetic-private-key'\n[providers.private-local]\napi = 'http://127.0.0.1:1/v1'\napikey = ''\n[providers.unconfigured-secret]\napikey = '...'\n"
           nil file nil 'silent)
          (cl-letf (((symbol-function 'kargu-api-select)
                     (lambda (field values annotations _apply)
                       (should (eq field 'provider))
                       (setq candidates values notes annotations)))
                    ((symbol-function 'auth-source-search)
                     (lambda (&rest _) (ert-fail "No synchronous auth-source search")))
                    ((symbol-function 'kargu-transport-request)
                     (lambda (&rest _) (ert-fail "No upstream discovery during provider selection")))
                    ((symbol-function 'message)
                     (lambda (format &rest arguments)
                       (push (apply #'format format arguments) messages))))
            (should-not (kargu--config-providers))
            ;; All config file reading happens in Rust, not the editor thread.
            (cl-letf (((symbol-function 'insert-file-contents)
                       (lambda (&rest _) (ert-fail "No synchronous UI config read"))))
              (setq request (kargu-chat-select-provider-company)))
            (should (kargu-async-task-p request))
            (should (kargu-async-pending-p request))
            (should-not candidates)
            (kargu-bridge-test--wait (lambda () (not (kargu-async-pending-p request))))
            (should (member "openrouter" candidates))
            (should (member "private-gateway" candidates))
            (should (member "private-local" candidates))
            (should-not (member "unconfigured-secret" candidates))
            (should-not (string-search "synthetic-picker-secret" (prin1-to-string notes)))
            (setq candidates nil)
            (write-region "[providers.replacement-gateway]\napi = 'https://example.invalid/v1'\napikey = 'synthetic-next-key'\n"
                          nil file nil 'silent)
            (setq request (kargu-chat-select-provider-company))
            (kargu-bridge-test--wait (lambda () (not (kargu-async-pending-p request))))
            (should (member "replacement-gateway" candidates))
            (should-not (member "private-gateway" candidates))
            (setq candidates nil)
            (write-region "apikey = 'synthetic-invalid-secret'\nprovider = 42\n" nil file nil 'silent)
            (setq request (kargu-chat-select-provider-company))
            (kargu-bridge-test--wait (lambda () (not (kargu-async-pending-p request))))
            (should-not candidates)
            (should (assoc "replacement-gateway" (kargu--config-providers)))
            (should (cl-some (lambda (text) (string-search "TOML" text)) messages))
            (should-not (string-search "synthetic-invalid-secret" (prin1-to-string messages)))))
      (delete-directory root t))))

(ert-deftest kargu-provider-selector-late-refresh-cannot-open-an-obsolete-view-test ()
  "Session, selection, draft, point, focus and active-work changes revoke UI."
  (dolist (change '(application session selection draft point focus busy))
    (with-temp-buffer
      (insert "draft")
      (let ((kargu-application--bound (kargu-application-create))
            (previous-buffer (window-buffer (selected-window))) task opened busy)
        (kargu-selection-update :provider "before")
        (unwind-protect
            (cl-letf (((symbol-function 'kargu-bridge-config-refresh) #'ignore)
                      ((symbol-function 'kargu-selection-busy-p) (lambda () busy))
                      ((symbol-function 'kargu-api-select--open-provider-selector)
                       (lambda () (setq opened t))))
              (setq task (kargu-chat-select-provider-company))
              (pcase change
                ('application (setq-local kargu-application-owner (kargu-application-create)))
                ('session (kargu-session-clear))
                ('selection (kargu-selection-update :provider "after"))
                ('draft (save-excursion (insert " user typing")))
                ('point (goto-char (point-min)))
                ('focus (set-window-buffer (selected-window) (current-buffer)))
                ('busy (setq busy t)))
              (with-temp-buffer
                (kargu-async-finish task (kargu-ok '(:data nil :path "/fixture" :digest "fixture"))))
              (should-not opened))
          (set-window-buffer (selected-window) previous-buffer))))))

(ert-deftest kargu-provider-selector-newest-refresh-cancels-only-its-predecessor-test ()
  "Repeated opens revoke the old task, not another view's native read."
  (let ((first-view (generate-new-buffer " *kargu-first-provider-view*"))
        (other-view (generate-new-buffer " *kargu-other-provider-view*"))
        first next other (opened 0) cleaned)
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-bridge-config-refresh)
                   (lambda (callback &rest options)
                     (let ((task (kargu-async-start callback :parent (plist-get options :parent) :owner nil)))
                       (kargu-async-add-cleanup task (lambda () (push task cleaned))))))
                  ((symbol-function 'kargu-api-select--open-provider-selector)
                   (lambda () (cl-incf opened))))
          (with-current-buffer first-view
            (setq-local kargu-application-owner (kargu-application-create))
            (setq first (kargu-chat-select-provider-company)))
          (with-current-buffer other-view
            (setq-local kargu-application-owner (kargu-application-create))
            (setq other (kargu-chat-select-provider-company)))
          (with-current-buffer first-view (setq next (kargu-chat-select-provider-company)))
          (should (eq (kargu-async-task-state first) :cancelled))
          (should (cl-some (lambda (child) (eq (kargu-async-task-parent child) first)) cleaned))
          (should (kargu-async-pending-p other))
          (kargu-async-finish first (kargu-err "stale fixture" :stale))
          (should (= opened 0))
          (kargu-async-finish next (kargu-ok (kargu-bridge--object
                                              "revision" 1 "path" "/current" "digest" :json-null "absent" t)))
          (should (= opened 1))
          (should (kargu-async-pending-p other))
          (kargu-async-finish other (kargu-ok (kargu-bridge--object
                                               "revision" 1 "path" "/other" "digest" :json-null "absent" t)))
          (should (= opened 2)))
      (when (buffer-live-p first-view) (kill-buffer first-view))
      (when (buffer-live-p other-view) (kill-buffer other-view)))))

(ert-deftest kargu-provider-selector-owner-close-revokes-real-native-read-test ()
  "Closing or repurposing a view revokes its real reply, not the shared core."
  (dolist (close '(kill mode))
    (kargu-bridge-test--with-core
     (let ((view (generate-new-buffer " *kargu-provider-owner*"))
           (file (make-temp-file "kargu-provider-owner-")) task held
           (refresh (symbol-function 'kargu-bridge-config-refresh))
           (call (symbol-function 'kargu-bridge-call)))
       (unwind-protect
           (cl-letf (((symbol-function 'kargu-bridge-config-refresh)
                      (lambda (callback &rest options)
                        (apply refresh callback :paths (list file)
                               (cl-loop for (key value) on options by #'cddr
                                        unless (memq key '(:paths :defaults-only))
                                        append (list key value)))))
                     ((symbol-function 'kargu-bridge-call)
                      (lambda (connection method params callback &rest options)
                        (apply call connection method params
                               (if (equal method "configuration/refresh")
                                   (lambda (value failure) (setq held (lambda () (funcall callback value failure))))
                                 callback) options)))
                     ((symbol-function 'kargu-api-select--open-provider-selector)
                      (lambda () (ert-fail "Closed owner cannot open a selector"))))
             (with-current-buffer view
               (setq-local kargu-application-owner (kargu-application-create))
               (setq task (kargu-chat-select-provider-company)))
             (kargu-bridge-test--wait (lambda () held))
             (with-current-buffer view
               (pcase close ('kill (kill-buffer view)) ('mode (fundamental-mode))))
             (should (eq (kargu-async-task-state task) :cancelled))
             (should-not (kargu-async-task-children task))
             (funcall held)
             (should (equal (gethash "status" (car (kargu-bridge-test--call conn "ping" (kargu-bridge--object)))) "ok")))
         (when (and task (kargu-async-pending-p task)) (kargu-async-cancel task))
         (when (buffer-live-p view) (kill-buffer view))
         (delete-file file))))))

(ert-deftest kargu-provider-list-dto-returns-namespace-and-readiness-test ()
  "Native provider/list returns typed DTO with namespace, readiness, and zero secrets."
  (let* ((app (kargu-application-create))
         result failure task)
    (unwind-protect
        (progn
          (require 'kargu/bridge/catalog)
          (setq task (kargu-bridge-provider-list
                      (lambda (dto err)
                        (setq result dto failure err))
                      :application app))
          (kargu-bridge-test--wait (lambda () (or result failure)))
          (should-not failure)
          (should (hash-table-p result))
          (should (equal (gethash "status" result) "ok"))
          (should (numberp (gethash "config_revision" result)))
          (let ((providers (append (gethash "providers" result) nil)))
            (should (consp providers))
            (dolist (p providers)
              (should (stringp (gethash "id" p)))
              (should (stringp (gethash "name" p)))
              (should (member (gethash "namespace" p) '("embedded" "api" "custom" "application")))
              (should (member (gethash "readiness" p) '("ready" "available")))
              (should (member (gethash "availability" p) '("ready" "available")))
              (should (memq (gethash "authenticated" p) '(t :json-false nil)))
              ;; Invariant: no secrets or headers in projection
              (should-not (gethash "apikey" p))
              (should-not (gethash "secret" p))
              (should-not (gethash "headers" p))
              (should-not (gethash "extra_headers" p)))))
      (when (and task (kargu-async-pending-p task))
        (kargu-async-cancel task)))))

(ert-deftest kargu-provider-registry-duplicate-display-name-isolation-test ()
  "Two providers with the identical display name maintain unforgeable distinct identities."
  (let ((table (copy-hash-table kargu-providers--table)))
    (unwind-protect
        (progn
          (kargu-register-provider :id "azure-gpt4" :name "GPT-4" :format 'openapi)
          (kargu-register-provider :id "openai-gpt4" :name "GPT-4" :format 'openapi)
          (should (equal (kargu-provider-name "azure-gpt4") "GPT-4"))
          (should (equal (kargu-provider-name "openai-gpt4") "GPT-4"))
          (let ((p1 (kargu-provider-get "azure-gpt4"))
                (p2 (kargu-provider-get "openai-gpt4")))
            (should-not (eq p1 p2))
            (should (equal (plist-get p1 :id) "azure-gpt4"))
            (should (equal (plist-get p2 :id) "openai-gpt4"))
            (should (eq (kargu-provider-namespace "azure-gpt4") 'embedded))
            (should (eq (kargu-provider-namespace "openai-gpt4") 'embedded))
            (should (equal (kargu-provider-readiness "azure-gpt4") "available")))
          (should (member "azure-gpt4" (kargu-provider-list)))
          (should (member "openai-gpt4" (kargu-provider-list))))
      (setq kargu-providers--table table))))

(provide 'tests/test-provider-selection)
;;; test-provider-selection.el ends here
