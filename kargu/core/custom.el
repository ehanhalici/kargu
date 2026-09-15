;;; kargu/core/custom.el --- All defcustom declarations -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; All user-facing customization variables for kargu.
;; Separated from `kargu/core' to keep the core slim and reduce
;; compilation-order sensitivities.
;; Every other kargu module reads these via `kargu/core'.

;;; Code:

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

(defgroup kargu nil
  "Agentic AI development assistant for Emacs."
  :group 'tools
  :prefix "kargu-")

(defcustom kargu-api-key nil
  "API key override for the active provider.

When nil, the key is resolved in this order:
1. `apikey' on the active `[providers.*]' table (or legacy TOML `apikey')
2. environment variable matching the endpoint host
   (`OPENROUTER_API_KEY', `OPENAI_API_KEY', ...)
3. `auth-source-search' on that host.
The TOML key is never written into this variable or Custom."
  :type '(choice (const :tag "Resolve from TOML / environment / auth-source" nil)
                 (string :tag "API key"))
  :group 'kargu)

(defcustom kargu-api-base "https://openrouter.ai/api/v1"
  "Fallback OpenAI-compatible endpoint if the active provider has no `api'.
Must contain the version prefix and no trailing slash."
  :type 'string
  :group 'kargu)

(defcustom kargu-model "anthropic/claude-3.5-sonnet"
  "Fallback model id if TOML `model' / `name' and the provider
`models' list are unset."
  :type 'string
  :group 'kargu)

(defcustom kargu-temperature 0.2
  "Sampling temperature sent with each request.
Set to nil to omit the field entirely."
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

(defcustom kargu-provider-parameters nil
  "Alist mapping provider ID strings to custom parameter alists.
For example, for openrouter:
  \\='((\"openrouter\" . ((\"sort\" . \"price\")
                      (\"allow_fallbacks\" . :json-false)
                      (\"zdr\" . t))))"
  :type '(alist :key-type string :value-type (alist :key-type string :value-type sexp))
  :group 'kargu)

(defcustom kargu-stream t
  "When non-nil, stream responses incrementally (SSE) over a plz
process filter."
  :type 'boolean
  :group 'kargu)

(defcustom kargu-api-retry-max 5
  "How many times to retry a chat request after HTTP 429/5xx."
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
  "Maximum characters of a tool result fed back to the model."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-app-url "https://github.com/kargu/kargu"
  "Attribution URL sent as the HTTP-Referer header to OpenRouter."
  :type 'string
  :group 'kargu)

(defcustom kargu-api-timeout 90
  "Timeout in seconds for HTTP requests to the LLM provider via plz."
  :type '(choice (natnum :tag "Seconds") (const :tag "No timeout" nil))
  :group 'kargu)

(defcustom kargu-log-wire nil
  "When non-nil, dump full request and response bodies into `*kargu-log*'."
  :type 'boolean
  :group 'kargu)

(defcustom kargu-log-dump-max 200000
  "Maximum characters of one wire-log dump block."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-mode-system-prompts
  '((ask   . "Mode: ASK (read-only). Analyze and explain. Do not edit files.")
    (plan  . "Mode: PLAN (read-only). Explore, then output a markdown implementation checklist. Do not edit files.")
    (debug . "Mode: DEBUG. Ground answers in DAP/runtime evidence and diagnostics. Do not edit unless asked.")
    (agent . "Mode: AGENT. Inspect, surgical edit, verify with Flycheck/LSP diagnostics, and run compiler/tests via bash."))
  "Alist mapping mode symbol to the system prompt injected as the first message."
  :type '(alist :key-type symbol :value-type string)
  :group 'kargu)

(defcustom kargu-sound-notifications t
  "When non-nil, play audio alerts on approvals, pauses, and run completions."
  :type 'boolean
  :group 'kargu)

(provide 'kargu/core/custom)

;;; kargu/core/custom.el ends here
