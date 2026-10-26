;;; key.el --- Memory-only native configuration projection -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Native code computes every fallback, endpoint and credential-source policy.
;; These readers bind explicit editor selection to committed DTO fields only.
;; Reading a projection never starts a core, refresh, file read or secret lookup.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/config/service)

(defvar kargu-config-credential-adapter nil
  "Optional function (PROVIDER HOST TASK) for cancellable secret interop.")

(declare-function kargu-connection-current "kargu/config/connection" ())
(declare-function kargu-connection-snapshot-provider "kargu/config/connection" (snapshot))
(declare-function kargu-connection-snapshot-model "kargu/config/connection" (snapshot))
(declare-function kargu-connection-snapshot-endpoint "kargu/config/connection" (snapshot))

(defun kargu-config-profile (&optional provider)
  "Borrow PROVIDER's committed native profile without resolving any policy."
  (let* ((id (or provider (kargu--provider-name)))
         (id (downcase (string-trim (format "%s" id))))
         (view (kargu-config-native-view)))
    (when view
      (cl-find-if (lambda (profile) (equal id (gethash "provider" profile)))
                  (append (gethash "profiles" view) nil)))))

(defun kargu-config-profile-field (name &optional provider)
  "Read native profile field NAME for PROVIDER, converting JSON null/false."
  (when-let* ((profile (kargu-config-profile provider))
              (value (gethash name profile)))
    (unless (memq value '(:json-null :json-false)) value)))

(defun kargu--provider-name ()
  "Read the bound request, explicit UI intent or native fallback provider.
The offline display label is not a prepared connection or an execution grant."
  (if-let* ((snapshot (and (fboundp 'kargu-connection-current) (kargu-connection-current))))
      (kargu-connection-snapshot-provider snapshot)
    (or (kargu-selection-provider)
        (when-let* ((view (kargu-config-native-view)))
          (gethash "provider" (gethash "fallback" view)))
        "default")))

(defun kargu--model ()
  "Read the bound request, explicit UI intent or compiled native model field."
  (if-let* ((snapshot (and (fboundp 'kargu-connection-current) (kargu-connection-current))))
      (kargu-connection-snapshot-model snapshot)
    (or (kargu-selection-model)
        (if (kargu-selection-provider)
            (kargu-config-profile-field "configured_model" (kargu-selection-provider))
          (when-let* ((view (kargu-config-native-view)))
            (let ((model (gethash "model" (gethash "fallback" view))))
              (unless (eq model :json-null) model)))))))

(defun kargu--api-base (&optional provider)
  "Read PROVIDER's captured/native endpoint spelling without fallback policy."
  (let ((id (or provider (kargu--provider-name)))
        (snapshot (and (fboundp 'kargu-connection-current) (kargu-connection-current))))
    (if (and snapshot (equal id (kargu-connection-snapshot-provider snapshot)))
        (kargu-connection-snapshot-endpoint snapshot)
      (kargu-config-profile-field "endpoint" id))))

(defun kargu-config-api-key-fast (&optional provider)
  "Read PROVIDER's last committed direct/keyless credential projection.
No environment expansion, auth-source search or core startup occurs here."
  (when-let* ((profile (kargu-config-profile provider))
              (credential (gethash "credential" profile)))
    (pcase (gethash "kind" credential)
      ("direct" (gethash "secret" credential))
      ("keyless" "")
      (_ nil))))

(defun kargu--api-key-placeholder-p (key)
  "Non-nil if KEY is empty or a documented dummy placeholder."
  (and (stringp key)
       (let ((k (downcase (string-trim key))))
         (or (string-empty-p k)
             (member k '("dummy" "none" "placeholder" "..."))
             (string-suffix-p "..." k)))))

(provide 'kargu/config/key)
;;; key.el ends here
