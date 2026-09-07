;;; kargu/api.el --- Chat send, models, connection test -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Public transport: `kargu-api-send', `kargu-api-list-models',
;; `kargu-set-model', `kargu-test-connection'.  Loads response,
;; tools, stream, and HTTP.

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
(require 'kargu/constants)
(require 'kargu/result)
(require 'kargu/contract)
(require 'kargu/config)
(require 'kargu/json)
(require 'kargu/history)
(require 'kargu/api/tools)
(require 'kargu/api/response)
(require 'kargu/api/stream)
(require 'kargu/api/circuit)
(require 'kargu/api/http)

(declare-function company-mode "company")
(declare-function company-manual-begin "company")
(declare-function company-abort "company")
(declare-function kargu-chat-refresh-footer "kargu/chat/prompt")
(declare-function kargu-provider-reasoning-efforts "kargu/providers/registry")
(defvar company-backends)
(defvar company-backend)
(defvar company-minimum-prefix-length)
(defvar company-idle-delay)
(defvar kargu-chat-buffer-name)

;;;; Public send API ------------------------------------------------------

(defun kargu-api-send (prompt callback &optional on-delta)
  "Send the next conversation turn to OpenRouter, asynchronously.
The UI thread is never blocked (plz runs curl in a subprocess).

PROMPT is the new user message (a string), or nil to continue
from the existing history (e.g. after tool results were
appended).  CALLBACK is called with one argument, the decoded
response alist:
  * on success, the full chat-completions response, with the
    assistant message already appended to the history;
  * on failure, an alist whose \"error\" key carries the message
    (see `kargu-response-error-message').

ON-DELTA, when supplied, is called with each decoded SSE event
as it arrives (only when `kargu-stream' is non-nil); the
final CALLBACK still receives the reconstructed response.

Before the request leaves Emacs, `kargu--validate-history'
runs: the payload NEVER ends on a model turn, and every tool
call of the previous assistant turn is answered before the model
is triggered again.  Only one request may be in flight at a
time; use `kargu-api-cancel' to abort."
  (kargu-contract-assert #'kargu-contract-prompt-p prompt
                         "PROMPT must be a string or nil: %S" prompt)
  (kargu-contract-assert #'functionp callback
                         "CALLBACK must be callable: %S" callback)
  (kargu-contract-assert #'kargu-contract-callback-p on-delta
                         "ON-DELTA must be callable or nil: %S" on-delta)
  (cl-block kargu-api-send
    ;; Guard Clause 1: Request already in flight
    (when kargu--busy
      (funcall callback
               `(("error" .
                  (("message" . "request already in flight; cancel first")))))
      (cl-return-from kargu-api-send nil))

    ;; Guard Clause 2: API key resolution
    (let ((key (kargu--resolve-api-key)))
      (unless key
        (funcall callback
                 `(("error" .
                    (("message" . "no API key: M-x kargu-edit-config, or set `kargu-api-key', or a host env/auth-source entry")))))
        (cl-return-from kargu-api-send nil))

      ;; Happy path execution
      (let ((added-prompt-p nil))
        (when (and prompt (not (string-empty-p prompt)))
          (kargu--history-add "user" prompt)
          (setq added-prompt-p t))
        (condition-case-unless-debug err
            (progn
              ;; Guard Clause 3: Completed assistant turn cannot continue without prompt
              (when (and (or (null prompt) (string-empty-p prompt))
                         (kargu--history-completed-assistant-tail-p))
                (user-error "nothing to continue; send a user message"))
              (kargu--validate-history)
              ;; Guard Clause 4: History must contain at least one user message
              (unless (cl-some (lambda (m)
                                 (equal (kargu--aget m "role") "user"))
                               kargu--message-history)
                (user-error "nothing to send: history has no user message"))
              ;; Guard Clause 5: History must not end on model turn
              (when (kargu--assistant-role-p (kargu--history-last-role))
                (user-error "refusing to send: history still ends on a model turn"))
              (let ((gen (cl-incf kargu--generation)))
                (setq kargu--busy t)
                (kargu--api-post
                 (concat (kargu--api-base) "/chat/completions")
                 (kargu--api-headers key)
                 (kargu--build-payload)
                 gen
                 callback
                 on-delta)))
          (error
           (setq kargu--busy nil)
           (when (and added-prompt-p
                      kargu--message-history
                      (equal (kargu--aget (car (last kargu--message-history)) "role") "user")
                      (equal (kargu--aget (car (last kargu--message-history)) "content") prompt))
             (setq kargu--message-history (butlast kargu--message-history)))
           (funcall callback
                    (kargu--api-error-alist (error-message-string err)))))))))

;;;; Model management -----------------------------------------------------

(defvar kargu--models-generation 0
  "Separate generation counter for model-catalog requests, so
that fetching the catalog never cancels a running chat request.")

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

(defun kargu-api-list-models (&optional callback provider-name)
  "Fetch catalog from active or specified PROVIDER-NAME asynchronously.
CALLBACK receives either the list of model alists or an error
alist with an \"error\" key."
  (interactive)
  (let* ((cb (or callback #'ignore))
         (pname (or provider-name (kargu--provider-name)))
         (pname-str (if (symbolp pname) (symbol-name pname) (format "%s" (or pname "default"))))
         (pname-lower (downcase (string-trim pname-str)))
         (key (kargu--resolve-api-key pname-lower))
         (gen (cl-incf kargu--models-generation))
         (is-keyless (member pname-lower '("ollama" "lmstudio" "llamacpp")))
         (custom-models-url (and (fboundp 'kargu-provider-models-api)
                                 (kargu-provider-models-api pname-lower)))
         (api-base (kargu--api-base pname-lower))
         (url (or custom-models-url
                  (cond
                   ((and (string-match-p "ollama" pname-lower)
                         (not (string-suffix-p "/v1" api-base)))
                    (concat api-base "/api/tags"))
                   ((string-suffix-p "/models" api-base)
                    api-base)
                   (t (concat api-base "/models")))))
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
                                 (puthash pname-lower clean-ids kargu--live-models-cache)))
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
  "Fetch and cache the model catalog synchronously from PROVIDER-NAME.
Returns a list of clean model ID strings, or nil on failure."
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

(defun kargu--extract-reasoning-efforts (model-data)
  "Extract supported reasoning effort strings from MODEL-DATA alist or plist.
Returns a list of clean effort strings (e.g. \\='(\"low\" \"medium\")), or nil."
  (when (or (consp model-data) (vectorp model-data))
    (let (raw-efforts)
      ;; 1. Check reasoning_options / reasoningOptions (OpenCode / models.dev schema)
      (let ((opts (or (kargu--aget model-data "reasoning_options")
                      (kargu--aget model-data "reasoningOptions")
                      (and (listp model-data) (plist-get model-data :reasoning-options)))))
        (when (vectorp opts)
          (setq opts (append opts nil)))
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
                    (setq raw-efforts (append raw-efforts vals)))))))))
      ;; 2. Check reasoning_efforts / reasoningEfforts / supported_reasoning_efforts
      (unless raw-efforts
        (let ((vals (or (kargu--aget model-data "reasoning_efforts")
                        (kargu--aget model-data "reasoningEfforts")
                        (kargu--aget model-data "supported_reasoning_efforts")
                        (and (listp model-data) (plist-get model-data :reasoning-efforts)))))
          (when vals
            (if (vectorp vals) (setq vals (append vals nil)))
            (when (listp vals)
              (setq raw-efforts (append raw-efforts vals))))))
      ;; 3. Check effort_levels / effortLevels / efforts
      (unless raw-efforts
        (let ((vals (or (kargu--aget model-data "effort_levels")
                        (kargu--aget model-data "effortLevels")
                        (kargu--aget model-data "efforts")
                        (and (listp model-data) (plist-get model-data :efforts)))))
          (when vals
            (if (vectorp vals) (setq vals (append vals nil)))
            (when (listp vals)
              (setq raw-efforts (append raw-efforts vals))))))
      ;; 4. Check nested reasoning object
      (unless raw-efforts
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
              (when vals
                (if (vectorp vals) (setq vals (append vals nil)))
                (when (listp vals)
                  (setq raw-efforts (append raw-efforts vals))))))))
      ;; 5. Check variants alist keys (e.g. (("low" . ...) ("medium" . ...)))
      (unless raw-efforts
        (let ((variants (or (kargu--aget model-data "variants")
                            (and (listp model-data) (plist-get model-data :variants)))))
          (when (and (listp variants) (consp variants))
            (dolist (v variants)
              (cond
               ((consp v)
                (let ((k (car v)))
                  (when (and (stringp k) (member (downcase k) '("minimal" "low" "medium" "high" "xhigh" "max" "none" "off")))
                    (push k raw-efforts))))
               ((stringp v)
                (when (member (downcase v) '("minimal" "low" "medium" "high" "xhigh" "max" "none" "off"))
                  (push v raw-efforts)))))
            (setq raw-efforts (nreverse raw-efforts)))))
      ;; Clean, deduplicate and convert to lowercase strings
      (when raw-efforts
        (let (cleaned)
          (dolist (item raw-efforts)
            (let ((s (cond
                      ((stringp item) (downcase (string-trim item)))
                      ((symbolp item) (downcase (symbol-name item)))
                      (t nil))))
              (when (and s (not (string-empty-p s)) (not (member s cleaned)))
                (push s cleaned))))
          (nreverse cleaned))))))

(defun kargu--record-models-metadata (models &optional provider-name)
  "Extract and record metadata from raw MODELS list into hash table.
PROVIDER-NAME is the associated provider ID string."
  (let ((pname (or provider-name (kargu--provider-name))))
    (dolist (m models)
      (when (listp m)
        (let* ((id (or (kargu--aget m "id") (kargu--aget m "name")))
               (clean-id (if (and (stringp id) (string-prefix-p "models/" id))
                             (substring id 7)
                           id))
               (top-p (or (kargu--aget m "top_provider") (kargu--aget m "topProvider")))
               (top-p-alist (if (and (consp top-p) (consp (car-safe top-p)) (consp (car-safe (car-safe top-p))))
                                (car top-p)
                              top-p))
               (arch (or (kargu--aget m "architecture") (kargu--aget m "details")))
               (arch-alist (if (and (consp arch) (consp (car-safe arch)) (consp (car-safe (car-safe arch))))
                                (car arch)
                              arch))
               (top-ctx (and (consp top-p-alist) (kargu--aget top-p-alist "context_length")))
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
                            top-max))
               (desc (kargu--aget m "description"))
               (pricing (or (kargu--aget m "pricing") (kargu--aget m "cost")))
               (pricing-alist (if (and (consp pricing) (consp (car-safe pricing)) (consp (car-safe (car-safe pricing))))
                                  (car pricing)
                                pricing))
               (in-cost (or (and (consp pricing-alist) (kargu--aget pricing-alist "prompt"))
                            (kargu--aget m "input_cost")))
               (out-cost (or (and (consp pricing-alist) (kargu--aget pricing-alist "completion"))
                             (kargu--aget m "output_cost")))
               (supp-params (or (kargu--aget m "supported_parameters")
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
                           (t nil)))
               (modality (or (and (consp arch-alist) (kargu--aget arch-alist "modality"))
                             (kargu--aget m "modality")))
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
          (when (and (stringp clean-id) (not (string-empty-p clean-id)))
            (let ((plist (list :id clean-id
                               :provider pname
                               :context-window (and (numberp ctx) (round ctx))
                               :max-output (and (numberp max-out) (round max-out))
                               :input-cost in-cost
                               :output-cost out-cost
                               :supports-reasoning reasoning
                               :reasoning-efforts efforts
                               :vision vision
                               :params params
                               :free free
                               :description (and (stringp desc) desc))))
              (kargu-model-set-metadata clean-id plist)
              (when (string-match-p "/" clean-id)
                (let ((short-id (car (last (split-string clean-id "/")))))
                  (unless (gethash (downcase short-id) kargu--model-metadata-table)
                    (kargu-model-set-metadata short-id plist)))))))))))

(defun kargu-model-annotation-string (model-id &optional provider-name)
  "Build a rich, compact annotation badge string for MODEL-ID.
Includes context window, max output tokens, reasoning/thinking support,
multimodal/vision capability, parameter size, and pricing/free badges."
  (let* ((mid (or model-id ""))
         (mid-clean (downcase (string-trim mid)))
         (pname (or provider-name (kargu--provider-name)))
         (meta (kargu-model-get-metadata mid))
         (ctx (or (and meta (plist-get meta :context-window))
                  (kargu-model-context-window mid)))
         (max-out (and meta (plist-get meta :max-output)))
         (efforts (or (and meta (plist-get meta :reasoning-efforts))
                      (kargu-model-reasoning-efforts mid pname)))
         (supp-r (kargu-model-supports-reasoning-p mid pname))
         (vision (or (and meta (plist-get meta :vision))
                     (string-match-p "vision\\|vl\\|multimodal\\|image" mid-clean)))
         (params (and meta (plist-get meta :params)))
         (free (or (and meta (plist-get meta :free))
                   (string-match-p "free" mid-clean)))
         (pricing (and meta (plist-get meta :input-cost)))
         (parts nil))
    ;; 1. Context window
    (when (and (numberp ctx) (> ctx 0))
      (let ((ctx-str (if (>= ctx 1000000)
                         (format "%dm ctx" (/ ctx 1000000))
                       (format "%dk ctx" (/ ctx 1000)))))
        (push ctx-str parts)))
    ;; 2. Max completion / output tokens
    (when (and (numberp max-out) (> max-out 0))
      (push (format "max %dk" (max 1 (/ max-out 1024))) parts))
    ;; 3. Parameter size / details (Ollama)
    (when (and (stringp params) (not (string-empty-p params)))
      (push params parts))
    ;; 4. Reasoning / thinking capability
    (cond
     ((and (listp efforts) efforts)
      (if (and (member "low" efforts) (member "high" efforts))
          (push "🧠 think: low..high" parts)
        (push (format "🧠 think: %s" (mapconcat #'identity efforts ",")) parts)))
     (supp-r
      (push "🧠 think" parts)))
    ;; 5. Vision / multimodal
    (when vision
      (push "👁 vision" parts))
    ;; 6. Free or Pricing
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
    (if parts
        (format "  [%s]" (mapconcat #'identity (nreverse parts) " · "))
      "")))

(defun kargu-model-supports-reasoning-p (&optional model-id provider-name)
  "Return non-nil if MODEL-ID supports thinking / reasoning.
Checks model metadata and provider API responses dynamically."
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
  "Return supported reasoning effort strings for MODEL-ID and PROVIDER-NAME.
Returns nil if the model does not support reasoning.
Derived strictly from live model metadata and provider API capabilities."
  (let* ((mid (or model-id (kargu--model) ""))
         (mid-lower (downcase (string-trim mid)))
         (pname (or provider-name (kargu--provider-name)))
         (meta (kargu-model-get-metadata mid))
         (supp (and meta (plist-get meta :supports-reasoning)))
         (efforts (and meta (plist-get meta :reasoning-efforts)))
         (prov-efforts (and pname (fboundp 'kargu-provider-reasoning-efforts)
                            (kargu-provider-reasoning-efforts pname))))
    (cond
     ;; 1. Explicit model metadata efforts from provider API
     ((and (listp efforts) efforts) efforts)
     ;; 2. Explicit false -> model does not support reasoning
     ((eq supp :json-false) nil)
     ;; 3. Provider-registered default efforts
     ((and (listp prov-efforts) prov-efforts)
      prov-efforts)
     ;; 4. Model supports reasoning or model name indicates reasoning
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

(defun kargu--completing-read-with-company (prompt candidates &optional default annotations)
  "Prompt for one of CANDIDATES using Company-mode with strict matching."
  (let* ((cand-strings (mapcar (lambda (c) (if (stringp c) c (format "%s" c))) candidates))
         (backend
          (lambda (command &optional arg &rest _ignored)
            (cl-case command
              (prefix
               (let ((text (minibuffer-contents-no-properties)))
                 (if (string-empty-p text) "" text)))
              (candidates
               (let* ((prefix (or arg ""))
                      (matched (cl-remove-if-not
                                (lambda (c) (string-prefix-p prefix c t))
                                cand-strings)))
                 (or matched cand-strings)))
              (annotation
               (when (and arg annotations)
                 (or (cdr (assoc arg annotations)) "")))
              (no-cache t)
              (sorted t)
              (duplicates nil)))))
    (minibuffer-with-setup-hook
        (lambda ()
          (when (featurep 'company)
            (setq-local company-backends (list backend))
            (setq-local company-minimum-prefix-length 0)
            (setq-local company-idle-delay 0.01)
            (company-mode 1)
            (run-at-time 0.05 nil
                         (lambda ()
                           (when (fboundp 'company-manual-begin)
                             (ignore-errors (company-manual-begin)))))))
      (completing-read prompt cand-strings nil t nil nil default))))

(defvar kargu-chat--output-marker)
(defvar kargu-chat-buffer-name)
(declare-function kargu-chat--goto-footer-field "kargu/chat/prompt")

(defun kargu--company-select-at-point (field candidates annotations callback &optional on-cancel)
  "Select a candidate from CANDIDATES at FIELD using in-buffer Company popup.
FIELD is \\='provider, \\='model, or \\='effort.
When `noninteractive' or Company is unavailable, falls back to
`kargu--completing-read-with-company'."
  (let ((cand-strings (mapcar (lambda (c) (if (stringp c) c (format "%s" c))) candidates))
        (chat-buf (or (and (markerp kargu-chat--output-marker)
                           (marker-position kargu-chat--output-marker)
                           (current-buffer))
                      (get-buffer kargu-chat-buffer-name))))
    (if (or noninteractive
            (not (featurep 'company))
            (not chat-buf))
        (let* ((prompt (format "kargu %s: " field))
               (res (kargu--completing-read-with-company
                     prompt cand-strings (car cand-strings) annotations)))
          (funcall callback res))
      (with-current-buffer chat-buf
        (let ((win (get-buffer-window (current-buffer))))
          (if win
              (select-window win)
            (pop-to-buffer (current-buffer))))
        (when (bound-and-true-p company-candidates)
          (ignore-errors (company-abort)))
        (unless (and (fboundp 'kargu-chat--goto-footer-field)
                     (kargu-chat--goto-footer-field field))
          (user-error "kargu: chat footer field not found: %s" field))
        (let* ((btn-start (1- (point)))
               (btn-end (save-excursion (search-forward "]" nil t))))
          (unless btn-end
            (user-error "kargu: button end delimiter not found"))
          (let ((inhibit-read-only t))
            (delete-region btn-start btn-end)
            (when (> btn-start (point-min))
              (put-text-property (1- btn-start) btn-start
                                 'rear-nonsticky '(read-only field front-sticky face)))
            (when (< btn-start (point-max))
              (put-text-property btn-start (1+ btn-start)
                                 'front-sticky nil)))
          (let* ((start-marker (copy-marker (point) nil))
                 (done nil)
                 (finish-hook nil)
                 (cancel-hook nil)
                 (orig-backends (and (boundp 'company-backends) company-backends))
                 (cleanup
                  (lambda ()
                    (when (markerp start-marker)
                      (set-marker start-marker nil))
                    (setq-local company-backends (or orig-backends '(kargu-chat-company)))
                    (setq-local company-minimum-prefix-length 1)
                    (setq-local company-idle-delay 0.15)))
                 (backend
                  (lambda (cmd &optional arg &rest _ignored)
                    (cl-case cmd
                      (prefix
                       (when (and (markerp start-marker)
                                  (marker-position start-marker)
                                  (>= (point) (marker-position start-marker)))
                         (buffer-substring-no-properties
                          (marker-position start-marker) (point))))
                      (candidates
                       (let* ((prefix (or arg ""))
                              (matched (cl-remove-if-not
                                        (lambda (c) (string-prefix-p prefix c t))
                                        cand-strings)))
                         (or matched cand-strings)))
                      (annotation
                       (when (and arg annotations)
                         (or (cdr (assoc arg annotations)) "")))
                      (require-match nil)
                      (sorted t)
                      (duplicates nil)
                      (post-completion nil)
                      (otherwise nil)))))
            (setq-local company-backends (list backend))
            (setq-local company-minimum-prefix-length 0)
            (setq-local company-idle-delay 0.01)
            (company-mode 1)
            (setq finish-hook
                  (lambda (result)
                    (remove-hook 'company-completion-finished-hook finish-hook t)
                    (remove-hook 'company-completion-cancelled-hook cancel-hook t)
                    (unless done
                      (setq done t)
                      (funcall cleanup)
                      (when (functionp callback)
                        (let ((chosen result))
                          (if noninteractive
                              (funcall callback chosen)
                            (run-at-time 0 nil
                                         (lambda ()
                                           (with-current-buffer (or (get-buffer kargu-chat-buffer-name)
                                                                    (current-buffer))
                                             (funcall callback chosen))))))))))
            (setq cancel-hook
                  (lambda (&optional _aborted)
                    (remove-hook 'company-completion-finished-hook finish-hook t)
                    (remove-hook 'company-completion-cancelled-hook cancel-hook t)
                    (unless done
                      (setq done t)
                      (funcall cleanup)
                      (if (functionp on-cancel)
                          (funcall on-cancel)
                        (when (fboundp 'kargu-chat-refresh-footer)
                          (kargu-chat-refresh-footer))))))
            (add-hook 'company-completion-finished-hook finish-hook nil t)
            (add-hook 'company-completion-cancelled-hook cancel-hook nil t)
            (unless (ignore-errors (company-manual-begin))
              (funcall cancel-hook))))))))

(defun kargu-chat-select-mode-company (&optional _event)
  "Interactively select an execution mode using Company at point.
Falls back to `completing-read' via `kargu-set-mode' when Company
is unavailable or in batch mode."
  (interactive (list last-input-event))
  (when (or (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
            (and (fboundp 'kargu-busy-p) (kargu-busy-p)))
    (user-error "kargu: cannot change mode while agent is running or thinking (stop with C-c C-k first)"))
  (let* ((modes '("ask" "plan" "debug" "agent"))
         (annotations '(("ask" . "  [Read-only answers; no file edits]")
                        ("plan" . "  [Read-only architecture & implementation planning]")
                        ("debug" . "  [Debugging mode; uses dape and diagnostic tools]")
                        ("agent" . "  [Full agentic mode; can edit files and run commands]"))))
    (kargu--company-select-at-point
     'mode
     modes
     annotations
     (lambda (chosen)
       (unless (and (stringp chosen) (member chosen modes))
         (when (fboundp 'kargu-chat-refresh-footer)
           (kargu-chat-refresh-footer))
         (user-error "kargu: invalid mode selection: %s" chosen))
       (kargu-set-mode (intern chosen))))))

(defun kargu-chat-select-effort-company (&optional _event)
  "Interactively select reasoning effort using Company completion at point.
Effort levels are resolved dynamically from the active model and provider."
  (interactive (list last-input-event))
  (let* ((mid (kargu--model))
         (pname (kargu--provider-name))
         (supported (kargu-model-reasoning-efforts mid pname)))
    (if (null supported)
        (let ((efforts '("off"))
              (annotations '(("off" . " [reasoning not supported by this model]"))))
          (kargu--company-select-at-point
           'effort
           efforts
           annotations
           (lambda (_chosen)
             (setq kargu-reasoning-effort nil)
             (when (fboundp 'kargu-chat-refresh-footer)
               (kargu-chat-refresh-footer))
             (force-mode-line-update t)
             (message "kargu: model '%s' does not support reasoning effort." mid))))
      (let* ((filtered (cl-remove-if (lambda (e) (member (downcase e) '("off" "none")))
                                     supported))
             (efforts (cons "off" filtered))
             (annotations (mapcar (lambda (e)
                                    (cons e (kargu--reasoning-effort-annotation e)))
                                  efforts)))
        (kargu--company-select-at-point
         'effort
         efforts
         annotations
         (lambda (chosen)
           (unless (and (stringp chosen) (member chosen efforts))
             (when (fboundp 'kargu-chat-refresh-footer)
               (kargu-chat-refresh-footer))
             (user-error "kargu: invalid reasoning effort: %s" chosen))
           (setq kargu-reasoning-effort
                 (if (member (downcase chosen) '("off" "none")) nil (intern chosen)))
           (when (fboundp 'kargu-chat-refresh-footer)
             (kargu-chat-refresh-footer))
           (force-mode-line-update t)
           (message "kargu: reasoning effort set to '%s'." chosen)))))))

(defun kargu-chat-select-model-company (&optional live-ids catalog-ids provider-name _event)
  "Interactively select a model for PROVIDER-NAME using Company at point.
Automatically fetches live model list from provider API if not cached."
  (interactive (list nil nil nil last-input-event))
  (when (or (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
            (and (fboundp 'kargu-busy-p) (kargu-busy-p)))
    (user-error "kargu: cannot change model while agent is running or thinking (stop with C-c C-k first)"))
  (let* ((pname (or provider-name (kargu--provider-name)))
         (pname-str (if (symbolp pname) (symbol-name pname) (format "%s" (or pname "default"))))
         (cached (and (null live-ids) (gethash pname-str kargu--live-models-cache)))
         (sync-models (and (null live-ids) (null cached)
                           (progn
                             (message "kargu: querying live model catalog from %s (%s)..."
                                      pname-str (kargu--api-base pname-str))
                             (kargu-api-fetch-models-sync pname-str))))
         (live (or live-ids cached sync-models))
         (catalog catalog-ids)
         (curr (kargu--model))
         (all-models (delete-dups (delq nil (append (and live (copy-sequence live))
                                                    (and catalog (copy-sequence catalog))
                                                    (and (kargu--nonempty curr) (list curr)))))))
    (if (null all-models)
        ;; Prompt manually if no models could be discovered
        (let ((chosen (read-string (format "kargu model for %s: " pname-str) (or curr ""))))
          (when (and (stringp chosen) (not (string-empty-p chosen)))
            (setq kargu--session-model chosen)
            (when (fboundp 'kargu-chat-refresh-footer)
              (kargu-chat-refresh-footer))
            (force-mode-line-update t)
            (message "kargu: model set to '%s'" chosen)
            chosen))
      (let ((annotations
             (mapcar (lambda (m)
                       (cons m (kargu-model-annotation-string m pname-str)))
                     all-models)))
        (kargu--company-select-at-point
         'model
         all-models
         annotations
         (lambda (chosen)
           (unless (and (stringp chosen) (not (string-empty-p chosen)))
             (when (fboundp 'kargu-chat-refresh-footer)
               (kargu-chat-refresh-footer))
             (user-error "kargu: invalid model selection: %s" chosen))
           (setq kargu--session-model chosen)
           (let* ((ctx (kargu-model-context-window chosen))
                  (thresh (and (fboundp 'kargu-history-compact-threshold)
                               (kargu-history-compact-threshold)))
                  (meta (kargu-model-get-metadata chosen))
                  (desc (and meta (plist-get meta :description))))
             (when (fboundp 'kargu-chat-refresh-footer)
               (kargu-chat-refresh-footer))
             (force-mode-line-update t)
             (message "kargu: model '%s' selected (Context: %d tokens, Compaction Threshold: %d chars)%s"
                      chosen ctx (or thresh 0) (if desc (format " · %s" desc) "")))
           (if (kargu-model-reasoning-efforts chosen pname-str)
               (if noninteractive
                   (kargu-chat-select-effort-company)
                 (run-at-time 0.05 nil #'kargu-chat-select-effort-company))
             (setq kargu-reasoning-effort nil)
             (when (fboundp 'kargu-chat-refresh-footer)
               (kargu-chat-refresh-footer))
             (force-mode-line-update t))))))))

(defun kargu-chat-select-provider-company (&optional _event)
  "Interactively select an authenticated provider using Company at point."
  (interactive (list last-input-event))
  (when (or (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
            (and (fboundp 'kargu-busy-p) (kargu-busy-p)))
    (user-error "kargu: cannot change provider while agent is running or thinking (stop with C-c C-k first)"))
  (let* ((all-connected (kargu-connected-providers))
         (cfg-list (and (fboundp 'kargu--config-providers)
                        (mapcar #'car (kargu--config-providers))))
         (cfg-connected (and cfg-list (cl-remove-if-not (lambda (p) (member p cfg-list)) all-connected)))
         (connected (or (and (not noninteractive) cfg-connected)
                        all-connected)))
    (unless connected
      (user-error "kargu: no providers with API keys found. Add keys with M-x kargu-edit-config"))
    (let ((annotations
           (mapcar (lambda (p)
                     (cons p (cond
                              ((member p '("ollama" "lmstudio" "llamacpp")) " [local]")
                              ((cl-some (lambda (v) (kargu--nonempty (getenv v)))
                                        (kargu-provider-env p))
                               " [env key]")
                              (t " [configured]"))))
                   connected)))
      (kargu--company-select-at-point
       'provider
       connected
       annotations
       (lambda (chosen)
         (unless (and (stringp chosen) (member chosen connected))
           (when (fboundp 'kargu-chat-refresh-footer)
             (kargu-chat-refresh-footer))
           (user-error "kargu: invalid provider selection: %s" chosen))
         (kargu-set-provider chosen)
         (when (fboundp 'kargu-chat-refresh-footer)
           (kargu-chat-refresh-footer))
         (if noninteractive
             (kargu-chat-select-model-company nil nil chosen)
           (run-at-time 0.05 nil
                        (lambda ()
                          (kargu-chat-select-model-company nil nil chosen)))))))))

(defun kargu--prompt-and-set-model (live-ids catalog-ids provider-name)
  "Prompt user to pick model from LIVE-IDS or CATALOG-IDS for PROVIDER-NAME."
  (kargu-chat-select-model-company live-ids catalog-ids provider-name))

(defun kargu-set-model (&optional refresh-or-model)
  "Set session model for the active provider.
If REFRESH-OR-MODEL is a string, set model to it directly.
If called interactively or with prefix, queries provider and prompts."
  (interactive "P")
  (if (and (stringp refresh-or-model) (not (string-empty-p refresh-or-model)))
      (progn
        (setq kargu--session-model refresh-or-model)
        (when (fboundp 'kargu-chat-refresh-footer)
          (kargu-chat-refresh-footer))
        (force-mode-line-update t)
        (message "kargu: model set to %s" refresh-or-model)
        refresh-or-model)
    (let ((pname (kargu--provider-name)))
      (kargu-chat-select-model-company nil nil pname))))

(defun kargu-switch-provider-and-model ()
  "Interactively switch provider, model, and reasoning effort.
Restricted strictly to authenticated providers and valid models."
  (interactive)
  (kargu-chat-select-provider-company))

(defun kargu-chat-select-provider ()
  "Select an active LLM provider, prioritizing authenticated providers."
  (interactive)
  (kargu-chat-select-provider-company))

;;;; Connection test ------------------------------------------------------

(defun kargu-test-connection ()
  "Ping the active provider with a minimal request and report the result.
The conversation history is untouched: the ping uses a scratch
history which is restored afterwards."
  (interactive)
  ;; Guard Clause 1: Loop active
  (when (and (fboundp 'kargu-loop-running-p)
             (kargu-loop-running-p))
    (user-error
     "An agent run is in progress; stop it first (M-x kargu-loop-stop)"))
  ;; Guard Clause 2: Circuit breaker status
  (unless (kargu-circuit-allow-request-p)
    (user-error "Circuit breaker is %s; cannot ping until cooldown"
                (kargu-circuit-status-string)))
  (let ((old-history kargu--message-history)
        (old-temp kargu-temperature)
        (old-max kargu-max-tokens)
        (old-session kargu--session))
    (setq kargu--message-history nil
          kargu-temperature nil
          kargu-max-tokens 32)
    (kargu--history-add "user" "Reply with the single word: pong")
    (message "kargu: pinging %s (%s)..." (kargu--provider-name) (kargu--model))
    (kargu-api-send
     nil
     (lambda (response)
       ;; restore scratch state regardless of outcome
       (setq kargu--message-history old-history
             kargu-temperature old-temp
             kargu-max-tokens old-max
             kargu--session old-session)
       (let ((err (kargu-response-error-message response)))
         (if err
             (progn
               (kargu-log 'error "test-connection: %s" err)
               (message "kargu: FAILED — %s" err))
           (message "kargu: OK — model replied: %s"
                    (truncate-string-to-width
                     (or (kargu-response-text response) "") 60))))))))

(provide 'kargu/api)

;;; kargu/api.el ends here
