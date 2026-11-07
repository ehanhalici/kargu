# Forensic Audit Report

**Work Product**: Wave 2 Implementation (Packages D, E, and F)  
**Profile**: General Project  
**Integrity Mode**: Development (from `ORIGINAL_REQUEST.md`, line 8)  
**Auditor**: `auditor_wave2_1`  
**Date**: 2026-10-22  
**Verdict**: **CLEAN**

---

### Executive Summary

The Forensic Auditor conducted an independent, rigorous, and empirical forensic audit of Wave 2 deliverables covering **Package D** (Single gate for tool registry and execution), **Package E** (Bounded transport, circuit breakers, and run budget integration), and **Package F** (Process/job ownership and cancellation lifecycle).

The entire ERT test suite ran across all test suites with **1049 tests passed, 0 failures, and 0 errors** (44.42s runtime). All package-specific contract suites passed with 100% success rate:
- Package D: 62/62 tests passed (including 19 new unified gate contract tests).
- Package E: 68/68 tests passed (including 9 transport contract tests and 7 stream backpressure tests).
- Package F: 44/44 tests passed (including 6 job owner tests, 4 process stress tests, 5 session transport tests).

Forensic source code analysis confirmed that no tests were weakened, skipped, commented out, or bypassed with hardcoded mocks. All 1049 tests executed genuine assertions against authentic production implementations.

Formal TLA+/TLC model checking specifications (`TransportMC.tla`, `ApprovalMC.tla`, `ProcessMC.tla`) passed exhaustively with zero errors. Byte-compilation with `(setq byte-compile-error-on-warn t)` across all 30 modified and new Elisp files completed with zero warnings and zero errors, leaving zero leftover `.elc` files. Repository governance rules were strictly respected: `skills.md`, `.gitignore`, and `.agents/` outside `.agents/teamwork/` remain 100% untouched and unstaged.

---

### Phase Results Summary

| Check / Verification Area | Result | Details | Raw Metric / Evidence |
|---|---|---|---|
| **Phase 1: Repository Governance** | **PASS** | `skills.md`, `.gitignore`, and `.agents/` outside `.agents/teamwork/` are 100% untouched and unstaged. | `git diff` & `git status --porcelain` clean |
| **Phase 1: Stray Artifact Hygiene** | **PASS** | Zero `.elc` files anywhere in the repository; no pre-populated log or result files. | `find . -name "*.elc"` returned 0 files |
| **Phase 1: Test Assertion Integrity** | **PASS** | Zero tests skipped, zero assertions weakened or removed; all test changes are strictly additive. | Git diff inspected across all test files |
| **Phase 1: Facade & Dummy Detection** | **PASS** | Zero dummy returns, zero facade implementations, zero hardcoded return values matching test cases. | Ripgrep verified 0 added mocks/dummies |
| **Phase 1: Package D Gate & Approval** | **PASS** | Genuine 13-stage pipeline, atomic single-use approval claiming, deep-copied schemas, output budget debiting, secret redaction, and draining before unload. | Verified in `kargu/tools/execution.el`, `kargu/tools/registry.el`, `kargu/permission/execute.el` |
| **Phase 1: Package E Transport & Circuit** | **PASS** | Provider-scoped circuit breakers with failure isolation, run budget debited on normal/retry requests, typed error symbols eliminating string matching, and bounded stream buffers. | Verified in `kargu/api/circuit.el`, `kargu/api/http.el`, `kargu/api/retry.el`, `kargu/api/stream.el` |
| **Phase 1: Package F Process & Jobs** | **PASS** | Resolved RISK-01 via `(accept-process-output nil 0.02)` non-starvation loop and negative PGID `(- pgid)` kill. Project-root scoped job service and interactive session transport. | Verified in `kargu/tools/process.el`, `kargu/tools/bash/jobs.el`, `kargu/tools/process/session.el` |
| **Phase 2: Full ERT Test Suite** | **PASS** | Full suite execution: 1049 tests run, 1049 passed, 0 failures, 0 errors. | `Ran 1049 tests, 1049 results as expected, 0 unexpected` |
| **Phase 2: Package D Contract Tests** | **PASS** | 62 tests across execution gate, registry, and permissions pass cleanly. | `Ran 62 tests, 62 results as expected, 0 unexpected` |
| **Phase 2: Package E Contract Tests** | **PASS** | 68 tests across transport, circuit, parameters, stream pressure pass cleanly. | `Ran 68 tests, 68 results as expected, 0 unexpected` |
| **Phase 2: Package F Contract Tests** | **PASS** | 44 tests across process execution, job owner, stress, and session pass cleanly. | `Ran 44 tests, 44 results as expected, 0 unexpected` |
| **Phase 2: Byte-Compilation Hygiene** | **PASS** | All 30 modified/new files compiled under `(setq byte-compile-error-on-warn t)`. | 0 warnings, 0 errors |
| **Phase 2: Checkdoc Hygiene** | **PASS** | All modified/new production Elisp files checked with `checkdoc-current-buffer`. | 0 warnings, 0 errors |
| **Phase 2: Formal TLC Model Checking** | **PASS** | `TransportMC.tla` (693 states), `ApprovalMC.tla` (1536 states), and `ProcessMC.tla` (179 states) all passed with zero errors. | TLC finished without error across all models |

---

### Detailed Contractual Verification

#### 1. Package D: Single Gate for Tool Registry & Execution (MOD-02, ARCH-02, ARCH-03, ARCH-09, ARCH-15, ARCH-16, ARCH-17)

1. **Unified Execution Gate Pipeline (`kargu/tools/execution.el`)**:
   - `kargu-tool-execution-context` struct cleanly encapsulates `app`, `run-id`, `session-id`, `root`, `mode`, `budget-scope`, and `policy-revision`.
   - `kargu-tool-approval` enforces single-use captured authority:
     - Token binds `root`, `tool-name`, deterministic `args-hash` (SHA-256), `policy-revision`, and `environment-hash`.
     - `kargu-tool-approval-claim` atomically toggles `(setf (kargu-tool-approval-claimed-p approval) t)` and returns `(kargu-err ... :approval-stale)` on any subsequent replay attempt.
     - Binding mismatches on tool name, root, arguments hash, or policy revision return `(kargu-err ... :approval-mismatch)`.
   - Gate stages verified:
     - Stage 1: Context & registry handle validation.
     - Stage 2: Canonical resolution and draining check (`kargu-tool-registry-draining-p`).
     - Stage 3: Mode permission check (`:modes` in policy).
     - Stage 4: Availability check (`:available-p` in policy).
     - Stage 5: Budget pre-check (`kargu-budget-live-p`).
     - Stage 6: Argument decoding & JSON object validation (`kargu-tool-execution-decode-arguments`).
     - Stage 7: Single-use approval verification & atomic claim.
     - Stage 8: Active task tracking via `kargu-async-start` and `kargu-tool-execution--track-task`.
     - Stage 9: Executor invocation (supporting both sync 1-arity and async 2-arity executors).
     - Stage 10: Secret redaction (`kargu-tool-execution-redact`) with regex patterns for Bearer tokens, OpenAI/Anthropic API keys (`sk-...`), and sensitive key-value pairs.
     - Stage 11: Output budget accounting via `kargu-budget-record-tokens`.
     - Stage 12: Output bounding, truncation, and project-owned archiving via `kargu--preserve-tool-output`.
     - Stage 13: Single terminal delivery barrier via `kargu-async-finish`.

2. **Draining and Unload Safety (`kargu/tools/registry.el`)**:
   - Added monotonic `revision` counter to `kargu-tool-registry` struct, incrementing on `register`, `alias`, `set-policy`, and `remove`.
   - Added `draining` table (`kargu-tool-registry-mark-draining`, `kargu-tool-registry-draining-p`, `kargu-tool-registry-clear-draining`).
   - Deep copy `(copy-tree parameters)` prevents external mutation of registered schemas.
   - `kargu-tool-execution-drain` marks tools draining, cancels or waits for active tasks to complete, and safely removes definitions.

3. **Approval Identity & Permission Invalidation (`kargu/permission/execute.el`, `kargu/permission.el`)**:
   - `kargu-permission-operation` includes `policy-revision`.
   - `kargu-permission--operation-valid-p` confirms that `policy-revision` has not changed between approval creation and execution.

4. **Public Compatibility Bridge (`kargu/api/tools.el`)**:
   - `kargu-execute-tool` delegates through the unified gate context and validation stages.
   - `kargu-unregister-tool` drains tasks cleanly before unregistering.

---

#### 2. Package E: Bounded Transport, Circuit Breakers, and Unified Budget (MOD-04, RISK-02, DEEP-09, DEEP-12, DEEP-14, ARCH-15, ARCH-16, ARCH-17)

1. **Provider-Scoped Circuit Breakers (`kargu/api/circuit.el`)**:
   - Encapsulated state in `kargu-circuit-breaker` struct.
   - `kargu-circuit--registry` isolates breaker state by provider key (e.g. `"openai"`, `"anthropic"`, `"provider-a"`, `"provider-b"`, `"default"`).
   - Tripping failures on Provider A leaves Provider B healthy and closed.
   - Bidirectional sync to legacy dynamic variables preserves compatibility for tests and default provider.
   - Scoped reset `(kargu-circuit-reset scope)` and global reset `(kargu-circuit-reset 'all)`.

2. **Unified Run Budget Accounting (`kargu/api/http.el`, `kargu/api/retry.el`, `kargu/api/client.el`)**:
   - `kargu--api-post` debits `:normal-request` for initial attempts and `:retry-attempt` for retries via `kargu-budget-debit`. If budget is exhausted, refuses request before network allocation with typed `:budget-exhausted` result.
   - `kargu--api-schedule-retry` checks budget availability before arming retry timer; halts and cancels if exhausted.
   - `kargu--record-usage` forwards prompt and completion token counts to `kargu-budget-record-tokens`, marking tokens unknown if absent rather than coercing to zero.

3. **Elimination of String Matching for Control Decisions (`kargu/api/retry.el`, ARCH-16)**:
   - Implemented `kargu-api-classify-error-code` mapping numeric status codes (429, 500, 502, 503, 504, 408, 400, 401, 403, 404), curl error numbers, and plz response envelopes to canonical domain symbols.
   - Retry decisions in `kargu--api-retryable-p` and `kargu--api-error-looks-retryable-p` operate strictly on typed error symbols and HTTP status codes.

4. **Bounded Stream Drains & Backpressure (`kargu/api/sse.el`, `kargu/api/stream.el`)**:
   - Enforced caps: `kargu-stream-max-incomplete-line-bytes` (64KB), `kargu-stream-max-raw-bytes` (4MB), `kargu-sse-max-event-bytes` (1MB), `kargu-stream-max-tool-calls` (64), `kargu-stream-max-tool-args-bytes` (512KB).
   - Duplicate finish events are discarded without state corruption.
   - Multibyte UTF-8 byte boundary preservation across buffer splits verified.

5. **Logical Request Ownership & Cross-Origin Security (`kargu/api/http.el`)**:
   - Logical request handle owns process, watchdog timer, and retry timer; cancels all idempotently.
   - `kargu-http--strip-auth-for-cross-origin` strips `Authorization` and `X-API-Key` on cross-origin redirects.

6. **Parameter Safety without Regexes (`kargu/api/parameters.el`, RISK-02)**:
   - Uses explicit `:reasoning-disallows-temperature` capability check instead of model name regexes.

---

#### 3. Package F: Process/Job Ownership & Cancellation Lifecycle (RISK-01, DEEP-05, DEEP-12, DEEP-15, ARCH-17, ARCH-18)

1. **Resolution of RISK-01 Anomaly (`kargu/tools/process.el`, `tests/test-process.el`)**:
   - **Defect A (Busy-Spin Starvation)**: Replaced `(accept-process-output process 0.02)` with `(accept-process-output nil 0.02)` across wait loops. Calling `accept-process-output` on terminated handles returned in ~12µs without sleeping, causing CPU starvation of pipe sentinels. Passing `nil` invokes `pselect` on all file descriptors, ensuring timely delivery.
   - **Defect B (Orphan Process Leakage)**: `kargu-process-cancel` captures `kargu-pgid` on process launch. On cancellation, even if the parent process has already died, signals `(- pid)` with `SIGINT` (graceful) and `SIGKILL` (force), reliably killing background subprocess groups on POSIX systems.
   - Empirically verified in `kargu-process-stress-child-group-reap-test`: detached background child (`sh -c "sleep 30 & echo $!; wait"`) reaped cleanly upon parent cancellation.

2. **Owned Job Lifecycle (`kargu/tools/bash/jobs.el`, ARCH-17, ARCH-18)**:
   - `kargu-job-service` struct encapsulates job counters, jobs hash table, active async process, and retention limit per canonical project root.
   - `kargu-job-service-for-project` isolates jobs across different projects.
   - `kargu-job-cancel` implements structured multi-phase cancellation (state -> SIGINT with grace -> SIGKILL -> clear handle).
   - Bounded retention pruning in `kargu-bash--prune-jobs` preserves active jobs and viewed buffers while pruning old completed records.

3. **Interactive Session Transport (`kargu/tools/process/session.el`, DEEP-05)**:
   - Lightweight interactive session transport with open stdin, streaming stdout filter, idle timeout bounding, internal buffer size capping, and clean EOF closure without PTY overhead.

---

### Empirical Verification Evidence

#### 1. Full ERT Test Suite Run
```bash
$ emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" -f ert-run-tests-batch-and-exit
...
Ran 1049 tests, 1049 results as expected, 0 unexpected (2026-10-22 04:03:36+0000, 44.425351 sec)
Exit code: 0
```

#### 2. Package-Specific ERT Test Results
- **Package D**:
  ```bash
  $ emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'tests/test-tool-execution-contract) (require 'tests/test-tool-registry) (require 'tests/test-permission-operation) (require 'tests/test-permission))" -f ert-run-tests-batch-and-exit
  Ran 62 tests, 62 results as expected, 0 unexpected (0.084730 sec)
  Exit code: 0
  ```
- **Package E**:
  ```bash
  $ emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'kargu) (require 'tests/test-transport-contract) (require 'tests/test-stream-pressure) (require 'tests/test-api) (require 'tests/test-stream) (require 'tests/test-parameters) (require 'tests/test-tool-calls))" -f ert-run-tests-batch-and-exit
  Ran 68 tests, 68 results as expected, 0 unexpected (0.078576 sec)
  Exit code: 0
  ```
- **Package F**:
  ```bash
  $ emacs -Q --batch -L . --eval "(progn (require 'package) (package-initialize) (require 'tests/test-process) (require 'tests/test-job-owner) (require 'tests/test-process-stress) (require 'tests/test-process-session))" -f ert-run-tests-batch-and-exit
  Ran 44 tests, 44 results as expected, 0 unexpected (1.541016 sec)
  Exit code: 0
  ```

#### 3. Formal Model Checking (TLA+/TLC)
- **Transport Contract (`TransportMC.tla`)**:
  ```
  1810 states generated, 693 distinct states found, 0 states left on queue.
  Model checking completed. No error has been found.
  Exit code: 0
  ```
- **Captured Approval (`ApprovalMC.tla`)**:
  ```
  8194 states generated, 1536 distinct states found, 0 states left on queue.
  Model checking completed. No error has been found.
  Exit code: 0
  ```
- **Process Capture (`ProcessMC.tla`)**:
  ```
  535 states generated, 179 distinct states found, 0 states left on queue.
  Model checking completed. No error has been found.
  Exit code: 0
  ```

#### 4. Byte-Compilation & Checkdoc Hygiene
- **Strict Byte-Compilation**:
  Compiled all 30 modified/new production and test files under `(setq byte-compile-error-on-warn t)`.
  Result: **0 warnings, 0 errors**.
- **Checkdoc**:
  Ran `checkdoc-current-buffer` across all modified and new production files.
  Result: **0 warnings, 0 errors**.
- **Leftover `.elc` Files**:
  `find . -name "*.elc"` returned 0 files.
- **Repository Governance**:
  `git diff skills.md .gitignore` -> empty
  `git diff --cached skills.md .gitignore` -> empty
  `git status --porcelain skills.md .gitignore` -> clean
  `.agents/` outside `.agents/teamwork/` (`.agents/rules/architecture_principles.md`) -> untouched

---

### Conclusion & Final Verdict

**Binary Verdict**: **CLEAN**

All requirements from `ORIGINAL_REQUEST.md` (R1 Wave 2 Packages D, E, F; R2; R3) and all forensic integrity criteria are satisfied. The implementations are authentic, zero facades or hardcoded bypasses exist, and all contracts have been mathematically and empirically verified.
