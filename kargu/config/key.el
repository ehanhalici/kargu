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
              (let ((default-models (plist-get default-info :models)))
                (and default-models
                     (list :models default-models)))))))

(defun kargu--provider-models ()
  "Model id strings listed on the active provider, or nil."
  (let ((models (plist-get (kargu--provider-plist) :models)))
    (and (listp models) models)))

(defun kargu--strip-trailing-slashes (url)
  "Return URL without a trailing slash."
  (if (and (stringp url) (not (string-empty-p url)))
      (replace-regexp-in-string "/+\\'" "" url)
    url))

(defun kargu--api-base (&optional provider-name)
  "Return endpoint base URL.
Use active or specified PROVIDER-NAME `api', else `kargu-api-base'."
  (kargu--strip-trailing-slashes
   (or (and provider-name
            (fboundp 'kargu-provider-api)
            (kargu-provider-api provider-name))
       (kargu--nonempty (plist-get (kargu--provider-plist) :api))
       kargu-api-base)))

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

(defconst kargu--env-key-by-host
  '(("openrouter\\.ai\\'" . "OPENROUTER_API_KEY")
    ("openai\\.com\\'" . "OPENAI_API_KEY")
    ("anthropic\\.com\\'" . "ANTHROPIC_API_KEY"))
  "Alist of host regexp to environment variable name.")

(defun kargu--env-api-key (host)
  "Environment API key for endpoint HOST, or nil."
  (when host
    (let ((entry (cl-find-if (lambda (cell) (string-match-p (car cell) host))
                             kargu--env-key-by-host)))
      (and entry (getenv (cdr entry))))))

(defun kargu--api-key-placeholder-p (key)
  "Non-nil if KEY is empty or a documented dummy placeholder."
  (and (stringp key)
       (let ((k (downcase (string-trim key))))
         (or (string-empty-p k)
             (member k '("dummy" "none" "opencode-free" "placeholder" "..."))
             (string-suffix-p "..." k)))))

(defun kargu--provider-env-api-key ()
  "API key from environment variables associated with active provider, or nil."
  (let ((envs (kargu-provider-env (kargu--provider-name))))
    (cl-some (lambda (var)
               (let ((val (getenv var)))
                 (and (kargu--nonempty val) val)))
             envs)))

(defun kargu--resolve-api-key (&optional provider-name)
  "Resolve the API key for the active or specified PROVIDER-NAME."
  (if (and provider-name
           (not (equal provider-name (kargu--provider-name))))
      (let* ((pname-str (if (symbolp provider-name) (symbol-name provider-name) (format "%s" provider-name)))
             (pname-lower (downcase (string-trim pname-str)))
             (entry (assoc pname-lower (kargu--config-providers)))
             (toml-plist (and entry (cdr entry)))
             (envs (and (fboundp 'kargu-provider-env) (kargu-provider-env pname-lower)))
             (env-val (cl-some (lambda (v) (let ((val (getenv v))) (and (kargu--nonempty val) val))) envs)))
        (or (and toml-plist (kargu--nonempty (plist-get toml-plist :apikey)))
            (kargu--nonempty env-val)
            (and (equal pname-lower (kargu--provider-name)) (kargu--nonempty kargu-api-key))
            (and toml-plist (plist-member toml-plist :apikey) "")
            nil))
    (cond
     ((kargu--nonempty kargu-api-key))
     ((kargu--nonempty (plist-get (kargu--provider-plist) :apikey)))
     ((kargu--nonempty (kargu--provider-env-api-key)))
     ((kargu--nonempty (kargu--env-api-key (kargu--url-host (kargu--api-base)))))
     ((let* ((host (or (kargu--url-host (kargu--api-base)) "openrouter.ai"))
             (found (progn (require 'auth-source)
                           (auth-source-search :host host :max 1))))
        (when found
          (let ((secret (plist-get (car found) :secret)))
            (kargu--nonempty
             (cond
              ((functionp secret) (funcall secret))
              ((stringp secret) secret)))))))
     ((plist-member (kargu--provider-plist) :apikey) "")
     (t nil))))

(provide 'kargu/config/key)

;;; kargu/config/key.el ends here
