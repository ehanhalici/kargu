;;; kargu/core.el --- Settings, session, logging -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; Package root on `load-path' (walk up to `kargu.el'), shared
;; settings, session counters, and the log buffer.  Every other
;; kargu file requires this, not `kargu' itself.
;;
;; Public: `kargu-set-mode', `kargu-session-usage',
;; `kargu-session-reset', `kargu-log', `kargu-show-log',
;; `kargu-toggle-wire-log'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kargu/constants)
(require 'kargu/contract)

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

;;;; Alist helpers --------------------------------------------------------

(defun kargu--aget (alist key &optional default)
  "Return the value for string KEY in ALIST, or DEFAULT."
  (alist-get key alist default nil #'equal))

(defun kargu--nonempty (value)
  "VALUE if it is a non-empty string, else nil."
  (and (stringp value) (not (string-empty-p value)) value))

;;;; Customization --------------------------------------------------------

(defgroup kargu nil
  "Agentic AI development assistant for Emacs."
  :group 'tools
  :prefix "kargu-")

(defcustom kargu-api-key nil
  "API key override for the active provider.

When nil, the key is resolved in this order:
1. `apikey' on the active `[providers.*]' table (or legacy TOML `apikey')
2. environment variable matching the endpoint host
   (`OPENROUTER_API_KEY', `OPENAI_API_KEY', …)
3. `auth-source-search' on that host.
The TOML key is never written into this variable or Custom."
  :type '(choice (const :tag "Resolve from TOML / environment / auth-source" nil)
                 (string :tag "API key"))
  :group 'kargu)

(defcustom kargu-api-base "https://openrouter.ai/api/v1"
  "Fallback OpenAI-compatible endpoint if the active provider has no `api'.
Must contain the version prefix and no trailing slash.  See
`kargu--api-base'."
  :type 'string
  :group 'kargu)

(defcustom kargu-model "anthropic/claude-3.5-sonnet"
  "Fallback model id if TOML `model' / `name' and the provider
`models' list are unset.  `kargu-set-model' picks from the
active provider's list (or the live `/models' catalog).
See `kargu--model'."
  :type 'string
  :group 'kargu)

(defcustom kargu-temperature 0.2
  "Sampling temperature sent with each request.
Set to nil to omit the field entirely (recommended for strict
reasoning models such as deepseek/deepseek-r1)."
  :type '(choice (const :tag "Omit from request" nil)
                 (number :tag "Temperature"))
  :group 'kargu)

(defcustom kargu-max-tokens nil
  "Maximum completion tokens, or nil for the provider default."
  :type '(choice (const :tag "Provider default" nil)
                 (integer :tag "Tokens"))
  :group 'kargu)

(defcustom kargu-reasoning-effort nil
  "Reasoning / thinking effort level for supported reasoning models.
When non-nil, can be `low', `medium', or `high' (or nil to omit)."
  :type '(choice (const :tag "Model default / Omit" nil)
                 (const :tag "Low reasoning effort" low)
                 (const :tag "Medium reasoning effort" medium)
                 (const :tag "High reasoning effort" high))
  :group 'kargu)

(defcustom kargu-thinking-budget nil
  "Maximum tokens allocated for reasoning / thinking process.
Set to an integer (e.g. 2048, 4096) or nil for model default."
  :type '(choice (const :tag "Model default" nil)
                 (integer :tag "Thinking token budget"))
  :group 'kargu)

(defcustom kargu-stream t
  "When non-nil, stream responses incrementally (SSE) over a plz
process filter, so partial answers appear while the model is
still generating.  Only engaged when the caller supplies an
on-delta callback (e.g. the chat UI); otherwise a single
asynchronous request is used.  Falls back automatically when the
installed plz is too old to support streaming filters."
  :type 'boolean
  :group 'kargu)

(defcustom kargu-api-retry-max 5
  "How many times to retry a chat request after HTTP 429/5xx.
Zero disables retries.  Uses exponential backoff and honors
Retry-After when present."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-max-iterations 12
  "Safety cap on tool-call iterations within one agent run."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-max-healing-steps 3
  "Maximum self-correction rounds after an edit introduces new
LSP diagnostics (used by the loop module)."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-tool-output-limit 24000
  "Maximum characters of a tool result fed back to the model.
Longer outputs are truncated; this protects the token budget."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-app-url "https://github.com/kargu/kargu"
  "Attribution URL sent as the HTTP-Referer header to OpenRouter."
  :type 'string
  :group 'kargu)

(defcustom kargu-api-timeout 90
  "Timeout in seconds for HTTP requests to the LLM provider via plz.
Passed as `:timeout' to plz (setting curl's `--max-time').
Prevents hung connections when upstream networks or proxies stall."
  :type '(choice (natnum :tag "Seconds") (const :tag "No timeout" nil))
  :group 'kargu)

(defcustom kargu-log-wire nil
  "When non-nil, dump full request and response bodies into `*kargu-log*'.
Independent of `kargu-active-mode' debug (dape).  Toggle with
`kargu-toggle-wire-log'.  API keys and Authorization headers
are never logged."
  :type 'boolean
  :group 'kargu)

(defcustom kargu-log-dump-max 200000
  "Maximum characters of one wire-log dump block.
Zero means no cap.  Oversized text is truncated with a suffix
noting how many characters were omitted."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-mode-system-prompts
  '((ask
     . "Mode: ASK (read-only). Analyze and explain. Do not edit files.")
    (plan
     . "Mode: PLAN (read-only). Explore, then output a markdown implementation checklist. Do not edit files.")
    (debug
     . "Mode: DEBUG. Ground answers in DAP/runtime evidence and diagnostics. Do not edit unless asked.")
    (agent
     . "Mode: AGENT. Inspect, surgical edit, verify with Flycheck/LSP diagnostics, and run compiler/tests via bash."))
  "Alist mapping mode symbol (`ask', `plan', `debug', `agent') to
the system prompt injected as the first message of every
conversation.  The prompt is refreshed on each request, so
changing modes mid-conversation takes effect immediately."
  :type '(alist :key-type symbol :value-type string)
  :group 'kargu)

;;;; Mode state -----------------------------------------------------------

(defvar kargu-active-mode 'ask
  "Current operating mode: one of `ask', `plan', `debug', `agent'.")

(defun kargu-set-mode (mode)
  "Set the active mode to MODE (`ask', `plan', `debug' or `agent')."
  (interactive
   (list (intern (completing-read "kargu mode: "
                                  '("ask" "plan" "debug" "agent")
                                  nil t))))
  (kargu-contract-assert #'kargu-contract-mode-p mode
                         "Unknown kargu mode: %s (expected one of %s)"
                         mode kargu-all-modes)
  (when (and (fboundp 'kargu-loop-running-p) (kargu-loop-running-p))
    (user-error "kargu: cannot change mode while an agent run is in progress (M-x kargu-loop-stop)"))
  (setq kargu-active-mode mode)
  (kargu-log 'info "mode set to `%s'" mode)
  (force-mode-line-update t)
  (message "kargu mode: %s" mode)
  mode)

(defun kargu-mode-ask ()
  "Switch kargu to ask mode (read-only answers)."
  (interactive)
  (kargu-set-mode 'ask))

(defun kargu-mode-debug ()
  "Switch kargu to debug mode (live DAP evidence, no edits)."
  (interactive)
  (kargu-set-mode 'debug))

(defun kargu-mode-agent ()
  "Switch kargu to agent mode (autonomous edits)."
  (interactive)
  (kargu-set-mode 'agent))

(defun kargu-mode-plan ()
  "Switch kargu to plan mode (read-only plan)."
  (interactive)
  (kargu-set-mode 'plan))

(defvar kargu-context-buffer)

(defun kargu--context-file-name ()
  "File name of `kargu-context-buffer', or nil."
  (cond
   ((and (boundp 'kargu-context-buffer)
         (bufferp kargu-context-buffer)
         (buffer-live-p kargu-context-buffer))
    (or (buffer-file-name kargu-context-buffer)
        (buffer-name kargu-context-buffer)))
   ((and (boundp 'kargu-context-buffer)
         (stringp kargu-context-buffer)
         (not (string-empty-p kargu-context-buffer)))
    kargu-context-buffer)
   (t nil)))

(defun kargu--os-description ()
  "Short OS / CPU string for the environment block."
  (format "%s (%s)"
          (pcase system-type
            ('gnu/linux "linux")
            ('darwin "darwin")
            ('windows-nt "windows")
            (sym (symbol-name sym)))
          (car (split-string system-configuration "-"))))

(defun kargu--shell-description ()
  "Login shell path for the environment block."
  (or (getenv "SHELL")
      (and (boundp 'shell-file-name) shell-file-name)
      "unknown"))

;;;; Session state --------------------------------------------------------

(defvar kargu--session
  (list :active nil
        :requests 0
        :tokens-in 0
        :tokens-out 0
        :started (format-time-string "%Y-%m-%d %H:%M"))
  "Session counters, updated by the API module.")

(defvar kargu--session-provider nil
  "Session override for the active TOML provider name, or nil.")

(defvar kargu--session-model nil
  "Session override for the model id, or nil.")

(defun kargu-session-usage ()
  "Return a short usage report string for the current session."
  (interactive)
  (let ((report (format "requests: %d  tokens-in: %d  tokens-out: %d"
                       (or (plist-get kargu--session :requests) 0)
                       (or (plist-get kargu--session :tokens-in) 0)
                       (or (plist-get kargu--session :tokens-out) 0))))
    (when (called-interactively-p 'any)
      (message "kargu %s" report))
    report))

(defun kargu-session-reset ()
  "Reset session counters, conversation history and agent state."
  (interactive)
  (setq kargu--session
        (list :active nil
              :requests 0
              :tokens-in 0
              :tokens-out 0
              :started (format-time-string "%Y-%m-%d %H:%M")))
  (when (fboundp 'kargu-history-reset)
    (kargu-history-reset))
  (when (fboundp 'kargu-circuit-reset)
    (kargu-circuit-reset))
  (setq kargu--session-provider nil
        kargu--session-model nil)
  (message "kargu session reset"))

;;;; Logging --------------------------------------------------------------

(defconst kargu--log-buffer "*kargu-log*"
  "Name of the kargu log buffer.")

(defun kargu--ensure-log-buffer ()
  "Return `*kargu-log*', creating it read-only with wrapping enabled."
  (let ((buf (get-buffer-create kargu--log-buffer)))
    (with-current-buffer buf
      (setq-local truncate-lines nil)
      (setq buffer-read-only t))
    buf))

(defun kargu-log (level format-string &rest args)
  "Append a log entry to the `*kargu-log*' buffer.
LEVEL is one of `debug', `info', `warn', `error', `request',
`response', `wire'.  FORMAT-STRING and ARGS are as in `format'.
The function never signals, so it is safe to call from curl
process filters and sentinels."
  (condition-case _err
      (with-current-buffer (kargu--ensure-log-buffer)
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (format-time-string "%H:%M:%S ")
                  (propertize (format "[%s/%s] " level kargu-active-mode)
                              'face (pcase level
                                      ((or 'error 'warn) 'font-lock-warning-face)
                                      ('request 'font-lock-keyword-face)
                                      ('response 'font-lock-string-face)
                                      ('wire 'font-lock-type-face)
                                      (_ 'font-lock-comment-face)))
                  (apply #'format format-string args)
                  "\n")))
    (error nil)))

(defun kargu--log-limit (text)
  "Truncate TEXT to `kargu-log-dump-max' characters."
  (let ((s (if (stringp text) text (format "%s" (or text ""))))
        (max kargu-log-dump-max))
    (if (and (natnump max) (> max 0) (> (length s) max))
        (concat (substring s 0 max)
                (format "\n...[truncated, %d more chars]"
                        (- (length s) max)))
      s)))

(defun kargu--log-looks-json-p (text)
  "Non-nil when TEXT looks like a JSON object or array."
  (and (stringp text)
       (let ((s (string-trim text)))
         (or (string-prefix-p "{" s) (string-prefix-p "[" s)))))

(declare-function json-pretty-print "json" (begin end &optional minimize))
(declare-function json-read "json" ())

(defun kargu--log-pretty (text)
  "Pretty-print TEXT when it is a single JSON value; otherwise TEXT.
Trailing content after the first value (concatenated objects) is
left untouched so wire dumps stay faithful."
  (if (not (kargu--log-looks-json-p text))
      text
    (condition-case nil
        (progn
          (require 'json)
          (with-temp-buffer
            (insert text)
            (goto-char (point-min))
            (json-read)
            (skip-chars-forward " \t\n\r")
            (unless (eobp)
              (error "trailing json"))
            (json-pretty-print (point-min) (point-max))
            (buffer-string)))
      (error text))))

(defun kargu--log-block (title text &optional pretty)
  "Append a titled dump of TEXT to the log when `kargu-log-wire' is on.
When PRETTY is non-nil, try to JSON-pretty-print TEXT first.
Never signals.  Does not log API keys."
  (when kargu-log-wire
    (condition-case _err
        (let* ((raw (if (stringp text) text (format "%s" (or text ""))))
               (body (kargu--log-limit (if pretty (kargu--log-pretty raw) raw))))
          (with-current-buffer (kargu--ensure-log-buffer)
            (let ((inhibit-read-only t))
              (goto-char (point-max))
              (insert (format-time-string "%H:%M:%S ")
                      (propertize (format "[wire/%s] " kargu-active-mode)
                                  'face 'font-lock-type-face)
                      (format "---- %s ----\n" title)
                      body
                      (if (string-suffix-p "\n" body) "" "\n")
                      (format "---- end %s ----\n" title)))))
      (error nil))))

(defun kargu--log-wire (format-string &rest args)
  "Like `kargu-log' at `wire', only when `kargu-log-wire' is on."
  (when kargu-log-wire
    (apply #'kargu-log 'wire format-string args)))

(defun kargu-toggle-wire-log ()
  "Toggle full request/response dumps in `*kargu-log*'."
  (interactive)
  (setq kargu-log-wire (not kargu-log-wire))
  (kargu-log 'info "wire log %s" (if kargu-log-wire "on" "off"))
  (kargu-show-log)
  (message "kargu wire log %s" (if kargu-log-wire "on" "off")))

(defun kargu-show-log ()
  "Pop to the kargu log buffer."
  (interactive)
  (pop-to-buffer (kargu--ensure-log-buffer)))

(provide 'kargu/core)

;;; kargu/core.el ends here
