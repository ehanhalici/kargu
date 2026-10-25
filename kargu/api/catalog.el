;;; catalog.el --- Dynamic model catalog and metadata -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Native model publications and passive UI fields.  The editor captures requests
;; and presents canonical DTOs; Rust owns metadata parsing and policy decisions.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/core)
(require 'kargu/contract)
(require 'kargu/json)
(require 'kargu/config/key)
(require 'kargu/api/circuit)
(require 'kargu/async)
(require 'kargu/models/store)
(require 'kargu/api/transport)

(declare-function kargu-provider-models-api "kargu/providers/registry" (provider))
(declare-function kargu-provider-public-models-p "kargu/providers/registry" (id url))
(declare-function kargu-provider-native-models-path "kargu/providers/registry" (id api-base))
(declare-function kargu-provider-keyless-p "kargu/providers/registry" (provider))
(declare-function kargu-provider-format "kargu/providers/registry" (provider))
(declare-function kargu-provider-effort-specs "kargu/providers/registry" (id))
(declare-function kargu-api-auth-intent "kargu/api/request" (key &optional provider))
(declare-function kargu-history-context-threshold "kargu/history/compact" (ctx-tokens))
(declare-function kargu-connection-current "kargu/config/connection" (&optional buffer))
(declare-function kargu-connection-setting "kargu/config/connection" (name &optional snapshot))
(declare-function kargu-connection-matches-p "kargu/config/connection" (model provider))
(declare-function kargu-config-copy "kargu/config/service" (value))

(defvar kargu--catalog-generations (make-hash-table :test #'equal)
  "Latest request generation per provider; gates cache writes, not delivery.")

(defcustom kargu-models-timeout 30
  "Seconds allowed for a model catalog request."
  :type 'number
  :group 'kargu)

(defvar kargu--live-models-cache (make-hash-table :test 'equal)
  "Session cache of live model ID lists, keyed by provider name.")

(defun kargu-model-set-metadata (id data &optional provider callback)
  "Capture ID's DATA for PROVIDER and return an asynchronous publication ticket.
CALLBACK receives (VIEW FAILURE) only after native completion; passive getters
retain the previous committed view meanwhile.  Decimal rates/limits must not
arrive as already-rounded floats.  No Elisp metadata store is maintained."
  (kargu-model-store-put (or provider
                             (and data (gethash "provider" (kargu-model-encode-value data)))
                             (kargu--provider-name)) id data callback))

(defun kargu-model-get-metadata (id &optional provider)
  "Read model ID's metadata for PROVIDER, defaulting to the active provider.
Only unambiguous short aliases in that provider are accepted."
  (when (and (stringp id) (not (string-empty-p id)))
    (if (and (fboundp 'kargu-connection-matches-p) (kargu-connection-matches-p id provider))
        (kargu-config-copy (kargu-connection-setting :metadata))
      (kargu-model-store-get (or provider (kargu--provider-name)) id))))



(defconst kargu--model-property-aliases
  '(("context-window" . "context_length") ("max-output" . "max_output")
    ("supports-tools" . "supports_tools") ("supports-reasoning" . "supports_reasoning"))
  "Canonical API fields for the inspector's capability property names.")

(defalias 'kargu--model-property-name #'kargu-model-encode-name)

(defun kargu-model-get-prop (model-id prop-key &optional provider)
  "Detach PROP-KEY from MODEL-ID's native metadata owned by PROVIDER."
  (let* ((data (kargu-model-get-metadata model-id provider))
         (key (kargu--model-property-name prop-key)))
    (or (kargu-aget data (or (cdr (assoc key kargu--model-property-aliases)) key))
        (kargu-aget data key))))

(cl-defun kargu-model-set-prop (model-id prop-key prop-value &key provider callback owner)
  "Capture PROP-KEY/PROP-VALUE for MODEL-ID at PROVIDER.
Return a native publication ticket; CALLBACK receives (VIEW FAILURE).  OWNER
may bind an inspector's lifetime.  Rust alone resolves aliases and overrides."
    (kargu-model-store-set-property
     (or provider (kargu--provider-name)) (or model-id (kargu--model) "")
   :property prop-key :value prop-value :callback callback :owner owner))

(defun kargu-model-read (&optional model-id provider)
  "Detach native catalog display fields for MODEL-ID at PROVIDER.
Unknown/invalid fields remain nil.  This passive reader does no parsing or IO."
  (if (and (fboundp 'kargu-connection-matches-p) (kargu-connection-matches-p model-id provider))
      (kargu-config-copy (kargu-connection-setting :fields))
    (plist-get (kargu-model-store-settings (or provider (kargu--provider-name))
                                           (or model-id (kargu--model) "") nil t) :fields)))

(defun kargu-model-context-window (&optional model-id provider)
  "Return MODEL-ID's native context capacity for PROVIDER, or nil if unknown."
  (plist-get (kargu-model-read model-id provider) :context-window))

(defun kargu-model-request-parameters (model-id provider)
  "Detach known exact-ID request parameters for MODEL-ID at PROVIDER.
Display aliases never lend request policy to a different model identity."
  (let ((parameters (plist-get (kargu-model-store-settings provider model-id nil t) :supported-parameters)))
    (when (vectorp parameters) (append parameters nil))))

(defun kargu-model-mark-tools-refused (&optional model-id provider callback)
  "Capture a refusal for MODEL-ID/PROVIDER; CALLBACK receives (VIEW FAILURE).
Return the asynchronous native publication ticket, not an optimistic success."
  (kargu-model-store-submit
   (or provider (kargu--provider-name))
   (kargu-bridge--object "operation" "refuse_tools" "model" (or model-id (kargu--model) ""))
   callback))

(defun kargu-model-forget-tools-refusals (&optional callback)
  "Asynchronously clear all provider refusals; report completion in CALLBACK."
  (kargu-model-store-submit (kargu--provider-name)
                            (kargu-bridge--object "operation" "clear_tool_refusals") callback))

(defun kargu-model-supports-tools-p (&optional model-id provider)
  "Read native tool permission for MODEL-ID/PROVIDER without starting a core."
  (if (and (fboundp 'kargu-connection-matches-p) (kargu-connection-matches-p model-id provider))
      (kargu-connection-setting :tools)
    (plist-get (kargu-model-store-settings (or provider (kargu--provider-name))
                                           (or model-id (kargu--model) "") nil t) :tools)))

(defun kargu-model-reasoning-efforts (&optional model-id provider-name)
  "Detach native reasoning efforts for MODEL-ID at PROVIDER-NAME, without IO."
  (plist-get (kargu-model-read model-id provider-name) :reasoning-efforts))

(defun kargu-model-supports-reasoning-p (&optional model-id provider-name)
  "Read native reasoning permission for MODEL-ID at PROVIDER-NAME."
  (if (and (fboundp 'kargu-connection-matches-p) (kargu-connection-matches-p model-id provider-name))
      (kargu-connection-setting :reasoning)
    (plist-get (kargu-model-store-settings (or provider-name (kargu--provider-name))
                                           (or model-id (kargu--model) "") nil t) :reasoning)))

(defun kargu-model--context-label (ctx)
  "Inspector label for context size CTX."
  (if (numberp ctx)
      (format "%d tokens (~%d chars)" ctx (/ (* ctx 7) 2))
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

(defun kargu-model--format-price (label free)
  "Display native exact price LABEL, or a badge when FREE is non-nil."
  (if free "⚡ free" (and (stringp label) label)))

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
                        (plist-get fields :price-label)
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
  "Detach canonical native IDs in MODELS, preserving first-advertised order.
Provider envelopes, identity normalization and invalid records are Rust's job."
  (delete-dups (mapcar (lambda (model) (copy-sequence (kargu-aget model "id"))) models)))

(cl-defun kargu--catalog-cache-live-models (provider models &optional callback &key valid-p)
  "Publish MODELS atomically for PROVIDER; CALLBACK receives (VIEW FAILURE).
The native catalog's IDs become the UI cache only after committed completion."
  (let ((provider (kargu-model-store--provider provider)))
    (kargu-model-store-submit
     provider
     (kargu-bridge--object "operation" "replace_catalog" "catalog"
                           (kargu-bridge--object "models" (vconcat (mapcar #'kargu-model-encode-value models))))
     (lambda (view failure)
       (unless failure
         (let ((catalog (cl-find-if (lambda (entry) (equal (gethash "provider" entry) provider))
                                    (gethash "catalogs" view))))
           (puthash provider (append (kargu-bridge-models--copy (gethash "models" catalog)) nil)
                    (kargu-metadata-table :catalog kargu--live-models-cache))))
       (when callback (funcall callback view failure)))
     :valid-p valid-p)))

(defun kargu--catalog-receive (task provider generation body)
  "Deliver canonical native BODY to TASK; atomically publish fresh GENERATION."
  (let* ((projection (kargu-json-decode body))
         (records (gethash "models" projection)))
    (unless (and (vectorp records) (<= (length records) 20000))
      (error "Invalid native model catalog projection"))
    (let ((models (kargu-json-to-record (append records nil))) ticket)
      (if (/= generation (gethash provider (kargu-metadata-table :generations kargu--catalog-generations)))
          (kargu-async-finish task models)
        (setq ticket
              (kargu--catalog-cache-live-models
               provider models
               (lambda (_view failure)
                 (if (and failure (= generation (gethash provider (kargu-metadata-table :generations kargu--catalog-generations))))
                     (kargu-async-finish task nil "Native model catalog publication failed")
                   (kargu-async-finish task models)))
               ;; Generation may revoke an upload, not undo an issued commit.
               ;; The single writer completes that revision before newer writes.
               :valid-p (lambda ()
                          (or (and ticket (kargu-bridge-model-ticket-commit-sent ticket))
                              (= generation (gethash provider (kargu-metadata-table :generations kargu--catalog-generations)))))))
        (kargu-async-add-cleanup task (lambda () (kargu-bridge-models-cancel ticket)))))))

(defun kargu--catalog-request (task provider generation)
  "Start catalog TASK for PROVIDER and cache GENERATION."
  (let* ((url (kargu--catalog-models-url provider (kargu--api-base provider)))
         (public (kargu-provider-public-models-p provider url))
         (key (unless public (kargu--resolve-api-key provider))))
    (when (and (not public) (not key) (not (kargu-provider-keyless-p provider)))
      (error "No API key for provider %s" provider))
    (let ((request
           (kargu-transport-request 'get url :auth (kargu-api-auth-intent key provider)
                :model-catalog t
                :application (kargu-application-context)
                :wire (if (kargu-connection-current) (kargu-connection-setting :wire)
                        (kargu-provider-format-record (kargu-provider-format provider)))
                :provider provider
                :as 'string :timeout kargu-models-timeout
                :then (kargu-async-wrap
                       task (kargu-application-wrap
                             (kargu-application-context)
                             (lambda (body)
                               (kargu--catalog-receive task provider generation body))))
                :else (kargu-async-wrap
                       task (lambda (error)
                              (kargu-async-finish task nil (kargu-result-err-message error)))))))
      (when (kargu-async-pending-p task)
        (kargu-async-add-cleanup task (lambda () (kargu-transport-cancel request)))))))

(defun kargu-api-list-models (&optional callback provider-name)
  "Fetch PROVIDER-NAME's live catalog asynchronously, delivering once.
CALLBACK receives model alists or an error alist.  Concurrent requests do
not suppress each other's callbacks; only the newest updates shared cache."
  (interactive)
  (let* ((provider (downcase (string-trim (format "%s" (or provider-name (kargu--provider-name))))))
         (generation (1+ (gethash provider (kargu-metadata-table :generations kargu--catalog-generations) 0)))
         ;; Catalog discovery is independent of a running agent and its Stop.
         (kargu--loop-run nil)
         (kargu-execution--current nil)
         (kargu-async--current-task nil)
         (task (kargu-async-start
                (kargu-application-wrap (kargu-application-context) (lambda (models error)
                  (funcall (or callback #'ignore)
                           (if error `(("error" . (("message" . ,error)))) models))))
                :timeout kargu-models-timeout)))
    (puthash provider generation (kargu-metadata-table :generations kargu--catalog-generations))
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
  (unless (gethash provider-name (kargu-metadata-table :prefetch kargu--models-prefetched))
    (puthash provider-name :pending (kargu-metadata-table :prefetch kargu--models-prefetched))
    (kargu-api-fetch-model-ids
     provider-name
     (lambda (_) (puthash provider-name :ready (kargu-metadata-table :prefetch kargu--models-prefetched)))
     (lambda (_) (remhash provider-name (kargu-metadata-table :prefetch kargu--models-prefetched))))))

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
         (effort (if active (or (kargu-selection-effort) "off") "not active")))
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
     (list mid key
           (cond ((member val-str '("nil" "false")) :json-false)
                 ((member val-str '("t" "true")) t)
                 (t val-str)) :provider provider)))
  (kargu-model-set-prop
   model-id prop-key prop-value :provider provider :owner (current-buffer)
   :callback (lambda (_view failure)
               (if failure (message "Kargu: native metadata property update failed")
                 (message "kargu: Property '%s' for model '%s' updated" prop-key model-id)))))

(provide 'kargu/api/catalog)

;;; catalog.el ends here
