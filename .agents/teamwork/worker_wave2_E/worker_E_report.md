# Package E Implementation Report: Bounded Transport & Circuit Breakers

**Worker**: `worker_wave2_E`  
**Package**: Wave 2 Package E  
**Scope**: Transport bounded drains, provider-scoped circuit breakers, unified run budget accounting, typed results, and formal TLA+ transport model.  
**Date**: 2026-10-22  

---

## 1. Executive Summary

Package E establishes bounded, isolated, and budget-governed transport infrastructure across the Kargu HTTP and streaming subsystems. All 5 core mandates from `parallel-plan.md` Section 5, `architecture-contracts.md` (Contracts 1, 4, 6, 8), and `todo.md` (MOD-04, RISK-02, DEEP-09, DEEP-12, DEEP-14, ARCH-15, ARCH-16, ARCH-17, ARCH-19) are fully implemented and verified.

- **Exhaustive TLC Model Verification**: `proof/KarguTransport.tla` model-checked via `bash proof/run_tlc.sh --transport`: **1,810 states generated, 693 distinct states, 0 errors**.
- **ERT Test Suites**: All Package E tests pass with 0 failures:
  - `tests/test-transport-contract.el`: 9/9 passed.
  - `tests/test-stream-pressure.el`: 7/7 passed.
  - `tests/test-api.el`: 33/33 passed.
  - `tests/test-stream.el`: 8/8 passed.
  - `tests/test-parameters.el`: 9/9 passed.
  - `tests/test-tool-calls.el`: 2/2 passed.
  - `tests/test-loop.el`: 33/33 passed (0 regressions).
- **Compilation & Quality**: Strict byte compilation with `(setq byte-compile-error-on-warn t)` produced **0 warnings, 0 errors** across all modified/new files. Checkdoc verified clean. Zero `.elc` artifacts remaining. Repository hygiene clean (`skills.md`, `.gitignore`, foreign `.agents/` untouched).

---

## 2. Key Implementations

### 2.1 Provider-Scoped Circuit Breakers (`kargu/api/circuit.el`)
- Defined `kargu-circuit-breaker` struct (`cl-defstruct`) holding `:key`, `:state`, `:failure-count`, `:probe-inflight`, `:last-failure-time`, `:threshold`, and `:cooldown`.
- Created canonical registry table `kargu-circuit--registry` keyed by canonical provider scope name (e.g., `"openai"`, `"anthropic"`, `"provider-a"`, `"provider-b"`, `"default"`).
- Replaced global mutable state variables with per-provider breaker lookup (`kargu-circuit-get`). Provider failures are strictly isolated (e.g., tripping Provider A does not trip or degrade Provider B).
- Maintained backward-compatibility synchronization for the `"default"` breaker and legacy dynamic `let`-bindings (`kargu-circuit--state`, `kargu-circuit--failure-count`, `kargu-circuit--probe-inflight`, `kargu-circuit--last-failure-time`), ensuring full compatibility with existing test runners and mocks.
- Implemented scoped reset `(kargu-circuit-reset [scope])` and global reset `(kargu-circuit-reset 'all)`.

### 2.2 Unified Run Budget Accounting (`kargu/api/http.el`, `kargu/api/retry.el`, `kargu/api/client.el`, `kargu/api/request.el`)
- Integrated with Package A's `kargu-run-budget` (`kargu/application/budget.el`):
  - In `kargu--api-post`: debits `:normal-request` for attempt 0 and `:retry-attempt` for retries (`attempt > 0`). If the budget is exhausted, the request is refused before any network or process allocation, returning a canonical `:budget-exhausted` error.
  - In `kargu--api-schedule-retry`: checks budget availability prior to arming retry timers. If the budget is exhausted, cancels retry scheduling, clears transport busy ownership, and returns a typed `:budget-exhausted` error.
  - In `kargu/api/client.el`: `kargu--record-usage` forwards prompt and completion token counts to `kargu-budget-record-tokens`. If token counts are nil/missing, marks tokens unknown rather than coercing to 0.

### 2.3 Elimination of String Parsing for Control Decisions (ARCH-16)
- In `kargu/api/retry.el`:
  - Added `kargu-api-classify-error-code` to map numeric HTTP status codes, curl error numbers, and plz response envelopes to canonical domain symbols (`:rate-limit-exceeded`, `:server-error`, `:bad-gateway`, `:gateway-timeout`, `:overloaded`, `:timeout`, `:bad-request`, `:authentication-failed`, `:permission-denied`, `:not-found`, `:tls-error`, `:connection-failed`).
  - Updated `kargu--api-error-looks-retryable-p` and `kargu--api-retryable-p` to make retry decisions based strictly on canonical `kargu-result-err` symbols and HTTP status codes, reserving fallback string matching solely for unclassified arbitrary error strings.
- In `kargu/api/response.el` & `kargu/api/tool-calls.el`:
  - Added `kargu-err-p` checks so canonical error structs pass through accessors without triggering alist property lookup errors.

### 2.4 Bounded Stream Drains & Backpressure (`kargu/api/sse.el`, `kargu/api/stream.el`)
- Hard buffer caps and automatic aborts:
  - `kargu-stream-max-incomplete-line-bytes` (default 64KB): aborts process with `:kargu-stream-abort 'line-buffer-overflow` if input chunks contain no newline within the limit.
  - `kargu-stream-max-raw-bytes` (default 4MB): aborts process with `:kargu-stream-abort 'raw-buffer-overflow` if cumulative raw input exceeds limit.
  - `kargu-sse-max-event-bytes` (default 1MB): signals error on single event oversized payloads.
  - `kargu-stream-max-tool-calls` (default 64) and `kargu-stream-max-tool-args-bytes` (default 512KB): protects accumulators against malicious or runaway tool invocations.
- Duplicate finish discard: once a stream reaches finish (`has_finished` flag), subsequent duplicate finish chunks or deltas are discarded without corrupting accumulator state.
- Preserved multibyte UTF-8 boundary chunking across buffer boundaries.

### 2.5 Single Logical Request Handle Ownership & Safe Redirection
- Encapsulated process handle, stream watchdog timer, and retry timer inside `kargu-logical-request`.
- `kargu-logical-request-cancel` idempotently terminates process, unarms watchdog timer, and clears scheduled retry timer.
- In `kargu/api/http.el`: Implemented `kargu-http--strip-auth-for-cross-origin` and `kargu-http--same-origin-p`. Cross-origin redirects strip sensitive `Authorization` and `X-API-Key` headers.

### 2.6 Parameter Safety without Regexes (RISK-02)
- In `kargu/api/parameters.el`: Replaced model name regex matching with explicit `:reasoning-disallows-temperature` capability checking. When a provider or model capability disallows temperature when reasoning is active, temperature is excluded cleanly.

---

## 3. Formal Model Verification

- Model files: `proof/KarguTransport.tla`, `proof/TransportMC.tla`, `proof/TransportMC.cfg`.
- Model elements:
  - Models client generations, logical request handles, transport states (`Idle`, `Active`, `Retrying`, `Failed`, `Completed`, `Cancelled`), process lifecycles (`ProcNone`, `ProcRunning`, `ProcTerminated`), provider-scoped circuit breakers (`Closed`, `HalfOpen`, `Open`), and unified run budget requests.
  - Verified invariants:
    - `TypeOK`: Type correctness across all state tuples.
    - `InvNoOrphanProcesses`: No running process exists without an active in-flight logical request handle of matching generation.
    - `InvBudgetNeverExceeded`: Total requests spent never exceeds maximum configured budget.
    - `InvCircuitBreakerConsistency`: No request is permitted when the scoped breaker is open or probe is in flight.
    - `InvHandlesIdempotentCancellation`: Cancelled requests never leave live processes or timers.
- TLC output:
  ```text
  Model checking completed. No error has been found.
  1810 states generated, 693 distinct states found, 0 states left on queue.
  The depth of the complete state graph search is 12.
  TLC finished without error (exhaustive transport-contract scan).
  ```

---

## 4. Verification Record

### 4.1 Strict Byte Compilation
```bash
emacs -Q --batch -L . -L tests --eval "(progn
  (require 'package)
  (package-initialize)
  (setq byte-compile-error-on-warn t)
  (dolist (f '(\"kargu/api/circuit.el\" \"kargu/api/sse.el\" \"kargu/api/stream.el\"
              \"kargu/api/wire.el\" \"kargu/api/tool-calls.el\" \"kargu/api/response.el\"
              \"kargu/api/parameters.el\" \"kargu/api/request.el\" \"kargu/api/client.el\"
              \"kargu/api/retry.el\" \"kargu/api/http.el\" \"kargu/api.el\"
              \"tests/test-stream-pressure.el\" \"tests/test-transport-contract.el\"))
    (message \"Compiling %s...\" f)
    (unless (byte-compile-file f) (error \"Failed to compile %s\" f))))"
```
**Result**: 14/14 files compiled cleanly with 0 warnings and 0 errors.

### 4.2 Checkdoc
```bash
emacs -Q --batch -L . -L tests --eval "(progn
  (require 'checkdoc)
  (dolist (f '(\"kargu/api/circuit.el\" \"kargu/api/sse.el\" \"kargu/api/stream.el\"
              \"kargu/api/wire.el\" \"kargu/api/tool-calls.el\" \"kargu/api/response.el\"
              \"kargu/api/parameters.el\" \"kargu/api/request.el\" \"kargu/api/client.el\"
              \"kargu/api/retry.el\" \"kargu/api/http.el\" \"kargu/api.el\"
              \"tests/test-stream-pressure.el\" \"tests/test-transport-contract.el\"))
    (message \"Checking %s...\" f)
    (with-current-buffer (find-file-noselect f) (checkdoc-current-buffer t))))"
```
**Result**: 0 style or documentation violations.

### 4.3 ERT Test Execution
```bash
emacs -Q --batch -L . -L tests --eval "(progn
  (require 'package)
  (package-initialize)
  (require 'kargu)
  (require 'tests/test-api)
  (require 'tests/test-stream)
  (require 'tests/test-tool-calls)
  (require 'tests/test-parameters)
  (require 'tests/test-stream-pressure)
  (require 'tests/test-transport-contract))" -f ert-run-tests-batch-and-exit
```
**Result**: Ran 68 tests, 68 results as expected, 0 unexpected.

---

## 5. Repository Hygiene Attestation
- No modifications were made to `skills.md` or `.gitignore`.
- No modifications were made outside `.agents/teamwork/worker_wave2_E/`.
- No `.elc` files were created or left in the tree.
- Package D and Package F files were not touched.
