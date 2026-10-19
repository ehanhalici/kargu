;;; catalog.el --- Dynamic model catalog and metadata -*- lexical-binding: t; -*-

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
(require 'kargu/core)
(require 'kargu/contract)
(require 'kargu/json)
(require 'kargu/config/key)
(require 'kargu/api/circuit)
(require 'kargu/async)
(require 'kargu/models/store)

(declare-function kargu-provider-models-api "kargu/providers/registry" (provider))
(declare-function kargu-provider-public-models-p "kargu/providers/registry" (id url))
(declare-function kargu-provider-native-models-path "kargu/providers/registry" (id api-base))
(declare-function kargu-provider-keyless-p "kargu/providers/registry" (provider))
(declare-function kargu-provider-format "kargu/providers/registry" (provider))
(declare-function kargu-provider-effort-specs "kargu/providers/registry" (id))
(declare-function kargu--plz-error-message "kargu/api/retry" (err))
(declare-function kargu--api-headers "kargu/api/request" (key &optional provider-name))
(declare-function kargu-history-context-threshold "kargu/history/compact" (ctx-tokens))

(defvar kargu--catalog-generations (make-hash-table :test #'equal)
  "Latest request generation per provider; gates cache writes, not delivery.")

(defcustom kargu-models-timeout 30
  "Seconds allowed for a model catalog request."
  :type 'number
  :group 'kargu)

(defvar kargu--live-models-cache (make-hash-table :test 'equal)
  "Session cache of live model ID lists, keyed by provider name.")

(defun kargu-model-set-metadata (id data &optional provider)
  "Register model ID's DATA for PROVIDER, defaulting to its recorded owner.
Without an explicit or recorded provider, use the active provider."
  (when (and (stringp id) (not (string-empty-p id)))
    (kargu-model-store-put (or provider (kargu--record-get data "provider")
                               (kargu--provider-name)) id data)))

(defun kargu-model-get-metadata (id &optional provider)
  "Read model ID's metadata for PROVIDER, defaulting to the active provider.
Only unambiguous short aliases in that provider are accepted."
  (when (and (stringp id) (not (string-empty-p id)))
    (kargu-model-store-get (or provider (kargu--provider-name)) id)))


(defun kargu--extract-models-from-json (data)
  "Extract a list of model alists or IDs from decoded JSON DATA."
  (cond
   ((null data) nil)
   ((vectorp data) (append data nil))
   ((or (listp data) (hash-table-p data))
    (or (kargu-aget data "data")
        (kargu-aget data "models")
        (kargu-aget data "items")
        (and (consp data) (consp (car data))
             (or (kargu-aget (car data) "id")
                 (kargu-aget (car data) "name"))
             data)))))

(defconst kargu--model-property-aliases
  '(("context-window" . "context_length") ("max-output" . "max_output")
    ("supports-tools" . "supports_tools") ("supports-reasoning" . "supports_reasoning"))
  "Canonical API fields for the inspector's capability property names.")

(defun kargu--model-property-name (property)
  "Return the string name of a string, symbol or keyword PROPERTY."
  (cond ((keywordp property) (substring (symbol-name property) 1))
        ((symbolp property) (symbol-name property))
        ((stringp property) property)
        (t (user-error "Kargu: invalid metadata property name"))))

(defun kargu-model-get-prop (model-id prop-key &optional provider)
  "Retrieve PROP-KEY from MODEL-ID's metadata owned by PROVIDER."
  (let* ((data (kargu-model-get-metadata model-id provider))
         (key (kargu--model-property-name prop-key)))
    (or (kargu--record-get data (or (cdr (assoc key kargu--model-property-aliases)) key))
        (kargu--record-get data key))))

(cl-defun kargu-model-set-prop (model-id prop-key prop-value &key provider)
  "Override PROP-KEY with PROP-VALUE for MODEL-ID at PROVIDER.
The override survives subsequent catalog refreshes for that identity."
  (let* ((key (kargu--model-property-name prop-key))
         (canonical (or (cdr (assoc key kargu--model-property-aliases)) key))
         (value (if (and (null prop-value)
                         (member canonical '("supports_tools" "supports_reasoning")))
                    :json-false prop-value)))
    (kargu-model-store-set-property
     (or provider (kargu--provider-name)) (or model-id (kargu--model) "")
     :property canonical :value value)))

(defun kargu--record-models-metadata (models &optional provider-name)
  "Record raw MODELS metadata for the optional PROVIDER-NAME."
  (let ((pname (or provider-name (kargu--provider-name))))
    (dolist (m models)
      (when (stringp m) (setq m (list (cons "id" m))))
      (when (listp m)
        (let* ((id (or (kargu-aget m "id") (kargu-aget m "name")))
               (clean-id (if (and (stringp id) (string-prefix-p "models/" id))
                             (substring id 7)
                           id)))
          (when (and (stringp clean-id) (not (string-empty-p clean-id)))
            (let ((entry (if (consp m)
                             (cons (cons "provider" pname) m)
                           m)))
              (kargu-model-set-metadata clean-id entry pname))))))))

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
      (or (kargu-aget data name)
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
  "Return non-nil for a free model described by DATA."
  (or (and (listp data) (plist-get data :free))
      (kargu--zero-price-p (kargu--nested-get data "pricing" "prompt"))
      (kargu--zero-price-p (kargu--record-get data "input-cost"))))

(defun kargu--read-vision-p (data)
  "Return non-nil for image support declared in DATA."
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

(defun kargu--read-efforts (data &optional provider)
  "Effort names from DATA, or nil when the record has none.
A stored `:reasoning-efforts' list is that list.  Otherwise the
PROVIDER's declared paths are read, defaulting to the active provider.
An undeclared key yields nothing."
  (cond
   ((null data) nil)
   ((kargu--reasoning-disabled-p data) nil)
   ((and (listp data)
         (kargu--effort-name-list (plist-get data :reasoning-efforts))))
   (t (and (fboundp 'kargu-provider-effort-specs)
           (kargu--efforts-from-specs
            data
            (kargu-provider-effort-specs
             (or provider (kargu--provider-name))))))))

(defun kargu-model-read (&optional model-id provider)
  "Read catalog fields for MODEL-ID from its raw API record.
The plist keys are `:context-window', `:max-output', `:reasoning-efforts',
`:vision', `:free', `:params', and `:input-cost'.  A missing field is nil.
PROVIDER defaults to the active provider.  No catalog fields are guessed."
  (let* ((provider (or provider (kargu--provider-name)))
         (data (kargu-model-get-metadata (or model-id (kargu--model) "") provider)))
    (list :context-window (kargu--read-context-window data)
          :max-output (kargu--read-max-output data)
          :reasoning-efforts (kargu--read-efforts data provider)
          :vision (kargu--read-vision-p data)
          :free (kargu--read-free-p data)
          :params (kargu--read-params data)
          :input-cost (kargu--read-input-cost data))))

(defun kargu-model-context-window (&optional model-id provider)
  "Return MODEL-ID's context window for PROVIDER, or nil when unknown."
  (plist-get (kargu-model-read model-id provider) :context-window))

(defun kargu--supported-parameters (data)
  "Return DATA's supported_parameters as a list, or nil when absent."
  (let ((raw (or (kargu-aget data "supported_parameters")
                 (kargu-aget data "supportedParameters")
                 (and (listp data) (plist-get data :supported-parameters)))))
    (cond
     ((vectorp raw) (append raw nil))
     ((consp raw) raw)
     (t nil))))

(defun kargu-model-request-parameters (model-id provider)
  "Return known supported parameters for exact MODEL-ID at PROVIDER.
Never borrow a fuzzy alias or another provider's record for request policy.
Manually installed metadata belongs to the provider selected when installed.
An absent or empty list means unknown, as in the tool capability contract."
  (when (and (stringp model-id) (not (string-empty-p (string-trim model-id))))
    (let* ((data (kargu-model-store-get provider model-id :exact t))
           (parameters (kargu--supported-parameters data)))
      (when (cl-every #'stringp parameters) parameters))))

(defun kargu--tools-explicitly-disabled-p (data)
  "Return non-nil for an explicit tool disable in DATA.
Missing metadata leaves tool support enabled."
  (or (let ((flag (or (kargu--record-get data "supports_tools")
                      (kargu--record-get data "supports-tools"))))
        (or (eq flag :json-false) (equal flag "false")))
      (and (listp data)
           (plist-member data :supports-tools)
           (not (plist-get data :supports-tools)))
      (let ((params (kargu--supported-parameters data)))
        (and params (not (member "tools" params))))))

(defvar kargu--tools-refused (make-hash-table :test #'equal)
  "Provider/model pairs whose endpoint answered that it cannot use tools.
This is what the endpoint said in this session; it is not catalog data.")

(defun kargu--tools-refusal-key (model-id &optional provider)
  "Key of MODEL-ID at PROVIDER, defaulting to the active provider."
  (cons (downcase (string-trim (format "%s" (or provider (kargu--provider-name)))))
        (string-trim (or model-id ""))))

(defun kargu-model-mark-tools-refused (&optional model-id provider)
  "Remember a tool refusal for MODEL-ID at PROVIDER, or the active pair."
  (puthash (kargu--tools-refusal-key (or model-id (kargu--model) "") provider) t
           kargu--tools-refused))

(defun kargu-model-forget-tools-refusals ()
  "Forget every provider refusal of tool use."
  (clrhash kargu--tools-refused))

(defun kargu-model-supports-tools-p (&optional model-id provider)
  "Return non-nil unless tools are ruled out for MODEL-ID.
Ruled out means the API metadata explicitly disables them or the provider
refused tool use in this session.  Missing metadata and a missing field
both leave tools available.  PROVIDER defaults to the active provider."
  (let* ((mid (or model-id (kargu--model) ""))
         (data (kargu-model-get-metadata mid provider)))
    (not (or (gethash (kargu--tools-refusal-key mid provider) kargu--tools-refused)
             (and data (kargu--tools-explicitly-disabled-p data))))))

(defun kargu--reasoning-support-flag (data)
  "Return the supports-reasoning flag in DATA, or nil when it is absent."
  (and data
       (or (kargu--record-get data "supports_reasoning")
           (kargu--record-get data "supports-reasoning"))))

(defun kargu--reasoning-disabled-p (data)
  "Return non-nil for an explicit reasoning disable in DATA."
  (let ((flag (kargu--reasoning-support-flag data)))
    (or (eq flag :json-false) (equal flag "false"))))

(defun kargu-model-reasoning-efforts (&optional model-id provider-name)
  "Return reasoning effort names for MODEL-ID from its API metadata.
When metadata is missing, PROVIDER-NAME is queried in the background (once)
and nil is returned until the answer arrives.
A false `supports_reasoning' flag returns nil.  A missing list returns nil."
  (let* ((mid (or model-id (kargu--model) ""))
         (pname (or provider-name (kargu--provider-name)))
         (pname-str (if (symbolp pname) (symbol-name pname) (format "%s" (or pname ""))))
         (data (kargu-model-get-metadata mid pname)))
    (when (and (null data) (not (string-empty-p pname-str)))
      (kargu--prefetch-models-once pname-str))
    (plist-get (kargu-model-read mid pname) :reasoning-efforts)))

(defun kargu-model-supports-reasoning-p (&optional model-id provider-name)
  "Return reasoning support for MODEL-ID and optional PROVIDER-NAME.
An explicit true flag is sufficient even without an API effort list."
  (let* ((data (kargu-model-get-metadata (or model-id (kargu--model) "") provider-name))
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
  "Format input COST, or a badge when FREE is non-nil."
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

(defun kargu-model-annotation-string (model-id &optional provider-name)
  "Build compact metadata badges for MODEL-ID at PROVIDER-NAME."
  (let ((parts (kargu-model--annotation-badges (kargu-model-read model-id provider-name))))
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
     ((and (kargu-nonempty api-base)
           default-api
           (not (equal (kargu--strip-trailing-slashes api-base)
                       (kargu--strip-trailing-slashes default-api))))
      (cond
       ((string-suffix-p "/models" api-base) api-base)
       ((kargu-provider-native-models-path pname-lower api-base)
        (concat api-base (kargu-provider-native-models-path pname-lower api-base)))
       (t (concat api-base "/models"))))
     ;; If catalog specified a dedicated models-api (and user didn't override api), use it:
     (custom-models-url custom-models-url)
     ;; Otherwise derive from api-base:
     ((kargu-provider-native-models-path pname-lower api-base)
      (concat api-base (kargu-provider-native-models-path pname-lower api-base)))
     ((string-suffix-p "/models" api-base)
      api-base)
     (t (concat api-base "/models")))))

(defun kargu--catalog-clean-model-ids (models)
  "Return IDs from normalized catalog MODELS records or plain ID strings."
  (delete-dups
   (delq nil
         (mapcar
          (lambda (model)
            (let ((id (if (consp model)
                          (or (kargu-aget model "id") (kargu-aget model "name"))
                        model)))
              (when (and (stringp id) (not (string-empty-p (string-trim id))))
                (if (string-prefix-p "models/" id) (substring id 7) id))))
          (kargu-seq-to-list models)))))

(defun kargu--catalog-cache-live-models (provider models)
  "Record metadata and ID lists for PROVIDER from MODELS, including emptiness."
  (let ((ids (kargu--catalog-clean-model-ids models)))
    (kargu--record-models-metadata models provider)
    (kargu-model-store-retain provider ids)
    (puthash provider ids kargu--live-models-cache)))

(defun kargu--catalog-response (body)
  "Return the model list in BODY, rejecting malformed and provider errors."
  (let* ((data (kargu-json-to-record (kargu--json-decode-safe body)))
         (error (kargu-aget data "error"))
         (models (kargu--extract-models-from-json data)))
    (when (and error (not (memq error '(:json-null :json-false))))
      (error "%s" (or (kargu-aget error "message") error)))
    (unless (or models (vectorp data) (equal (string-trim body) "[]")
                (and (consp data)
                     (seq-some (lambda (key) (assoc key data)) '("data" "models" "items"))))
      (error "Unexpected /models response: %s" (truncate-string-to-width (or body "") 200)))
    (unless (or (null models) (listp models) (vectorp models))
      (error "Invalid model list"))
    (kargu-seq-to-list models)))

(defun kargu--catalog-receive (task provider generation body)
  "Complete TASK with BODY, updating PROVIDER cache only for GENERATION."
  (let ((models (kargu--catalog-response body)))
    (when (= generation (gethash provider kargu--catalog-generations))
      (kargu--catalog-cache-live-models provider models))
    (kargu-async-finish task models)))

(defun kargu--catalog-request (task provider generation)
  "Start catalog TASK for PROVIDER and cache GENERATION."
  (let* ((url (kargu--catalog-models-url provider (kargu--api-base provider)))
         (public (kargu-provider-public-models-p provider url))
         (key (unless public (kargu--resolve-api-key provider))))
    (when (and (not public) (not key) (not (kargu-provider-keyless-p provider)))
      (error "No API key for provider %s" provider))
    (let ((request
           (plz 'get url :headers (kargu--api-headers key provider)
                :as 'string :timeout kargu-models-timeout
                :then (kargu-async-wrap
                       task (lambda (body)
                              (kargu--catalog-receive task provider generation body)))
                :else (kargu-async-wrap
                       task (lambda (error)
                              (kargu-async-finish task nil (kargu--plz-error-message error)))))))
      (when (kargu-async-pending-p task)
        (setf (kargu-async-task-cancel task)
              (lambda () (when (processp request) (delete-process request))))))))

(defun kargu-api-list-models (&optional callback provider-name)
  "Fetch PROVIDER-NAME's live catalog asynchronously, delivering once.
CALLBACK receives model alists or an error alist.  Concurrent requests do
not suppress each other's callbacks; only the newest updates shared cache."
  (interactive)
  (let* ((provider (downcase (string-trim (format "%s" (or provider-name (kargu--provider-name))))))
         (generation (1+ (gethash provider kargu--catalog-generations 0)))
         ;; Catalog discovery is independent of a running agent and its Stop.
         (kargu--loop-run nil)
         (kargu-async--current-task nil)
         (task (kargu-async-start
                (lambda (models error)
                  (funcall (or callback #'ignore)
                           (if error `(("error" . (("message" . ,error)))) models)))
                :timeout kargu-models-timeout)))
    (puthash provider generation kargu--catalog-generations)
    (funcall (kargu-async-wrap task
                              (lambda () (kargu--catalog-request task provider generation))))
    task))

(defun kargu-api-prefetch-models (&optional provider-name)
  "Prefetch the live catalog of PROVIDER-NAME asynchronously."
  (interactive)
  (kargu--prefetch-models-once (or provider-name (kargu--provider-name))))

(defun kargu-api-fetch-model-ids (provider-name callback &optional on-error)
  "Fetch PROVIDER-NAME's model IDs and deliver to CALLBACK once.
On failure, call ON-ERROR with its message, or CALLBACK with nil for
compatibility.  A successful empty catalog also delivers nil."
  (kargu-api-list-models
   (lambda (models)
     (if-let* ((error (kargu-aget models "error")))
         (if on-error (funcall on-error (kargu-aget error "message")) (funcall callback nil))
       (funcall callback (kargu--catalog-clean-model-ids models))))
   provider-name))

(defvar kargu--models-prefetched (make-hash-table :test #'equal)
  "Provider catalog prefetch states: :pending or :ready.")

(defun kargu--prefetch-models-once (provider-name)
  "Fetch PROVIDER-NAME once, allowing another attempt after failure."
  (unless (gethash provider-name kargu--models-prefetched)
    (puthash provider-name :pending kargu--models-prefetched)
    (kargu-api-fetch-model-ids
     provider-name
     (lambda (_) (puthash provider-name :ready kargu--models-prefetched))
     (lambda (_) (remhash provider-name kargu--models-prefetched)))))

(defun kargu-model-info--efforts-label (efforts)
  "One line naming EFFORTS."
  (cond
   ((null efforts) "none")
   ((listp efforts) (mapconcat #'format efforts ", "))
   (t (format "%s" efforts))))

(defun kargu-model-info-facts (&optional model-id provider)
  "Return inspector facts for MODEL-ID at PROVIDER (or the active pair)."
  (let* ((mid (or model-id (kargu--model)))
         (pname (downcase (string-trim (format "%s" (or provider (kargu--provider-name))))))
         (data (kargu-model-get-metadata mid pname))
         (props (or (and (listp data) (plist-get data :props)) data))
         (fields (kargu-model-read mid pname))
         (ctx (plist-get fields :context-window))
         (thresh (and (fboundp 'kargu-history-context-threshold)
                      (kargu-history-context-threshold ctx)))
         (max-out (plist-get fields :max-output))
         (desc (or (kargu-model-get-prop mid "description" pname)
                   (and (listp data) (plist-get data :description))))
         (efforts (or (kargu-model-reasoning-efforts mid pname)
                      (and (listp data) (plist-get data :reasoning-efforts))))
         (active (and (equal pname (kargu--provider-name)) (equal mid (kargu--model))))
         (effort (if active (or kargu-reasoning-effort "off") "not active")))
    (list :id mid
          :provider pname
          :props props
          :context ctx
          :threshold (or thresh 45000)
          :max-out max-out
          :description desc
          :efforts efforts
          :effort effort
          :tools (and mid (kargu-model-supports-tools-p mid pname)))))

(defvar-local kargu-model-info--provider nil
  "Provider captured by this model inspector, independent of chat selection.")

(defvar-local kargu-model-info--id nil
  "Canonical model identifier captured by this inspector.")

(defun kargu-model-info--fill (facts)
  "Replace the current buffer with the inspector text for FACTS."
  (let ((mid (plist-get facts :id))
        (thresh (plist-get facts :threshold))
        (max-out (plist-get facts :max-out))
        (desc (plist-get facts :description))
        (efforts (plist-get facts :efforts))
        (props (plist-get facts :props)))
    (erase-buffer)
    (insert (format "Kargu Model Inspector: %s\n" mid))
    (insert (make-string 60 ?=) "\n\n")
    (insert (format "Provider:            %s\n" (plist-get facts :provider)))
    (insert (format "Context Window:      %s\n"
                    (kargu-model--context-label (plist-get facts :context))))
    (insert (format "Compaction Limit:    %s chars\n" thresh))
    (insert (format "Max Output Tokens:   %s\n" (or max-out "default")))
    (insert (format "Current Effort:      %s\n" (plist-get facts :effort)))
    (insert (format "Supported Efforts:   %s\n" (kargu-model-info--efforts-label efforts)))
    (insert (format "Tools Supported:     %s\n" (if (plist-get facts :tools) "yes" "no")))
    (when desc
      (insert (format "\nDescription:\n  %s\n" desc)))
    (insert "\n" (make-string 60 ?-) "\n")
    (insert "Raw API Properties (Key - Value Pairs):\n")
    (insert (make-string 60 ?-) "\n")
    (if (null props)
        (insert "  (No raw API properties recorded for this model)\n")
      (dolist (item (and (listp props) props))
        (if (consp item)
            (insert (format "  %-26s : %S\n" (car item) (cdr item)))
          (insert (format "  %S\n" item)))))
    (insert "\n[Press 'e' to edit/override a property, 'q' to quit]\n")))

(defun kargu-model-info--echo (facts)
  "Echo a one-line summary of FACTS."
  (let ((thresh (plist-get facts :threshold))
        (max-out (plist-get facts :max-out))
        (desc (plist-get facts :description)))
    (message "kargu Model: %s (%s) · Context: %s · Compaction: %s chars · MaxOut: %s · Effort: %s%s"
             (plist-get facts :id)
             (plist-get facts :provider)
             (kargu-model--context-label (plist-get facts :context))
             (if thresh (format "%d" thresh) "45000")
             (if max-out (format "%d" max-out) "default")
             (plist-get facts :effort)
             (if desc (format " · %s" desc) ""))))

(defun kargu-model-info (&optional model-id provider)
  "Display metadata and raw API properties for MODEL-ID at PROVIDER.
When called interactively, opens an inspector buffer with all key-value pairs."
  (interactive)
  (let* ((facts (kargu-model-info-facts model-id provider))
         (buf (get-buffer-create (format "*kargu model: %s / %s*"
                                         (plist-get facts :provider) (plist-get facts :id)))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (kargu-model-info--fill facts)
        (goto-char (point-min))
        (special-mode)
        (setq kargu-model-info--provider (plist-get facts :provider)
              kargu-model-info--id (plist-get facts :id))
        (local-set-key (kbd "e") #'kargu-model-edit-prop)))
    (if (called-interactively-p 'interactive)
        (display-buffer buf)
      (kargu-model-info--echo facts))))

(cl-defun kargu-model-edit-prop (model-id prop-key prop-value &key provider)
  "Override PROP-KEY with PROP-VALUE for MODEL-ID at PROVIDER.
An inspector retains the provider/model it originally displayed."
  (interactive
   (let* ((provider (or kargu-model-info--provider (kargu--provider-name)))
          (mid (or kargu-model-info--id
                   (read-string (format "Model ID (default %s): " (kargu--model)) nil nil (kargu--model))))
          (meta (kargu-model-get-metadata mid provider))
          (props (or (and (listp meta) (plist-get meta :props)) meta))
          (cand-keys (delq nil (mapcar (lambda (x) (and (consp x) (format "%s" (car x))))
                                       (and (listp props) props))))
          (key (completing-read "Property to edit/override: "
                                (append '("context-window" "max-output" "supports-tools" "supports-reasoning")
                                        cand-keys)
                                nil nil))
          (curr-val (kargu-model-get-prop mid key provider))
          (val-str (read-string (format "New value for %s (current: %S): " key curr-val))))
     (list mid key (read val-str) :provider provider)))
  (kargu-model-set-prop model-id prop-key prop-value :provider provider)
  (message "kargu: Property '%s' for model '%s' updated to %S" prop-key model-id prop-value))

(provide 'kargu/api/catalog)

;;; catalog.el ends here
