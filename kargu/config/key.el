;;; key.el --- Multi-tier API key and endpoint resolution -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Memory-only key and endpoint selection from published config and environment.
;; Auth-source belongs to the shared asynchronous connection interop port.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rx)
(require 'kargu/core)
(require 'kargu/providers)

(defvar kargu-config-credential-adapter nil
  "Optional function (PROVIDER HOST TASK) for cancellable secret resolution.")

(declare-function kargu--config-providers "kargu/config/schema" ())
(declare-function kargu--config-plist "kargu/config/schema" ())
(declare-function url-host "url-parse")
(declare-function url-generic-parse-url "url-parse")
(declare-function kargu-connection-current "kargu/config/connection" ())
(declare-function kargu-connection-snapshot-provider "kargu/config/connection" (snapshot))
(declare-function kargu-connection-snapshot-model "kargu/config/connection" (snapshot))
(declare-function kargu-connection-snapshot-endpoint "kargu/config/connection" (snapshot))

(defun kargu--provider-name ()
  "Return the owning session's provider, or an explicit config fallback."
  (or (and (fboundp 'kargu-connection-current) (kargu-connection-current)
           (kargu-connection-snapshot-provider (kargu-connection-current)))
      (kargu-selection-provider)
      (kargu-nonempty (plist-get (kargu--config-plist) :provider))
      (caar (kargu--config-providers))
      "default"))

(defun kargu--provider-plist (&optional provider)
  "Return PROVIDER's settings, defaulting to the current session's provider."
  (let* ((name (or provider (kargu--provider-name)))
         (entry (assoc name (kargu--config-providers)))
         (default-info (kargu-provider-get name))
         (toml-plist (cdr entry)))
    (append toml-plist
            (when (and default-info (null (plist-get toml-plist :api)))
              (let ((default-api (plist-get default-info :api)))
                (and (kargu-nonempty default-api)
                     (list :api default-api))))
            (when (and default-info (null (plist-get toml-plist :models)))
              (let ((default-models (kargu-provider-models name)))
                (and default-models
                     (list :models default-models)))))))

(defun kargu--api-base (&optional provider-name)
  "Return endpoint base URL.
Use active or specified PROVIDER-NAME `api' from TOML config if set,
otherwise provider's catalog default URL, else `kargu-api-base'.
Return the captured spelling unchanged; Rust owns endpoint path derivation."
  (let* ((pname (or provider-name (kargu--provider-name)))
         (pname-str (if (symbolp pname) (symbol-name pname) (format "%s" (or pname ""))))
         (pname-lower (downcase (string-trim pname-str)))
         (entry (assoc pname-lower (and (fboundp 'kargu--config-providers)
                                        (kargu--config-providers))))
         (toml-api (and entry (plist-get (cdr entry) :api)))
         (active-api (and (null provider-name)
                          (fboundp 'kargu--provider-plist)
                          (plist-get (kargu--provider-plist) :api)))
         (catalog-api (and (fboundp 'kargu-provider-api)
                           (kargu-provider-api pname-lower))))
    (or (and (fboundp 'kargu-connection-current) (kargu-connection-current)
             (equal pname-lower (kargu-connection-snapshot-provider (kargu-connection-current)))
             (kargu-connection-snapshot-endpoint (kargu-connection-current)))
        (and (kargu-nonempty toml-api) toml-api)
        (and (kargu-nonempty active-api) active-api)
        (and (kargu-nonempty catalog-api) catalog-api)
        kargu-api-base)))

(defun kargu--model ()
  "Return the owning session's model, or an explicit provider/config fallback."
  (or (and (fboundp 'kargu-connection-current) (kargu-connection-current)
           (kargu-connection-snapshot-model (kargu-connection-current)))
      (kargu-selection-model)
      (and (null (kargu-selection-provider))
           (kargu-nonempty (plist-get (kargu--config-plist) :model)))
      (kargu-nonempty (plist-get (kargu--provider-plist) :model))))

(defun kargu--url-host (url)
  "Host name of URL, or nil."
  (when (kargu-nonempty url)
    (require 'url-parse)
    (url-host (url-generic-parse-url url))))

(defun kargu--api-key-placeholder-p (key)
  "Non-nil if KEY is empty or a documented dummy placeholder."
  (and (stringp key)
       (let ((k (downcase (string-trim key))))
         (or (string-empty-p k)
             (member k '("dummy" "none" "placeholder" "..."))
             (string-suffix-p "..." k)))))

(defun kargu--provider-env-api-key (&optional provider-name)
  "API key from environment variables associated with PROVIDER-NAME, or nil."
  (let* ((pname (or provider-name (kargu--provider-name)))
         (pname-str (if (symbolp pname) (symbol-name pname) (format "%s" pname)))
         (envs (and (fboundp 'kargu-provider-env)
                    (kargu-provider-env (downcase (string-trim pname-str))))))
    (cl-some (lambda (var)
               (let ((val (getenv var)))
                 (and (kargu-nonempty val) val)))
             envs)))

(defun kargu--expand-env-refs (value)
  "VALUE with each ${NAME} replaced by that environment variable.
Return nil for non-strings or unset/empty references; log only missing names."
  (save-match-data
    (when (stringp value)
      (catch 'unset
        (replace-regexp-in-string
         (rx "${" (group (any alpha "_") (* (any alnum "_"))) "}")
         (lambda (match)
           (let ((name (match-string 1 match)))
             (or (kargu-nonempty (getenv name))
                 (progn
                   (kargu-log 'warn "Configured environment variable %s is unset or empty; trying remaining credential sources" name)
                   (throw 'unset nil)))))
         value t t)))))

(defun kargu--provider-toml-plist (pname-lower provider-name)
  "TOML plist of PNAME-LOWER; the active provider's when PROVIDER-NAME is nil."
  (if-let* ((entry (assoc pname-lower (and (fboundp 'kargu--config-providers)
                                           (kargu--config-providers)))))
      (cdr entry)
    (and (null provider-name) (fboundp 'kargu--provider-plist)
         (kargu--provider-plist))))

(defun kargu--resolve-direct-api-key (&optional provider-name)
  "Resolve PROVIDER-NAME's credential from memory, TOML or env without auth-source."
  (let* ((pname (or provider-name (kargu--provider-name)))
         (pname-lower (downcase (string-trim (format "%s" pname))))
         (active (or (null provider-name)
                     (equal pname-lower
                            (downcase (string-trim (format "%s" (kargu--provider-name)))))))
         (toml-plist (kargu--provider-toml-plist pname-lower provider-name))
         (raw-key (and toml-plist (plist-get toml-plist :apikey)))
         (toml-key (kargu-nonempty (kargu--expand-env-refs raw-key))))
    (cond
     ((and active (boundp 'kargu-api-key) (kargu-nonempty kargu-api-key)))
     (toml-key)
     ((and toml-plist (equal raw-key "")) "")
     ((kargu-nonempty (kargu--provider-env-api-key pname-lower))))))

(defun kargu-config-api-key-fast (&optional provider-name)
  "Return PROVIDER-NAME's key without invoking secret functions or pinentry.
Reads purely from in-memory configuration without triggering auth-source search."
  (kargu--resolve-direct-api-key provider-name))

(provide 'kargu/config/key)

;;; key.el ends here
