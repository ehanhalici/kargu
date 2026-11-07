# Project: Kargu Multi-Wave Parallel Architecture Transformation & Verification

## Architecture
- **Coordination Model**: Top-level Project Orchestrator delegating waves sequentially (Wave 0 -> Wave 5), with up to 3 parallel packages per wave.
- **Runtime Invariant**: Single-active-run invariant per Emacs application instance (ARCH-01/ARCH-12). Multi-agent parallelism during development does not alter Kargu's runtime execution model.
- **Context Ownership**: Application-level coordination using explicit `kargu-application` struct with unique session/run/request identifiers. Releasing or resetting a claim leaves unrelated applications/sessions completely untouched.
- **Adapter Modularity**: Feature adapters (LSP, Dape, Bash, Git, Diff, Search, Webfetch) must be cleanly pluggable and detachable without breaking offline core headless loop execution (ARCH-09). Missing adapters return typed `unavailable` states.
- **Fail-Closed Security & Integrity**: Provenance tracking, egress policy enforcement, and single-gate execution for all tools. Zero tolerance for test cheating or hardcoded mock bypasses.

## Feature Inventory
| # | Feature / Work Package | Description | Milestone | Source |
|---|------------------------|-------------|-----------|--------|
| 1 | Baseline Verification & Wave 0 Boundaries | Establish 8 core contract boundaries, expose public `kargu-file-current-revision`, add dual-application isolation fixture, write `architecture-contracts.md` | Wave 0 | parallel-plan §3 |
| 2 | Package A: Application, Coordinator & Budget | Explicit `kargu-application` handle, claim/transition/release, mode FSM, safe reset ordering, unified run budget accounting (`kargu/application/budget.el`, `KarguBudget.tla`) | Wave 1 | parallel-plan §4 / ARCH-01 |
| 3 | Package B: Owned Edit Service & Approval Identity | Explicit edit service context, frozen approval/transaction revision, Unified Diff / block / symbol unified pipeline, active cleanup, eliminate cross-module private calls (`KarguEdit.tla`) | Wave 1 | parallel-plan §4 / ARCH-04 |
| 4 | Package C: Async Credential Discovery & Connection Snapshot | Nonblocking credential worker, synthetic secret safety (CONFIG-01), immutable connection snapshot (provider, model, endpoint, revision, scope), (`KarguConnection.tla`) | Wave 1 | parallel-plan §4 / CONFIG-01 |
| 5 | Package D: Single Gate for Tool Registry & Execution | Composition-provided registry, async execution context, single approval gate, safe unload without leaking active runs (`KarguApproval.tla`, `KarguTools.tla`) | Wave 2 | parallel-plan §5 / MOD-02 |
| 6 | Package E: Bounded Transport & Circuit Breakers | Request handle, budget debit for all attempts/retries, bounded parser & drain for SSE/events, provider/connection scoped circuit breaker, TLS safety (`KarguCircuit.tla`, `KarguTransport.tla`) | Wave 2 | parallel-plan §5 / MOD-04 |
| 7 | Package F: Process/Job Ownership & Cancellation Lifecycle | Explicit session/project job ownership, tree cancellation, graceful close vs force kill, signal/EOF tracking, RISK-01 investigation harness (`KarguProcess.tla`) | Wave 2 | parallel-plan §5 / RISK-01 |
| 8 | Package G: Headless Loop & History Protocol Wall | Headless engine loop, single finish event, protocol wall for all requests, unified budget consumption for retries/heal/compact (`KarguLoop.tla`, `KarguProtocol.tla`, `KarguVerification.tla`) | Wave 3 | parallel-plan §6 / MOD-01 |
| 9 | Package H: Owned View, Selection, Catalog & Plan Services | Provider/model catalog service, owned selection, UI decoupled from data, async plan dispatcher, bounded render queue (`KarguSelection.tla`, `KarguPlan.tla`) | Wave 3 | parallel-plan §6 / ARCH-06 |
| 10 | Package I: Log Data Minimization & Bounded Retention | Metadata-only default log, structured redaction for secrets, owned logger handle, bounded retention cap on every write, zero leakage on error | Wave 3 | parallel-plan §6 / DEEP-06 |
| 11 | Package J: LSP Diagnostics, Capability & Coordinate Conversion | Typed diagnostic snapshot with checker/server/source revisions, exact end-exclusive coordinates, versioned pull validation for COMPAT-01 (`KarguDiagnostics.tla`) | Wave 4 | parallel-plan §7 / COMPAT-01 |
| 12 | Package K: Dape Debugger Adapter Boundary & Resource Cleanup | Dape private API isolation behind typed adapter port, owned connection lifecycle, async clean shutdown of launch/compile/watch/server resources (`KarguDebug*.tla`) | Wave 4 | parallel-plan §7 / ARCH-05 |
| 13 | Package L: Filesystem Writer Contracts & Data Lifecycle | Public file revision & snapshot API, concurrent writer serialization / conflict detection, persistence data lifetime & retention policy (`KarguRestore.tla`, `KarguWriter.tla`) | Wave 4 | parallel-plan §7 / DEEP-10 |
| 14 | Package M: Fake Agent Backend Port & Contract Suite | Pluggable backend adapter abstraction, execution owner interface, fake agent test fixture, identical event/approval/stop contract as native (`KarguBackend.tla`) | Wave 5 | parallel-plan §8 / MOD-08 |
| 15 | Package N: Provenance, Egress Policy & Structured Tool Trust | Untrusted data provenance labeling, programmatic egress gate, structured argv execution with `--`, canonical path boundary enforcement | Wave 5 | parallel-plan §8 / ARCH-02 |
| 16 | Package O: Test Lint Hygiene & Checkdoc Debt | Clean checkdoc warnings across 18 designated test files, preserve assertions and test fixture semantics, zero byte-compilation warnings | Wave 5 | parallel-plan §8 / TEST-01 |
| 17 | Final Acceptance Gate & Verification | 100% passing ERT test suite (953+ tests), zero byte-compile warnings with `byte-compile-error-on-warn t`, zero leftover `.elc` files, full TLC model checking pass, updated `todo.md` | Final | parallel-plan §9 |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M0 | Wave 0: Coordinator Boundaries & Fixtures | `kargu.el`, `kargu/core.el`, `kargu/contract/*.el`, `tests/test-helpers.el`, `tests/test-modules.el`, `architecture-contracts.md`, public `kargu-file-current-revision` in `kargu/files.el`, dual-app fixture | None | DONE |
| M1 | Wave 1: Core Ownership & Snapshot (A, B, C) | Package A (Application & Budget), Package B (Edit Service & Approval), Package C (Async Credential & Connection Snapshot) | M0 | DONE |
| M2 | Wave 2: Execution, Transport & Jobs (D, E, F) | Package D (Tool Execution Gate), Package E (Bounded Transport & Circuit), Package F (Process/Job Ownership & Lifecycle) | M1 | DONE |
| M3 | Wave 3: Headless Engine, UI Decoupling & Privacy (G, H, I) | Package G (Headless Loop & Budget), Package H (Catalog, Selection, View & Plan), Package I (Redaction & Bounded Log) | M2 | IN_PROGRESS |
| M4 | Wave 4: Detachable Adapters & Persistence (J, K, L) | Package J (LSP Diagnostics & Coordinates), Package K (Dape Adapter & Cleanup), Package L (Writer Contracts & Data Lifetime) | M3 | PLANNED |
| M5 | Wave 5: Backend Port, Egress & Lint Hygiene (M, N, O) | Package M (Fake Agent Backend Port), Package N (Provenance & Egress Policy), Package O (Test Checkdoc Hygiene) | M4 | PLANNED |
| M6 | Final Acceptance Gate | Full test suite verification (953+ tests), byte-compilation, TLC proofs, cleanup of `.elc`, `todo.md` update, final report | M5 | PLANNED |

## Interface Contracts
### 1. Application Contract
- Explicit `kargu-application` struct with `session-id`, `run-id`, `status`, and active `logical-request`.
- `kargu-application-claim`: claims application execution, enforces single-active-run invariant, rejects second concurrent claim.
- `kargu-application-release`: releases active claim; only releases matching claim.

### 2. Async Scope Contract
- Structured task tracking with owner, parent, deadline, and cancellation handle.
- Cancellation request, process exit, and terminal callback are strictly separated.

### 3. Edit Service Contract
- Explicit edit service context managing snapshot, review, change, and rollback tables.
- Captured document and policy revisions verified before applying changes.
- Unified result type for `applied`, `staged`, `conflict`, and `partial`.

### 4. Connection Snapshot Contract
- Immutable snapshot binding provider, model, endpoint, protocol capability, config revision, and credential scope.
- Secrets never exposed in argv, logs, or unredacted traces.

### 5. Tool Registry & Execution Contract
- Registry instance provided via composition.
- Single gate for validation, mode check, permission check, approval capture, execution, and output budget.

### 6. Budget Accounting Contract
- Single unified debit gate for normal requests, retries, compaction, and healing.
- Explicit request count and overall deadline tracking.

### 7. Events Contract
- Minimal run, session, request, call, and connection identities with immutable payloads.
- Clear separation between passive notification and control requests requiring response.

### 8. Result Contract
- Typed domain error codes and status outcomes extending `kargu/contract/result.el`.
- No parsing of error text strings to infer retry/success.

## Code Layout & Write Boundaries
- Strictly adhere to package allowlists per `parallel-plan.md`.
- Concurrent workers within each wave must NEVER write to the same file.
- Repository governance: NEVER modify or stage `skills.md`, `.gitignore`, or `.agents/`.
- No leftover `.elc` byte-compiled artifacts in the source repository.
