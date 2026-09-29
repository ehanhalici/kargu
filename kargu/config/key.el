;;; kargu/config/key.el --- Multi-tier API key and endpoint resolution -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; API key and base endpoint resolution across custom variables, TOML tables,
;; environment variables, and auth-source.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
;; Ensure the package root is on `load-path' during byte/native
;; compilation from a subdirectory (Magit-style kargu/core features).
(eval-and-compile
  (let ((root (locate-dominating-file
               (or (bound-and-true-p byte-compile-current-file)
                   load-file-name
                   buffer-file-name
                   default-directory)
               "kargu.el")))
    (when root
      (add-to-list 'load-path (file-name-as-directory
                               (expand-file-name root))))))

(require 'kargu/core)
(require 'kargu/providers)

(declare-function kargu--config-providers "kargu/config/schema" ())
(declare-function kargu--config-plist "kargu/config/schema" ())
(declare-function url-host "url-parse")
(declare-function url-generic-parse-url "url-parse")
(declare-function auth-source-search "auth-source")

(defun kargu--provider-name ()
  "Name of the active provider."
  (or (kargu--nonempty kargu--session-provider)
      (kargu--nonempty (plist-get (kargu--config-plist) :provider))
      (caar (kargu--config-providers))
      "default"))

(defun kargu--provider-plist ()
  "Plist for the active provider (`:api', `:apikey', `:models')."
  (let* ((name (kargu--provider-name))
         (entry (assoc name (kargu--config-providers)))
         (default-info (kargu-provider-get name))
         (toml-plist (cond
                      (entry (cdr entry))
                      (default-info nil)
                      (t (cdr (car (kargu--config-providers)))))))
    (append toml-plist
            (when (and default-info (null (plist-get toml-plist :api)))
              (let ((default-api (plist-get default-info :api)))
                (and (kargu--nonempty default-api)
                     (list :api default-api))))
            (when (and default-info (null (plist-get toml-plist :models)))
              (let ((default-models (kargu-provider-models name)))
                (and default-models
                     (list :models default-models)))))))

(defun kargu--strip-trailing-slashes (url)
  "Return URL without a trailing slash."
  (if (and (stringp url) (not (string-empty-p url)))
      (replace-regexp-in-string "/+\\'" "" url)
    url))

(defun kargu--api-base (&optional provider-name)
  "Return endpoint base URL.
Use active or specified PROVIDER-NAME `api' from TOML config if set,
otherwise provider's catalog default URL, else `kargu-api-base'."
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
    (kargu--strip-trailing-slashes
     (or (and (kargu--nonempty toml-api) toml-api)
         (and (kargu--nonempty active-api) active-api)
         (and (kargu--nonempty catalog-api) catalog-api)
         kargu-api-base))))

(defun kargu--model ()
  "Model id: session model, explicit TOML model, or nil if not selected yet."
  (or (kargu--nonempty kargu--session-model)
      (and (null kargu--session-provider)
           (kargu--nonempty (plist-get (kargu--config-plist) :model)))
      (kargu--nonempty (plist-get (kargu--provider-plist) :model))))

(defun kargu--url-host (url)
  "Host name of URL, or nil."
  (when (kargu--nonempty url)
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
                 (and (kargu--nonempty val) val)))
             envs)))

(defun kargu--resolve-api-key (&optional provider-name)
  "Resolve the API key for the active or specified PROVIDER-NAME.
Multi-tier resolution:
1. `kargu-api-key' global variable override.
2. TOML configuration `:apikey' for the provider.
3. Environment variables declared on the provider in catalog (`:env').
4. Auth-source credentials for the provider endpoint host."
  (let* ((pname (or provider-name (kargu--provider-name)))
         (pname-str (if (symbolp pname) (symbol-name pname) (format "%s" pname)))
         (pname-lower (downcase (string-trim pname-str)))
         (entry (assoc pname-lower (and (fboundp 'kargu--config-providers) (kargu--config-providers))))
         (toml-plist (if entry
                         (cdr entry)
                       (if (and (null provider-name) (fboundp 'kargu--provider-plist))
                           (kargu--provider-plist)
                         nil)))
         (toml-key (and toml-plist (plist-get toml-plist :apikey)))
         (env-val (kargu--provider-env-api-key pname-lower)))
    (cond
     ;; 1. Global override
     ((and (boundp 'kargu-api-key) (kargu--nonempty kargu-api-key)))
     ;; 2. Explicit TOML config for this provider
     ((kargu--nonempty toml-key))
     ;; 3. Provider-declared environment variables from catalog
     ((kargu--nonempty env-val))
     ;; 4. Auth-source lookup for endpoint host
     ((let* ((api (or (and toml-plist (plist-get toml-plist :api))
                      (and (fboundp 'kargu-provider-api) (kargu-provider-api pname-lower))
                      (and (null provider-name) (kargu--api-base))
                      kargu-api-base))
             (host (and api (kargu--url-host api)))
             (found (and host (progn (require 'auth-source)
                                     (auth-source-search :host host :max 1)))))
        (when found
          (let ((secret (plist-get (car found) :secret)))
            (kargu--nonempty
             (cond
              ((functionp secret) (funcall secret))
              ((stringp secret) secret)))))))
     ;; 5. Explicit empty string key in TOML (e.g. keyless proxy/local runner)
     ((and toml-plist (plist-member toml-plist :apikey)) "")
     (t nil))))

(provide 'kargu/config/key)

;;; kargu/config/key.el ends here
