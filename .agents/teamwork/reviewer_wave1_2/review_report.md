# Review & Adversarial Challenge Report: Wave 1 Package C

**Reviewer**: reviewer_wave1_2 (Wave 1 Reviewer 2)  
**Target**: Package C (Credential/Connection Snapshot and Repository Health)  
**Date**: 2026-10-21  

---

## Part 1: Quality Review

## Review Summary

**Verdict**: **APPROVE**

Package C implementation satisfies all requirements specified in `parallel-plan.md` (Section 4: Wave 1 Package C), `architecture-contracts.md` (Contract 4: Connection Snapshot), and CONFIG-01 / ARCH-15 / ARCH-19 / DEEP-14 / MOD-03:
- UI and discovery paths are purely non-blocking in-memory (`kargu-config-api-key-fast`, `kargu-check-setup`), completely preventing synchronous `auth-source-search` and pinentry evaluation on the Emacs UI thread (CONFIG-01).
- Background worker (`kargu/config/worker.el`) executes asynchronous subprocess lookups via `make-process` in batch mode (`-Q --batch`), passes only host and paths in `argv` (zero secrets in `argv`), caps output buffer at 64KB (`kargu-config-worker-max-bytes`), and deletes the child process upon cancellation or timeout.
- Connection snapshot (`kargu/config/connection.el`) is an immutable struct (`:read-only t` slots), securely wraps credentials in `kargu-credential-scope`, wipes secrets in memory using `clear-string`, binds monotonic `kargu-config-revision`, and safely discards stale results upon configuration or session changes.
- 100% test pass rate across 41 Package C unit tests. Clean byte-compilation with `byte-compile-error-on-warn t` (0 warnings). Checkdoc clean (0 warnings). Exhaustive TLA+/TLC model checking verified across 77,292 distinct states with 0 errors. Repository hygiene confirmed (0 `.elc` files, protected paths untouched).

---

## Findings

### [Minor] Finding 1: Full ERT Suite Legacy Transition Gaps in Unmigrated Waves
- **What**: In the full 988-test ERT suite run, 962 tests passed and 26 tests failed.
- **Where**: Legacy modules scheduled for Waves 2–4 (`tests/test-loop.el`, `tests/test-heal.el`, `tests/test-dape.el`, `tests/test-cache.el`, and legacy transition tests in `tests/test-modules.el`).
- **Why**: Package A introduced strict application state machine validation (`kargu-application-transition`), enforcing that transitions out of `:idle` must go through valid sequence (`:starting`, etc.) under an owned claim. Legacy tests from prior code directly invoke `(kargu-state-transition-status :verifying)` from `:idle` without claiming a run.
- **Impact on Package C**: Zero impact. All 41 Package C tests pass with 100% success rate. Package C contains no references or call sites involved in these legacy failures. Wave 2 (Package E), Wave 3 (Package G), and Wave 4 (Package K, J) will migrate these legacy test cases to use the owned application coordinator.
- **Suggestion**: Ensure Wave 2 and Wave 3 packages continue their scheduled migration of the loop and transport tests to consume the owned coordinator.

---

## Verified Claims

- **Claim 1: CONFIG-01 UI Thread Non-Blocking Invariant**
  - Claim: UI and setup checks never trigger synchronous `auth-source-search` or pinentry callable `:secret` evaluation.
  - Verification Method: Verified in `kargu/config/key.el:224-228` (`kargu-config-api-key-fast` calls `kargu--resolve-direct-api-key` in-memory only), `kargu/config/schema.el:187` (`kargu-check-setup` uses `kargu-config-api-key-fast`), and `kargu/config/key.el:256-265` (`kargu-config-resolve-api-key-result` returns `:unavailable` when `:secret` is a callable function). Tested via ERT `kargu-connection-callable-secret-never-called-on-ui-thread-test` and `kargu-provider-discovery-never-invokes-secret-function-or-gpg-test`.
  - Result: **PASS**

- **Claim 2: Asynchronous Subprocess Worker & Secret Safety (DEEP-14)**
  - Claim: `kargu/config/worker.el` executes via `make-process`, never passes secrets in `argv`, caps output at 64KB, and deletes child process on cancellation.
  - Verification Method: Verified `make-process` command construction in `worker.el:122-133` (passes `-Q --batch --eval <script> -- host sources-str`). Verified filter enforces `kargu-config-worker-max-bytes` (65,536 bytes) and terminates process. Verified cleanup hook interrupts and deletes process. Real subprocess execution verified independently with temporary authinfo file (`OK:test-secret-token-real` resolved, zero secrets in `argv`). Tested via ERT `kargu-connection-worker-never-passes-secrets-in-argv-test` and `kargu-connection-cancellation-cleans-up-worker-test`.
  - Result: **PASS**

- **Claim 3: Immutable Connection Snapshot & Scope Wiping (Contract 4)**
  - Claim: `kargu-connection-snapshot` fields are immutable (`:read-only t`), summaries omit credentials, and scope wipe zeroes secret bytes using `clear-string`.
  - Verification Method: Verified struct definition in `kargu/config/connection.el:84-94`, redaction in `connection.el:110-121`, and zeroing in `connection.el:71-80`. Adversarial test verified that modifying struct slots raises error, summary string does not contain secret, and underlying string in memory is mutated to null bytes by `clear-string`.
  - Result: **PASS**

- **Claim 4: Monotonic Revision & Stale Result Discard**
  - Claim: `kargu-config-revision` increments on TOML reload or provider switch; late background discovery results after a revision bump are rejected as `:stale-discard`.
  - Verification Method: Verified `kargu-config-bump-revision` in `schema.el:27-30` and callers in `schema.el:73, 103`. Verified stale check in `connection.el:170, 214-216`. Tested via ERT `kargu-connection-stale-discard-on-config-revision-test`.
  - Result: **PASS**

- **Claim 5: Unit Test Pass Rate**
  - Claim: 41 unit tests pass with exit code 0.
  - Verification Method: Independently executed 3 test suites:
    - `test-connection-snapshot.el`: 11 / 11 passed (0.104 sec).
    - `test-config.el`: 11 / 11 passed (0.020 sec).
    - `test-providers.el`: 19 / 19 passed (0.080 sec).
    Total: 41 / 41 passed (100%).
  - Result: **PASS**

- **Claim 6: Byte-Compilation & Checkdoc Cleanliness**
  - Claim: 0 warnings under `byte-compile-error-on-warn t` and 0 checkdoc warnings.
  - Verification Method: Independently compiled all Package C source and test files with `(setq byte-compile-error-on-warn t)`. Ran `checkdoc-file` on all 6 Package C files. Both completed with 0 warnings and exit code 0.
  - Result: **PASS**

- **Claim 7: Formal Model Verification (TLC)**
  - Claim: Exhaustive model checking of `KarguConnection.tla` without invariant violations.
  - Verification Method: Executed `bash proof/run_tlc.sh --connection`. TLC parsed and model-checked `ConnectionMC.tla`, generating 446,212 states and 77,292 distinct states with 0 errors.
  - Result: **PASS**

- **Claim 8: Repository Hygiene**
  - Claim: 0 leftover `.elc` files; `skills.md`, `.gitignore`, and `.agents/` outside `.agents/teamwork/` untouched.
  - Verification Method: Executed `find . -name "*.elc"` (0 files). Checked `git status --porcelain` on `skills.md`, `.gitignore`, and `.agents/rules` (all untouched, unmodified).
  - Result: **PASS**

---

## Coverage Gaps

- None identified for Package C scope. All production and test code paths specified in Contract 4 and parallel-plan Section 4 are fully implemented and verified.

---

## Unverified Items

- None. Every Package C assertion and verification method was independently run and confirmed.

---

## Part 2: Adversarial Review & Stress Testing

## Challenge Summary

**Overall risk assessment**: **LOW**

Adversarial analysis probed failure modes across memory leakage, buffer overflows, process orphans, concurrent revision invalidation, and unsupported cryptographic keyrings. All defenses held securely and failed closed without UI blocking or data leakage.

---

## Challenges

### [Low] Challenge 1: Memory Residuals of Decrypted Credentials
- **Assumption Challenged**: Calling `clear-string` completely eliminates credentials from Emacs memory.
- **Attack Scenario**: Garbage collection or temporary string copies created by Lisp functions could leave residual copies in uncollected heap memory.
- **Blast Radius**: If an attacker inspects raw process core dumps, residual ephemeral memory chunks might contain old keys.
- **Mitigation Assessment**: `kargu-credential-scope-wipe` explicitly calls `(clear-string sec)` on the master string and sets the struct reference to `nil`. In Emacs Lisp, `clear-string` modifies the string byte vector in-place. Furthermore, summaries strictly omit credential scopes, preventing credentials from entering logging buffers or history lists. This matches the strongest memory zeroing guarantee achievable in GNU Emacs Lisp.
- **Status**: **Mitigated / Accepted**

### [Low] Challenge 2: Background Worker Output Overflow Attack
- **Assumption Challenged**: A compromised or malicious auth-source provider could output megabytes of data to cause OOM or block the Emacs event loop.
- **Attack Scenario**: Subprocess produces infinite stream of characters on stdout.
- **Blast Radius**: UI thread starvation or Emacs crash.
- **Mitigation Assessment**: `kargu-config-worker-resolve` installs a filter that tracks `bytes-received`. Once `bytes-received > kargu-config-worker-max-bytes` (64KB), it immediately calls `(delete-process p)`, cleans and erases the buffer, and finishes the task with `:auth-unavailable`.
- **Status**: **Defended & Verified**

### [Low] Challenge 3: Orphaned Worker Processes upon Task Cancellation
- **Assumption Challenged**: A hanging auth-source worker process might continue running in the background after the user stops the session.
- **Attack Scenario**: User requests a plan or model switch, discovery hangs on network, user cancels or closes Emacs buffer.
- **Blast Radius**: Lingering zombie processes consuming system resources.
- **Mitigation Assessment**: Task registration attaches an async cleanup handler: `(kargu-async-add-cleanup task (lambda () (when (and proc (process-live-p proc)) (interrupt-process proc) (delete-process proc)) ...))`. Adversarial test verified that cancelling the task immediately terminates the child process and frees buffers.
- **Status**: **Defended & Verified**

---

## Stress Test Results

1. **In-place memory zeroing test**:
   - Scenario: Allocate secret string, bind to scope, invoke `kargu-credential-scope-wipe`.
   - Expected: `(kargu-credential-scope-secret scope)` returns `nil`, and underlying string bytes no longer contain plaintext characters.
   - Result: **PASS** (`(string-search "adversarial" secret)` returns `nil`).

2. **64KB Buffer Overflow Boundary**:
   - Scenario: Subprocess generates data exceeding 65,536 bytes.
   - Expected: Filter intercepts excess, invokes `delete-process`, cleans buffer, delivers `:auth-unavailable`.
   - Result: **PASS** (process aborted and error delivered).

3. **Subprocess Pipe Real Resolution**:
   - Scenario: Real subprocess spawned with temporary netrc file.
   - Expected: `make-process` runs `-Q --batch`, passes only host in `argv`, returns `OK:<secret>`, wipes process buffer.
   - Result: **PASS** (`OK:test-secret-token-real` cleanly resolved, 0 credentials in `argv`).

4. **Task Cancellation & Process Cleanup**:
   - Scenario: Spawn worker task and immediately call `kargu-async-cancel`.
   - Expected: Task transitions to `:cancelled`, child process killed, no delivery.
   - Result: **PASS** (`(kargu-async-task-state task)` is `:cancelled`, delivered is `nil`).

---

## Integrity Check Verification

- **Hardcoded test outputs in source**: NONE.
- **Facade implementations without logic**: NONE.
- **Shortcuts bypassing real async worker**: NONE.
- **Fabricated verification logs**: NONE (independently reproduced and validated).
- **Self-certifying work**: NONE.

**Verdict**: **APPROVE**
