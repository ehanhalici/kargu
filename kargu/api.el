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
  "Return the context window size in tokens for MODEL-ID (default active model)."
  (let* ((mid (or model-id (kargu--model) ""))
         (meta (kargu-model-get-metadata mid))
         (ctx (and meta (plist-get meta :context-window))))
    (cond
     ((and (integerp ctx) (> ctx 0)) ctx)
     ;; Heuristics for well-known models
     ((string-match-p "gemini-3" mid) 1000000)
     ((string-match-p "gemini-2" mid) 1000000)
     ((string-match-p "gemini-1\\.5" mid) 1000000)
     ((string-match-p "gemini" mid) 1000000)
     ((string-match-p "claude-3" mid) 200000)
     ((string-match-p "claude" mid) 200000)
     ((string-match-p "deepseek" mid) 64000)
     ((string-match-p "o1\\|o3" mid) 200000)
     ((string-match-p "gpt-4o" mid) 128000)
     ((string-match-p "gpt-4" mid) 128000)
     ((string-match-p "llama-3" mid) 128000)
     ((string-match-p "qwen" mid) 128000)
     ((string-match-p "mistral" mid) 32000)
     (t 128000))))

(defun kargu--extract-models-from-json (data)
  "Extract a list of model alists or IDs from decoded JSON DATA."
  (cond
   ((null data) nil)
   ((vectorp data) (append data nil))
   ((listp data)
    (or (kargu--aget data "data")
        (kargu--aget data "models")
        (and (consp (car data)) (kargu--aget (car data) "id") data)))))

(defun kargu-api-list-models (callback)
  "Fetch the model catalog from the active provider asynchronously.
CALLBACK receives either the list of model alists or an error
alist with an \"error\" key."
  (let ((key (kargu--resolve-api-key))
        (gen (cl-incf kargu--models-generation)))
    (if (null key)
        (funcall callback
                 `(("error" . (("message" . "no API key")))))
      (plz 'get (concat (kargu--api-base) "/models")
           :headers (if (kargu--nonempty key)
                        `(("Authorization" . ,(concat "Bearer " key)))
                      nil)
           :as 'string
           :then (lambda (body)
                   (when (= gen kargu--models-generation)
                     (let* ((data (kargu--json-decode-safe body))
                            (extracted (kargu--extract-models-from-json data)))
                       (funcall callback
                                (or extracted
                                    `(("error" .
                                       (("message" . ,(format "unexpected /models body: %s"
                                                              (truncate-string-to-width
                                                               (or body "") 200)))))))))))
           :else (lambda (err)
                   (when (= gen kargu--models-generation)
                     (funcall callback
                              `(("error" .
                                 (("message" .
                                   ,(kargu--plz-error-message err))))))))))))

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
                            (kargu--aget reasoning "supported_efforts"))))
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

(defun kargu--record-models-metadata (models)
  "Extract and record metadata from raw MODELS list into hash table."
  (dolist (m models)
    (when (listp m)
      (let* ((id (or (kargu--aget m "id") (kargu--aget m "name")))
             (clean-id (if (and (stringp id) (string-prefix-p "models/" id))
                           (substring id 7)
                         id))
             (ctx (or (kargu--aget m "context_length")
                      (kargu--aget m "context_window")
                      (kargu--aget m "max_input_tokens")
                      (kargu--aget m "max_context_tokens")))
             (max-out (or (kargu--aget m "max_completion_tokens")
                          (kargu--aget m "max_output")
                          (kargu--aget m "max_output_tokens")))
             (desc (kargu--aget m "description"))
             (pricing (or (kargu--aget m "pricing") (kargu--aget m "cost")))
             (in-cost (or (and (listp pricing) (kargu--aget pricing "prompt"))
                          (kargu--aget m "input_cost")))
             (out-cost (or (and (listp pricing) (kargu--aget pricing "completion"))
                           (kargu--aget m "output_cost")))
             (efforts (kargu--extract-reasoning-efforts m))
             (sr (kargu--aget m "supports_reasoning"))
             (sr-p (and sr (not (eq sr :json-false))))
             (r (kargu--aget m "reasoning"))
             (r-p (and r (not (eq r :json-false))))
             (explicit-false (or (eq sr :json-false) (eq r :json-false)))
             (reasoning (cond
                         (explicit-false :json-false)
                         (efforts t)
                         (sr-p t)
                         (r-p t)
                         ((and (stringp clean-id)
                               (string-match-p "thinking\\|reasoning\\|r1\\|o1\\|o3" (downcase clean-id)))
                          t)
                         (t nil))))
        (when (and (stringp clean-id) (not (string-empty-p clean-id)))
          (let ((plist (list :id clean-id
                             :provider (kargu--provider-name)
                             :context-window (and (numberp ctx) (round ctx))
                             :max-output (and (numberp max-out) (round max-out))
                             :input-cost in-cost
                             :output-cost out-cost
                             :supports-reasoning reasoning
                             :reasoning-efforts efforts
                             :description (and (stringp desc) desc))))
            (kargu-model-set-metadata clean-id plist)
            (when (string-match-p "/" clean-id)
              (let ((short-id (car (last (split-string clean-id "/")))))
                (unless (gethash (downcase short-id) kargu--model-metadata-table)
                  (kargu-model-set-metadata short-id plist))))))))))

(defun kargu-model-supports-reasoning-p (&optional model-id provider-name)
  "Return non-nil if MODEL-ID supports thinking / reasoning.
Checks model metadata, provider defaults, and well-known model heuristics."
  (let* ((mid (or model-id (kargu--model) ""))
         (pname (or provider-name (kargu--provider-name)))
         (meta (kargu-model-get-metadata mid))
         (supp (and meta (plist-get meta :supports-reasoning)))
         (efforts (and meta (plist-get meta :reasoning-efforts)))
         (prov-efforts (and pname (fboundp 'kargu-provider-reasoning-efforts)
                            (kargu-provider-reasoning-efforts pname))))
    (cond
     ((or efforts prov-efforts (and supp (not (eq supp :json-false)))) t)
     ((eq supp :json-false) nil)
     (t t))))

(defun kargu-model-reasoning-efforts (&optional model-id provider-name)
  "Return supported reasoning effort strings for MODEL-ID and PROVIDER-NAME.
Returns nil if the model does not support reasoning."
  (let* ((mid (or model-id (kargu--model) ""))
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
     ;; 4. Well-known model family heuristics
     ((and (stringp mid) (not (string-empty-p mid)))
      (let ((clean (downcase mid)))
        (cond
         ;; Claude 3.7 supports low, medium, high, max
         ((string-match-p "claude-3-7\\|claude-3\\.7" clean)
          '("low" "medium" "high" "max"))
         ;; Gemini 2.5/2.0 thinking supports low, medium, high, max
         ((string-match-p "gemini-2\\.5\\|gemini-3\\|gemini.*thinking" clean)
          '("low" "medium" "high" "max"))
         ;; OpenAI o1, o3, o-series
         ((string-match-p "o1\\|o3\\|o4\\|gpt-5" clean)
          '("low" "medium" "high"))
         ;; DeepSeek R1 and general reasoning models
         ((string-match-p "thinking\\|reasoning\\|r1" clean)
          '("low" "medium" "high"))
         ;; Default fallback when not explicitly disabled
         (t '("low" "medium" "high")))))
     ;; Fallback default
     (t '("low" "medium" "high")))))

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
                 (saved-backends (and (boundp 'company-backends) company-backends))
                 (done nil)
                 (cleanup
                  (lambda ()
                    (when (markerp start-marker)
                      (set-marker start-marker nil))
                    (setq-local company-backends saved-backends)))
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
                      (require-match t)
                      (sorted t)
                      (duplicates nil)
                      (post-completion
                       (unless done
                         (setq done t)
                         (unwind-protect
                             (let ((inhibit-read-only t))
                               (when (functionp callback)
                                 (funcall callback arg)))
                           (funcall cleanup)))))))
                 (finish-hook nil)
                 (cancel-hook nil))
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
                      (unwind-protect
                          (let ((inhibit-read-only t))
                            (when (functionp callback)
                              (funcall callback result)))
                        (funcall cleanup)))))
            (setq cancel-hook
                  (lambda (&optional _aborted)
                    (remove-hook 'company-completion-finished-hook finish-hook t)
                    (remove-hook 'company-completion-cancelled-hook cancel-hook t)
                    (unless done
                      (setq done t)
                      (unwind-protect
                          (let ((inhibit-read-only t))
                            (if (functionp on-cancel)
                                (funcall on-cancel)
                              (when (fboundp 'kargu-chat-refresh-footer)
                                (kargu-chat-refresh-footer))))
                        (funcall cleanup)))))
            (add-hook 'company-completion-finished-hook finish-hook nil t)
            (add-hook 'company-completion-cancelled-hook cancel-hook nil t)
            (setq company-backend backend)
            (unless (ignore-errors (company-manual-begin))
              (funcall cancel-hook)
              (let* ((prompt (format "kargu %s: " field))
                     (res (kargu--completing-read-with-company
                           prompt cand-strings (car cand-strings) annotations)))
                (funcall callback res)))))))))

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
                 (if (member chosen '("off" "none")) nil (intern chosen)))
           (when (fboundp 'kargu-chat-refresh-footer)
             (kargu-chat-refresh-footer))
           (force-mode-line-update t)
           (message "kargu: reasoning effort set to '%s'." chosen)))))))

(defun kargu-chat-select-model-company (&optional live-ids catalog-ids provider-name _event)
  "Interactively select a model for PROVIDER-NAME using Company at point."
  (interactive (list nil nil nil last-input-event))
  (let* ((pname (or provider-name (kargu--provider-name)))
         (live (or live-ids (gethash pname kargu--live-models-cache)))
         (catalog (or catalog-ids (kargu--provider-models)))
         (all-models (delete-dups (delq nil (append live catalog (list (kargu--model)))))))
    (unless all-models
      (user-error "kargu: model list is empty for '%s'" pname))
    (let ((annotations
           (mapcar (lambda (m)
                     (let* ((ctx (kargu-model-context-window m))
                            (meta (kargu-model-get-metadata m))
                            (max-out (and meta (plist-get meta :max-output)))
                            (ctx-label (if (>= ctx 1000000)
                                           (format "%dm ctx" (/ ctx 1000000))
                                         (format "%dk ctx" (/ ctx 1000))))
                            (ann (if max-out
                                     (format "  [%s, max %dk]" ctx-label (/ max-out 1024))
                                   (format "  [%s]" ctx-label))))
                        (cons m ann)))
                   all-models)))
      (kargu--company-select-at-point
       'model
       all-models
       annotations
       (lambda (chosen)
         (unless (and (stringp chosen) (member chosen all-models))
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
         (if (kargu-model-reasoning-efforts chosen pname)
             (kargu-chat-select-effort-company)
           (setq kargu-reasoning-effort nil)
           (when (fboundp 'kargu-chat-refresh-footer)
             (kargu-chat-refresh-footer))
           (force-mode-line-update t)))))))

(defun kargu-chat-select-provider-company (&optional _event)
  "Interactively select an authenticated provider using Company at point."
  (interactive (list last-input-event))
  (let ((connected (kargu-connected-providers)))
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
         (message "kargu: fetching models for provider %s..." chosen)
         (kargu-api-list-models
          (lambda (models)
            (let ((catalog-models (kargu--provider-models)))
              (unless (kargu--aget models "error")
                (kargu--record-models-metadata models))
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
                (when clean-ids
                  (puthash chosen clean-ids kargu--live-models-cache))
                (kargu-chat-select-model-company clean-ids catalog-models chosen))))))))))

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
    (let* ((pname (kargu--provider-name))
           (cached (and (null refresh-or-model) (gethash pname kargu--live-models-cache)))
           (catalog-models (or (kargu--provider-models) nil)))
      (if cached
          (kargu-chat-select-model-company cached catalog-models pname)
        (message "kargu: querying live model catalog from %s (%s)..."
                 pname (kargu--api-base))
        (kargu-api-list-models
         (lambda (models)
           (let ((err (kargu--aget models "error")))
             (if err
                 (progn
                   (kargu-log 'warn "could not fetch live models from %s: %s"
                              pname (kargu--aget err "message"))
                   (message "kargu: live query failed (%s); using catalog defaults"
                            (kargu--aget err "message"))
                   (kargu-chat-select-model-company nil catalog-models pname))
               (kargu--record-models-metadata models)
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
                 (when clean-ids
                   (puthash pname clean-ids kargu--live-models-cache))
                 (kargu-chat-select-model-company clean-ids catalog-models pname))))))))))

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
