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
(declare-function kargu-provider-reasoning-efforts "kargu/providers/registry" (provider))
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

(defun kargu-model-context-window (&optional model-id)
  "Return the context window size in tokens for MODEL-ID (default active model).
Purely derived from live model metadata or session defaults."
  (let* ((mid (or model-id (kargu--model) ""))
         (meta (kargu-model-get-metadata mid))
         (ctx (and meta (plist-get meta :context-window))))
    (if (and (integerp ctx) (> ctx 0))
        ctx
      128000)))

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

(defun kargu--extract-efforts-from-options (model-data)
  "Extract reasoning effort list from reasoning_options schema."
  (let ((opts (or (kargu--aget model-data "reasoning_options")
                  (kargu--aget model-data "reasoningOptions")
                  (and (listp model-data) (plist-get model-data :reasoning-options))))
        res)
    (when (vectorp opts) (setq opts (append opts nil)))
    (when (listp opts)
      (dolist (opt opts)
        (when (or (consp opt) (vectorp opt))
          (let ((type (or (kargu--aget opt "type")
                          (and (listp opt) (plist-get opt :type))))
                (vals (or (kargu--aget opt "values")
                          (kargu--aget opt "options")
                          (and (listp opt) (plist-get opt :values))
                          (and (listp opt) (plist-get opt :options)))))
            (when (and (equal type "effort") vals)
              (if (vectorp vals) (setq vals (append vals nil)))
              (when (listp vals)
                (setq res (append res vals))))))))
    res))

(defun kargu--extract-efforts-from-arrays (model-data)
  "Extract reasoning effort list from direct effort arrays."
  (let ((vals (or (kargu--aget model-data "reasoning_efforts")
                  (kargu--aget model-data "reasoningEfforts")
                  (kargu--aget model-data "supported_reasoning_efforts")
                  (kargu--aget model-data "effort_levels")
                  (kargu--aget model-data "effortLevels")
                  (kargu--aget model-data "efforts")
                  (and (listp model-data) (plist-get model-data :reasoning-efforts))
                  (and (listp model-data) (plist-get model-data :efforts)))))
    (cond
     ((vectorp vals) (append vals nil))
     ((listp vals) vals)
     (t nil))))

(defun kargu--extract-efforts-from-reasoning-obj (model-data)
  "Extract reasoning effort list from nested reasoning object."
  (let ((reasoning (or (kargu--aget model-data "reasoning")
                       (and (listp model-data) (plist-get model-data :reasoning)))))
    (when (and (listp reasoning) (consp reasoning))
      (let ((vals (or (kargu--aget reasoning "efforts")
                      (kargu--aget reasoning "effort")
                      (kargu--aget reasoning "values")
                      (kargu--aget reasoning "options")
                      (kargu--aget reasoning "supported_efforts")
                      (and (consp (car-safe reasoning))
                           (or (kargu--aget (car reasoning) "efforts")
                               (kargu--aget (car reasoning) "effort")
                               (kargu--aget (car reasoning) "values")
                               (kargu--aget (car reasoning) "options")
                               (kargu--aget (car reasoning) "supported_efforts"))))))
        (cond
         ((vectorp vals) (append vals nil))
         ((listp vals) vals)
         (t nil))))))

(defun kargu--extract-efforts-from-variants (model-data)
  "Extract reasoning effort list from variants alist."
  (let ((variants (or (kargu--aget model-data "variants")
                      (and (listp model-data) (plist-get model-data :variants))))
        res)
    (when (and (listp variants) (consp variants))
      (dolist (v variants)
        (cond
         ((consp v)
          (let ((k (car v)))
            (when (and (stringp k) (member (downcase k) '("minimal" "low" "medium" "high" "xhigh" "max" "none" "off")))
              (push k res))))
         ((stringp v)
          (when (member (downcase v) '("minimal" "low" "medium" "high" "xhigh" "max" "none" "off"))
            (push v res)))))
      (nreverse res))))

(defun kargu--clean-effort-strings (raw-efforts)
  "Clean, deduplicate and convert RAW-EFFORTS to lowercase strings."
  (when raw-efforts
    (let (cleaned)
      (dolist (item raw-efforts)
        (let ((s (cond
                  ((stringp item) (downcase (string-trim item)))
                  ((symbolp item) (downcase (symbol-name item)))
                  (t nil))))
          (when (and s (not (string-empty-p s)) (not (member s cleaned)))
            (push s cleaned))))
      (nreverse cleaned))))

(defun kargu--extract-reasoning-efforts (model-data)
  "Extract supported reasoning effort strings from MODEL-DATA alist or plist.
Returns a list of clean effort strings (e.g. \\='(\"low\" \"medium\")), or nil."
  (when (or (consp model-data) (vectorp model-data))
    (let ((raw (or (kargu--extract-efforts-from-options model-data)
                   (kargu--extract-efforts-from-arrays model-data)
                   (kargu--extract-efforts-from-reasoning-obj model-data)
                   (kargu--extract-efforts-from-variants model-data))))
      (kargu--clean-effort-strings raw))))

(defun kargu--parse-model-limits (m top-p-alist)
  "Return cons (CTX . MAX-OUT) tokens for model M."
  (let* ((top-ctx (and (consp top-p-alist) (kargu--aget top-p-alist "context_length")))
         (top-max (and (consp top-p-alist) (kargu--aget top-p-alist "max_completion_tokens")))
         (ctx (or (kargu--aget m "context_length")
                  (kargu--aget m "context_window")
                  (kargu--aget m "max_input_tokens")
                  (kargu--aget m "inputTokenLimit")
                  (kargu--aget m "max_context_tokens")
                  top-ctx))
         (max-out (or (kargu--aget m "max_completion_tokens")
                      (kargu--aget m "max_output")
                      (kargu--aget m "max_output_tokens")
                      (kargu--aget m "outputTokenLimit")
                      (kargu--aget m "max_tokens")
                      top-max)))
    (cons (and (numberp ctx) (round ctx))
          (and (numberp max-out) (round max-out)))))

(defun kargu--parse-model-pricing (m pricing-alist)
  "Return cons (IN-COST . OUT-COST) for model M."
  (let ((in-cost (or (and (consp pricing-alist) (kargu--aget pricing-alist "prompt"))
                     (kargu--aget m "input_cost")))
        (out-cost (or (and (consp pricing-alist) (kargu--aget pricing-alist "completion"))
                      (kargu--aget m "output_cost"))))
    (cons in-cost out-cost)))

(defun kargu--parse-model-reasoning (m clean-id)
  "Return cons (EFFORTS . REASONING-FLAG) for model M."
  (let* ((supp-params (or (kargu--aget m "supported_parameters")
                          (kargu--aget m "supportedParameters")))
         (supp-params-list (cond ((vectorp supp-params) (append supp-params nil))
                                 ((listp supp-params) supp-params)
                                 (t nil)))
         (has-reasoning-param (and supp-params-list
                                   (cl-some (lambda (p)
                                              (and (stringp p)
                                                   (string-match-p "reasoning" (downcase p))))
                                            supp-params-list)))
         (efforts (or (kargu--extract-reasoning-efforts m)
                      (and has-reasoning-param '("low" "medium" "high"))))
         (sr (kargu--aget m "supports_reasoning"))
         (sr-p (and sr (not (eq sr :json-false))))
         (r (kargu--aget m "reasoning"))
         (r-p (and r (not (eq r :json-false))))
         (explicit-false (or (eq sr :json-false) (eq r :json-false)))
         (clean-lower (downcase (or clean-id "")))
         (reasoning (cond
                     (explicit-false :json-false)
                     (efforts t)
                     (has-reasoning-param t)
                     (sr-p t)
                     (r-p t)
                     ((string-match-p "thinking\\|reasoning\\|r1\\|o1\\|o3\\|o4" clean-lower)
                      t)
                     (t nil))))
    (cons efforts reasoning)))

(defun kargu--parse-model-features (m clean-id arch-alist in-cost out-cost)
  "Return plist of extracted features for model M."
  (let* ((clean-lower (downcase (or clean-id "")))
         (modality (or (and (consp arch-alist) (kargu--aget arch-alist "modality"))
                       (kargu--aget m "modality")))
         (supp-params (or (kargu--aget m "supported_parameters")
                          (kargu--aget m "supportedParameters")))
         (supp-params-list (cond ((vectorp supp-params) (append supp-params nil))
                                 ((listp supp-params) supp-params)
                                 (t nil)))
         (supports-tools (cond
                          ((null supp-params-list) t)
                          ((member "tools" supp-params-list) t)
                          (t nil)))
         (param-size (or (and (consp arch-alist) (kargu--aget arch-alist "parameter_size"))
                         (kargu--aget m "parameter_size")))
         (quant (or (and (consp arch-alist) (kargu--aget arch-alist "quantization_level"))
                    (kargu--aget m "quantization_level")))
         (params (cond
                  ((and param-size quant) (format "%s %s" param-size quant))
                  (param-size (format "%s" param-size))
                  (t nil)))
         (vision (or (string-match-p "image\\|multimodal\\|vision" (format "%s" (or modality "")))
                     (string-match-p "vision\\|vl\\|multimodal\\|image" clean-lower)))
         (free (or (string-match-p "free" clean-lower)
                   (and (numberp in-cost) (= in-cost 0)
                        (numberp out-cost) (= out-cost 0)))))
    (list :params params :vision vision :free free :supports-tools supports-tools)))

(defun kargu--record-models-metadata (models &optional provider-name)
  "Extract and record metadata from raw MODELS list into hash table.
PROVIDER-NAME is the associated provider ID string."
  (let ((pname (or provider-name (kargu--provider-name))))
    (dolist (m models)
      (when (listp m)
        (let* ((id (or (kargu--aget m "id") (kargu--aget m "name")))
               (clean-id (if (and (stringp id) (string-prefix-p "models/" id))
                             (substring id 7)
                           id)))
          (when (and (stringp clean-id) (not (string-empty-p clean-id)))
            (let* ((top-p (or (kargu--aget m "top_provider") (kargu--aget m "topProvider")))
                   (top-p-alist (if (and (consp top-p) (consp (car-safe top-p)) (consp (car-safe (car-safe top-p))))
                                    (car top-p)
                                  top-p))
                   (arch (or (kargu--aget m "architecture") (kargu--aget m "details")))
                   (arch-alist (if (and (consp arch) (consp (car-safe arch)) (consp (car-safe (car-safe arch))))
                                   (car arch)
                                 arch))
                   (limits (kargu--parse-model-limits m top-p-alist))
                   (pricing (or (kargu--aget m "pricing") (kargu--aget m "cost")))
                   (pricing-alist (if (and (consp pricing) (consp (car-safe pricing)) (consp (car-safe (car-safe pricing))))
                                      (car pricing)
                                    pricing))
                   (costs (kargu--parse-model-pricing m pricing-alist))
                   (reasoning-info (kargu--parse-model-reasoning m clean-id))
                   (features (kargu--parse-model-features m clean-id arch-alist (car costs) (cdr costs)))
                   (desc (kargu--aget m "description"))
                   (plist (list :id clean-id
                                :provider pname
                                :context-window (car limits)
                                :max-output (cdr limits)
                                :input-cost (car costs)
                                :output-cost (cdr costs)
                                :supports-reasoning (cdr reasoning-info)
                                :reasoning-efforts (car reasoning-info)
                                :supports-tools (plist-get features :supports-tools)
                                :vision (plist-get features :vision)
                                :params (plist-get features :params)
                                :free (plist-get features :free)
                                :description (and (stringp desc) desc))))
              (kargu-model-set-metadata clean-id plist)
              (when (string-match-p "/" clean-id)
                (let ((short-id (car (last (split-string clean-id "/")))))
                  (unless (gethash (downcase short-id) kargu--model-metadata-table)
                    (kargu-model-set-metadata short-id plist)))))))))))

(defun kargu-model--annotation-badges (meta mid-clean mid pname)
  "Collect list of annotation badge strings from META, MID-CLEAN, MID, and PNAME."
  (let* ((ctx (or (and meta (plist-get meta :context-window))
                  (kargu-model-context-window mid)))
         (max-out (and meta (plist-get meta :max-output)))
         (efforts (or (and meta (plist-get meta :reasoning-efforts))
                      (kargu-model-reasoning-efforts mid pname)))
         (supp-r (kargu-model-supports-reasoning-p mid pname))
         (supp-tools (if meta (plist-get meta :supports-tools) t))
         (vision (or (and meta (plist-get meta :vision))
                     (string-match-p "vision\\|vl\\|multimodal\\|image" mid-clean)))
         (params (and meta (plist-get meta :params)))
         (free (or (and meta (plist-get meta :free))
                   (string-match-p "free" mid-clean)))
         (pricing (and meta (plist-get meta :input-cost)))
         (parts nil))
    (when (and (numberp ctx) (> ctx 0))
      (push (if (>= ctx 1000000)
                (format "%dm ctx" (/ ctx 1000000))
              (format "%dk ctx" (/ ctx 1000)))
            parts))
    (when (and (numberp max-out) (> max-out 0))
      (push (format "max %dk" (max 1 (/ max-out 1024))) parts))
    (when (and (stringp params) (not (string-empty-p params)))
      (push params parts))
    (cond
     ((and (listp efforts) efforts)
      (if (and (member "low" efforts) (member "high" efforts))
          (push "🧠 think: low..high" parts)
        (push (format "🧠 think: %s" (mapconcat #'identity efforts ",")) parts)))
     (supp-r
      (push "🧠 think" parts)))
    (when (eq supp-tools nil)
      (push "🚫 no-tools" parts))
    (when (string-match-p "content-safety\\|llama-guard\\|moderation" mid-clean)
      (push "🛡️ moderation" parts))
    (when vision
      (push "👁 vision" parts))
    (let ((p-num (cond ((numberp pricing) pricing)
                       ((and (stringp pricing) (not (string-empty-p pricing)))
                        (string-to-number pricing))
                       (t nil))))
      (cond
       (free
        (push "⚡ free" parts))
       ((and (numberp p-num) (> p-num 0))
        (let ((per-m (* p-num 1000000.0)))
          (push (format "$%.2f/1M" per-m) parts)))))
    (nreverse parts)))

(defun kargu-model-annotation-string (model-id &optional provider-name)
  "Build a rich, compact annotation badge string for MODEL-ID."
  (let* ((mid (or model-id ""))
         (mid-clean (downcase (string-trim mid)))
         (pname (or provider-name (kargu--provider-name)))
         (meta (kargu-model-get-metadata mid))
         (parts (kargu-model--annotation-badges meta mid-clean mid pname)))
    (if parts
        (format "  [%s]" (mapconcat #'identity parts " · "))
      "")))

(defun kargu-model-supports-tools-p (&optional model-id)
  "Return non-nil if MODEL-ID supports tools/function calling.
Defaults to t when unknown or not explicitly set to nil."
  (let* ((mid (or model-id (kargu--model) ""))
         (meta (kargu-model-get-metadata mid)))
    (if meta
        (not (eq (plist-get meta :supports-tools) nil))
      t)))

(defun kargu-model-supports-reasoning-p (&optional model-id provider-name)
  "Return non-nil if MODEL-ID supports thinking / reasoning."
  (let* ((mid (or model-id (kargu--model) ""))
         (pname (or provider-name (kargu--provider-name)))
         (meta (kargu-model-get-metadata mid))
         (supp (and meta (plist-get meta :supports-reasoning)))
         (efforts (and meta (plist-get meta :reasoning-efforts)))
         (prov-efforts (and pname (fboundp 'kargu-provider-reasoning-efforts)
                            (kargu-provider-reasoning-efforts pname))))
    (cond
     ((eq supp :json-false) nil)
     ((or efforts prov-efforts (and supp (not (eq supp :json-false)))) t)
     (t nil))))

(defun kargu-model-reasoning-efforts (&optional model-id provider-name)
  "Return supported reasoning effort strings for MODEL-ID and PROVIDER-NAME."
  (let* ((mid (or model-id (kargu--model) ""))
         (mid-lower (downcase (string-trim mid)))
         (pname (or provider-name (kargu--provider-name)))
         (meta (kargu-model-get-metadata mid))
         (supp (and meta (plist-get meta :supports-reasoning)))
         (efforts (and meta (plist-get meta :reasoning-efforts)))
         (prov-efforts (and pname (fboundp 'kargu-provider-reasoning-efforts)
                            (kargu-provider-reasoning-efforts pname))))
    (cond
     ((and (listp efforts) efforts) efforts)
     ((eq supp :json-false) nil)
     ((and (listp prov-efforts) prov-efforts)
      prov-efforts)
     ((or (and supp (not (eq supp :json-false)))
          (string-match-p "r1\\|o1\\|o3\\|o4\\|thinking\\|reasoning\\|3-7\\|3\\.7" mid-lower))
      '("low" "medium" "high"))
     (t nil))))

(defun kargu--reasoning-effort-annotation (effort-str)
  "Return human-readable annotation string for EFFORT-STR."
  (let ((clean (downcase (if (stringp effort-str) effort-str (format "%s" effort-str)))))
    (cond
     ((member clean '("off" "none")) " [reasoning off]")
     ((string= clean "minimal") " [minimal effort]")
     ((string= clean "low") " [fast / low effort]")
     ((string= clean "medium") " [balanced effort]")
     ((string= clean "high") " [deep reasoning effort]")
     ((string= clean "xhigh") " [extra deep effort]")
     ((string= clean "max") " [maximum reasoning effort]")
     (t (format " [%s effort]" clean)))))

(defun kargu--catalog-models-url (pname-lower api-base)
  "Determine the models endpoint URL for PNAME-LOWER and API-BASE."
  (let ((custom-models-url (and (fboundp 'kargu-provider-models-api)
                               (kargu-provider-models-api pname-lower))))
    (or custom-models-url
        (cond
         ((and (string-match-p "ollama" pname-lower)
               (not (string-suffix-p "/v1" api-base)))
          (concat api-base "/api/tags"))
         ((string-suffix-p "/models" api-base)
          api-base)
         (t (concat api-base "/models"))))))

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
         (is-keyless (member pname-lower '("ollama" "lmstudio" "llamacpp")))
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
  "Display complete metadata and statistics for MODEL-ID (or active model)."
  (interactive)
  (let* ((mid (or model-id (kargu--model)))
         (pname (kargu--provider-name))
         (ctx (kargu-model-context-window mid))
         (thresh (and (fboundp 'kargu-history-compact-threshold)
                      (kargu-history-compact-threshold)))
         (meta (kargu-model-get-metadata mid))
         (max-out (and meta (plist-get meta :max-output)))
         (desc (and meta (plist-get meta :description)))
         (effort (or (and (boundp 'kargu-reasoning-effort) kargu-reasoning-effort) "off")))
    (message "kargu Model: %s (%s) · Context: %s tokens (~%s chars) · Compaction: %s chars · MaxOut: %s · Effort: %s%s"
             mid pname
             (format "%d" ctx)
             (format "%d" (round (* ctx 3.5)))
             (if thresh (format "%d" thresh) "45000")
             (if max-out (format "%d" max-out) "default")
             effort
             (if desc (format " · %s" desc) ""))))

(provide 'kargu/api/catalog)

;;; kargu/api/catalog.el ends here
