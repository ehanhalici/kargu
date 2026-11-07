# Wave 2 Review Report: Package D & Package E

**Reviewer**: `reviewer_wave2_1`  
**Roles**: Reviewer, Adversarial Critic  
**Date**: 2026-10-22  
**Target Milestone**: Dalga 2 (Packages D & E)  
**Parent Agent**: `246e42bd-e1b7-4f73-8026-d90704dd17ec`

---

## 1. Review Summary

**Verdict: APPROVE**

Both Package D (Tool Execution Gate & Registry) and Package E (Bounded Transport & Circuit Breakers) exhibit exceptional architectural rigor, complete specification and contract compliance, high test coverage, clean static quality metrics (zero byte-compile warnings with `byte-compile-error-on-warn t`, zero checkdoc warnings), and mathematically sound formal model checking via TLC without errors. No integrity violations or shortcuts were found.

---

## 2. Integrity and Anti-Cheat Assessment

An exhaustive adversarial examination of the source code, test suites, and git history was conducted against all integrity dimensions:

1. **Hardcoded Test Results / Facade Implementations**:
   - Grep analysis for synthetic test tool names (`leak_tool`, `huge_tool`, `echo_tool`, `provider-a`, `provider-b`) across `kargu/` returned 0 matches.
   - All logic in `kargu/tools/execution.el`, `kargu/tools/registry.el`, `kargu/permission/execute.el`, `kargu/api/circuit.el`, `kargu/api/http.el`, `kargu/api/retry.el`, `kargu/api/sse.el`, and `kargu/api/stream.el` executes genuine, stateful algorithmic logic.
2. **Shortcuts & Delegations**:
   - The 13-stage tool execution gate runs every stage sequentially without skipping permission checks, parameter validation, secret redaction, or budgeting.
   - Transport error classification uses typed domain error symbols without delegating to brittle regex or string searches on error messages.
3. **Fabricated Logs / Self-Certifying Work**:
   - All verification steps (ERT tests, byte-compilation, checkdoc, TLC model checking) were reproduced and executed independently with genuine verification tools, matching all upstream claims verbatim.
4. **Repository Hygiene**:
   - Zero byte-compiled `.elc` artifacts remain.
   - Protected files `skills.md` and `.gitignore` remain completely unstaged and unmodified.
   - No cross-agent workspace contamination.

---

## 3. Package D: Tool Execution Gate & Registry Review

### 3.1 Contract Compliance (Contract 5, MOD-02, ARCH-02, ARCH-03, ARCH-09, ARCH-15, ARCH-16, ARCH-17)

1. **13-Stage Execution Gate (`kargu/tools/execution.el`)**:
   - Stage 1: Context validation (`kargu-tool-execution--validate-gate` validates `kargu-tool-registry-p` and `kargu-tool-execution-context-p`).
   - Stage 2: Registry presence & canonical resolution (`kargu-tool-registry-find` flattens aliases to canonical names).
   - Stage 3: Draining check (`kargu-tool-registry-draining-p` rejects new invocations on draining tools with `:tool-draining`).
   - Stage 4: Mode permission check (`:modes` in policy must match context mode, e.g. mutating tools prohibited in `:ask` or `:plan`).
   - Stage 5: Availability check (`:available-p` thunk evaluated; string refusal returned cleanly without crashing).
   - Stage 6: Budget pre-check (`kargu-budget-live-p` verifies run budget is not exhausted before dispatching).
   - Stage 7: Decode & validate parameters (`kargu-tool-execution-decode-arguments` ensures arguments form a single JSON object).
   - Stage 8: Single-use approval verification & claim resolution (`kargu-tool-approval-claim` enforces single-use token binding).
   - Stage 9: Async task tracking (`kargu-tool-execution--track-task` registers active tasks under canonical name with unwinding cleanup).
   - Stage 10: Tool execution dispatch (handles both 1-arity sync and 2-arity async executors with `condition-case-unless-debug` error protection).
   - Stage 11: Secret redaction (`kargu-tool-execution-redact` scrubs Bearer tokens, API keys, and sensitive key-value pairs).
   - Stage 12: Output token budgeting debit (`kargu-budget-record-tokens` attributes output tokens against run budget).
   - Stage 13: Output truncation and archiving (`kargu-tool-execution-truncate-for-model` bounds result to `kargu-tool-output-limit` and archives excess to project-scoped `*kargu-output-N*` buffer up to character and buffer quotas).

2. **Single-Use Captured Approval (`kargu-tool-approval`)**:
   - Enforces `claimed-p` slot mutation: once claimed, subsequent attempts immediately return `:approval-stale`.
   - Cryptographic and contextual binding: binds canonical tool name, SHA256 arguments hash (`kargu-tool-approval--hash-args`), canonical directory root (`file-truename`), and monotonic policy revision (`policy-revision`). Any deviation triggers `:approval-mismatch`.
   - Replay attacks and parameter tampering are impossible.

3. **Registry Monotonic Revision & Draining (`kargu/tools/registry.el`)**:
   - `revision` integer slot increments monotonically on all registry mutations (`register`, `alias`, `set-policy`, `remove`).
   - Consumer schema immutability: `kargu-tool-registry-register` performs `(copy-tree parameters)` so consumer mutations cannot alter registry definitions.
   - Draining lifecycle: `kargu-tool-execution-drain` marks tool draining, cancels active tasks if requested, and waits for active task count to reach zero before removing definition.

4. **Public API Bridge (`kargu/api/tools.el`)**:
   - Single-point argument decoding: `kargu-tool-execution-decode-arguments` is invoked once and reused across validation and gate execution.
   - Synchronous/asynchronous bridge: safely dispatches through `kargu-tool-gate-execute` (async) or `kargu-tool-gate-execute-sync` (sync), handling async-requiring tools cleanly.

---

## 4. Package E: Bounded Transport & Circuit Breakers Review

### 4.1 Contract Compliance (Contract 1, Contract 4, Contract 6, Contract 8, MOD-04, RISK-02, DEEP-09, DEEP-12, DEEP-14, ARCH-15, ARCH-16, ARCH-17)

1. **Provider-Scoped Circuit Breakers (`kargu/api/circuit.el`)**:
   - 3-state state machine: `:closed`, `:open`, `:half-open`.
   - Provider isolation: circuit breakers are keyed by normalized provider name (`kargu-circuit--registry`). Outages on Provider A do not trip Provider B.
   - Canary probe slot: during `:half-open`, exactly one request is permitted to probe upstream health (`kargu-circuit-breaker-probe-inflight`). Concurrent requests are refused until probe succeeds or fails.
   - Scoped reset: `kargu-circuit-reset` can reset an individual provider or all providers (`'all`).
   - Backward-compatibility: synchronizes seamlessly with legacy dynamic variables.

2. **Unified Run Budget Debiting (`kargu/api/http.el`, `kargu/api/retry.el`)**:
   - Initial HTTP request debits `:normal-request` (`requests: 1`).
   - Retries debit `:retry-attempt` (`requests: 1`).
   - Exhaustion check: if `kargu-budget-debit` returns an error (due to request limit, token limit, or deadline expiration), the transport immediately halts without sending HTTP traffic.
   - Token accounting: usage is recorded into budget. Missing upstream usage sets `tokens-unknown-p = t` without fabricating zero counts.

3. **No String Parsing for Error Decisions (`kargu/api/retry.el`)**:
   - Canonical classification: `kargu-api-classify-error-code` maps HTTP status codes and curl errors to canonical domain symbols (`:rate-limit-exceeded`, `:server-error`, `:bad-gateway`, `:gateway-timeout`, `:overloaded`, `:timeout`, `:tls-error`, `:connection-failed`, `:bad-request`, `:authentication-failed`).
   - `kargu--api-error-looks-retryable-p` directly checks canonical symbols and `kargu-result-err` structures, eliminating brittle string matching for control flow.

4. **Bounded Stream Buffers (`kargu/api/sse.el`, `kargu/api/stream.el`)**:
   - Incomplete line limit: `kargu-stream-max-incomplete-line-bytes` (default 64 KB). Exceeding aborts stream with `'line-buffer-overflow`.
   - Raw buffer limit: `kargu-stream-max-raw-bytes` (default 4 MB). Exceeding aborts stream with `'raw-buffer-overflow`.
   - Single event limit: `kargu-sse-max-event-bytes` (default 1 MB).
   - Tool calls limit: `kargu-stream-max-tool-calls` (default 64).
   - Tool arguments limit: `kargu-stream-max-tool-args-bytes` (default 512 KB).
   - Multibyte UTF-8 chunk preservation: splits across chunk boundaries decode accurately without corrupting multibyte code points.
   - Duplicate finish discard: data chunks arriving after `:done` or `finish_reason` are discarded.

5. **Cross-Origin Credential Stripping (`kargu/api/http.el`)**:
   - `kargu-http--strip-auth-for-cross-origin` inspects scheme, host, and port using `url-generic-parse-url`. On origin mismatch, sensitive `Authorization` and `X-API-Key` headers are stripped.

---

## 5. Adversarial Challenge & Stress-Test Analysis

### Challenge 1: Single-Use Approval Replay & Environmental Drift
- **Assumption Challenged**: Approval granted for tool execution cannot be intercepted, replayed, or reused in modified contexts.
- **Attack Vector**: (1) Presenting the same approval struct to a second execution; (2) Changing tool arguments after approval generation; (3) Changing directory root; (4) Mutating tool registry policy during pending approval.
- **Result**: PASS. `kargu-tool-approval-claim` verifies `(null claimed-p)`, canonical tool name, deterministic SHA-256 arguments hash, directory root, and policy revision. Replay yields `:approval-stale`; tampering yields `:approval-mismatch`. Formal TLC model `proof/ApprovalMC.tla` verified 8,194 states with 0 invariant violations.

### Challenge 2: Tool Registry Concurrency & Active Task Draining
- **Assumption Challenged**: Unregistering or replacing a tool definition does not corrupt in-flight asynchronous tool tasks.
- **Attack Vector**: An active async task is running when an administrator unregisters or re-registers the tool.
- **Result**: PASS. `kargu-tool-execution-drain` marks the canonical name as draining, rejecting new executions with `:tool-draining`. Active tasks continue under async handles or are cancelled via `:cancel-p t`. The definition is removed only after active task count drops to zero.

### Challenge 3: Malicious SSE Stream Flooding & UTF-8 Fragmentation
- **Attack Vector**: (1) Endless raw byte stream without newlines; (2) Thousands of small lines exceeding memory; (3) Multibyte UTF-8 characters split at 1-byte increments.
- **Result**: PASS. (1) Incomplete line buffer triggers abort at 64 KB; (2) Total raw buffer triggers abort at 4 MB; (3) `tests/test-stream-pressure.el` verified byte-by-byte streaming of complex multibyte UTF-8 emoji ("Merhaba dünya 🦀🚀🤖") with 100% fidelity.

### Challenge 4: Credential Egress via Redirects
- **Attack Vector**: Redirect pointing to different port on same host, or different protocol (HTTPS -> HTTP), or external host.
- **Result**: PASS. `kargu-http--same-origin-p` enforces equality across scheme, host, and port. All three mismatch vectors strip `Authorization` and `X-API-Key`.

---

## 6. Verified Claims Matrix

| Claim | Verification Method | Status |
|---|---|---|
| Package D 19 Contract Tests | `emacs -Q --batch -L . -l tests/test-tool-execution-contract.el -f ert-run-tests-batch-and-exit` | PASS (19/19) |
| Package E 68 Transport & Pressure Tests | `emacs -Q --batch -L . -L tests --eval "(...)" -f ert-run-tests-batch-and-exit` | PASS (68/68) |
| Full Repository ERT Test Suite | 1049 tests run in clean batch Emacs | PASS (1049/1049, 0 unexpected) |
| TLC Model Check: Captured Approval | `bash proof/run_tlc.sh --approval` | PASS (8,194 states, 0 errors) |
| TLC Model Check: Bounded Transport | `bash proof/run_tlc.sh --transport` | PASS (1,810 states, depth 13, 0 errors) |
| Strict Byte-Compilation (0 warnings) | `(setq byte-compile-error-on-warn t)` on 22 Package D & E files | PASS (0 errors, 0 warnings) |
| Strict Checkdoc (0 warnings) | `checkdoc-current-buffer` on all 20 modified/new files | PASS (0 warnings) |
| Clean Working Tree / No `.elc` | `find . -name "*.elc"` and `git status --porcelain skills.md .gitignore` | PASS (Empty output) |

---

## 7. Verdict & Recommendation

**VERDICT: APPROVE**

Package D and Package E are completely implemented, fully tested, mathematically verified, and production-ready for Dalga 2 integration.
