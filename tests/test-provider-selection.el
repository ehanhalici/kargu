;;; test-provider-selection.el --- Owned config-backed provider picker -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Real XDG file -> bounded child -> application publication -> provider UI.
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
            ;; All file reading must happen in the child, not the editor thread.
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
            (cl-letf (((symbol-function 'kargu-config-worker-start) #'ignore)
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
  "Repeated opens revoke the old task, not another view's config worker."
  (let ((first-view (generate-new-buffer " *kargu-first-provider-view*"))
        (other-view (generate-new-buffer " *kargu-other-provider-view*"))
        first next other (opened 0) cleaned)
    (unwind-protect
        (cl-letf (((symbol-function 'kargu-config-worker-start)
                   (lambda (task &rest _)
                     (kargu-async-add-cleanup task (lambda () (push task cleaned)))))
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
          (kargu-async-finish first (kargu-ok '(:data nil :path "/stale" :digest "old")))
          (should (= opened 0))
          (kargu-async-finish next (kargu-ok '(:data nil :path "/current" :digest "next")))
          (should (= opened 1))
          (should (kargu-async-pending-p other))
          (kargu-async-finish other (kargu-ok '(:data nil :path "/other" :digest "other")))
          (should (= opened 2)))
      (when (buffer-live-p first-view) (kill-buffer first-view))
      (when (buffer-live-p other-view) (kill-buffer other-view)))))

(ert-deftest kargu-provider-selector-owner-close-kills-real-worker-test ()
  "Closing or repurposing a view kills only its actual pending child."
  (dolist (close '(kill mode))
    (let ((view (generate-new-buffer " *kargu-provider-owner*")) task process)
      (unwind-protect
          (cl-letf (((symbol-function 'kargu-config--file-script) (lambda () "(sleep-for 10)"))
                    ((symbol-function 'kargu-api-select--open-provider-selector)
                     (lambda () (ert-fail "Closed owner cannot open a selector"))))
            (with-current-buffer view
              (setq task (kargu-chat-select-provider-company))
              (setq process (get-process "kargu-config-worker"))
              (should (process-live-p process))
              (pcase close ('kill (kill-buffer view)) ('mode (fundamental-mode))))
            (should (eq (kargu-async-task-state task) :cancelled))
            (should-not (process-live-p process)))
        (when (and task (kargu-async-pending-p task)) (kargu-async-cancel task))
        (when (buffer-live-p view) (kill-buffer view))))))

(provide 'tests/test-provider-selection)
;;; test-provider-selection.el ends here
