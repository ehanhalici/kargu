# Package E Exploration & Architecture Report
# Bounded Transport & Circuit Breakers (Wave 2, Package E)

**Author:** `explorer_wave2_E`  
**Date:** 2026-10-21  
**Milestone:** Wave 2 Package E  
**Scope:** `kargu/api.el`, `kargu/api/*.el`, `tests/test-*.el`, `proof/KarguTransport.tla`  
**Referenced Contracts:** Contract 1 (Application), Contract 4 (Connection Snapshot), Contract 6 (Budget Accounting), Contract 8 (Result Types)  
**Tracked Items:** MOD-04, RISK-02, DEEP-09, DEEP-12, DEEP-14, ARCH-15, ARCH-16, ARCH-17, ARCH-19  

---

## 1. Executive Summary & Problem Analysis

In Kargu's architectural transformation, the transport subsystem (`kargu/api/`) connects the agent engine to external and local LLM endpoints. Prior to Wave 2, the transport layer suffered from several architectural deficiencies:

1. **Global Mutable Singletons & Unowned Request State (MOD-04, ARCH-12)**:
   - `kargu--busy`, `kargu--current-process`, and `kargu--generation` resided as global variables.
   - HTTP transport read global configuration functions (`(kargu--resolve-api-key)`, `(kargu--api-base)`) directly rather than receiving an immutable `kargu-connection-snapshot` (Contract 4) and an owning `kargu-application` coordinator (Contract 1).
   - Cancellation relied on incrementing a global `kargu--generation` counter, leaving dangling timers and processes dependent on generation checks.

2. **Unaccounted Retries & Disjoint Budgets (DEEP-09, Contract 6)**:
   - Retries in `kargu/api/retry.el` (`kargu-api-retry-max`) and HTTP timeouts operated completely independently of Package A's `kargu-run-budget` (`kargu/application/budget.el`).
   - If an agent run had a limit of 10 requests, transport-level retries (on 429 or 5xx) were "free", multiplying actual API cost and delay without debiting from the run budget.
   - Upstream token usage was not reported back into `kargu-run-budget`.

3. **Global Unscoped Circuit Breaker (MOD-05, ARCH-15)**:
   - `kargu/api/circuit.el` maintained a single set of global variables: `kargu-circuit--state`, `kargu-circuit--failure-count`, `kargu-circuit--probe-inflight`, `kargu-circuit--last-failure-time`.
   - If one provider (e.g. local Ollama or an invalid secondary endpoint) failed 4 times, it tripped the circuit breaker to `:open` for **all** providers, blocking queries to Anthropic, OpenAI, or OpenRouter.
   - Resetting session state or another provider improperly flushed or preserved circuit state globally.

4. **Unbounded Buffers & Missing Backpressure (DEEP-12)**:
   - `kargu/api/sse.el` accumulated incomplete raw stream bytes in `(process-get process :kargu-raw)` with no byte ceiling. A stream without newlines could exhaust Emacs process memory.
   - The plz process buffer accumulated the entire raw HTTP response without a maximum cap.
   - `kargu/api/stream.el` merged tool call arguments and string deltas without individual or cumulative upper bounds.
   - Incomplete multibyte UTF-8 sequences split across chunks lacked deterministic bounds.
   - Rapid SSE bursts processed thousands of events synchronously without yielding to the Emacs event loop, starving UI updates and blocking user cancellation (`Stop`).

5. **String Error Parsing Instead of Typed Results (ARCH-16, Contract 8)**:
   - `kargu--api-error-looks-retryable-p` used regex patterns (`"HTTP \\(%s\\)"`, `"overloaded"`, `"upstream error"`) to determine retryability.
   - Callback failures returned ad-hoc alists `(("error" . (("message" . ...))))` instead of canonical `kargu-result-ok` / `kargu-result-err` with domain error symbols (`:http-status-429`, `:http-status-500`, `:timeout`, `:connection-failed`, `:stream-error`, `:budget-exhausted`) and effect plists (`:side-effect :none` or `:side-effect :unknown`).

6. **Security & Redirect Integrity (DEEP-14, RISK-02)**:
   - Cross-origin HTTP redirects (`301`, `302`, `307`, `308`) must never forward authorization headers (`Authorization`, `x-api-key`) to a foreign host.
   - TLS certificate verification must strictly remain enabled; `--insecure` is forbidden.
   - RISK-02: `kargu/api/parameters.el` must evaluate reasoning and sampling parameter compatibility from catalog capabilities rather than ad-hoc model name regexes, preserving explicit distinctions between `none`, `off`, and `nil` effort.

---

## 2. Existing Codebase Audit & Gap Analysis

| File | Current Status | Wave 2 Package E Target |
|---|---|---|
| `kargu/api/circuit.el` | Global variables (`kargu-circuit--state`, etc.). Single global circuit. | Provider/connection-scoped circuit breaker (`kargu-circuit-breaker` struct, registry table, scoped reset). |
| `kargu/api/http.el` | Reads global config; uses `kargu--busy`, `kargu--current-process`; untyped error alist; no budget check. | Accepts `app` and `connection-snapshot`. Single logical handle owns process/timers. Debits initial request from budget. Emits typed results. Strips auth headers on cross-origin redirect. |
| `kargu/api/retry.el` | Retries without budget debit; regex parses error strings; global generation check. | Debits `:retry-attempt` from `kargu-run-budget`. Inspects typed error codes. Halts retry on budget/deadline exhaustion. |
| `kargu/api/sse.el` | Unbounded `concat` in `:kargu-raw`. Process buffer grows unbounded. | Hard byte bounds on incomplete line (`kargu-stream-max-incomplete-line-bytes`), raw buffer (`kargu-stream-max-raw-bytes`). Clean error on breach. |
| `kargu/api/stream.el` | Unbounded tool-call argument merge; unbounded event accumulation; no event-loop yielding. | Hard limits on tool call count, argument size, and total text. Bounded event loop yielding for large event bursts. |
| `kargu/api/client.el` | Autoloads and high-level send; calls `kargu--resolve-api-key` directly. | Migrates to pass `kargu-application` and `kargu-connection-snapshot`. Supports typed result callbacks. |
| `kargu/api/parameters.el`| Selects sampling fields; lacks reasoning compatibility guard. | RISK-02: Enforces reasoning compatibility where reasoning disables temperature without model name regexes. |
| `kargu/api/wire.el` | Transforms OpenAI wire shape to/from Blocks. | Preserves bounds and identities during transformation. |
| `kargu/api/response.el` | Decodes responses and extracts usage/overflow. | Extracts usage and forwards to budget recording without synthesizing zero values. |
| `tests/test-transport-contract.el` | Does not exist. | **New Test Suite**: Tests handle lifecycle, budget debiting, scoped circuit breakers, typed results, TLS/redirect safety. |
| `tests/test-stream-pressure.el` | Does not exist. | **New Test Suite**: Tests newline-less line overflow, raw buffer caps, multibyte emoji chunking, fast producer backpressure. |
| `proof/KarguTransport.tla` | Does not exist. | **New Formal Specification**: Multi-provider transport FSM, single handle ownership, budget accounting, bounded buffer safety. |
| `proof/run_tlc.sh` | Missing `--transport` flag. | Updated to include exhaustive verification of `TransportMC.tla`. |

---

## 3. Detailed Architectural Design for Package E

### 3.1. Handle-Owned Transport Architecture

```
                  +-------------------------------+
                  |       kargu-application       |
                  |          (Package A)          |
                  +---------------+---------------+
                                  |
                                  | claims / owns
                                  v
                  +---------------+---------------+
                  |    kargu-logical-request      |
                  |     (Transport Handle)        |
                  +---------------+---------------+
                                  |
            +---------------------+---------------------+
            |                     |                     |
            v                     v                     v
    +---------------+     +---------------+     +---------------+
    |  plz process  |     |  retry timer  |     | stream timer  |
    | (active curl) |     |   (backoff)   |     | (stall/ceil)  |
    +---------------+     +---------------+     +---------------+
            |
            | bounded data chunks
            v
    +---------------+
    | Stream Parser | (bounded raw buffer, line buffer, tool-call args)
    +---------------+
```

The `kargu-logical-request` structure in `kargu/application/coordinator.el` serves as the authoritative handle for the entire duration of a logical conversation turn.

#### Invariants:
1. **Single Handle Ownership (ARCH-17)**:
   - A single `kargu-logical-request` owns the active attempt process, the pending retry timer (if between retries), and the stream watchdog timer.
   - When an attempt fails and a retry is scheduled, the process field is cleared and the `retry-timer` field is populated on the **same** logical handle.
   - When the retry timer fires and a new curl process spawns, `retry-timer` is cleared and `process` is updated on the **same** logical handle.
2. **Idempotent Single Cancellation**:
   - Calling `kargu-logical-request-cancel` transitions `state` to `:cancelled`, cancels `retry-timer`, cancels `stream-timer`, terminates `process` if live, releases any active circuit canary probe, and clears `active-request` on the owning `kargu-application`.
   - Repeated calls to cancel are guaranteed no-ops (`Safety_SingleHandleOwnership`).
3. **No Orphan Processes or Stale Callbacks**:
   - Every network callback checks whether its request handle is still `:in-flight` and matches the current generation. If cancelled or superseded, callbacks immediately discard payload and release resources without side effects.

---

### 3.2. Run Budget Accounting Integration (Contract 6 & DEEP-09)

Every transport operation must debit against the unified `kargu-run-budget` (`kargu/application/budget.el`):

1. **Initial Dispatch**:
   ```elisp
   (let ((budget (or explicit-budget (kargu-application-budget app))))
     (when budget
       (let ((debit-res (kargu-budget-debit budget :normal-request :requests 1)))
         (when (kargu-err-p debit-res)
           ;; Abort immediately with typed error
           (funcall callback debit-res)
           (cl-return-from kargu-transport-send nil)))))
   ```
2. **Retry Attempts**:
   ```elisp
   (when (and budget (kargu-run-budget-live-p budget))
     (let ((debit-res (kargu-budget-debit budget :retry-attempt :requests 1)))
       (if (kargu-ok-p debit-res)
           ;; Schedule retry backoff
           (kargu--api-schedule-retry ...)
         ;; Budget exhausted: fail with typed error
         (funcall callback
                  (kargu-err "Run budget exhausted; cannot retry"
                             :budget-exhausted
                             (list :reason (kargu-run-budget-status budget)))))))
   ```
3. **Token Usage Accounting**:
   When the response arrives (or streaming accumulates `usage`):
   ```elisp
   (when budget
     (let ((prompt-tokens (kargu-aget usage "prompt_tokens"))
           (completion-tokens (kargu-aget usage "completion_tokens")))
       (kargu-budget-record-tokens budget prompt-tokens completion-tokens)))
   ```
   If `prompt_tokens` or `completion_tokens` are omitted by the upstream provider, `kargu-budget-record-tokens` sets `tokens-unknown-p = t` rather than recording false zero tokens.

---

### 3.3. Provider/Connection-Scoped Circuit Breaker (`circuit.el`)

#### Structure:
```elisp
(cl-defstruct (kargu-circuit-breaker
               (:constructor kargu-circuit-breaker--create))
  "Scoped circuit breaker instance for a provider or connection endpoint."
  (key nil :read-only t)
  (state :closed)          ; :closed, :open, :half-open
  (failure-count 0)
  (probe-inflight nil)
  (last-failure-time 0.0)
  (threshold 4 :read-only t)
  (cooldown 30.0 :read-only t))
```

#### Registry & Scope Resolution:
- Maintain `kargu-circuit--registry` (hash table keyed by lowercase provider name or host endpoint string).
- `kargu-circuit-get (&optional scope)` returns the breaker for `scope` (defaulting to current provider or `"default"`).
- `kargu-circuit-allow-request-p (&optional scope)`: Checks only the breaker corresponding to `scope`.
- `kargu-circuit-record-success (&optional scope)`: Closes only the breaker for `scope`.
- `kargu-circuit-record-failure (reason &optional scope)`: Increments failures and trips only the breaker for `scope`.
- `kargu-circuit-reset (&optional scope)`:
  - If `scope` is `'all`, clears the entire registry.
  - If `scope` is specified, resets **only** that specific provider/connection breaker.
- **Invariants**: Outages or invalid endpoints for Provider A (e.g., local Ollama) never open the circuit for Provider B (e.g., Anthropic or OpenAI).

---

### 3.4. Bounded Stream & Parser Drains (`sse.el`, `stream.el`)

#### Configurable Limits:
```elisp
(defcustom kargu-stream-max-raw-bytes (* 4 1024 1024)
  "Maximum raw bytes allowed in the process buffer for a single request (4MB)."
  :type 'natnum :group 'kargu)

(defcustom kargu-stream-max-incomplete-line-bytes (* 64 1024)
  "Maximum bytes allowed in an incomplete SSE line before a newline is encountered (64KB)."
  :type 'natnum :group 'kargu)

(defcustom kargu-sse-max-event-bytes (* 1024 1024)
  "Maximum bytes allowed in a single decoded SSE event payload (1MB)."
  :type 'natnum :group 'kargu)

(defcustom kargu-stream-max-total-bytes (* 2 1024 1024)
  "Maximum cumulative text and reasoning characters in a stream (2MB)."
  :type 'natnum :group 'kargu)

(defcustom kargu-stream-max-tool-calls 64
  "Maximum distinct tool calls permitted in a single model turn."
  :type 'natnum :group 'kargu)

(defcustom kargu-stream-max-tool-args-bytes (* 512 1024)
  "Maximum JSON string length for a single tool call's arguments (512KB)."
  :type 'natnum :group 'kargu)
```

#### Bounded Stream Filter Algorithm:
1. **Raw Accumulation Bound**:
   `total-bytes = total-bytes + (length chunk)`.
   If `total-bytes > kargu-stream-max-raw-bytes`:
   Signal `:stream-error` ("Raw stream buffer exceeded limit"), abort process, clean up.
2. **Incomplete Line Bound**:
   `raw = concat(pending_raw, chunk)`.
   If `(null (cl-position ?\n raw))` and `(length raw) > kargu-stream-max-incomplete-line-bytes`:
   Signal `:stream-error` ("SSE line exceeded maximum bound"), abort process, clean up.
3. **Multibyte UTF-8 Preservation**:
   When splitting by `\n`, if trailing bytes contain an incomplete UTF-8 sequence, keep at most 3 trailing bytes in `pending_raw`. If trailing bytes exceed 4 bytes without forming valid UTF-8, signal `:stream-error` ("Malformed UTF-8 stream").
4. **Tool-Call Arguments Bound**:
   In `kargu--merge-tool-args`:
   If `(+ (length old) (length new)) > kargu-stream-max-tool-args-bytes`:
   Signal `:stream-error` ("Tool call arguments exceeded maximum bound").
   In `kargu--merge-tool-call-fragment`:
   If `(hash-table-count calls-map) >= kargu-stream-max-tool-calls` and `idx` is new:
   Signal `:stream-error` ("Maximum tool calls limit exceeded").
5. **Event-Loop Yielding**:
   If a single process filter invocation processes more than 50 SSE lines, dispatch remaining processing via `run-at-time 0 nil` to allow the Emacs event loop to service input, UI redraw, and user cancellation (`Stop`).

---

### 3.5. Security: TLS Verification & Redirect Credential Isolation (DEEP-14)

1. **Strict TLS Verification**:
   - `plz` invocations must never pass `-k` or `--insecure` to curl.
   - Any SSL/TLS handshake or certificate error returns typed `(kargu-err "TLS verification failed" :tls-error ...)`.
2. **Cross-Origin Redirect Isolation**:
   - If an HTTP request receives a `3xx` redirect, curl's default behavior must not leak credentials to a different origin.
   - When following redirects, if the redirect location differs in protocol, host, or port from the original request URL, the Authorization header (`Authorization`, `x-api-key`) must be completely stripped.
3. **Zero Secret Leakage in Logs**:
   - Transport logs log URL, model, and non-sensitive options; secrets in `credential-scope` or Authorization headers are strictly excluded.

---

### 3.6. Parameter Compatibility Guard (RISK-02)

In `kargu/api/parameters.el`:
- Evaluate provider/model request policies.
- If reasoning is active (effort is not `nil`, `"off"`, or `"none"`):
  - Check if the provider's request policy or model catalog flags `:reasoning-disallows-temperature t` (e.g. OpenAI o-series models reject temperature parameter).
  - If reasoning disallows temperature, omit the `"temperature"` key entirely.
  - No ad-hoc regex matching against model names: inspect declared catalog capability.

---

## 4. Concrete Implementation Specifications & Code Blocks for Worker E

### 4.1. `kargu/api/circuit.el` — Scoped Circuit Breaker

```elisp
;;; circuit.el --- Circuit breaker pattern for API requests -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'kargu/core)
(require 'kargu/contract/assert)

(defcustom kargu-circuit-failure-threshold 4
  "Number of consecutive failures required to trip the circuit open."
  :type 'natnum
  :group 'kargu)

(defcustom kargu-circuit-cooldown-seconds 30.0
  "Seconds to stay in open state before attempting a canary probe."
  :type 'number
  :group 'kargu)

(cl-defstruct (kargu-circuit-breaker
               (:constructor kargu-circuit-breaker--create))
  "Scoped circuit breaker instance for a provider or connection endpoint."
  (key nil :read-only t)
  (state :closed)
  (failure-count 0)
  (probe-inflight nil)
  (last-failure-time 0.0)
  (threshold kargu-circuit-failure-threshold :read-only t)
  (cooldown kargu-circuit-cooldown-seconds :read-only t))

(defvar kargu-circuit--registry (make-hash-table :test #'equal)
  "Table of scoped circuit breakers keyed by provider or connection string.")

(defun kargu-circuit--scope-key (&optional scope)
  "Normalize SCOPE to a canonical string key."
  (cond
   ((null scope)
    (downcase (or (and (fboundp 'kargu--provider-name) (kargu--provider-name)) "default")))
   ((symbolp scope) (downcase (symbol-name scope)))
   ((stringp scope) (downcase (string-trim scope)))
   (t (format "%s" scope))))

(defun kargu-circuit-get (&optional scope)
  "Return or create the `kargu-circuit-breaker' for SCOPE."
  (let ((key (kargu-circuit--scope-key scope)))
    (or (gethash key kargu-circuit--registry)
        (puthash key (kargu-circuit-breaker--create :key key) kargu-circuit--registry))))

(defun kargu-circuit--cooling-p (cb)
  "Non-nil while CB is :open and its cooldown has not elapsed."
  (and (eq (kargu-circuit-breaker-state cb) :open)
       (< (- (float-time) (kargu-circuit-breaker-last-failure-time cb))
          (kargu-circuit-breaker-cooldown cb))))

(defun kargu-circuit-open-p (&optional scope)
  "Return non-nil when a request for SCOPE would be refused right now."
  (let ((cb (kargu-circuit-get scope)))
    (or (kargu-circuit--cooling-p cb)
        (and (eq (kargu-circuit-breaker-state cb) :half-open)
             (kargu-circuit-breaker-probe-inflight cb)))))

(defun kargu-circuit-allow-request-p (&optional scope)
  "Return non-nil if a request for SCOPE may be sent, claiming the probe slot if needed."
  (let ((cb (kargu-circuit-get scope)))
    (cond
     ((eq (kargu-circuit-breaker-state cb) :closed) t)
     ((kargu-circuit-open-p scope) nil)
     (t
      (when (eq (kargu-circuit-breaker-state cb) :open)
        (setf (kargu-circuit-breaker-state cb) :half-open)
        (kargu-log 'info "circuit breaker [%s]: cooldown elapsed; half-open canary probe"
                   (kargu-circuit-breaker-key cb)))
      (setf (kargu-circuit-breaker-probe-inflight cb) t)
      t))))

(defun kargu-circuit-release-probe (&optional scope)
  "Release an in-flight probe on CB for SCOPE without declaring upstream healthy."
  (let ((cb (kargu-circuit-get scope)))
    (setf (kargu-circuit-breaker-probe-inflight cb) nil)))

(defun kargu-circuit-record-success (&optional scope)
  "Record a successful request for SCOPE, closing its circuit breaker."
  (let ((cb (kargu-circuit-get scope)))
    (when (or (eq (kargu-circuit-breaker-state cb) :half-open)
              (eq (kargu-circuit-breaker-state cb) :open)
              (> (kargu-circuit-breaker-failure-count cb) 0))
      (kargu-log 'info "circuit breaker [%s]: request succeeded; resetting to :closed"
                 (kargu-circuit-breaker-key cb)))
    (setf (kargu-circuit-breaker-state cb) :closed
          (kargu-circuit-breaker-probe-inflight cb) nil
          (kargu-circuit-breaker-failure-count cb) 0)))

(defun kargu-circuit-record-failure (&optional reason scope)
  "Record a failed request for SCOPE with optional REASON string."
  (let ((cb (kargu-circuit-get scope)))
    (setf (kargu-circuit-breaker-last-failure-time cb) (float-time)
          (kargu-circuit-breaker-probe-inflight cb) nil)
    (cl-incf (kargu-circuit-breaker-failure-count cb))
    (cond
     ((eq (kargu-circuit-breaker-state cb) :half-open)
      (setf (kargu-circuit-breaker-state cb) :open)
      (kargu-log 'warn "circuit breaker [%s]: probe failed (%s); tripped back to :open"
                 (kargu-circuit-breaker-key cb) (or reason "unknown error")))
     ((>= (kargu-circuit-breaker-failure-count cb) (kargu-circuit-breaker-threshold cb))
      (setf (kargu-circuit-breaker-state cb) :open)
      (kargu-log 'warn "circuit breaker [%s]: %d consecutive failures reached (%s); circuit OPEN for %.1fs"
                 (kargu-circuit-breaker-key cb)
                 (kargu-circuit-breaker-failure-count cb)
                 (or reason "unknown error")
                 (kargu-circuit-breaker-cooldown cb)))
     (t
      (kargu-log 'debug "circuit breaker [%s]: failure %d/%d (%s)"
                 (kargu-circuit-breaker-key cb)
                 (kargu-circuit-breaker-failure-count cb)
                 (kargu-circuit-breaker-threshold cb)
                 (or reason "error"))))))

(defun kargu-circuit-reset (&optional scope)
  "Reset circuit breaker for SCOPE, or all breakers if SCOPE is \\='all."
  (interactive)
  (if (eq scope 'all)
      (clrhash kargu-circuit--registry)
    (let ((cb (kargu-circuit-get scope)))
      (setf (kargu-circuit-breaker-state cb) :closed
            (kargu-circuit-breaker-probe-inflight cb) nil
            (kargu-circuit-breaker-failure-count cb) 0
            (kargu-circuit-breaker-last-failure-time cb) 0.0)
      (kargu-log 'info "circuit breaker [%s]: manually reset to :closed"
                 (kargu-circuit-breaker-key cb)))))

(defun kargu-circuit-status-string (&optional scope)
  "Return human-readable circuit breaker status for SCOPE."
  (let ((cb (kargu-circuit-get scope)))
    (pcase (kargu-circuit-breaker-state cb)
      (:closed "closed (healthy)")
      (:half-open "half-open (probing)")
      (:open
       (let ((remaining (max 0.0 (- (+ (kargu-circuit-breaker-last-failure-time cb)
                                       (kargu-circuit-breaker-cooldown cb))
                                    (float-time)))))
         (format "OPEN (cooldown: %.0fs remaining)" remaining)))
      (_ "unknown"))))
```

---

### 4.2. `kargu/api/sse.el` — Bounded Raw Buffer & Line Drains

```elisp
(defcustom kargu-stream-max-incomplete-line-bytes (* 64 1024)
  "Maximum allowable bytes in an incomplete SSE line buffer before a newline."
  :type 'natnum :group 'kargu)

(defcustom kargu-stream-max-raw-bytes (* 4 1024 1024)
  "Maximum allowable total raw bytes in a stream buffer."
  :type 'natnum :group 'kargu)

(defun kargu--stream-filter (process string on-delta &optional on-event)
  "Decode SSE bytes in STRING from PROCESS with hard buffer and line limits."
  (save-match-data
    (kargu--api-note-stream-byte process)
    (condition-case-unless-debug err
        (let* ((buffer (process-buffer process))
               (str-len (length string))
               (total (+ (or (process-get process :kargu-total-bytes) 0) str-len)))
          (process-put process :kargu-total-bytes total)
          ;; (1) Enforce total raw buffer cap
          (when (> total kargu-stream-max-raw-bytes)
            (process-put process :kargu-stream-abort 'raw-buffer-overflow)
            (ignore-errors (delete-process process))
            (error "Stream raw buffer limit exceeded (%d > %d)"
                   total kargu-stream-max-raw-bytes))

          ;; (2) Write to plz process buffer
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (save-excursion
                (save-restriction
                  (widen)
                  (goto-char (point-max))
                  (insert string)))))

          ;; (3) Bounded incomplete line parsing
          (let* ((prev-raw (or (process-get process :kargu-raw) ""))
                 (raw (concat prev-raw string))
                 (pos (cl-position ?\n raw :from-end t)))
            (if (null pos)
                (progn
                  (when (> (length raw) kargu-stream-max-incomplete-line-bytes)
                    (process-put process :kargu-stream-abort 'line-buffer-overflow)
                    (ignore-errors (delete-process process))
                    (error "SSE line exceeded maximum bound (%d > %d)"
                           (length raw) kargu-stream-max-incomplete-line-bytes))
                  (process-put process :kargu-raw raw))
              (let* ((complete (decode-coding-string (substring raw 0 (1+ pos)) 'utf-8))
                     (rest (substring raw (1+ pos))))
                (process-put process :kargu-raw rest)
                (dolist (line (split-string (string-remove-suffix "\n" complete) "\n" nil))
                  (kargu--stream-line process line on-delta on-event))))))
      (error
       (kargu-log 'error "stream filter error: %s" (error-message-string err))))))
```

---

### 4.3. `kargu/api/stream.el` — Bounded Accumulation & Event Limits

```elisp
(defcustom kargu-sse-max-event-bytes (* 1024 1024)
  "Maximum bytes in a single SSE event payload."
  :type 'natnum :group 'kargu)

(defcustom kargu-stream-max-tool-calls 64
  "Maximum number of tool calls permitted in a single streamed response."
  :type 'natnum :group 'kargu)

(defcustom kargu-stream-max-tool-args-bytes (* 512 1024)
  "Maximum argument string length for any single tool call."
  :type 'natnum :group 'kargu)

(defun kargu-sse--dispatch (parser)
  "Take and decode PARSER's pending event with size bounding."
  (let ((lines (nreverse (kargu-sse-parser-data parser)))
        (type (kargu-sse-parser-event parser)))
    (setf (kargu-sse-parser-data parser) nil
          (kargu-sse-parser-event parser) nil)
    (when lines
      (let ((data (mapconcat #'identity lines "\n")))
        (when (> (length data) kargu-sse-max-event-bytes)
          (error "SSE event data exceeded maximum allowed size (%d > %d)"
                 (length data) kargu-sse-max-event-bytes))
        (kargu--log-block "SSE data" data t)
        (if (equal (string-trim data) "[DONE]")
            :done
          (let ((event (kargu-sse-decode-data data)))
            (if (and (equal type "error")
                     (memq (kargu-aget event "error") '(nil :json-null :json-false)))
                (list (cons "error"
                            (or (kargu--provider-error-text event)
                                (kargu-nonempty (kargu-aget event "message"))
                                "Provider sent an SSE error event")))
              event)))))))

(defun kargu--merge-tool-args (old new)
  "Merge streamed argument fragments OLD and NEW with length check."
  (let* ((new-s (kargu--tool-args-fragment-string new))
         (old-s (or old ""))
         (merged
          (cond
           ((null new-s) old-s)
           ((string-empty-p old-s) new-s)
           ((and (or (equal (string-trim old-s) "{}")
                     (equal (string-trim old-s) "[]"))
                 (kargu--json-complete-value-string-p new-s))
            new-s)
           ((and (kargu--json-complete-value-string-p old-s)
                 (kargu--json-complete-value-string-p new-s))
            new-s)
           (t (concat old-s new-s)))))
    (when (> (length merged) kargu-stream-max-tool-args-bytes)
      (error "Tool call arguments exceeded maximum allowed size (%d > %d)"
             (length merged) kargu-stream-max-tool-args-bytes))
    merged))

(defun kargu--merge-tool-call-fragment (calls-map frag)
  "Merge one streamed tool-call FRAG into CALLS-MAP enforcing call count bounds."
  (let* ((idx (kargu--stream-fragment-index frag))
         (exists (gethash idx calls-map)))
    (unless exists
      (when (>= (hash-table-count calls-map) kargu-stream-max-tool-calls)
        (error "Exceeded maximum allowed streamed tool calls count (%d)"
               kargu-stream-max-tool-calls)))
    (let* ((fn (kargu-aget frag "function"))
           (call (or exists
                     (puthash idx
                              (list (cons "id" (or (kargu-aget frag "id") ""))
                                    (cons "type" "function")
                                    (cons "function"
                                          (list (cons "name" (or (and fn (kargu-aget fn "name")) ""))
                                                (cons "arguments" ""))))
                              calls-map)))
           (cfn (kargu-aget call "function")))
      (when-let* ((id (kargu-nonempty (kargu-aget frag "id"))))
        (when (and (kargu-nonempty (kargu-aget call "id"))
                   (not (equal id (kargu-aget call "id"))))
          (error "Conflicting tool-call identities at stream index %s" idx))
        (setcdr (assoc "id" call) id))
      (when fn
        (when-let* ((name (kargu-nonempty (kargu-aget fn "name"))))
          (setcdr (assoc "name" cfn) name))
        (let ((args (kargu-aget fn "arguments")))
          (unless (memq args '(nil :json-null))
            (setcdr (assoc "arguments" cfn)
                    (kargu--merge-tool-args (kargu-aget cfn "arguments") args))))))))
```

---

### 4.4. `kargu/api/http.el` & `retry.el` — Budget Debiting & Typed Result Integration

```elisp
(defun kargu--api-post-with-handle (handle url headers payload callback &optional on-delta attempt)
  "POST PAYLOAD to URL for HANDLE, debiting run budget for every attempt."
  (let* ((app (kargu-logical-request-app handle))
         (budget (and app (kargu-application-budget app)))
         (scope (kargu-logical-request-scope handle))
         (attempt (or attempt 0)))
    ;; 1. Circuit breaker gate
    (unless (or (> attempt 0)
                (kargu-circuit-allow-request-p scope))
      (kargu-http-clear-busy)
      (let ((err-msg (format "Circuit breaker OPEN for %s: %s"
                             scope (kargu-circuit-status-string scope))))
        (funcall callback (kargu-err err-msg :connection-failed
                                     (list :scope scope :side-effect :none))))
      (cl-return-from kargu--api-post-with-handle nil))

    ;; 2. Budget accounting debit gate (Contract 6)
    (when budget
      (let* ((debit-type (if (> attempt 0) :retry-attempt :normal-request))
             (debit-res (kargu-budget-debit budget debit-type :requests 1)))
        (when (kargu-err-p debit-res)
          (kargu-http-clear-busy)
          (funcall callback debit-res)
          (cl-return-from kargu--api-post-with-handle nil))))

    ;; 3. Spawn process via plz and store in HANDLE
    ...))
```

---

## 5. Test Suites Specification

### 5.1. `tests/test-transport-contract.el`

Must test:
1. `kargu-transport-logical-handle-owns-all-resources-test`: Verify single handle holds process, retry timer, and stream timer.
2. `kargu-transport-budget-debits-initial-and-retry-attempts-test`: Initial debit of 1 request, subsequent retry debits 1 request; budget exhaustion prevents dispatch.
3. `kargu-transport-budget-records-token-usage-accurately-test`: Recorded prompt/completion tokens update `kargu-run-budget`; missing tokens mark `tokens-unknown-p = t`.
4. `kargu-transport-scoped-circuit-breaker-isolation-test`: 4 failures on provider A trip circuit A; provider B remains `:closed`.
5. `kargu-transport-circuit-scoped-reset-test`: Resetting provider A leaves provider B unaffected.
6. `kargu-transport-typed-results-mapping-test`: 429 returns `:http-status-429`; 500 returns `:http-status-500`; timeout returns `:timeout`.
7. `kargu-transport-tls-verification-enforced-test`: Self-signed or invalid cert returns `:tls-error` without curl `--insecure`.
8. `kargu-transport-redirect-cross-origin-strips-auth-test`: Redirect from `api.example.com` to `storage.example.net` strips Authorization header.

### 5.2. `tests/test-stream-pressure.el`

Must test:
1. `kargu-stream-newline-less-line-overflow-aborts-cleanly-test`: Stream chunk of 70KB without newline trips `line-buffer-overflow` and terminates process.
2. `kargu-stream-raw-buffer-total-overflow-aborts-test`: Total bytes exceeding 4MB aborts stream with terminal error.
3. `kargu-stream-single-event-size-limit-test`: 2MB data payload in a single SSE event aborts with `:stream-error`.
4. `kargu-stream-multibyte-utf8-chunking-test`: Feeds multibyte emoji byte-by-byte; verifies clean assembly.
5. `kargu-stream-tool-call-count-limit-test`: Model sending > 64 tool calls trips call count limit.
6. `kargu-stream-tool-call-arg-limit-test`: Model sending > 512KB arguments trips argument limit.
7. `kargu-stream-monotonic-time-jump-test`: Clock jump does not stall stream watchdog.
8. `kargu-stream-duplicate-finish-ignored-test`: Data chunk after `:done` is discarded.

---

## 6. Formal Specification Design (TLA+ / TLC)

### 6.1. `proof/KarguTransport.tla`

The specification models:
- Set of `Providers = {p1, p2}`
- Budget with `MaxRequests`
- Logical Request FSM: `IDLE -> IN_FLIGHT -> RETRYING -> FINISHED / CANCELLED / ERROR`
- Bounded stream buffer: `streamBytes <= MaxStreamBytes`
- Owned resources: `resources \subseteq {"process", "retry_timer", "watch_timer"}`
- Key invariants:
  - `Safety_BudgetNeverExceeded`
  - `Safety_SingleHandleOwnership`
  - `Safety_CircuitIsolation`
  - `Safety_StreamBoundsEnforced`
  - `Safety_SingleCallbackDelivery`

### 6.2. `proof/TransportMC.tla` & `TransportMC.cfg`
Model check with TLC:
- `Providers = {p1, p2}`
- `MaxRequests = 3`
- `MaxRetries = 2`
- `FailureThreshold = 2`
- `MaxStreamBytes = 4`

### 6.3. `proof/run_tlc.sh`
Add option `--transport` pointing to `TransportMC.tla` and `TransportMC.cfg`.

---

## 7. Action Plan for Worker E

1. **Phase 1: Scoped Circuit Breaker (`circuit.el`)**:
   Implement `kargu-circuit-breaker` struct and registry table. Ensure full backward compatibility with callers while adding scoped isolation.
2. **Phase 2: Bounded Stream & Parser Drains (`sse.el`, `stream.el`)**:
   Introduce limits (`kargu-stream-max-incomplete-line-bytes`, `kargu-stream-max-raw-bytes`, `kargu-sse-max-event-bytes`, tool-call caps).
3. **Phase 3: Handle & Budget Integration (`http.el`, `retry.el`, `client.el`)**:
   Refactor `kargu--api-post` to require or accept `app` and `connection-snapshot`. Debit `:normal-request` and `:retry-attempt` against `kargu-run-budget`. Record usage on response. Return typed results (`kargu-ok`, `kargu-err`).
4. **Phase 4: Security & Parameter Compatibility (`parameters.el`, `http.el`)**:
   Implement redirect origin check to strip auth headers. Integrate RISK-02 reasoning/sampling constraint.
5. **Phase 5: Test Suites**:
   Write `tests/test-transport-contract.el` and `tests/test-stream-pressure.el`. Ensure 100% test pass rate.
6. **Phase 6: Formal Proofs**:
   Write `proof/KarguTransport.tla`, `proof/TransportMC.tla`, `proof/TransportMC.cfg`, update `proof/run_tlc.sh`, and run exhaustive TLC checking.
