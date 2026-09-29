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
(require 'kargu/core)
(require 'kargu/providers)

(declare-function kargu--config-providers "kargu/config/schema" ())
(declare-function kargu--config-plist "kargu/config/schema" ())
(declare-function url-host "url-parse")
(declare-function url-generic-parse-url "url-parse")
(declare-function auth-source-search "auth-source")

(defun kargu--chat-buffer-selection (variable)
  "Non-empty buffer-local VARIABLE when the current buffer is a kargu chat."
  (when (and (derived-mode-p 'kargu-chat-mode) (boundp variable))
    (kargu-nonempty (symbol-value variable))))

(defun kargu--provider-name ()
  "Name of the active provider.
An open chat contributes its own remembered provider."
  (or (kargu--chat-buffer-selection 'kargu-chat--session-provider)
      (kargu-nonempty kargu--session-provider)
      (kargu-nonempty (plist-get (kargu--config-plist) :provider))
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
                (and (kargu-nonempty default-api)
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
     (or (and (kargu-nonempty toml-api) toml-api)
         (and (kargu-nonempty active-api) active-api)
         (and (kargu-nonempty catalog-api) catalog-api)
         kargu-api-base))))

(defun kargu--model ()
  "Model id: the open chat's model, else the session, else an explicit TOML model."
  (or (kargu--chat-buffer-selection 'kargu-chat--session-model)
      (kargu-nonempty kargu--session-model)
      (and (null kargu--session-provider)
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
Nil when VALUE is not a string or a referenced variable is unset or empty."
  (when (stringp value)
    (catch 'unset
      (replace-regexp-in-string
       "\\${\\([A-Za-z_][A-Za-z0-9_]*\\)}"
       (lambda (m)
         (or (kargu-nonempty (getenv (match-string 1 m)))
             (throw 'unset nil)))
       value t t))))

(defun kargu--auth-source-api-key (api)
  "Secret auth-source holds for the host of URL API, or nil."
  (let* ((host (and api (kargu--url-host api)))
         (found (and host (progn (require 'auth-source)
                                 (auth-source-search :host host :max 1)))))
    (when found
      (let ((secret (plist-get (car found) :secret)))
        (kargu-nonempty
         (cond
          ((functionp secret) (funcall secret))
          ((stringp secret) secret)))))))

(defun kargu--provider-toml-plist (pname-lower provider-name)
  "TOML plist of PNAME-LOWER; the active provider's when PROVIDER-NAME is nil."
  (if-let* ((entry (assoc pname-lower (and (fboundp 'kargu--config-providers)
                                           (kargu--config-providers)))))
      (cdr entry)
    (and (null provider-name) (fboundp 'kargu--provider-plist)
         (kargu--provider-plist))))

(defun kargu--resolve-api-key (&optional provider-name)
  "Resolve the API key for the active or specified PROVIDER-NAME.
In order:
1. `kargu-api-key', for the active provider only, so another provider's
   key is never sent to it.
2. The provider's TOML `apikey', with ${VAR} references expanded.  An
   explicit empty string means keyless and stops the search.
3. Environment variables the catalog declares for the provider (`:env').
4. Auth-source credentials for the provider endpoint host."
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
     ((kargu-nonempty (kargu--provider-env-api-key pname-lower)))
     ((kargu--auth-source-api-key
       (or (and toml-plist (plist-get toml-plist :api))
           (and (fboundp 'kargu-provider-api) (kargu-provider-api pname-lower))
           (and (null provider-name) (kargu--api-base))
           kargu-api-base))))))

(provide 'kargu/config/key)

;;; kargu/config/key.el ends here
