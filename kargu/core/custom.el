;;; custom.el --- All defcustom declarations -*- lexical-binding: t; -*-

;; Copyright (C) 2026 kargu developers.
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Part of kargu.

;;; Commentary:

;; All user-facing customization variables for kargu.
;; Separated from `kargu/core' to keep the core slim and reduce
;; compilation-order sensitivities.
;; Every other kargu module reads these via `kargu/core'.

;;; Code:

(require 'kargu/core/group)

(defcustom kargu-ui-enabled t
  "Whether package composition loads chat, plan review and UI adapters.
Set this before loading Kargu for headless use.  This is a startup choice,
not permission to unload active views or jobs at runtime."
  :type 'boolean
  :group 'kargu)

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

(defcustom kargu-api-base nil
  "Fallback endpoint when the active provider has no `api'.
Nil means the request needs an endpoint from the provider record.
A string must contain the version prefix and no trailing slash."
  :type '(choice (const :tag "No fallback" nil)
                 (string :tag "Endpoint"))
  :group 'kargu)

(defcustom kargu-temperature 0.2
  "Sampling temperature when allowed by model metadata or provider policy.
Set to nil to omit it entirely.  Unknown OpenAI models omit sampling by
catalog policy; explicit supported_parameters metadata can enable it."
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
  "When non-nil, stream responses incrementally using SSE."
  :type 'boolean
  :group 'kargu)

(defcustom kargu-stream-max-raw-bytes (* 4 1024 1024)
  "Captured Rust response byte limit, at most 4 MiB."
  :type 'natnum :group 'kargu)
(defcustom kargu-stream-max-incomplete-line-bytes (* 64 1024)
  "Captured Rust SSE line byte limit, at most 64 KiB."
  :type 'natnum :group 'kargu)
(defcustom kargu-sse-max-event-bytes (* 1024 1024)
  "Captured Rust SSE event byte limit, at most 1 MiB."
  :type 'natnum :group 'kargu)
(defcustom kargu-stream-max-tool-calls 64
  "Captured Rust streamed tool-call limit, at most 64."
  :type 'natnum :group 'kargu)
(defcustom kargu-stream-max-tool-args-bytes (* 512 1024)
  "Captured Rust argument byte limit per streamed call, at most 512 KiB."
  :type 'natnum :group 'kargu)

(defcustom kargu-api-retry-max 5
  "How many times to retry a chat request after HTTP 429/5xx."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-http-retry-statuses '(429 500 502 503 504 529)
  "HTTP statuses that are retried with backoff and count against the breaker.
Error text from a 200 response that names one of these is treated the same."
  :type '(repeat integer)
  :group 'kargu)

(defcustom kargu-api-retry-after-max 60
  "Longest wait in seconds honoured from a Retry-After header."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-max-iterations 12
  "Safety cap on tool-call iterations within one agent run."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-max-healing-steps 3
  "Maximum self-correction rounds after edits introduce diagnostics."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-low-usage-mode nil
  "Use smaller tool results and project outlines without changing the model."
  :type 'boolean
  :group 'kargu)

(defcustom kargu-low-usage-output-limit 6000
  "Maximum tool-result characters when low usage mode is enabled."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-low-usage-symbol-limit 200
  "Maximum project-outline symbols when low usage mode is enabled."
  :type 'natnum
  :group 'kargu)

(defun kargu-usage-limit (normal reduced)
  "Return NORMAL, limited to REDUCED when low usage mode is enabled."
  (if kargu-low-usage-mode (min normal reduced) normal))

(defcustom kargu-tool-output-limit 24000
  "Maximum characters of a tool result fed back to the model."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-app-url "https://github.com/kargu/kargu"
  "Attribution URL sent as the HTTP-Referer header."
  :type 'string
  :group 'kargu)

(defcustom kargu-api-timeout 90
  "Rust total deadline in seconds for a non-streaming chat request.
Streaming uses `kargu-api-stall-timeout' and `kargu-api-stream-ceiling'.
Connection and first-byte bounds remain independent even when this is nil."
  :type '(choice (natnum :tag "Seconds") (const :tag "No timeout" nil))
  :group 'kargu)

(defcustom kargu-api-connect-timeout 10
  "Rust connection timeout in seconds, independent of the response deadline."
  :type 'natnum :group 'kargu)

(defcustom kargu-api-first-byte-timeout 30
  "Rust response-header timeout in seconds, including connection setup."
  :type 'natnum :group 'kargu)

(defcustom kargu-api-stall-timeout 45
  "Seconds a streaming response may go without bytes before it is aborted.
nil disables only the idle bound; Rust still applies the other deadlines."
  :type '(choice (natnum :tag "Seconds") (const :tag "No stall timeout" nil))
  :group 'kargu)

(defcustom kargu-api-stream-ceiling 900
  "Maximum seconds a streaming response may run, even while bytes arrive.
nil disables the ceiling.  The abort message is \"stream exceeded ceiling\"."
  :type '(choice (natnum :tag "Seconds") (const :tag "No ceiling" nil))
  :group 'kargu)

(defcustom kargu-log-wire nil
  "When non-nil, dump request and response bodies into the log buffer."
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
    (agent . "Mode: AGENT. Inspect, edit surgically, verify with available diagnostics, and run project compiler/tests."))
  "Alist mapping mode symbol to the system prompt injected as the first message."
  :type '(alist :key-type symbol :value-type string)
  :group 'kargu)

(defcustom kargu-sound-notifications t
  "When non-nil, play audio alerts on approvals, pauses, and run completions."
  :type 'boolean
  :group 'kargu)

(provide 'kargu/core/custom)

;;; custom.el ends here
