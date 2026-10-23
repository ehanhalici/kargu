;;; key.el --- Multi-tier API key and endpoint resolution -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; API key and base endpoint resolution across custom variables, TOML tables,
;; environment variables, and auth-source.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rx)
(require 'kargu/core)
(require 'kargu/async)
(require 'kargu/contract/result)
(require 'kargu/providers)
(require 'kargu/config/worker)

(defvar auth-sources)

(defvar kargu-config-credential-adapter nil
  "Optional function (PROVIDER HOST TASK) for cancellable secret resolution.")

(defvar kargu-config--nonblocking-auth-p nil
  "Non-nil while provider discovery checks auth-source without secret unlock.")

(declare-function kargu--config-providers "kargu/config/schema" ())
(declare-function kargu--config-plist "kargu/config/schema" ())
(declare-function url-host "url-parse")
(declare-function url-generic-parse-url "url-parse")
(declare-function auth-source-search "auth-source")
(declare-function kargu-config-revision "kargu/config/schema" ())
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
     (or (and (fboundp 'kargu-connection-current) (kargu-connection-current)
              (equal pname-lower (kargu-connection-snapshot-provider (kargu-connection-current)))
              (kargu-connection-snapshot-endpoint (kargu-connection-current)))
         (and (kargu-nonempty toml-api) toml-api)
         (and (kargu-nonempty active-api) active-api)
         (and (kargu-nonempty catalog-api) catalog-api)
         kargu-api-base))))

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

(defun kargu-config-auth-source-supported-p (source)
  "Return non-nil when SOURCE names a supported local plaintext auth file."
  (not (null (kargu-config-worker-source-path source))))

(defun kargu-config--unsupported-auth-sources-p ()
  "Return non-nil when `auth-sources' declares an interactive/encrypted store."
  (and (boundp 'auth-sources)
       (listp auth-sources)
       (cl-some (lambda (src) (not (kargu-config-auth-source-supported-p src)))
                auth-sources)))

(defun kargu--auth-source-search-safe (host)
  "Search supported `auth-sources' for HOST without unlocking encrypted files."
  (require 'auth-source)
  (let ((auth-sources
         (if (and (boundp 'auth-sources) (listp auth-sources))
             (cl-remove-if-not #'kargu-config-auth-source-supported-p auth-sources)
           auth-sources)))
    (when (or (not (listp auth-sources)) auth-sources)
      (auth-source-search :host host :max 1))))

(defun kargu--auth-source-api-key (api)
  "Return the auth-source secret for URL API's host, or nil.
When `kargu-config--nonblocking-auth-p' is non-nil, skip `:secret' functions."
  (let* ((host (and api (kargu--url-host api)))
         (found (and host (kargu--auth-source-search-safe host))))
    (when found
      (let ((secret (plist-get (car found) :secret)))
        (kargu-nonempty
         (cond
          ((stringp secret) secret)
          ((and (not kargu-config--nonblocking-auth-p) (functionp secret))
           (funcall secret))))))))

(defun kargu--provider-toml-plist (pname-lower provider-name)
  "TOML plist of PNAME-LOWER; the active provider's when PROVIDER-NAME is nil."
  (if-let* ((entry (assoc pname-lower (and (fboundp 'kargu--config-providers)
                                           (kargu--config-providers)))))
      (cdr entry)
    (and (null provider-name) (fboundp 'kargu--provider-plist)
         (kargu--provider-plist))))

(defun kargu--provider-auth-api (pname-lower provider-name toml-plist)
  "Return endpoint URL for PNAME-LOWER, PROVIDER-NAME and TOML-PLIST."
  (or (and toml-plist (plist-get toml-plist :api))
      (and (fboundp 'kargu-provider-api) (kargu-provider-api pname-lower))
      (and (null provider-name) (kargu--api-base))
      kargu-api-base))

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
         (toml-plist (kargu--provider-toml-plist pname-lower provider-name)))
    (or (kargu--resolve-direct-api-key provider-name)
        (kargu--auth-source-api-key
         (kargu--provider-auth-api pname-lower provider-name toml-plist)))))

(defun kargu-config-api-key-fast (&optional provider-name)
  "Return PROVIDER-NAME's key without invoking secret functions or pinentry.
Reads purely from in-memory configuration without triggering auth-source search."
  (kargu--resolve-direct-api-key provider-name))

(defun kargu-config-api-key (&optional provider-name)
  "Resolve PROVIDER-NAME's credential using the configuration precedence.
The global override belongs to the active provider only.  An explicit
empty TOML key denotes keyless access; missing references fall through."
  (let ((kargu-config--nonblocking-auth-p nil))
    (kargu--resolve-api-key provider-name)))

(defun kargu-config-resolve-api-key-result (&optional provider-name)
  "Resolve PROVIDER-NAME's credential as a typed `kargu-result'.
Unsupported interactive auth backends return code `unavailable'.
Callable secret functions require async resolution and return `unavailable'."
  (let* ((pname (or provider-name (kargu--provider-name)))
         (pname-lower (downcase (string-trim (format "%s" pname))))
         (direct (kargu--resolve-direct-api-key provider-name)))
    (cond
     (direct (kargu-ok direct))
     ((and (fboundp 'kargu-provider-keyless-p)
           (kargu-provider-keyless-p pname-lower))
      (kargu-ok ""))
     ((kargu-config--unsupported-auth-sources-p)
      (kargu-err (format "Credential backend for %s is unavailable" pname-lower)
                 'unavailable))
     (t
      (let* ((toml-plist (kargu--provider-toml-plist pname-lower provider-name))
             (api (kargu--provider-auth-api pname-lower provider-name toml-plist))
             (host (and api (kargu--url-host api)))
             (found (and host (kargu--auth-source-search-safe host))))
        (if found
            (let ((secret (plist-get (car found) :secret)))
              (cond
               ((stringp secret) (kargu-ok secret))
               ((functionp secret)
                ;; Callable secret functions must never be executed synchronously on the UI thread!
                (kargu-err (format "Callable secret for %s requires async resolution" pname-lower)
                           'unavailable))
               (t (kargu-err (format "No API key configured for %s" pname-lower)
                             'missing))))
          (kargu-err (format "No API key configured for %s" pname-lower)
                     'missing)))))))

(defun kargu-config--deliver-key-result (callback value error)
  "Deliver resolved credential VALUE or ERROR to CALLBACK as a `kargu-result'."
  (cond
   ((or (kargu-ok-p value) (kargu-err-p value)) (funcall callback value))
   (error (funcall callback (kargu-err error 'failed)))
   ((stringp value) (funcall callback (kargu-ok value)))
   (t (funcall callback (kargu-err "Credential resolution failed" 'failed)))))

(defun kargu-config--dispatch-key (provider endpoint task)
  "Resolve PROVIDER's key into TASK using only its captured ENDPOINT."
  (let ((direct (kargu--resolve-direct-api-key provider)))
    (cond
     (direct (kargu-async-finish task (kargu-ok direct)))
     ((kargu-provider-keyless-p provider) (kargu-async-finish task (kargu-ok "")))
     ((functionp kargu-config-credential-adapter)
      (funcall kargu-config-credential-adapter provider (kargu--url-host endpoint) task))
     (t (kargu-config-worker-resolve provider (kargu--url-host endpoint) task)))))

(cl-defun kargu-config-resolve-api-key-async
    (provider-name callback &key timeout origin)
  "Resolve PROVIDER-NAME's credential into CALLBACK within TIMEOUT seconds.
ORIGIN, endpoint and configuration revision must still match on delivery."
  (kargu-contract-assert #'functionp callback)
  (let* ((origin (or origin (current-buffer)))
         (session (kargu-session-context origin))
         (provider (downcase (string-trim (format "%s" (or provider-name (kargu--provider-name))))))
         (endpoint (kargu--api-base provider))
         (revision (kargu-config-revision))
         (valid-p (lambda ()
                    (and (buffer-live-p origin)
                         (with-current-buffer origin
                           (and (eq session (kargu-session-context))
                                (= revision (kargu-config-revision))
                                (equal endpoint (kargu--api-base provider)))))))
         (task (kargu-async-start
                (lambda (value error)
                  (when (funcall valid-p)
                    (kargu-config--deliver-key-result callback value error)))
                :owner nil :parent nil :buffer origin
                :timeout (or timeout kargu-config-worker-default-timeout) :valid-p valid-p)))
    (funcall (kargu-async-wrap task
                              (lambda () (kargu-config--dispatch-key provider endpoint task))))
    task))

(provide 'kargu/config/key)

;;; key.el ends here
