# Challenge Report: Wave 2 Empirical Challenge 2

**Author:** `challenger_wave2_2`  
**Role:** EMPIRICAL CHALLENGER (critic, specialist)  
**Date:** 2026-10-22  
**Target:** Wave 2 Package E (Transport, Circuit Breakers, Stream Pressure & Formal Proofs)  
**Verdict:** **APPROVE**  

---

## 1. Challenge Summary

**Overall risk assessment**: **LOW**

Empirical stress testing and formal exhaustive TLC verification have confirmed the core architectural guarantees of Wave 2 Package E:
1. **Provider Circuit Isolation**: Breakers maintain strict per-provider isolation. Upstream outages on `provider-alpha` trip only alpha to `:open` without degrading `provider-beta`. Canary probing in `:half-open` serializes correctly. Scoped resets affect only the targeted provider.
2. **Run Budget Debits on Retries**: Unified run budget debits initial requests and subsequent retries. When `max-requests` is reached (e.g., 2), no further HTTP requests are dispatched across the wire, and a terminal `:budget-exhausted` error is delivered.
3. **Stream Buffer Pressure**: 64KB incomplete line bounds and 4MB raw payload bounds immediately kill offending subprocesses (`delete-process`), preventing buffer bloat and memory exhaustion.
4. **Cross-Origin Header Stripping**: Cross-origin redirects across host, port, or protocol boundaries strip sensitive `Authorization` and `X-API-Key` headers while preserving non-sensitive headers.
5. **Formal Proofs**: All 7 Wave 2 TLA+ specifications pass exhaustive breadth-first model checking via `proof/run_tlc.sh` with 0 errors across 480,370 generated states.

Two non-blocking empirical refinement findings were discovered during stress testing:
- **Challenge 1 (Medium/Low)**: Stream abort callback delivers `"stream stalled"` with an untyped error alist rather than a typed error symbol (`:stream-line-overflow` or `:stream-raw-overflow`).
- **Challenge 2 (Low)**: The retry scheduler checks `(kargu-budget-live-p budget)` rather than `(> (kargu-budget-remaining-requests budget) 0)`, scheduling a doomed backoff timer before debit rejection occurs in `kargu--api-post`.

---

## 2. Empirical Stress Challenges

### Challenge 1: Stream Buffer Abort Error Classification & Typing

- **Assumption challenged**: That stream buffer pressure violations abort with a canonical typed error code and accurate error description.
- **Attack scenario**: Feed a stream chunk exceeding `kargu-stream-max-incomplete-line-bytes` (64KB) or `kargu-stream-max-raw-bytes` (4MB).
- **Observation**:
  - `kargu--stream-filter` immediately flags `:kargu-stream-abort` as `'line-buffer-overflow` or `'raw-buffer-overflow` and kills the process (`(delete-process process)`).
  - However, when `kargu-http--fail-request` invokes `kargu--api-fail-stream`, `kargu--api-stream-abort-message` (lines 129–133 in `kargu/api/http.el`) only checks `(eq reason 'ceiling)` and falls back to `"stream stalled"`.
  - In addition, `kargu--api-fail-stream` invokes `(kargu--api-error-alist msg)` without supplying a `code` or `data` argument.
  - The client callback receives `(("error" ("message" . "stream stalled")))` rather than a typed error symbol (e.g. `:stream-line-overflow`) or accurate description.
- **Blast radius**: Low. The subprocess is safely terminated and memory bloat is prevented. However, control decisions cannot distinguish a network stall from a buffer overflow via canonical Result symbols.
- **Mitigation**: Update `kargu--api-stream-abort-message` to map `'line-buffer-overflow` to `"SSE line exceeded maximum bound"` and `'raw-buffer-overflow` to `"Stream raw buffer limit exceeded"`. Pass corresponding error codes (`:stream-line-overflow`, `:stream-raw-overflow`) to `kargu--api-error-alist`.

### Challenge 2: Eager Budget Exhaustion Gate in Retry Scheduler

- **Assumption challenged**: That retries are suppressed immediately when the budget reaches 0 without setting asynchronous backoff timers.
- **Attack scenario**: Set `max-requests = 2`, issue a request that fails with retryable HTTP 503. Initial attempt uses request 1, retry attempt uses request 2 (leaving 0 remaining). The retry attempt also fails with HTTP 503.
- **Observation**:
  - In `KarguTransport.tla` (line 97), `FailAndRetry` has guard `budget_spent < MaxRequests`. When `budget_spent == MaxRequests`, the formal model transitions directly to `FailTerminal`.
  - In `kargu/api/retry.el` (line 271), `budget-ok` checks `(or (null budget) (kargu-budget-live-p budget))`.
  - Because `budget.el` leaves `(kargu-run-budget-status budget)` as `:ok` until a debit is rejected by `kargu-budget-debit`, `(kargu-budget-live-p budget)` remains `t` even when `requests-spent == max-requests` (i.e. `remaining-requests == 0`).
  - Therefore, `kargu--api-on-transport-error` schedules `run-at-time` for backoff. Only when the timer fires and `kargu--api-post` calls `(kargu-budget-debit budget :retry-attempt :requests 1)` is the debit rejected and the request aborted.
  - No 3rd HTTP call is ever made (`plz-calls = 2`), preserving the single budget invariant.
- **Blast radius**: Low. Safety is guaranteed because `kargu--api-post` enforces the debit gate. However, an unnecessary timer delay occurs before delivering the terminal error.
- **Mitigation**: Update `budget-ok` in `kargu/api/retry.el` to `(and (kargu-budget-live-p budget) (> (kargu-budget-remaining-requests budget) 0))` so `kargu--api-on-transport-error` immediately triggers terminal error delivery without scheduling backoff timers.

---

## 3. Stress Test Results

| Scenario | Expected Behavior | Actual Behavior | Result |
|---|---|---|---|
| **Circuit Trip Isolation** | Fail `provider-alpha` 4 times; alpha trips to `:open`; `provider-beta` remains `:closed`. | Alpha state `:open`, open-p `t`, allow-p `nil`. Beta state `:closed`, open-p `nil`, allow-p `t`. | **PASS** |
| **Circuit Scoped Reset** | Trip both alpha and beta; reset only alpha; alpha becomes `:closed`, beta remains `:open`. | Alpha state `:closed`, beta state `:open` (open-p `t`). | **PASS** |
| **Canary Probe Serialization** | After cooldown, 1 probe allowed (`:half-open`, `probe-inflight t`); concurrent requests denied. | 1st request returns `t` and claims probe; 2nd concurrent request returns `nil`. | **PASS** |
| **Cross-Origin Host Redirect** | Redirect `api.example.com` -> `storage.other.com` strips `Authorization` & `X-API-Key`. | Sensitive headers stripped; `Content-Type`, `Accept`, `User-Agent` preserved. | **PASS** |
| **Cross-Origin Port Redirect** | Redirect `api.example.com:443` -> `api.example.com:8443` strips sensitive headers. | Sensitive headers stripped. | **PASS** |
| **Cross-Origin Proto Redirect**| Redirect `https://` -> `http://` strips sensitive headers. | Sensitive headers stripped. | **PASS** |
| **Same-Origin Redirect** | Redirect `api.example.com/v1/chat` -> `api.example.com/v1/download` keeps all headers. | All 5 headers preserved verbatim. | **PASS** |
| **Incomplete Line Overflow** | 65,537 bytes without newline aborts immediately and kills subprocess. | Abort reason `:line-buffer-overflow`, process live-p `nil`. | **PASS** |
| **Raw Buffer Cap Overflow** | > 4MB total raw bytes aborts immediately and kills subprocess. | Abort reason `:raw-buffer-overflow`, process live-p `nil`. | **PASS** |
| **Budget Debits on Retries** | Budget `max-requests = 2`; 503 errors debit initial and retry; stops at 2 HTTP calls. | Initial spent=1, retry spent=2. Exactly 2 HTTP calls executed. Rejection with `:budget-exhausted`. | **PASS** |

---

## 4. Formal Model Verification Results

All 7 Wave 2 TLA+ specifications were verified using `bash proof/run_tlc.sh`:

1. **KarguApproval** (`bash proof/run_tlc.sh --approval`):
   - States generated: 8,194
   - Distinct states: 1,536
   - Depth: 11
   - TLC exit code: 0 (0 errors)
2. **KarguTransport** (`bash proof/run_tlc.sh --transport`):
   - States generated: 1,810
   - Distinct states: 693
   - Depth: 13
   - TLC exit code: 0 (0 errors)
3. **KarguProcess** (`bash proof/run_tlc.sh --process`):
   - States generated: 535
   - Distinct states: 179
   - Depth: 9
   - TLC exit code: 0 (0 errors)
4. **KarguConnection** (`bash proof/run_tlc.sh --connection`):
   - States generated: 446,212
   - Distinct states: 77,292
   - Depth: 19
   - TLC exit code: 0 (0 errors)
5. **KarguBudget** (`bash proof/run_tlc.sh --budget`):
   - States generated: 1,591
   - Distinct states: 432
   - Depth: 11
   - TLC exit code: 0 (0 errors)
6. **KarguMode** (`bash proof/run_tlc.sh --mode`):
   - States generated: 20,179
   - Distinct states: 5,958
   - Depth: 16
   - TLC exit code: 0 (0 errors)
7. **KarguEdit** (`bash proof/run_tlc.sh --edit-transaction`):
   - States generated: 1,849
   - Distinct states: 560
   - Depth: 11
   - TLC exit code: 0 (0 errors)

**Cumulative formal verification**: 480,370 states generated, 86,650 distinct states checked, 0 errors found.

---

## 5. Unchallenged Areas

- **Live Upstream Endpoints**: Real external network latency, cloud proxy behaviors, and upstream TLS certificate renewals are out of scope (mocked or pipe-tested via controlled local test harnesses).
- **Package D & F Domain Internals**: Tool execution gate permissions and process tree signal handling are owned by challenger `challenger_wave2_1`.
