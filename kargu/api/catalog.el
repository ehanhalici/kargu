;;; kargu/api/catalog.el --- Dynamic model catalog and metadata -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Dynamic /models catalog querying, caching, and model metadata extraction.
;; Extracts context windows, pricing, reasoning/thinking support, and multimodal capabilities.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'plz)
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
(require 'kargu/contract)
(require 'kargu/json)
(require 'kargu/config/key)
(require 'kargu/api/circuit)

(declare-function kargu-provider-models-api "kargu/providers/registry" (provider))
(declare-function kargu-provider-keyless-p "kargu/providers/registry" (provider))
(declare-function kargu-provider-format "kargu/providers/registry" (provider))
(declare-function kargu-provider-effort-specs "kargu/providers/registry" (id))
(declare-function kargu--plz-error-message "kargu/api/http" (err))
(declare-function kargu--api-headers "kargu/api/http" (key &optional provider-name))
(declare-function kargu-history-compact-threshold "kargu/history-compact")

(defvar kargu--models-generation 0
  "Separate generation counter for model-catalog requests.")

(defvar kargu--live-models-cache (make-hash-table :test 'equal)
  "Session cache of live model ID lists, keyed by provider name.")

(defvar kargu--model-metadata-table (make-hash-table :test 'equal)
  "Hash table mapping model ID string to metadata plist:
(:id :context-window :max-output :description :supports-reasoning :reasoning-efforts).")

(defun kargu-model-set-metadata (id plist)
  "Register metadata PLIST for model ID string."
  (when (and (stringp id) (not (string-empty-p id)))
    (puthash (downcase (string-trim id)) plist kargu--model-metadata-table)))

(defun kargu-model-get-metadata (id)
  "Retrieve metadata plist for model ID string, or nil."
  (when (and (stringp id) (not (string-empty-p id)))
    (let* ((clean (downcase (string-trim id)))
           (meta (gethash clean kargu--model-metadata-table)))
      (or meta
          ;; If clean has slash, try without provider prefix
          (and (string-match-p "/" clean)
               (let ((short-id (car (last (split-string clean "/")))))
                 (gethash short-id kargu--model-metadata-table)))
          ;; If clean has no slash, look for any key ending in /clean or :clean
          (let (found)
            (maphash (lambda (k v)
                       (when (and (not found)
                                  (or (string-suffix-p (concat "/" clean) k)
                                      (string-suffix-p (concat ":" clean) k)))
                         (setq found v)))
                     kargu--model-metadata-table)
            found)))))


(defun kargu--extract-models-from-json (data)
  "Extract a list of model alists or IDs from decoded JSON DATA."
  (cond
   ((null data) nil)
   ((vectorp data) (append data nil))
   ((listp data)
    (or (kargu--aget data "data")
        (kargu--aget data "models")
        (kargu--aget data "items")
        (and (consp (car data))
             (or (kargu--aget (car data) "id")
                 (kargu--aget (car data) "name"))
             data)))))

(defun kargu-model-get-prop (model-id prop-key)
  "Retrieve property PROP-KEY from MODEL-ID's metadata.
Looks up directly in the model's raw API data."
  (when-let* ((data (kargu-model-get-metadata model-id)))
    (let ((k-str (if (stringp prop-key) prop-key (format "%s" prop-key)))
          (k-sym (if (keywordp prop-key) prop-key (intern (concat ":" (format "%s" prop-key))))))
      (cond
       ((consp data)
        (or (kargu--aget data k-str)
            (and (listp data) (plist-get data k-sym))))
       (t nil)))))

(defun kargu-model-set-prop (model-id prop-key prop-value)
  "Set or override PROP-KEY with PROP-VALUE in MODEL-ID's metadata."
  (let* ((mid (or model-id (kargu--model) ""))
         (data (kargu-model-get-metadata mid))
         (k-str (if (stringp prop-key) prop-key (format "%s" prop-key)))
         (updated
          (cond
           ((consp data)
            (cons (cons k-str prop-value)
                  (cl-remove-if (lambda (x) (and (consp x) (equal (car x) k-str))) data)))
           (t (list (cons k-str prop-value))))))
    (kargu-model-set-metadata mid updated)
    updated))

(defun kargu--record-models-metadata (models &optional provider-name)
  "Record raw model metadata objects directly from MODELS list into hash table."
  (let ((pname (or provider-name (kargu--provider-name))))
    (dolist (m models)
      (when (listp m)
        (let* ((id (or (kargu--aget m "id") (kargu--aget m "name")))
               (clean-id (if (and (stringp id) (string-prefix-p "models/" id))
                             (substring id 7)
                           id)))
          (when (and (stringp clean-id) (not (string-empty-p clean-id)))
            (let ((entry (if (consp m)
                             (cons (cons "provider" pname) m)
                           m)))
              (kargu-model-set-metadata clean-id entry)
              (when (string-match-p "/" clean-id)
                (let ((short-id (car (last (split-string clean-id "/")))))
                  (unless (gethash (downcase short-id) kargu--model-metadata-table)
                    (kargu-model-set-metadata short-id entry)))))))))))

(defun kargu--unwrap-alist (value)
  "Return VALUE when it is an alist.
A one-element list whose car is an alist is unwrapped."
  (if (and (consp value)
           (consp (car-safe value))
           (consp (car-safe (car-safe value))))
      (car value)
    value))

(defun kargu--record-get (data key)
  "Return KEY from raw alist or plist DATA, or nil."
  (when (listp data)
    (let ((name (if (stringp key) key (format "%s" key))))
      (or (kargu--aget data name)
          (plist-get data (intern (concat ":" name)))
          (plist-get data (intern (concat ":" (replace-regexp-in-string "_" "-" name))))
          (plist-get data (intern (concat ":" (replace-regexp-in-string "-" "_" name))))))))

(defun kargu--nested-get (data key subkey)
  "Return SUBKEY inside KEY of DATA."
  (kargu--record-get (kargu--unwrap-alist (kargu--record-get data key)) subkey))

(defun kargu--read-number (value)
  "Return VALUE as an integer, or nil when it is not a number."
  (cond
   ((null value) nil)
   ((integerp value) value)
   ((numberp value) (round value))
   ((and (stringp value) (not (string-empty-p (string-trim value))))
    (kargu-to-int value))
   (t nil)))

(defun kargu--read-context-window (data)
  "Context window from DATA, or nil when the record omits it."
  (kargu--read-number
   (or (kargu--record-get data "context_length")
       (kargu--record-get data "context_window")
       (kargu--record-get data "inputTokenLimit")
       (kargu--record-get data "context-window"))))

(defun kargu--read-max-output (data)
  "Max output tokens from DATA, or nil when the record omits it."
  (kargu--read-number
   (or (kargu--record-get data "max_output")
       (kargu--record-get data "outputTokenLimit")
       (kargu--record-get data "max_completion_tokens")
       (kargu--nested-get data "top_provider" "max_completion_tokens")
       (kargu--record-get data "max-output"))))

(defun kargu--read-input-cost (data)
  "Prompt price from DATA as a number, or nil."
  (let ((raw (or (kargu--nested-get data "pricing" "prompt")
                 (kargu--record-get data "input-cost"))))
    (cond
     ((numberp raw) raw)
     ((and (stringp raw) (not (string-empty-p raw)))
      (ignore-errors (string-to-number raw)))
     (t nil))))

(defun kargu--zero-price-p (value)
  "Non-nil when VALUE is a numeric zero price."
  (cond
   ((numberp value) (= value 0))
   ((and (stringp value) (string-match-p "[0-9]" value))
    (let ((n (ignore-errors (string-to-number value))))
      (and (numberp n) (= n 0))))
   (t nil)))

(defun kargu--read-free-p (data)
  "Non-nil when DATA says the model is free."
  (or (and (listp data) (plist-get data :free))
      (kargu--zero-price-p (kargu--nested-get data "pricing" "prompt"))
      (kargu--zero-price-p (kargu--record-get data "input-cost"))))

(defun kargu--read-vision-p (data)
  "Non-nil when DATA says the model accepts images."
  (or (and (listp data) (plist-get data :vision))
      (let ((modality (or (kargu--nested-get data "architecture" "modality")
                          (kargu--record-get data "modality"))))
        (and (stringp modality) (string-match-p "image" modality) t))))

(defun kargu--read-params (data)
  "Parameter-size label from DATA, or nil."
  (or (let ((stored (and (listp data) (plist-get data :params))))
        (and (stringp stored) (not (string-empty-p stored)) stored))
      (let* ((details (kargu--unwrap-alist (kargu--record-get data "details")))
             (size (kargu--record-get details "parameter_size"))
             (quant (kargu--record-get details "quantization_level")))
        (cond
         ((and (stringp size) (not (string-empty-p size))
               (stringp quant) (not (string-empty-p quant)))
          (format "%s %s" size quant))
         ((and (stringp size) (not (string-empty-p size))) size)))))

(defun kargu--effort-name-list (value)
  "Effort names in list or vector VALUE, or nil.
A bare string is not a list."
  (cond
   ((vectorp value) (kargu--effort-name-list (append value nil)))
   ((and (proper-list-p value)
         value
         (cl-every (lambda (item)
                     (or (stringp item)
                         (and (symbolp item) (not (keywordp item)))))
                   value))
    (delq nil
          (mapcar (lambda (item)
                    (let ((name (if (stringp item) item (symbol-name item))))
                      (and (not (string-empty-p name)) name)))
                  value)))
   (t nil)))

(defun kargu--effort-csv (value)
  "Effort names in comma-separated string VALUE, or nil."
  (when (and (stringp value) (not (string-empty-p (string-trim value))))
    (delq nil
          (mapcar (lambda (part)
                    (let ((name (string-trim part)))
                      (and (not (string-empty-p name)) name)))
                  (split-string value ",")))))

(defun kargu--effort-names (value type)
  "Effort names in VALUE of TYPE (`list' or `csv'), or nil."
  (cond
   ((eq type 'list) (kargu--effort-name-list value))
   ((eq type 'csv) (kargu--effort-csv value))
   (t nil)))

(defun kargu--path-get (data key)
  "KEY inside DATA.
A list of objects is searched for KEY.  A missing key is nil."
  (or (kargu--record-get data key)
      (and (vectorp data) (kargu--path-get (append data nil) key))
      (and (consp data)
           (consp (car data))
           (consp (caar data))
           (cl-some (lambda (item) (kargu--path-get item key)) data))))

(defun kargu--read-path (data path)
  "Value at PATH of string keys in DATA, or nil."
  (if (null path)
      data
    (kargu--read-path (kargu--path-get data (car path)) (cdr path))))

(defun kargu--efforts-from-specs (data specs)
  "Effort names in DATA at the first matching spec in SPECS, or nil.
Each spec is `:path' and `:type'."
  (when (and data specs)
    (cl-some (lambda (spec)
               (kargu--effort-names
                (kargu--read-path data (plist-get spec :path))
                (plist-get spec :type)))
             specs)))

(defun kargu--read-efforts (data)
  "Effort names from DATA, or nil when the record has none.
A stored `:reasoning-efforts' list is that list.  Otherwise the
active provider's declared paths are read.  An undeclared key
yields nothing."
  (cond
   ((null data) nil)
   ((kargu--reasoning-disabled-p data) nil)
   ((and (listp data)
         (kargu--effort-name-list (plist-get data :reasoning-efforts))))
   (t (and (fboundp 'kargu-provider-effort-specs)
           (kargu--efforts-from-specs
            data
            (kargu-provider-effort-specs
             (and (fboundp 'kargu--provider-name) (kargu--provider-name))))))))

(defun kargu-model-read (&optional model-id)
  "Read catalog fields for MODEL-ID from its raw API record.
The plist keys are `:context-window', `:max-output', `:reasoning-efforts',
`:vision', `:free', `:params', and `:input-cost'.  A missing field is nil.
This does not invent a context window or an effort list."
  (let ((data (kargu-model-get-metadata (or model-id (kargu--model) ""))))
    (list :context-window (kargu--read-context-window data)
          :max-output (kargu--read-max-output data)
          :reasoning-efforts (kargu--read-efforts data)
          :vision (kargu--read-vision-p data)
          :free (kargu--read-free-p data)
          :params (kargu--read-params data)
          :input-cost (kargu--read-input-cost data))))

(defun kargu-model-context-window (&optional model-id)
  "Return the context window size for MODEL-ID, or nil when unknown."
  (plist-get (kargu-model-read model-id) :context-window))

(defun kargu--supported-parameters (data)
  "Return DATA's supported_parameters as a list, or nil when absent."
  (let ((raw (or (kargu--aget data "supported_parameters")
                 (kargu--aget data "supportedParameters")
                 (and (listp data) (plist-get data :supported-parameters)))))
    (cond
     ((vectorp raw) (append raw nil))
     ((consp raw) raw)
     (t nil))))

(defun kargu--tools-explicitly-disabled-p (data)
  "Return non-nil when DATA says tools are unavailable.
A missing field is not a disable.  A false `supports_tools' flag,
a stored `:supports-tools' nil, or a parameter list that omits
\"tools\" are."
  (or (let ((flag (kargu--aget data "supports_tools")))
        (or (eq flag :json-false) (equal flag "false")))
      (and (listp data)
           (plist-member data :supports-tools)
           (not (plist-get data :supports-tools)))
      (let ((params (kargu--supported-parameters data)))
        (and params (not (member "tools" params))))))

(defun kargu-model-supports-tools-p (&optional model-id)
  "Return non-nil unless MODEL-ID's API explicitly disables tools.
Missing metadata and a missing field both leave tools available."
  (let ((data (kargu-model-get-metadata (or model-id (kargu--model) ""))))
    (not (and data (kargu--tools-explicitly-disabled-p data)))))

(defun kargu--reasoning-support-flag (data)
  "Return the supports-reasoning flag in DATA, or nil when it is absent."
  (and data
       (or (kargu--aget data "supports_reasoning")
           (kargu--aget data "supports-reasoning")
           (and (listp data) (plist-get data :supports-reasoning)))))

(defun kargu--reasoning-disabled-p (data)
  "Return non-nil when DATA explicitly disables reasoning."
  (let ((flag (kargu--reasoning-support-flag data)))
    (or (eq flag :json-false) (equal flag "false"))))

(defun kargu-model-reasoning-efforts (&optional model-id provider-name)
  "Return reasoning effort names for MODEL-ID from its API metadata.
When metadata is missing, query PROVIDER-NAME once and read it again.
A false `supports_reasoning' flag returns nil.  A missing list returns nil."
  (let* ((mid (or model-id (kargu--model) ""))
         (pname (or provider-name (kargu--provider-name)))
         (pname-str (if (symbolp pname) (symbol-name pname) (format "%s" (or pname ""))))
         (data (kargu-model-get-metadata mid)))
    (when (and (null data)
               (not (string-empty-p pname-str))
               (fboundp 'kargu-api-fetch-models-sync))
      (kargu-api-fetch-models-sync pname-str))
    (plist-get (kargu-model-read mid) :reasoning-efforts)))

(defun kargu-model-supports-reasoning-p (&optional model-id provider-name)
  "Return non-nil if MODEL-ID's API says it supports reasoning.
An explicit true flag counts even when the API sent no level list."
  (let* ((data (kargu-model-get-metadata (or model-id (kargu--model) "")))
         (flag (kargu--reasoning-support-flag data)))
    (and (not (kargu--reasoning-disabled-p data))
         (or (memq flag '(t :json-true))
             (equal flag "true")
             (and (kargu-model-reasoning-efforts model-id provider-name) t)))))

(defun kargu-model--context-label (ctx)
  "Inspector label for context size CTX."
  (if (numberp ctx)
      (format "%d tokens (~%d chars)" ctx (round (* ctx 3.5)))
    "unknown"))

(defun kargu-model--format-context (ctx)
  "Annotation token for context size CTX, or nil."
  (when (and (numberp ctx) (> ctx 0))
    (if (>= ctx 1000000)
        (format "%dm ctx" (/ ctx 1000000))
      (format "%dk ctx" (/ ctx 1000)))))

(defun kargu-model--format-max-output (max-out)
  "Annotation token for max output MAX-OUT, or nil."
  (when (and (numberp max-out) (> max-out 0))
    (format "max %dk" (max 1 (/ max-out 1024)))))

(defun kargu-model--format-efforts (efforts)
  "Annotation token for effort list EFFORTS, or nil."
  (when (and (listp efforts) efforts)
    (if (and (member "low" efforts) (member "high" efforts))
        "🧠 think: low..high"
      (format "🧠 think: %s" (mapconcat #'identity efforts ",")))))

(defun kargu-model--format-price (cost free)
  "Annotation token for input COST, or the free badge."
  (cond
   (free "⚡ free")
   ((and (numberp cost) (> cost 0))
    (format "$%.2f/1M" (* cost 1000000.0)))))

(defun kargu-model--annotation-badges (fields)
  "Badge strings for catalog FIELDS read by `kargu-model-read'."
  (let ((parts nil))
    (when-let* ((ctx (kargu-model--format-context (plist-get fields :context-window))))
      (push ctx parts))
    (when-let* ((max-out (kargu-model--format-max-output (plist-get fields :max-output))))
      (push max-out parts))
    (let ((params (plist-get fields :params)))
      (when (and (stringp params) (not (string-empty-p params)))
        (push params parts)))
    (when-let* ((efforts (kargu-model--format-efforts (plist-get fields :reasoning-efforts))))
      (push efforts parts))
    (when (plist-get fields :vision)
      (push "👁 vision" parts))
    (when-let* ((price (kargu-model--format-price
                        (plist-get fields :input-cost)
                        (plist-get fields :free))))
      (push price parts))
    (nreverse parts)))

(defun kargu-model-annotation-string (model-id &optional _provider-name)
  "Build a compact annotation badge string for MODEL-ID."
  (let ((parts (kargu-model--annotation-badges (kargu-model-read model-id))))
    (if parts
        (format "  [%s]" (mapconcat #'identity parts " · "))
      "")))

(defun kargu--catalog-models-url (pname-lower api-base)
  "Determine the models endpoint URL for PNAME-LOWER and API-BASE."
  (let* ((default-api (and (fboundp 'kargu-provider-api) (kargu-provider-api pname-lower)))
         (custom-models-url (and (fboundp 'kargu-provider-models-api)
                                 (kargu-provider-models-api pname-lower))))
    (cond
     ;; If user configured a custom api-base different from default catalog api, derive from api-base:
     ((and (kargu--nonempty api-base)
           default-api
           (not (equal (kargu--strip-trailing-slashes api-base)
                       (kargu--strip-trailing-slashes default-api))))
      (cond
       ((string-suffix-p "/models" api-base) api-base)
       ((and (fboundp 'kargu-provider-format)
             (eq (kargu-provider-format pname-lower) 'ollama)
             (not (string-suffix-p "/v1" api-base)))
        (concat api-base "/api/tags"))
       (t (concat api-base "/models"))))
     ;; If catalog specified a dedicated models-api (and user didn't override api), use it:
     (custom-models-url custom-models-url)
     ;; Otherwise derive from api-base:
     ((and (fboundp 'kargu-provider-format)
           (eq (kargu-provider-format pname-lower) 'ollama)
           (not (string-suffix-p "/v1" api-base)))
      (concat api-base "/api/tags"))
     ((string-suffix-p "/models" api-base)
      api-base)
     (t (concat api-base "/models")))))

(defun kargu--catalog-cache-live-models (pname-lower extracted)
  "Record metadata and cache clean model IDs for PNAME-LOWER from EXTRACTED list."
  (kargu--record-models-metadata extracted pname-lower)
  (let ((clean-ids
         (delq nil
               (mapcar (lambda (m)
                         (let ((id (if (consp m)
                                       (or (kargu--aget m "id") (kargu--aget m "name"))
                                     m)))
                           (if (and (stringp id) (string-prefix-p "models/" id))
                               (substring id 7)
                             id)))
                       extracted))))
    (when clean-ids
      (puthash pname-lower clean-ids kargu--live-models-cache))))

(defun kargu-api-list-models (&optional callback provider-name)
  "Fetch catalog from active or specified PROVIDER-NAME asynchronously.
CALLBACK receives either the list of model alists or an error alist."
  (interactive)
  (let* ((cb (or callback #'ignore))
         (pname (or provider-name (kargu--provider-name)))
         (pname-str (if (symbolp pname) (symbol-name pname) (format "%s" (or pname "default"))))
         (pname-lower (downcase (string-trim pname-str)))
         (key (kargu--resolve-api-key pname-lower))
         (gen (cl-incf kargu--models-generation))
         (is-keyless (and (fboundp 'kargu-provider-keyless-p)
                          (kargu-provider-keyless-p pname-lower)))
         (api-base (kargu--api-base pname-lower))
         (url (kargu--catalog-models-url pname-lower api-base))
         (headers (kargu--api-headers key pname-lower)))
    (if (and (null key) (not is-keyless))
        (funcall cb
                 `(("error" . (("message" . ,(format "no API key for provider %s" pname-str))))))
      (plz 'get url
           :headers headers
           :as 'string
           :then (lambda (body)
                   (when (= gen kargu--models-generation)
                     (let* ((data (kargu--json-decode-safe body))
                            (extracted (kargu--extract-models-from-json data)))
                       (if extracted
                           (progn
                             (kargu--catalog-cache-live-models pname-lower extracted)
                             (funcall cb extracted))
                         (funcall cb
                                  `(("error" .
                                     (("message" . ,(format "unexpected /models body from %s: %s"
                                                           pname-str
                                                           (truncate-string-to-width
                                                            (or body "") 200)))))))))))
           :else (lambda (err)
                   (when (= gen kargu--models-generation)
                     (funcall cb
                              `(("error" .
                                 (("message" .
                                   ,(kargu--plz-error-message err))))))))))))

(defun kargu-api-prefetch-models (&optional provider-name)
  "Prefetch live models asynchronously for PROVIDER-NAME into cache."
  (interactive)
  (let ((pname (or provider-name (kargu--provider-name))))
    (kargu-api-list-models #'ignore pname)))

(defun kargu-api-fetch-models-sync (&optional provider-name)
  "Fetch and cache the model catalog synchronously from PROVIDER-NAME."
  (let* ((pname (or provider-name (kargu--provider-name)))
         (pname-str (if (symbolp pname) (symbol-name pname) (format "%s" (or pname "default"))))
         (pname-lower (downcase (string-trim pname-str)))
         (result nil)
         (done nil))
    (kargu-api-list-models
     (lambda (models)
       (let ((err (kargu--aget models "error")))
         (unless err
           (kargu--record-models-metadata models pname-lower)
           (let* ((raw-ids (kargu--extract-models-from-json models))
                  (clean-ids
                   (delq nil
                         (mapcar (lambda (m)
                                   (let ((id (if (consp m)
                                                 (or (kargu--aget m "id") (kargu--aget m "name"))
                                               m)))
                                     (if (and (stringp id) (string-prefix-p "models/" id))
                                         (substring id 7)
                                       id)))
                                 raw-ids))))
             (setq result clean-ids)))
         (setq done t)))
     pname-lower)
    (let ((start (float-time)))
      (while (and (not done) (< (- (float-time) start) 5.0))
        (accept-process-output nil 0.05)))
    (when result
      (puthash pname-lower result kargu--live-models-cache))
    result))

(defun kargu-model-info (&optional model-id)
  "Display complete metadata and all raw API properties for MODEL-ID.
When called interactively, opens an inspector buffer with all key-value pairs."
  (interactive)
  (let* ((mid (or model-id (kargu--model)))
         (pname (or (kargu-model-get-prop mid "provider") (kargu--provider-name)))
         (data (kargu-model-get-metadata mid))
         (props (or (and (listp data) (plist-get data :props)) data))
         (ctx (kargu-model-context-window mid))
         (thresh (and (fboundp 'kargu-history-compact-threshold)
                      (kargu-history-compact-threshold)))
         (max-out (kargu-model-get-prop mid "max_output"))
         (desc (or (kargu-model-get-prop mid "description")
                   (and (listp data) (plist-get data :description))))
         (efforts (or (kargu-model-reasoning-efforts mid pname)
                      (and (listp data) (plist-get data :reasoning-efforts))))
         (effort-curr (or (and (boundp 'kargu-reasoning-effort) kargu-reasoning-effort) "off"))
         (buf (get-buffer-create (format "*kargu model: %s*" mid))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Kargu Model Inspector: %s\n" mid))
        (insert (make-string 60 ?=) "\n\n")
        (insert (format "Provider:            %s\n" pname))
        (insert (format "Context Window:      %s\n" (kargu-model--context-label ctx)))
        (insert (format "Compaction Limit:    %s chars\n" (or thresh 45000)))
        (insert (format "Max Output Tokens:   %s\n" (or max-out "default")))
        (insert (format "Current Effort:      %s\n" effort-curr))
        (insert (format "Supported Efforts:   %s\n"
                        (if efforts (if (listp efforts) (mapconcat #'format efforts ", ") (format "%s" efforts)) "none")))
        (insert (format "Tools Supported:     %s\n"
                        (if (kargu-model-supports-tools-p mid) "yes" "no")))
        (when desc
          (insert (format "\nDescription:\n  %s\n" desc)))
        (insert "\n" (make-string 60 ?-) "\n")
        (insert "Raw API Properties (Key - Value Pairs):\n")
        (insert (make-string 60 ?-) "\n")
        (if (null props)
            (insert "  (No raw API properties recorded for this model)\n")
          (dolist (item (cond ((listp props) props) (t nil)))
            (cond
             ((consp item)
              (let ((k (car item))
                    (v (cdr item)))
                (insert (format "  %-26s : %S\n" k v))))
             (t (insert (format "  %S\n" item))))))
        (insert "\n[Press 'e' to edit/override a property, 'q' to quit]\n")
        (goto-char (point-min))
        (special-mode)
        (local-set-key (kbd "e") #'kargu-model-edit-prop)))
    (if (called-interactively-p 'interactive)
        (display-buffer buf)
      (message "kargu Model: %s (%s) · Context: %s · Compaction: %s chars · MaxOut: %s · Effort: %s%s"
               mid pname
               (kargu-model--context-label ctx)
               (if thresh (format "%d" thresh) "45000")
               (if max-out (format "%d" max-out) "default")
               effort-curr
               (if desc (format " · %s" desc) "")))))

(defun kargu-model-edit-prop (model-id prop-key prop-value)
  "Interactively edit or override PROP-KEY with PROP-VALUE for MODEL-ID."
  (interactive
   (let* ((mid (read-string (format "Model ID (default %s): " (kargu--model)) nil nil (kargu--model)))
          (meta (kargu-model-get-metadata mid))
          (props (and meta (plist-get meta :props)))
          (cand-keys (delq nil (mapcar (lambda (x) (and (consp x) (format "%s" (car x))))
                                       (and (listp props) props))))
          (key (completing-read "Property to edit/override: "
                                (append '("context-window" "max-output" "supports-tools" "supports-reasoning")
                                        cand-keys)
                                nil nil))
          (curr-val (kargu-model-get-prop mid key))
          (val-str (read-string (format "New value for %s (current: %S): " key curr-val))))
     (list mid key (read val-str))))
  (kargu-model-set-prop model-id prop-key prop-value)
  (message "kargu: Property '%s' for model '%s' updated to %S" prop-key model-id prop-value))

(provide 'kargu/api/catalog)

;;; kargu/api/catalog.el ends here
