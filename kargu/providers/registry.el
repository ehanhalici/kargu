;;; registry.el --- LLM Provider Registry -*- lexical-binding: t; -*-

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

(require 'kargu/core)
(require 'auth-source)

(declare-function kargu--config-providers "kargu/config/schema")
(declare-function kargu-config-api-key-fast "kargu/config/key" (&optional provider-name))
(declare-function kargu-config-profile-field "kargu/config/key" (name &optional provider))
(declare-function kargu-config-native-view "kargu/config/service" ())

(defvar kargu-providers--table (make-hash-table :test 'equal)
  "Hash table mapping provider ID strings to provider metadata plists.")

(defvar kargu-provider-formats nil
  "Alist of (FORMAT . PLIST) wire records.
The provider catalog defines this.  A provider's `:models' plist
replaces that format's model-field map when the value is a field
spec, not a list of model name strings.")


(defun kargu-register-provider (&rest plist)
  "Register a provider in the global registry.
PLIST must contain at least `:id'.  Other supported keys:
`:name', `:api', `:env', `:models', `:models-api',
`:usage-api', `:extra-headers', `:npm', `:format',
`:prompt-caching', `:prompt-for', `:keyless', `:local', `:request'.
The `:request' plist overrides format request policy, preserving explicit nil."
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

(defun kargu-provider--prompt-rules ()
  "Alist of (REGEXP . FILE) taken from each provider's `:prompt-for'.
Longer patterns come first so a specific model id wins over a shorter one."
  (let (rules)
    (maphash
     (lambda (_id info)
       (dolist (pair (kargu-provider--literal (plist-get info :prompt-for)))
         (when (and (consp pair) (stringp (car pair)) (stringp (cdr pair)))
           (push pair rules))))
     kargu-providers--table)
    (sort rules (lambda (a b) (> (length (car a)) (length (car b)))))))

(defun kargu-provider-prompt-file (model-id)
  "Return the base-prompt basename for MODEL-ID, or nil.
The file comes from `:prompt-for' on the provider catalog records.
The same model id always selects the same file."
  (when (kargu-nonempty model-id)
    (let ((id (downcase (string-trim model-id))))
      (cdr (cl-find-if (lambda (pair) (string-match-p (car pair) id))
                       (kargu-provider--prompt-rules))))))

(defun kargu-provider-prompt-caching (id)
  "Return non-nil if provider ID supports prompt caching."
  (let ((info (kargu-provider-get id)))
    (and info (plist-get info :prompt-caching))))

(defun kargu-provider-format (id)
  "Return API access format symbol for provider ID, or nil if unsupported."
  (let ((info (kargu-provider-get id)))
    (and info (plist-get info :format))))

(defun kargu-provider-format-record (format)
  "Wire plist for FORMAT, or nil when the catalog has no such format."
  (and format (cdr (assq format kargu-provider-formats))))

(defun kargu-provider--models-override (info)
  "INFO's `:models' value when it is a field-spec plist, or nil.
A list of model name strings is not a field spec."
  (let ((models (and info (plist-get info :models))))
    (and (consp models) (keywordp (car models)) models)))

(defun kargu-provider-wire (id)
  "Wire plist for provider ID.
A field-spec `:models' on that provider replaces the format's model map."
  (let* ((base (kargu-provider-format-record (kargu-provider-format id)))
         (override (kargu-provider--models-override (kargu-provider-get id))))
    (cond
     ((and base override)
      (plist-put (copy-sequence base) :models override))
     (base)
     (override (list :models override)))))


(defun kargu-provider--effort-specs (models)
  "Effort path specs inside a `:models' plist MODELS, or nil.
One spec plist or a list of spec plists both count."
  (let ((specs (and (consp models)
                    (keywordp (car models))
                    (plist-get models :reasoning-efforts))))
    (cond
     ((and (consp specs) (keywordp (car specs)) (plist-member specs :path))
      (list specs))
     ((and (consp specs) (consp (car specs)) (keywordp (caar specs)))
      specs)
     (t nil))))

(defun kargu-provider-effort-specs (id)
  "Effort path specs for provider ID, or nil when none are declared."
  (let ((wire (kargu-provider-wire id)))
    (kargu-provider--effort-specs (and wire (plist-get wire :models)))))

(defun kargu-provider-cache-marker-p (id)
  "Non-nil when requests to provider ID carry prompt-cache markers.
The provider must enable prompt caching and its format must place markers."
  (and (kargu-provider-prompt-caching id)
       (plist-get (kargu-provider-format-record (kargu-provider-format id))
                  :cache-marker)
       t))

(defun kargu-provider-format-field (id field)
  "FIELD of provider ID's format record, or nil."
  (plist-get (kargu-provider-format-record (kargu-provider-format id)) field))

(defun kargu-provider-reasoning-shape (id)
  "How provider ID's requests carry reasoning settings.
One of `effort' (the default), `nested' or `thinking'."
  (or (plist-get (kargu-provider-format-record (kargu-provider-format id))
                 :reasoning-shape)
      'effort))

(defun kargu-provider-format-auth (format)
  "Auth style for FORMAT: `x-api-key' or `bearer'."
  (or (plist-get (kargu-provider-format-record format) :auth) 'bearer))

(defun kargu-provider-format-headers (format)
  "Default HTTP headers for FORMAT, or nil."
  (plist-get (kargu-provider-format-record format) :default-headers))

(defun kargu-provider-format-stream-p (format)
  "Non-nil when FORMAT accepts an OpenAI SSE stream.
A missing format record streams.  An explicit `:stream' nil does not."
  (let ((spec (kargu-provider-format-record format)))
    (or (null spec)
        (not (plist-member spec :stream))
        (plist-get spec :stream))))

(defun kargu-provider-api (id)
  "Return default base URL for provider ID, or nil if unknown."
  (let ((info (kargu-provider-get id)))
    (and info (kargu-nonempty (plist-get info :api)))))

(defun kargu-provider-models-api (id)
  "Return dedicated models list URL for provider ID, or nil to use default."
  (let ((info (kargu-provider-get id)))
    (and info (kargu-nonempty (or (plist-get info :models-api)
                                  (plist-get info :models-endpoint))))))

(defun kargu-provider-usage-api (id)
  "Return usage / quota endpoint URL for provider ID, or nil."
  (let ((info (kargu-provider-get id)))
    (and info (kargu-nonempty (or (plist-get info :usage-api)
                                  (plist-get info :account-api))))))

(defun kargu-provider--literal (value)
  "Return VALUE, unwrapping a quoted catalog form."
  (if (and (consp value) (eq (car value) 'quote))
      (cadr value)
    value))

(defun kargu-provider-extra-headers (id)
  "Return extra HTTP headers alist for provider ID, or nil."
  (let ((info (kargu-provider-get id)))
    (and info (kargu-provider--literal (plist-get info :extra-headers)))))

(defun kargu-provider-env (id)
  "Return list of environment variable names for provider ID."
  (let ((info (kargu-provider-get id)))
    (and info (plist-get info :env))))

(defun kargu-provider-models (id)
  "Return list of known model strings for provider ID.
A `:models' field-spec plist is not a model list."
  (let* ((info (kargu-provider-get id))
         (models (and info (plist-get info :models))))
    (and (listp models)
         models
         (cl-every #'stringp models)
         models)))

(defun kargu-provider-name (id)
  "Return human-readable display name for provider ID."
  (let ((info (kargu-provider-get id)))
    (or (and info (kargu-nonempty (plist-get info :name)))
        (if (symbolp id) (symbol-name id) (format "%s" id)))))

(defun kargu-provider-list ()
  "Return a sorted list of all registered provider ID strings."
  (let (ids)
    (maphash (lambda (k _v) (push k ids)) kargu-providers--table)
    (sort ids #'string-lessp)))

(defun kargu-provider-keyless-p (id)
  "Read provider ID's last committed native keyless flag."
  (require 'kargu/config/key)
  (kargu-config-profile-field "keyless" id))

(defun kargu-provider-local-p (id)
  "Read provider ID's last committed native local-runner annotation."
  (require 'kargu/config/key)
  (kargu-config-profile-field "local" id))

(defun kargu-provider-authenticated-p (id)
  "Read provider ID's committed native eligibility, without credential lookup."
  (require 'kargu/config/key)
  (kargu-config-profile-field "authenticated" id))

(defun kargu-connected-providers ()
  "Read the native committed eligible provider IDs without IO or unlock."
  (require 'kargu/config/service)
  (when-let* ((view (kargu-config-native-view)))
    (append (gethash "connected" view) nil)))

(provide 'kargu/providers/registry)

;;; registry.el ends here
