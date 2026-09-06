;;; kargu/providers/registry.el --- LLM Provider Registry -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Central registry of LLM providers.  Maintains provider metadata including
;; default API endpoint URLs, environment variable names for authentication,
;; and recommended/known models.
;;
;; Allows zero-URL configuration: users only need to provide their API key
;; in `config.toml' (or in environment variables) without having to manually
;; look up and configure provider endpoints.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

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
(require 'auth-source)

(declare-function kargu--url-host "kargu/config")
(declare-function kargu--config-providers "kargu/config")

(defvar kargu-providers--table (make-hash-table :test 'equal)
  "Hash table mapping provider ID strings to provider metadata plists.")

(defconst kargu-providers-popular
  '("openrouter"
    "anthropic"
    "openai"
    "deepseek"
    "groq"
    "togetherai"
    "cerebras"
    "xai"
    "mistral"
    "google"
    "ollama"
    "lmstudio"
    "perplexity"
    "github-copilot"
    "cloudflare-workers-ai"
    "cohere")
  "Curated list of popular and common provider IDs.")

(defun kargu-register-provider (&rest plist)
  "Register a provider in the global registry.
PLIST must contain at least `:id'.  Other supported keys:
`:name', `:api', `:env', `:models', `:npm', `:reasoning-efforts'."
  (let* ((id (plist-get plist :id))
         (id-str (cond ((stringp id) (downcase (string-trim id)))
                       ((symbolp id) (downcase (symbol-name id)))
                       (t (error "Provider :id must be a string or symbol: %S" id)))))
    (when (string-empty-p id-str)
      (error "Provider :id cannot be empty"))
    (puthash id-str plist kargu-providers--table)
    id-str))

(defun kargu-provider-get (id)
  "Return the metadata plist for provider ID (string or symbol), or nil."
  (when id
    (let ((id-str (if (symbolp id) (symbol-name id) (format "%s" id))))
      (gethash (downcase (string-trim id-str)) kargu-providers--table))))

(defun kargu-provider-api (id)
  "Return default base URL for provider ID, or nil if unknown."
  (let ((info (kargu-provider-get id)))
    (and info (kargu--nonempty (plist-get info :api)))))

(defun kargu-provider-env (id)
  "Return list of environment variable names for provider ID."
  (let ((info (kargu-provider-get id)))
    (and info (plist-get info :env))))

(defun kargu-provider-models (id)
  "Return list of known model strings for provider ID."
  (let ((info (kargu-provider-get id)))
    (and info (plist-get info :models))))

(defun kargu-provider-reasoning-efforts (id)
  "Return list of default reasoning effort level strings for provider ID, or nil."
  (let ((info (kargu-provider-get id)))
    (and info (plist-get info :reasoning-efforts))))

(defun kargu-provider-name (id)
  "Return human-readable display name for provider ID."
  (let ((info (kargu-provider-get id)))
    (or (and info (kargu--nonempty (plist-get info :name)))
        (if (symbolp id) (symbol-name id) (format "%s" id)))))

(defun kargu-provider-list ()
  "Return a sorted list of all registered provider ID strings."
  (let (ids)
    (maphash (lambda (k _v) (push k ids)) kargu-providers--table)
    (sort ids #'string-lessp)))

(defconst kargu-providers-local-keyless
  '("ollama" "lmstudio" "llamacpp")
  "List of local runner provider IDs that do not require an API key.")

(defun kargu-provider-valid-key-p (key)
  "Return non-nil if KEY is a valid, non-placeholder API key string."
  (and (stringp key)
       (let ((trimmed (string-trim key)))
         (and (not (string-empty-p trimmed))
              (not (string-suffix-p "..." trimmed))))))

(defun kargu-provider-authenticated-p (id)
  "Non-nil if provider ID has an API key available or is a keyless runner.
Checks TOML configuration, environment variables, and auth-source."
  (let* ((id-str (if (symbolp id) (symbol-name id) (format "%s" id)))
         (id-lower (downcase (string-trim id-str))))
    (cond
     ;; Global override
     ((and (boundp 'kargu-api-key) (kargu-provider-valid-key-p kargu-api-key)) t)
     ;; Keyless local runner
     ((member id-lower kargu-providers-local-keyless) t)
     ;; Check TOML configured providers table
     ((let* ((providers (and (fboundp 'kargu--config-providers)
                             (kargu--config-providers)))
             (entry (assoc id-lower providers)))
        (and entry
             (kargu-provider-valid-key-p (plist-get (cdr entry) :apikey)))))
     ;; Check provider-specific environment variables
     ((let ((envs (kargu-provider-env id-lower)))
        (cl-some (lambda (var)
                   (let ((val (getenv var)))
                     (and (kargu-provider-valid-key-p val) val)))
                 envs)))
     ;; Check auth-source for provider host
     ((let* ((api (kargu-provider-api id-lower))
             (host (and api (fboundp 'kargu--url-host) (kargu--url-host api))))
        (when host
          (ignore-errors
            (car (auth-source-search :host host :max 1))))))
     (t nil))))

(defun kargu-connected-providers ()
  "Return list of all registered provider IDs that are authenticated or keyless."
  (cl-remove-if-not #'kargu-provider-authenticated-p (kargu-provider-list)))

(defun kargu-provider-popular-list ()
  "Return the list of popular provider ID strings that are registered."
  (cl-remove-if-not (lambda (id) (gethash id kargu-providers--table))
                    kargu-providers-popular))

(provide 'kargu/providers/registry)

;;; registry.el ends here
