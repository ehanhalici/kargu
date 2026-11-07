# Kargu Architectural Transformation Specification Matrix
**Authoritative Sources**: `parallel-plan.md`, `todo.md`, `ORIGINAL_REQUEST.md`  
**Mining Agent**: `teamwork_preview_spec_miner_survey_2` (Survey Spec Miner)  
**Date**: 2026-10-21  
**Base Revision**: `988dd9685515e2008d0c80d3126f8a4deb402748`  
**Verification Baseline**: 942/942 ERT passing, clean byte-compilation (`byte-compile-error-on-warn t`), clean checkdoc on changed production/new tests, TLC exhaustive models clean.

---

## 1. Executive Summary & Architectural Overview

The Kargu architecture transformation is a multi-wave, parallel refactoring plan designed to decompose Kargu from a singleton-oriented, tightly coupled Emacs LLM assistant into a modular, headless-capable, pluggable, verified architecture.

### Architectural Tenets
1. **Single-Active-Run Invariant (ARCH-01, ARCH-12)**: At any given moment, an Emacs application instance allows at most ONE active agent execution run. Concurrency among development workers does NOT alter Kargu's runtime execution policy. State is owned by an explicit `application` context rather than global mutable variables.
2. **Pluggable & Detachable Adapters (ARCH-09)**: Feature modules (LSP, Dape debugger, search, bash, git, skills, webfetch, chat view, plan mode, diff engine, external agent backend) must be removable without breaking core headless operation. Missing adapters report explicit typed `unavailable` states rather than crashing or claiming false success. Missing security gates fail closed.
3. **Strict Wave Sequencing and Integration Gating**: Waves execute sequentially (Wave 0 through Wave 5). Within Waves 1 through 5, up to three workers execute in parallel in isolated worktrees. No worker advances to the next wave until the Coordinator verifies and commits the integrated baseline.
4. **Programmatic Verification & Formal Proofs**: Every wave must satisfy:
   - 100% ERT test pass rate (0 failures, 0 errors, 929+ / 942 tests).
   - Zero byte-compilation warnings with `byte-compile-error-on-warn t`.
   - Checkdoc compliance on all modified production and new test files.
   - Exhaustive TLC model checking on all affected formal specifications (`proof/run_tlc.sh`).
5. **Worktree & Repository Governance**:
   - `skills.md`, `.gitignore`, and `.agents/` are strictly protected and NEVER modified or staged.
   - Workers adhere strictly to file write allowlists.
   - Coordinator exclusively manages `todo.md` closures and composition root wiring.

---

## 2. Exhaustive Wave & Package Matrix (Waves 0–5, Packages A–O)

### Wave 0 — Coordinator Contract Foundation & Shared Boundaries

| Attribute | Specification |
|---|---|
| **Role** | Coordinator |
| **Objective** | Establish contract boundaries, canonical types, result types, assertion framework, test fixtures, and formal model baseline. Prevent ad-hoc cross-module dependencies. |
| **Associated TODOs** | ARCH-08 (Canonical Types), ARCH-10 (Domain Types), ARCH-11 (FSM Base), ARCH-12 (Context Base), ARCH-15 (Boundary Validation), ARCH-16 (Result Types), ARCH-18 (Test Contracts). |
| **Allowlisted Production Files** | `kargu.el`, `kargu/core.el`, `kargu/contract.el`, `kargu/contract/assert.el`, `kargu/contract/constants.el`, `kargu/contract/types.el`, `kargu/contract/result.el`, `kargu/contract/history.el`, `kargu/contract/selection.el`, `kargu/contract/file-window.el`, `kargu/json.el`, `kargu/core/custom.el`, `kargu/core/group.el`. |
| **Bootstrap File Edit** | `kargu/files.el` — Expose `kargu-file-current-revision` as public verified API before Wave 1 so Package B can eliminate private calls without creating an alternative disk reader. Write ownership of `kargu/files.el` transfers to Package L in Wave 4. |
| **Allowlisted New Files** | `architecture-contracts.md` (contract inventory). |
| **Allowlisted Test Files** | `tests/run-tests.el`, `tests/test-helpers.el`, `tests/test-modules.el`, `tests/test-laws.el`, `tests/test-integration.el`. |
| **Allowlisted Proof Files** | `proof/run_tlc.sh`, `proof/README.md`, `proof/KarguState.tla`, `proof/KarguContract.tla`, `proof/MC.tla`, `proof/MC.cfg`. |
| **Documentation Files** | `README.md`, `todo.md`, `parallel-plan.md`. |
| **Target Contracts Fixed** | 1. **Application**: Explicit `application` handle + session/run/request IDs. Claim first, view notification after; release releases only identical claim. UI command gets handle from composition; lower services do not look up singletons.<br>2. **Async Scope**: Owner/parent/task, deadline, and cancel/close. Cancellation request, process exit, and terminal delivery are distinct events; early completion cannot bypass setup barrier.<br>3. **Edit**: Explicit edit service; source revision and config/policy revision; block/symbol/Unified Diff converge on same transaction outcome (`applied`, `staged`, `conflict`, `partial/unknown`).<br>4. **Connection**: Provider/model/endpoint/format/config-capability revision snapshot. Credential bound strictly to this snapshot. Secrets excluded from argv/log/session.<br>5. **Tool**: Registry + execution context + args + completion callback → cancel handle. Unified gate for alias and direct calls.<br>6. **Budget**: Single total request/deadline/token debit gate per run. Regular requests, retries, healing, compaction share debit gate. Unknown usage is never coerced to `0`.<br>7. **Events**: Minimal run/session/request/call/connection ID; immutable payload; passive observer vs replying control request separated.<br>8. **Results**: Canonical domain error codes and effect status on `contract/result.el`. No text parsing to decide retry/success. |
| **Invariants & Acceptance** | - Two isolated application fixtures cannot mutate each other.<br>- Second run on the same application context is rejected.<br>- Public contracts load cleanly when optional modules are physically omitted.<br>- Pure definition inventory does not substitute for code guarantee. |
| **Prerequisites** | Base commit `988dd9685515e2008d0c80d3126f8a4deb402748`. |

---

### Wave 1 — Foundation: Application Context, Edit Service, Async Credential Discovery

#### Package A: Explicit Application / Async Ownership & Shared Budget Foundation
| Attribute | Specification |
|---|---|
| **Assigned Worker** | Worker 1 |
| **Package Focus** | Application context lifecycle, claim/transition/release state machine, async task ownership, session epoch isolation, and core run budget. |
| **Associated TODOs** | ARCH-01 (Session & Run Coordination), ARCH-11 (FSM Transitions), ARCH-12 (No Global Mutable State), ARCH-16 (Named Results), ARCH-17 (Resource Ownership), MOD-05 (Ordered Reset), MOD-07 (Runtime Context), DEEP-09 (Unified Budget Accounting Base). |
| **Allowlisted Production Files** | `kargu/application/coordinator.el`, `kargu/application/mode.el`, `kargu/application/reset.el`, `kargu/core/session.el`, `kargu/async.el`, `kargu/state.el`, `kargu/state/store.el`, `kargu/state/selectors.el`, `kargu/state/transitions.el`, `kargu/state/hooks.el`. |
| **Allowlisted New Files** | `kargu/application/budget.el`. |
| **Allowlisted Test Files** | `tests/test-state.el`, `tests/test-async.el`, `tests/test-mode-ownership.el`. |
| **Allowlisted New Test Files** | `tests/test-application-context.el`, `tests/test-run-budget.el`. |
| **Allowlisted Proof Files** | `proof/KarguMode.tla`, `proof/ModeMC.tla`, `proof/ModeMC.cfg`. |
| **Allowlisted New Proof Files** | `proof/KarguBudget.tla`, `proof/BudgetMC.tla`, `proof/BudgetMC.cfg`. |
| **Required Invariants & Rules** | - Transform coordinator from global-reading store to handle-accepting claim/transition/release manager.<br>- Separate session identity/epoch from application claim.<br>- Maintain ordered reset: foreign run/request/circuit or session counters must not be wiped when an unrelated session resets.<br>- Async scope takes explicit owner/parent; legacy wrapper confined to composition boundary.<br>- Pure budget record: exact request count and deadline; token/cost can carry `unknown`. Single-compaction default preserved.<br>- Do NOT blindly delete legacy bridge variables until all consumers are migrated. Supply coordinator with exact remaining consumer list. Final bridge deletion belongs to coordinator post-Wave 5. |
| **Acceptance Criteria** | 2 applications + 2 sessions; double claim on same app rejected; early/duplicate callback handled; reset/close/reentrant listener; foreign app's timer/process preserved; subtasks cannot reset parent budget. `KarguMode` and `KarguBudget` pass exhaustive TLC model checking. |
| **Commit Sequence** | 1. Context / claim → 2. Async / reset transitions → 3. Budget core. |
| **Dependencies** | Wave 0 contracts. |

#### Package B: Single-Owned Edit Service & Approval Identity
| Attribute | Specification |
|---|---|
| **Assigned Worker** | Worker 2 |
| **Package Focus** | Explicit edit-service record, frozen approval/review transaction, isolated Git apply engine, unified diff pipeline. |
| **Associated TODOs** | ARCH-03 (Captured Continuation Approval), ARCH-04 (Unified Edit Pipeline), ARCH-08 (Typed Edit Outcome), ARCH-10 (Domain Edit Types), ARCH-15 (Edit Boundary Validation), ARCH-17 (Transaction Cleanup), MOD-07 (Edit Context); explicit transaction evidence for DEEP-10 (Multi-Writer), DEEP-11 (Crash Recovery), DEEP-15 (Data Lifecycle). |
| **Allowlisted Production Files** | `kargu/edit.el`, `kargu/tools/diff.el`, `kargu/tools/diff/stage.el`, `kargu/tools/diff/review.el`, `kargu/tools/diff/track.el`. |
| **Allowlisted New Files** | `kargu/tools/diff/context.el`. |
| **Allowlisted Test Files** | `tests/test-patch.el`, `tests/test-edit-transaction.el`. |
| **Allowlisted New Test Files** | `tests/test-edit-service.el`. |
| **Allowlisted Proof Files** | `proof/KarguEdit.tla`, `proof/EditMC.tla`, `proof/EditMC.cfg`. |
| **Allowlisted New Proof Files** | None (updates existing edit model). |
| **Required Invariants & Rules** | - Move snapshot/change/review tables, pending callbacks, and temp resources into explicit `kargu-edit-service` record.<br>- Transaction plan captures source revision, session/run/app revision, and review/auto-save/policy revision.<br>- After waiting for approval, re-validate document and permissions; new mode/config must not inherit stale approval.<br>- Single outcome captures save-hook results, write failures, and rollback conflicts. Observer Stop/reset halts subsequent batch files.<br>- Keep isolated Git apply guarantee; never touch user's working index (`git apply --cached` forbidden). Keep scratch/source size limits.<br>- Service close/unload terminates only own review/process/timer/temp assets. No cross-service path collisions.<br>- Do not secretly add crash journal or OS locks (coordinated with Package L in Wave 4). |
| **Acceptance Criteria** | 13 existing edit regressions pass; two services on same/different path; config/session alteration during approval; active review/process close; staged index fixture untouched; dirty/narrowed/CRLF/Unicode buffers; final save error and foreign writer handling; single callback; zero resource leak. Updated `KarguEdit` passes exhaustive TLC. |
| **Commit Sequence** | 1. Record ownership → 2. Frozen approval / transaction → 3. Active close and budgets. |
| **Dependencies** | Wave 0 contracts; `kargu-file-current-revision` bootstrap. |

#### Package C: Real Async Credential / Config Discovery & Connection Snapshot
| Attribute | Specification |
|---|---|
| **Assigned Worker** | Worker 3 |
| **Package Focus** | Eliminating synchronous `auth-source` stalls (CONFIG-01), cancellable background secret resolver, immutable connection snapshot. |
| **Associated TODOs** | CONFIG-01 (Async Credential Boundary), ARCH-15 (Config Validation), ARCH-19 (Config Evolution), DEEP-14 (Connection Trust Snapshot); remaining I/O boundary from MOD-03. |
| **Allowlisted Production Files** | `kargu/config.el`, `kargu/config/key.el`, `kargu/config/schema.el`, `kargu/config/toml.el`, `kargu/providers/registry.el`. |
| **Allowlisted New Files** | `kargu/config/connection.el`, `kargu/config/worker.el`. |
| **Allowlisted Test Files** | `tests/test-config.el`, `tests/test-providers.el`. |
| **Allowlisted New Test Files** | `tests/test-connection-snapshot.el`. |
| **Allowlisted Proof Files** | None. |
| **Allowlisted New Proof Files** | `proof/KarguConnection.tla`, `proof/ConnectionMC.tla`, `proof/ConnectionMC.cfg`. |
| **Required Invariants & Rules** | - Lock CONFIG-01 with synthetic callable secret and slow/remote source fixture.<br>- NEVER invoke `auth-source-search` or callable `:secret` synchronously in UI thread or during discovery. Memory/direct/keyless paths return immediately; unsupported interactive/encrypted backends return explicit `unavailable`.<br>- Move disk resolution to cancellable worker/adapter. Never place secrets in command line argv. Auth unlock cannot be faked via timers.<br>- Pure config parsing/migration; publish config only after whole is verified.<br>- Bind provider, model, endpoint, protocol, config revision, and credential scope into single immutable connection snapshot.<br>- Retain same snapshot across retries. Deliver redacted immutable connection snapshot to Package E. Secret storage/cleanup aligns with L and I. |
| **Acceptance Criteria** | Priority order and keyless preserved; `off`/`none`/`inherit` operational; callable secret never runs on UI thread; encrypted backend safely returns `unavailable`; endpoint/key changes, wrong owner, early/double results, and process cleanup verified. Zero secret leaks to wrong host/argv/log. `KarguConnection` passes exhaustive TLC. |
| **Commit Sequence** | 1. Side-effect-free discovery → 2. Owned resolver → 3. Revision-bound connection. |
| **Dependencies** | Wave 0 contracts. |

#### Wave 1 Integration Gate (Coordinator)
- Verify Packages A, B, C worktrees merge cleanly without cross-boundary conflicts.
- Three ports (Application/Budget, Edit Service, Connection Snapshot) operate independently.
- Full ERT test suite passes (0 failures, 0 errors).
- Clean byte-compilation with `byte-compile-error-on-warn t` on all modified/new files.
- Clean checkdoc on all modified production and new test files.
- `proof/run_tlc.sh` passes for `KarguMode`, `KarguBudget`, `KarguEdit`, and `KarguConnection`.

---

### Wave 2 — Execution & Transport: Tool Gate, Bounded Transport, Process Lifecycle

#### Package D: Single Gate for Registry, Permission, and Tool Execution
| Attribute | Specification |
|---|---|
| **Assigned Worker** | Worker 1 |
| **Package Focus** | Unified execution gate, single-use captured approval, async tool executor, dynamic unregister/drain lifecycle. |
| **Associated TODOs** | MOD-02 (Tool SPI & Execution Gate), ARCH-02 (Command Policy & Argv), ARCH-03 (Captured Continuation), ARCH-09 (Pluggable Tools), ARCH-15 (Tool Input/Output Validation), ARCH-16 (Tool Error Results), ARCH-17 (Tool Resource Ownership), ARCH-19 (Tool Schema Evolution). |
| **Allowlisted Production Files** | `kargu/api/tools.el`, `kargu/tools/registry.el`, `kargu/permission.el`, `kargu/permission/guards.el`, `kargu/permission/policy.el`, `kargu/permission/bash.el`, `kargu/permission/execute.el`, `kargu/confirm.el`. |
| **Allowlisted New Files** | `kargu/tools/execution.el`. |
| **Allowlisted Test Files** | `tests/test-tool-registry.el`, `tests/test-permission.el`, `tests/test-permission-operation.el`. |
| **Allowlisted New Test Files** | `tests/test-tool-execution-contract.el`. |
| **Allowlisted Proof Files** | `proof/KarguApproval.tla`, `proof/ApprovalMC.tla`, `proof/ApprovalMC.cfg`, `proof/KarguTools.tla`. |
| **Allowlisted New Proof Files** | None (updates existing approval and tools models). |
| **Required Invariants & Rules** | - Registry instance provided via composition; tool definition/alias/revision separated from mutable pending execution.<br>- Unregister/disable must drain or cancel running tasks before unloading module code.<br>- Context-bearing async executor; legacy synchronous handler becomes boundary adapter only.<br>- Unified gate enforces: mode, schema validation, availability, alias/direct dispatch, output budget, redaction, terminal delivery.<br>- Captured approval is strictly single-use, bound to environment, root directory, config revision, and capability. Never re-introduce replay or preapproved store.<br>- Argv is not a sandbox; if OS isolation is unavailable, report explicit protection level.<br>- Feature adapters (LSP, Dape, bash, git) retain registration hooks in their own packages; D provides the execution contract. |
| **Acceptance Criteria** | Fake and real controlled handlers pass same contract suite; sync/async/early/double/late completion handled; readonly alias cannot bypass permissions; missing confirmation results in safe rejection; observer errors/reentrancy handled; pending work drained during unregister; snapshot schema protected against consumer mutation. `KarguApproval` and `KarguTools` pass exhaustive TLC. |
| **Commit Sequence** | 1. Owned registry → 2. Execution gate → 3. Approval / unload. |
| **Dependencies** | Wave 1 integrated baseline (Package A context, Package C connection). |

#### Package E: Independent, Bounded Transport Bound to Trusted Target
| Attribute | Specification |
|---|---|
| **Assigned Worker** | Worker 2 |
| **Package Focus** | Loop-independent HTTP/SSE transport, debit permission against shared budget, backpressure control, cross-origin credential guard, circuit breaker scoping. |
| **Associated TODOs** | MOD-04 (Independent Transport Port), RISK-02 (Sampling/Reasoning Conditional Compatibility), DEEP-09 (Unified Budget Debit), DEEP-12 (Transport Backpressure), DEEP-14 (Connection Trust & Credential Binding), ARCH-15 (Wire Boundary Validation), ARCH-16 (Typed Network Errors), ARCH-17 (Connection Resource Lifecycle), ARCH-19 (Wire Protocol Evolution). |
| **Allowlisted Production Files** | `kargu/api.el`, `kargu/api/client.el`, `kargu/api/http.el`, `kargu/api/request.el`, `kargu/api/retry.el`, `kargu/api/response.el`, `kargu/api/parameters.el`, `kargu/api/sse.el`, `kargu/api/stream.el`, `kargu/api/wire.el`, `kargu/api/tool-calls.el`, `kargu/api/cache.el`, `kargu/api/circuit.el`. |
| **Allowlisted New Files** | None. |
| **Allowlisted Test Files** | `tests/test-api.el`, `tests/test-stream.el`, `tests/test-tool-calls.el`, `tests/test-parameters.el`, `tests/test-cache.el`. |
| **Allowlisted New Test Files** | `tests/test-transport-contract.el`, `tests/test-stream-pressure.el`. |
| **Allowlisted Proof Files** | `proof/KarguCircuit.tla`. |
| **Allowlisted New Proof Files** | `proof/KarguTransport.tla`, `proof/TransportMC.tla`, `proof/TransportMC.cfg`. |
| **Required Invariants & Rules** | - Form requests strictly via A's context and C's connection snapshot; transport never modifies loop/UI/busy singletons.<br>- Single logical request handle owns all process, retry backoff timer, and stream watch timer resources.<br>- Retries use identical authorized endpoint/credential snapshot.<br>- Every attempt (initial + retries) must debit from Package A's run budget. If side-effect status is unknown, avoid blind retry.<br>- Circuit breaker is provider/connection scoped.<br>- Strict bounds on raw buffer, partial UTF-8 sequences, SSE events, and tool-call accumulation. Bounded drain yields to event loop; terminal/tool/approval events are never dropped.<br>- Typed transport-independent callback results; boundary classifies HTTP/wire errors.<br>- Cross-origin redirects: NEVER forward authorization headers to different origin/host. Disabling TLS or silent fallback forbidden.<br>- RISK-02: If no concrete versioned error fixture exists, leave TODO open with evidence. No inventing provider/model regexes. |
| **Acceptance Criteria** | Transport starts, streams, completes, and cancels without loading loop or chat; spawn/init/backoff/stall/EOF races handled; byte-by-byte emoji streaming; large events without newlines handled; fast producer / slow consumer backpressure; clock jump tolerance; duplicate finish blocked; budget cap enforced; zero credential leakage to wrong origin. `KarguCircuit` and `KarguTransport` pass exhaustive TLC. |
| **Commit Sequence** | 1. Explicit request/connection → 2. Budget/retry/circuit → 3. Bounded parser/drain → 4. Security fixtures. |
| **Dependencies** | Wave 1 integrated baseline (Package A budget, Package C connection). |

#### Package F: Process / Job Ownership & Stress Anomaly Isolation
| Attribute | Specification |
|---|---|
| **Assigned Worker** | Worker 3 |
| **Package Focus** | Resolving process cancellation / stderr closure anomaly (RISK-01), project/session owned job table, structured process termination. |
| **Associated TODOs** | RISK-01 (Process Cancellation / Stderr Anomaly), DEEP-05 (Job Lifecycle & Session Transport), DEEP-12 (Process Buffer Bounds), DEEP-15 (Job Data Retention), ARCH-17 (Process Lifecycle Ownership), ARCH-18 (Deterministic Process Fixtures). |
| **Allowlisted Production Files** | `kargu/tools/process.el`, `kargu/tools/bash.el`, `kargu/tools/bash/jobs.el`, `kargu/tools/toolchain.el`. |
| **Allowlisted New Files** | `kargu/tools/process/session.el` (conditional: permitted only if fake/local interactive stdin fixture proves batch port insufficient). |
| **Allowlisted Test Files** | `tests/test-process.el`, `tests/test-tools.el`. |
| **Allowlisted New Test Files** | `tests/test-job-owner.el`, `tests/test-process-stress.el`, and conditionally `tests/test-process-session.el`. |
| **Allowlisted Proof Files** | `proof/KarguProcess.tla`, `proof/ProcessMC.tla`, `proof/ProcessMC.cfg`. |
| **Allowlisted New Proof Files** | None (updates existing process model). |
| **Required Invariants & Rules** | - Instrument RISK-01 with process group signals, stdout/stderr EOF events, and redacted callback timings. Compare waiting solely on main process vs stepping event loop. Do NOT close with blind timeout increase or rerunning tests.<br>- Move job table, job counters, and foreground processes to explicit project/session service.<br>- Cancellation affects only owned process tree; distinguish graceful close, deadline expiry, and force kill (`SIGTERM` -> `SIGKILL`).<br>- Maintain startup barrier and stderr drain before delivering single terminal result.<br>- Batch stdin EOF behavior preserved; long-lived interactive sessions confined to minimal port. No sprawling PTY framework.<br>- Output and retention policies bounded and passed to Packages I and L. Secret echo and terminal escape sequences sanitized. |
| **Acceptance Criteria** | Real local process fixtures + deterministic event sequences; zero orphaned child processes; foreign jobs preserved across resets; silent/stdin-waiting/large stderr/early exit handled; stop-reset-close sequences clean; one cleanup failure does not prevent releasing other resources. If RISK-01 cannot be reproduced, document evidence and leave open. `KarguProcess` passes exhaustive TLC. |
| **Commit Sequence** | 1. Anomaly harness → 2. Owned job lifecycle → 3. Minimal session transport (if needed). |
| **Dependencies** | Wave 1 integrated baseline (Package A async scope). |

#### Wave 2 Integration Gate (Coordinator)
- Verify unified tool execution gate (D), bounded transport (E), and process ownership (F).
- Zero global state leakage; cancel handles cleanly terminate child processes and HTTP streams.
- Full ERT test suite passes (0 failures, 0 errors).
- Clean byte-compilation with `byte-compile-error-on-warn t` on all modified/new files.
- Clean checkdoc on all modified production and new test files.
- `proof/run_tlc.sh` passes for `KarguApproval`, `KarguTools`, `KarguCircuit`, `KarguTransport`, and `KarguProcess`.

---

### Wave 3 — Headless Engine, View Isolation, Privacy & Retention

#### Package G: Native Loop, History Protocol Wall, and Shared Budget Consumption
| Attribute | Specification |
|---|---|
| **Assigned Worker** | Worker 1 |
| **Package Focus** | Headless agent execution loop, history store with write-time invariants and protocol wall, unified budget debiting across retries/healing/compaction. |
| **Associated TODOs** | MOD-01 (Loop/UI Separation), ARCH-07 (History Protocol Wall & Invariants), ARCH-08 (Typed History Events), ARCH-11 (Loop FSM Transitions), ARCH-14 (Measured History Simplification), ARCH-16 (Loop Error Model), DEEP-01 (Diagnostics Baseline Integration), DEEP-02 (Compaction Policy Analysis), DEEP-04 (Prompt Prefix & Cache Savings), DEEP-09 (Unified Budget Consumption). |
| **Allowlisted Production Files** | `kargu/loop.el`, `kargu/loop/machine.el`, `kargu/loop/tools.el`, `kargu/loop/ui.el`, `kargu/loop/heal.el`, `kargu/loop/compact.el`, `kargu/history.el`, `kargu/history/store.el`, `kargu/history/protocol.el`, `kargu/history/repair.el`, `kargu/history/compact.el`, `kargu/prompt.el`, `kargu/prompt/default.txt`. |
| **Allowlisted New Files** | None. |
| **Allowlisted Test Files** | `tests/test-loop.el`, `tests/test-history.el`, `tests/test-history-store.el`, `tests/test-heal.el`, `tests/test-compact.el`, `tests/test-fake-agent.el`. |
| **Allowlisted New Test Files** | `tests/test-headless-events.el`, `tests/test-budget-composition.el`. |
| **Allowlisted Proof Files** | `proof/KarguLoop.tla`, `proof/KarguProtocol.tla`, `proof/KarguVerification.tla`, `proof/VerificationMC.tla`, `proof/VerificationMC.cfg`. |
| **Allowlisted New Proof Files** | None. |
| **Required Invariants & Rules** | - Connect engine exclusively to Package A's application/run context, Package D's execution gate, and Package E's transport port. Engine never looks for chat buffers or global UI pending lists.<br>- Event IDs derived from frozen context; single finish event, minimal payload, observer isolation.<br>- Unified budget: standard requests, retries, healing, compaction, and continuation all consume from same budget. Preserve single-compaction default; multi-stage compaction requires explicit user policy.<br>- History store maintains owned queue; every outbound request passes through the protocol wall.<br>- Measure next-turn token cost without re-encoding whole history. Simplify repair/compaction only with profiling evidence.<br>- Diagnostics baseline: if baseline unavailable, return `unknown`. Existing error is not treated as new regression.<br>- Prompt cache: preserve fixed prefix/guidance; never leak tool names when tools are disabled. Unknown usage does not invent fake cache metrics. |
| **Acceptance Criteria** | Multi-turn tool execution succeeds with fake model when chat/UI is completely absent; two views, view close, reentrant Stop handled cleanly; duplicate/orphan protocol events handled; stale compact responses rejected; total budget cap strictly enforced; unknown baseline does not report false clean or false regression. `KarguLoop`, `KarguProtocol`, and `KarguVerification` pass exhaustive TLC. |
| **Commit Sequence** | 1. Event / context binding → 2. Shared budget consumption → 3. Measured simplification for history/prompt. |
| **Dependencies** | Wave 2 integrated baseline (Package A context/budget, Package D execution gate, Package E transport). |

#### Package H: Owned View, Selection, Catalog, and Plan Services
| Attribute | Specification |
|---|---|
| **Assigned Worker** | Worker 2 |
| **Package Focus** | Decoupling chat UI, metadata catalog, selection, and plan dispatcher into owned services consuming A and G ports. |
| **Associated TODOs** | MOD-01 (Chat Decoupling), MOD-06 (Plan Dispatcher Port), MOD-07 (View Runtime Context), ARCH-01 (Chat Buffer Ownership), ARCH-06 (Chat Data vs View Layout), ARCH-09 (Pluggable View/Plan Adapters), ARCH-12 (Context-Driven UI), ARCH-19 (Catalog Evolution); domain ownership for ARCH-08. |
| **Allowlisted Production Files** | `kargu/chat.el`, `kargu/chat/routing.el`, `kargu/chat/render.el`, `kargu/chat/stream.el`, `kargu/chat/transcript.el`, `kargu/chat/prompt.el`, `kargu/chat/header.el`, `kargu/chat/select.el`, `kargu/chat/complete.el`, `kargu/chat/attach.el`, `kargu/chat/tune.el`, `kargu/chat/plan.el`, `kargu/selection.el`, `kargu/api/select.el`, `kargu/api/catalog.el`, `kargu/models/store.el`, `kargu/providers.el`, `kargu/providers/catalog.el`, `kargu/plan.el`, `kargu/plan/context.el`, `kargu/plan/store.el`, `kargu/plan/dispatch.el`, `kargu/plan/buffer.el`, `kargu/ui.el`, `kargu/ui/confirm.el`, `kargu/ui/notify.el`, `kargu/ui/transient.el`. |
| **Allowlisted New Files** | None. |
| **Allowlisted Test Files** | `tests/test-chat.el`, `tests/test-chat-state.el`, `tests/test-selection.el`, `tests/test-model-store.el`, `tests/test-metadata.el`, `tests/test-dynamic-models.el`, `tests/test-confirm.el`, `tests/test-plan.el`, `tests/test-plan-async.el`, `tests/test-attach.el`. |
| **Allowlisted New Test Files** | `tests/test-view-lifetime.el`. |
| **Allowlisted Proof Files** | `proof/KarguSelection.tla`, `proof/SelectionMC.tla`, `proof/SelectionMC.cfg`, `proof/KarguPlan.tla`, `proof/PlanMC.tla`, `proof/PlanMC.cfg`. |
| **Allowlisted New Proof Files** | None. |
| **Required Invariants & Rules** | - Delivered in staged commits: 1. Metadata/selection → 2. View/stream → 3. Plan/confirmation. Each stage passes relevant test suites.<br>- Move catalog generation, cache, and refusal tables to explicit provider/model service. Capability revision bound to C/E snapshot.<br>- UI consumes A (application) and G (loop) ports; transcript/draft/selection is not a parallel state store. Render queue bounded/coalesced; Stop button remains responsive.<br>- View/job-owned handles replace shared global pending confirmation lists; missing handle safely rejects.<br>- Plan dispatcher calls application port, not private native loop internals. Claim, approved revision, draft, and mode setup preserved. Buffer close cleans up subscriptions and owned model pickers.<br>- Do NOT engage in split-buffer or header-line layout experiments; preserve existing UX and text markers. |
| **Acceptance Criteria** | Two independent projects/views; background selection/delayed response does not steal window focus; draft text, point position, narrowing, and IME Unicode preserved during streaming; observer Stop works; confirmation close cleans up; model service isolated; async plan preparation and double approval prevention; headless operation works when view adapters absent. `KarguSelection` and `KarguPlan` pass exhaustive TLC. |
| **Commit Sequence** | 1. Metadata service → 2. Owned selection → 3. View stream / confirmation → 4. Plan adapter / close. |
| **Dependencies** | Wave 2 integrated baseline (Package A context, Package G loop). |

#### Package I: Log Data Minimization, Strict Retention & Redaction
| Attribute | Specification |
|---|---|
| **Assigned Worker** | Worker 3 |
| **Package Focus** | Data minimization, proactive redaction before writing, strict retention caps without leaking raw content, benchmark-driven optimization. |
| **Associated TODOs** | DEEP-06 (Log Privacy & Minimization), DEEP-07 (Log Retention & Performance), ARCH-14 (Simplest Measured Log Trimming), ARCH-15 (Boundary Redaction), ARCH-16 (Redaction Error Safety); log scope for DEEP-15 (Disk Lifecycle). |
| **Allowlisted Production Files** | `kargu/core/log.el`. |
| **Allowlisted New Files** | `kargu/core/redact.el`. |
| **Allowlisted Test Files** | None (no existing test files modified). |
| **Allowlisted New Test Files** | `tests/test-log-privacy.el`, `tests/test-log-retention.el`. |
| **Allowlisted Proof Files** | None. |
| **Allowlisted New Proof Files** | None. |
| **Required Invariants & Rules** | - Default to metadata-only logging; full wire dump is explicit opt-in with privacy warning.<br>- Mask credentials and sensitive structured fields at common write boundary before writing to log or temp buffer. On redactor failure, fail closed (never fallback to raw output).<br>- Synthetic secret fixtures for URLs, queries, upstream error echoes, and export. Acknowledge that regex cannot catch all secrets in free text; primary defense is data minimization.<br>- Logger and retention managed via explicit owned handle; no global runtime store. Retention enforces strict cap after every write. Test zero retention, single huge log entry, Unicode, narrowing, and undo.<br>- Measure trim calls, actual character deletions, allocation, and peak memory in benchmark. Add ring buffer only if benchmark proves necessity. Connect to C/F/L policies via narrow public port. |
| **Acceptance Criteria** | Keyless/nested/malformed JSON/truncated/error/export scenarios verified; zero content written when log is disabled; redactor error never exposes raw secrets; retention cap strictly observed on every write; two logger owners completely isolated. Zero leaked credentials in logs. |
| **Commit Sequence** | 1. Minimization / redaction → 2. Owned bounded retention → 3. Measured optimization (if needed). |
| **Dependencies** | Wave 2 integrated baseline (Package C connection, Package E transport, Package F process). |

#### Wave 3 Integration Gate (Coordinator)
- Verify headless loop operation (G), decoupled view/plan services (H), and log redaction/retention (I).
- Engine executes end-to-end tool loop without Emacs frame or chat UI buffer.
- Full ERT test suite passes (0 failures, 0 errors).
- Clean byte-compilation with `byte-compile-error-on-warn t` on all modified/new files.
- Clean checkdoc on all modified production and new test files.
- `proof/run_tlc.sh` passes for `KarguLoop`, `KarguProtocol`, `KarguVerification`, `KarguSelection`, and `KarguPlan`.

---

### Wave 4 — Adapters & Persistence: LSP, Debugger, Writer Contracts & Data Lifecycle

#### Package J: LSP Capability, Fresh Diagnostics, and Exact Coordinate Conversion
| Attribute | Specification |
|---|---|
| **Assigned Worker** | Worker 1 |
| **Package Focus** | Typed diagnostic snapshots with checker/server/source revisions, exact end-exclusive coordinate conversion, pull/versioned diagnostics (COMPAT-01). |
| **Associated TODOs** | COMPAT-01 (Alternative Verification for Unversioned Eglot Push), DEEP-01 (Fresh Diagnostic Baseline), DEEP-13 (Precise Coordinate Systems), ARCH-09 (Pluggable LSP Adapter), ARCH-15 (Diagnostic Boundary Validation), ARCH-17 (LSP Resource Cleanup), ARCH-19 (LSP Capability Evolution). |
| **Allowlisted Production Files** | `kargu/tools/lsp.el`, `kargu/tools/lsp/context.el`, `kargu/tools/lsp/diagnostics.el`, `kargu/tools/lsp/freshness.el`, `kargu/tools/lsp/settle.el`, `kargu/tools/lsp/symbols.el`, `kargu/tools/lsp/skeleton.el`, `kargu/tools/lsp/register.el`. |
| **Allowlisted New Files** | None. |
| **Allowlisted Test Files** | `tests/test-lsp.el`, `tests/test-lsp-settle.el`, `tests/test-lsp-project-diagnostics.el`. |
| **Allowlisted New Test Files** | `tests/test-lsp-contract.el`. |
| **Allowlisted Proof Files** | `proof/KarguDiagnostics.tla`, `proof/DiagnosticsMC.tla`, `proof/DiagnosticsMC.cfg`. |
| **Allowlisted New Proof Files** | None. |
| **Required Invariants & Rules** | - Provide typed port for diagnostic snapshots and range results containing checker, server, session, and source revisions.<br>- Pass exact end-exclusive character ranges to Package B's edit plan; line-only fallback forbidden. Encodings negotiated from LSP server capabilities (`utf-16`, `utf-8`, `utf-32`); if unsupported, return `unavailable` (never clamp or guess coordinates).<br>- Cache and request ownership managed by explicit LSP service. Server restart, stale requests, and outdated callbacks never bleed into new generations. Test cancellation, publication listeners, and unregister/unload.<br>- COMPAT-01: Support capability-based pull/versioned diagnostic verification only when server explicitly supports it; unversioned push cannot be treated as fresh verification proof. Missing capability returns `unavailable`.<br>- If project-wide freshness is unsupported, limit proof claim to edited file only. Never claim whole project is clean without proof. |
| **Acceptance Criteria** | Emoji/non-BMP/combining/Turkish/tab/CRLF/EOF/empty/long-line/narrowed buffers round-trip accurately; old request/tick/server isolation; stale/unversioned push rejection; unavailable baseline reporting; duplicate diagnostics deduplication; cross-file diagnostics effect fixtures. Coordinator connects G/heal consumer. `KarguDiagnostics` passes exhaustive TLC. |
| **Commit Sequence** | 1. Typed coordinates / snapshot → 2. Owned lifecycle → 3. Pull / project verification (if capability exists). |
| **Dependencies** | Wave 3 integrated baseline (Package B edit plan contract, Package G heal consumer). |

#### Package K: Debugger Adapter Boundary & Resource Cleanup Without Changing Dape
| Attribute | Specification |
|---|---|
| **Assigned Worker** | Worker 2 |
| **Package Focus** | Encapsulating Dape behind clean debugger port, version-dependent access via capability checks, nonblocking socket/timer FSM, active unload cleanup. |
| **Associated TODOs** | ARCH-05 (Debugger Port & Owned Lifecycle), ARCH-09 (Pluggable Debugger), ARCH-17 (Debugger Resource Cleanup), ARCH-19 (Dape Compatibility), DEEP-13 (Debugger Coordinate Mapping), DEEP-16 (Debugger System Composition); closed DAPE items serve as regression baseline. |
| **Allowlisted Production Files** | `kargu/tools/dape.el`, `kargu/tools/dape/commands.el`, `kargu/tools/dape/context.el`, `kargu/tools/dape/events.el`, `kargu/tools/dape/execution.el`, `kargu/tools/dape/launch.el`, `kargu/tools/dape/lifecycle.el`, `kargu/tools/dape/policy.el`, `kargu/tools/dape/preflight.el`, `kargu/tools/dape/readiness.el`, `kargu/tools/dape/register.el`, `kargu/tools/dape/render.el`, `kargu/tools/dape/selection.el`, `kargu/tools/dape/session.el`, `kargu/tools/dape/watch.el`, `kargu/tools/dape/workspace.el`. |
| **Allowlisted New Files** | `kargu/tools/dape/adapter.el` (conditional: permitted if minimal capability boundary for private Dape access is required). |
| **Allowlisted Test Files** | `tests/test-dape-commands.el`, `tests/test-dape-lifecycle.el`, `tests/test-dape-workspace.el`, `tests/test-dape-startup.el`, `tests/test-dape-watch.el`, `tests/test-dape-execution.el`, `tests/test-dape-selection.el`, `tests/test-dape-admission.el`, `tests/test-dape-readiness.el`, `tests/test-dape-compile.el`. |
| **Allowlisted New Test Files** | None. |
| **Allowlisted Proof Files** | `proof/KarguDebugClose.tla`, `proof/DebugCloseMC.tla`, `proof/DebugCloseMC.cfg`, `proof/KarguDebugStartup.tla`, `proof/DebugStartupMC.tla`, `proof/DebugStartupMC.cfg`, `proof/KarguDebugExecution.tla`, `proof/DebugExecutionMC.tla`, `proof/DebugExecutionMC.cfg`, `proof/KarguDebugWatch.tla`, `proof/DebugWatchMC.tla`, `proof/DebugWatchMC.cfg`, `proof/KarguDebugSelection.tla`, `proof/DebugSelectionMC.tla`, `proof/DebugSelectionMC.cfg`, `proof/KarguDebugReadiness.tla`, `proof/DebugReadinessMC.tla`, `proof/DebugReadinessMC.cfg`. |
| **Allowlisted New Proof Files** | None. |
| **Required Invariants & Rules** | - Enumerate public debugger port, private Dape calls, and capability matrix. Do NOT attempt to build a custom DAP client.<br>- Version-dependent access strictly isolated to adapter layer; unsupported capabilities return `unavailable`.<br>- Consume Package A's context/async and Package D's tool registry; eliminate global run lookups. Retain freshness guards across async transitions.<br>- Preserve commit `5c492b0` launch/source/foreign UI isolation using real local processes + fake DAP server. Specifically verify server restart, thread/frame ID reuse, child startup, source mapping, and coordinate revisions.<br>- Disable/unload terminates launch/compile/watch/child/server/stderr processes within async deadline; never disturbs foreign adapters or UI overlays. Advice runs only for owned resources and is cleanly removed on unload. |
| **Acceptance Criteria** | All existing Dape ERT tests pass (10 test suites); two adapters/projects, foreign UI, compile Stop, close during callback, duplicate sentinels, connection drops, active unload; timer, process, and listener counts return to baseline after unload. All 6 debugger TLA+ models pass exhaustive TLC. |
| **Commit Sequence** | 1. Capability boundary → 2. Explicit owner and simplification → 3. Active close / unload. |
| **Dependencies** | Wave 3 integrated baseline (Package A context, Package D tool gate). |

#### Package L: File / Persistence Writer Contracts, Conflict Resolution & Data Lifecycle
| Attribute | Specification |
|---|---|
| **Assigned Worker** | Worker 3 |
| **Package Focus** | Multi-writer conflict detection, atomic publication of session storage, explicit retention/recovery boundaries, safe data lifecycle. |
| **Associated TODOs** | DEEP-10 (Multiple Writers & Revision Clashes), DEEP-11 (Crash Recovery & Restart Reconciliation), DEEP-15 (Data Lifecycle & Storage Quotas), ARCH-15 (Storage Boundary Validation), ARCH-17 (Persistence Cleanup), ARCH-19 (Storage Schema Migration); durability boundary of ARCH-04. |
| **Allowlisted Production Files** | `kargu/files.el`, `kargu/files/async.el`, `kargu/files/worker.el`, `kargu/chat/session.el`, `kargu/chat/session/storage.el`, `kargu/chat/session/schema.el`, `kargu/chat/session/validate.el`, `kargu/chat/session/restore.el`. |
| **Allowlisted New Files** | `kargu/files/writer.el`, `kargu/chat/session/retention.el` (both permitted). |
| **Allowlisted Test Files** | `tests/test-file-window.el`, `tests/test-session.el`, `tests/test-session-storage.el`, `tests/test-session-validate.el`, `tests/test-session-restore.el`, `tests/test-session-routing.el`. |
| **Allowlisted New Test Files** | `tests/test-writer-conflicts.el`, `tests/test-data-lifetime.el`. |
| **Allowlisted Proof Files** | `proof/KarguRestore.tla`, `proof/RestoreMC.tla`, `proof/RestoreMC.cfg`. |
| **Allowlisted New Proof Files** | `proof/KarguWriter.tla`, `proof/WriterMC.tla`, `proof/WriterMC.cfg` (conditional: if new writer FSM added). |
| **Required Invariants & Rules** | - File revision / public snapshot API operates without cross-module private helpers. Restore/listing worker protocol bounded and versioned; metadata listing does not count as full session restore.<br>- Conflicting writers within the same Emacs application are serialized or rejected with conflict; never hold file locks while awaiting user approval.<br>- Test 2-process read-check-write races; declare that cooperative locks do not block external formatters or Git checkouts. Do not rewrite B's edit engine; common writer result is wired to B by coordinator.<br>- In-process rollback, restart reconciliation, and power-loss durability are separate guarantees. No automatic replay, resurrecting old approvals, or journaling full source/secrets. Clean only owned storage/temp files; never follow symlinks to delete foreign files.<br>- Storage mode permissions verified on supported platform. Normal delete is not represented as secure erase. |
| **Acceptance Criteria** | Two Emacs/processes writing same record; external file replacement/symlink detection; stale save/delete rejection; disk full / rename error handling; private file permissions (e.g. 0600); controlled process termination and restart; session restore does not trigger agent execution; pending approval does not survive restart; quota cleanup does not touch foreign/active data. `KarguRestore` (and `KarguWriter` if added) passes exhaustive TLC. |
| **Commit Sequence** | 1. Revision / writer conflict → 2. Persistence atomic publication → 3. Explicit retention / restart policy. |
| **Dependencies** | Wave 3 integrated baseline (Package B edit service, Package C connection). |

#### Wave 4 Integration Gate (Coordinator)
- Verify detachable LSP (J) and Dape (K) adapters, verified writer contracts and data lifecycle (L).
- Disabling LSP or Dape does not crash core editing or chat.
- Full ERT test suite passes (0 failures, 0 errors).
- Clean byte-compilation with `byte-compile-error-on-warn t` on all modified/new files.
- Clean checkdoc on all modified production and new test files.
- `proof/run_tlc.sh` passes for `KarguDiagnostics`, `KarguDebug*` (all 6 specs), `KarguRestore`, and `KarguWriter`.

---

### Wave 5 — Hybrid Architecture, Egress/Security Composition, Test Hygiene

#### Package M: Fake Agent Backend Port Without Writing External Integrations
| Attribute | Specification |
|---|---|
| **Assigned Worker** | Worker 1 |
| **Package Focus** | Execution-owner abstraction separating LLM completion transport from full tool-loop agent backends (MOD-08), fake backend contract suite. |
| **Associated TODOs** | MOD-08 (Hybrid Client Preparation), DEEP-05 (Backend Session Lifecycle), DEEP-16 (Backend Composition Correctness), ARCH-09 (Pluggable Backend Adapter), ARCH-16 (Backend Result Mapping), ARCH-19 (Backend Capability Negotiation). |
| **Allowlisted Production Files** | None (M does not edit existing production files). |
| **Allowlisted New Files** | `kargu/application/backend.el`, `kargu/backends/native.el`. |
| **Allowlisted Test Files** | None (M does not edit existing test files). |
| **Allowlisted New Test / Fixture Files** | `tests/test-backend-contract.el`, `tests/fixtures/fake-agent.el`. |
| **Allowlisted Proof Files** | None. |
| **Allowlisted New Proof Files** | `proof/KarguBackend.tla`, `proof/BackendMC.tla`, `proof/BackendMC.cfg`. |
| **Required Invariants & Rules** | - Place native loop (Package G) behind minimal execution-owner backend adapter. LLM transport (E) and full agent backend are distinct contracts.<br>- Support capability discovery, start, resume, event streaming, approval delegation, cancel, and session mapping; unsupported resume returns `unavailable`.<br>- At any time, exactly ONE execution owner manages a run. Two loops never manage the same files concurrently.<br>- Native adapter preserves existing confirmation, edit, and rollback gates.<br>- Fake agent fixture provides identical event, approval, Stop, and UI contracts without requiring external binaries or network.<br>- Prohibited: MCP/IPC/real CLI integrations, credential discovery, or binary downloads. Never represent external unverified modifications as having passed Kargu approval. |
| **Acceptance Criteria** | Native and fake backends pass identical contract suite; single active run invariant upheld; disconnect handling; duplicate/out-of-order event resilience; reset during approval; unsupported resume rejection; foreign session isolation; late events ignored after cancel; fake backend drives UI flow when LLM transport is absent. `KarguBackend` passes exhaustive TLC. |
| **Commit Sequence** | 1. Port / native adapter → 2. Fake contract and fault suite. (Real adapters deferred to subsequent plans). |
| **Dependencies** | Wave 4 integrated baseline (Package G loop, Package D tool gate). |

#### Package N: Composition of Context / Egress, Shell, and Endpoint Security
| Attribute | Specification |
|---|---|
| **Assigned Worker** | Worker 2 |
| **Package Focus** | Provenance tracking, programmatic egress policy, structured argv for tools, endpoint security composition. |
| **Associated TODOs** | ARCH-02 (Command & Argv Security), DEEP-08 (Context Trust Boundaries), DEEP-14 (Endpoint & Credential Trust Composition), DEEP-16 (Security Composition Correctness); allowed context boundary for MOD-08. |
| **Allowlisted Production Files** | `kargu/fs.el`, `kargu/tools/search.el`, `kargu/tools/git.el`, `kargu/tools/skill.el`, `kargu/tools/webfetch.el`, `kargu/net/address.el`, `kargu/net/resolve.el`, `kargu/tools/deps.el`. |
| **Allowlisted New Files** | `kargu/permission/egress.el`. |
| **Allowlisted Test Files** | `tests/test-security.el`, `tests/test-fs.el`, `tests/test-git.el`, `tests/test-webfetch.el`, `tests/test-address.el`, `tests/test-deps.el`. |
| **Allowlisted New Test Files** | `tests/test-egress-policy.el`. |
| **Allowlisted Proof Files** | None. |
| **Allowlisted New Proof Files** | None. |
| **Required Invariants & Rules** | - Separate project instructions, file contents, web responses, and tool results from trusted user policy. Prompt labeling is not security: permissions and egress are enforced at programmatic gates.<br>- Never attach entire process environment, secret keys, or out-of-scope files to model requests.<br>- Bind context sharing to provider/backend target and project scope using C's connection snapshot and D's permission gate. Symlink, out-of-root, and redirect boundaries strictly enforced.<br>- Structured tool invocation: enforce program + argv, `--` option terminator, option injection defense, hook/config blocking, executable/PATH verification, and canonical root validation.<br>- If OS sandbox capability is unavailable, report explicit protection level; no guessing wrappers.<br>- Test programmatic gate rejection of unauthorized actions, not model obedience to prompt text. |
| **Acceptance Criteria** | Synthetic prompt-injection payloads in files/tools rejected; secret context excluded from request payloads; wrong provider/origin blocked; symlink and option injection attacks thwarted; network and environment scope restricted; unauthorized executable changes rejected at gate. |
| **Commit Sequence** | 1. Provenance / egress → 2. Structured adapter trust → 3. System fault fixtures. |
| **Dependencies** | Wave 4 integrated baseline (Package C connection, Package D permission, Package E transport). |

#### Package O: Clean Up Real Lint Debt in Legacy Tests
| Attribute | Specification |
|---|---|
| **Assigned Worker** | Worker 3 |
| **Package Focus** | Eliminating genuine checkdoc warnings in 18 legacy test files without altering test semantics, assertions, or fixture data. |
| **Associated TODOs** | TEST-01 (Checkdoc Debt in Legacy ERT), ARCH-18 (Change Discipline). |
| **Allowlisted Production Files** | NONE (O never modifies production files). |
| **Allowlisted New Files** | NONE. |
| **Allowlisted Test Files (ONLY these 18 files)** | `tests/test-api.el`, `tests/test-async.el`, `tests/test-attach.el`, `tests/test-chat.el`, `tests/test-compact.el`, `tests/test-confirm.el`, `tests/test-contract.el`, `tests/test-dynamic-models.el`, `tests/test-fake-agent.el`, `tests/test-heal.el`, `tests/test-history.el`, `tests/test-languages.el`, `tests/test-loop.el`, `tests/test-lsp.el`, `tests/test-metadata.el`, `tests/test-permission.el`, `tests/test-session.el`, `tests/test-state.el`. |
| **Explicitly Excluded Test Files** | `tests/test-deps.el`, `tests/test-git.el`, `tests/test-security.el`, `tests/test-webfetch.el` (owned by Package N); `tests/test-integration.el` (owned by Coordinator). O reports lint issues in these files to N/Coordinator. |
| **Allowlisted Proof Files** | NONE. |
| **Required Invariants & Rules** | - Re-evaluate 23-file / 84-warning inventory on integrated baseline. Distinguish real header/docstring debt from fixture false-positives.<br>- Fix header sections (e.g. `;;; Code:`), docstring argument names, and unquoted symbols.<br>- NEVER alter synthetic error text, expected output strings, assertions, or test logic just to satisfy checkdoc.<br>- Package-wide checkdoc disabling (`checkdoc-force-docstrings-flag nil` or file-local suppressions) is strictly prohibited.<br>- Zero modifications to production code or test helper behaviors.<br>- Zero test deletions; report exact count of preserved tests. |
| **Acceptance Criteria** | Identical ERT test suite contracts; zero byte-compile warnings; genuine checkdoc debt reduced to zero or cataloged with documented fixture false-positives; zero loss of test count or test coverage. |
| **Commit Sequence** | 1. Headers → 2. Genuine docstring issues → 3. Fixture classification report. |
| **Dependencies** | Wave 4 integrated baseline. |

#### Wave 5 Integration Gate & Final Integrated Acceptance (Coordinator)
- Verify fake agent backend port (M), egress/security composition (N), and clean test linting (O).
- Run full integrated exclusion matrix: test that Kargu operates when optional adapters (LSP, Dape, search, bash, git, skills, webfetch) are omitted.
- Verify single-active-run invariant across all entry points (UI, headless, fake backend).
- Execute complete ERT test suite: 100% passing (0 failures, 0 errors, 929+ / 942 tests).
- Byte-compile all modified and new Elisp files with `(setq byte-compile-error-on-warn t)`: 0 warnings.
- Clean checkdoc on all modified production files and new test files.
- Clean `git diff --check`.
- Execute full TLC model checker suite (`proof/run_tlc.sh`) across all formal specifications:
  - `MC.tla` (KarguLoop, KarguProtocol, KarguCircuit, KarguTools, KarguState)
  - `RestoreMC.tla`, `ModeMC.tla`, `PlanMC.tla`, `ApprovalMC.tla`, `SelectionMC.tla`
  - `ProcessMC.tla`, `DiagnosticsMC.tla`, `DebugCloseMC.tla`, `DebugStartupMC.tla`
  - `DebugWatchMC.tla`, `DebugExecutionMC.tla`, `EditMC.tla`, `VerificationMC.tla`
  - `DebugSelectionMC.tla`, `DebugReadinessMC.tla`
  - New models: `BudgetMC.tla`, `ConnectionMC.tla`, `TransportMC.tla`, `BackendMC.tla` (and `WriterMC.tla` if created).
- Verify worktree integrity: `skills.md`, `.gitignore`, and `.agents/` remain completely untouched and unstaged.
- Final removal of deprecated global bridge variables (`kargu--loop-run`, `kargu--busy`, `kargu--current-process`, etc.) by coordinator after confirming zero consumers remain.
- Update `todo.md` with verified closures, leaving unresolved risks (RISK-01, RISK-02) and unchosen optional features open.
- Publish final integration report with commit hashes, modified files, removed legacy paths, and contract test results.

---

## 3. Cross-Cutting Invariants & Architectural Rules

### 1. Single-Active-Run Invariant (ARCH-01 / ARCH-12)
- **Invariant**: Within an Emacs OS process, at most ONE active agent execution run (`kargu-run`) may execute at any given time.
- **Enforcement**:
  - The runtime state is anchored in an explicit `kargu-application` struct, not in global variables.
  - Starting a run requires acquiring an exclusive claim on the application coordinator.
  - If a second run attempts to start while a run is active, the coordinator immediately rejects the request with an explicit `busy` or `already-active` error.
  - Releasing a claim requires presenting the exact claim token; foreign entities cannot release or overwrite an active run's claim.
  - The active run's mode is locked at claim time and cannot be altered mid-run.
  - Multiple chat buffers or sessions may exist concurrently, but they cannot execute agent loops simultaneously.
  - Global mutable singletons (`kargu--loop-run`, `kargu--busy`, `kargu--current-process`, `kargu-application--context`) are transitional bridges that are completely eliminated once all consumers migrate to explicit handles.

### 2. Pluggable & Detachable Adapters (ARCH-09)
- **Invariant**: Kargu features are modular adapters that plug into core ports via dependency inversion. Core contracts must never `require` or depend on concrete feature adapters.
- **Rules**:
  - Adapters include: LSP (`kargu/tools/lsp*`), Dape (`kargu/tools/dape*`), Bash/Jobs (`kargu/tools/bash*`), Git (`kargu/tools/git*`), Search (`kargu/tools/search*`), Skill (`kargu/tools/skill*`), WebFetch (`kargu/tools/webfetch*`), Chat UI (`kargu/chat*`), Plan Mode (`kargu/plan*`), Diff Engine (`kargu/tools/diff*`), Backend (`kargu/backends/*`).
  - If any optional adapter is missing, uninstalled, or disabled, core offline headless execution remains fully functional.
  - Missing adapters report typed `unavailable` outcomes rather than throwing errors or claiming success.
  - Security gates (permission guards, egress policies) fail closed: if a security adapter is absent, any unsafe operation (file modification, network egress, process execution) is safely rejected.
  - Active unload: When an adapter is unregistered or disabled, it must drain or cancel its running tasks, timers, and processes within an async deadline before unloading code.

### 3. Strict Wave Sequencing & Integration Gating
- **Sequence**: Wave 0 -> Wave 1 -> Wave 2 -> Wave 3 -> Wave 4 -> Wave 5.
- **Rules**:
  - Workers within a wave work in parallel in isolated branches/worktrees.
  - Waves are strictly sequential: no worker may start a task in Wave N+1 until Wave N has been fully integrated, verified, and committed by the Coordinator.
  - Workers must only write to their assigned package allowlisted files.
  - If a worker requires a public API change in another module, they must request it from the Coordinator; they may not edit files outside their allowlist.
  - Gate criteria: 100% ERT pass rate, zero byte-compile warnings with `byte-compile-error-on-warn t`, clean checkdoc on changed production and new tests, clean `git diff --check`, exhaustive TLC passes on all affected models.

### 4. Forbidden Actions & Worktree Governance
- **Strict Prohibitions**:
  - NEVER modify, stage, or commit `skills.md`.
  - NEVER modify, stage, or commit `.gitignore`.
  - NEVER modify, stage, or commit files under `.agents/`.
  - NEVER run `git add -A` or commit unstaged changes belonging to another agent or user.
  - NEVER push to remote repositories or merge to `master` without explicit user instruction.
  - NEVER use global mutable singletons or general event bus / DI containers.
  - NEVER silence checkdoc or byte-compile linters by deleting tests or altering test fixtures.

---

## 4. Comprehensive Features Discovered Table

| # | Category | Feature | Description | Inputs | Outputs | Error Behavior | Discovered Via |
|---|---|---|---|---|---|---|---|
| 1 | Wave 0 | Coordinator Contract Framework | Core type definitions, assertions, constants, and canonical result structs establishing modular boundaries | Elisp definitions in `kargu/contract/*.el` | Validated contract types and result structures | Signals error on contract assertion failure | `parallel-plan.md` §3 |
| 2 | Wave 0 | Public Revision Reader Bootstrap | Publicly exposes `kargu-file-current-revision` to eliminate private cross-package calls from Package B | Buffer or file path | Integer or string revision identifier | Returns `nil` or error if unreadable | `parallel-plan.md` §3 |
| 3 | Wave 1 / A | Owned Application Context | Explicit `kargu-application` struct managing claim, transition, and release lifecycle per Emacs instance | Application handle, session handle, run request | Claim token, status record | Rejects double claims; rejects invalid claim release | `parallel-plan.md` §4 (A), `todo.md` ARCH-01/12 |
| 4 | Wave 1 / A | Async Task Ownership & Scope | Structured async cancellation tree binding tasks to owners with deadlines | Parent owner, task callback, deadline | Async task handle | Cancel triggers teardown; early completion cannot skip setup | `parallel-plan.md` §4 (A), `todo.md` ARCH-17 |
| 5 | Wave 1 / A | Run Budget Core | Unified accounting of request counts, deadlines, and token limits per run | Debit request (count, tokens, timeout) | Approved debit or budget exhaustion | Rejects requests exceeding budget; unknown usage handled safely | `parallel-plan.md` §4 (A), `todo.md` DEEP-09 |
| 6 | Wave 1 / B | Single-Owned Edit Service | Encapsulated edit transaction service managing pre-state snapshots, review tables, and commit hooks | Edit plan (block, symbol, or patch), buffer/path | Transaction outcome (`applied`, `staged`, `conflict`, `partial`) | Rejects stale revisions; handles rollback conflicts | `parallel-plan.md` §4 (B), `todo.md` ARCH-04 |
| 7 | Wave 1 / B | Frozen Approval & Transaction Plan | Captures source revision, session/run epoch, and policy revision into an immutable review plan | Document snapshot, proposed changes | Typed review token | Re-validates upon approval; invalidates on config change | `parallel-plan.md` §4 (B), `todo.md` ARCH-03 |
| 8 | Wave 1 / B | Isolated Unified Diff Engine | Applies unified diffs in temporary isolated directory using `git apply` without touching user index | Patch string, target files | Staged changes for review | Rejects malformed patches, rejects out-of-scope targets | `parallel-plan.md` §4 (B), `todo.md` ARCH-04 |
| 9 | Wave 1 / C | Nonblocking Credential Discovery | Resolves API keys and credentials in cancellable worker process without blocking Emacs UI thread | Provider name, config scope | Redacted credential token or `unavailable` | Timeout/cancel terminates worker; no plaintext leaks | `parallel-plan.md` §4 (C), `todo.md` CONFIG-01 |
| 10 | Wave 1 / C | Immutable Connection Snapshot | Bundles provider, model, endpoint, protocol version, and credential scope into a single immutable record | Config settings, credential token | Connection snapshot handle | Fails if required endpoint is invalid or TLS unverifiable | `parallel-plan.md` §4 (C), `todo.md` DEEP-14 |
| 11 | Wave 2 / D | Unified Tool Execution Gate | Single gate for tool registry, schema validation, permissions, budget checking, and execution | Tool name, arguments, execution context | Typed execution result or async handle | Denies unregistered, unauthorized, or budget-exceeded calls | `parallel-plan.md` §5 (D), `todo.md` MOD-02 |
| 12 | Wave 2 / D | Single-Use Captured Approval | Bound continuation for tool execution tied to root, environment, and config revision | User confirmation response, approval token | One-time execution authorization | Replay attempts rejected; invalidated on environment change | `parallel-plan.md` §5 (D), `todo.md` ARCH-03 |
| 13 | Wave 2 / D | Dynamic Tool Unload / Drain | Safely drains running tasks and cancels resources when a tool is disabled or unregistered | Unregister request, tool identifier | Unload confirmation | Drains tasks before unbinding code; prevents dangling callbacks | `parallel-plan.md` §5 (D), `todo.md` ARCH-09 |
| 14 | Wave 2 / E | Loop-Independent HTTP Transport | Asynchronous HTTP/SSE transport decoupled from agent loop and UI state | Request parameters, connection snapshot | SSE event stream, response record | Circuit opens on failure; timeouts cleanly cancel requests | `parallel-plan.md` §5 (E), `todo.md` MOD-04 |
| 15 | Wave 2 / E | Transport Backpressure & Bounds | Enforces buffer limits on SSE events, incomplete lines, and tool-call accumulations | Inbound byte stream | Bounded parsed chunks | Raises terminal error on limit breach; drains event loop | `parallel-plan.md` §5 (E), `todo.md` DEEP-12 |
| 16 | Wave 2 / E | Cross-Origin Credential Guard | Strict check preventing authorization headers from following HTTP redirects to different origins | Redirect URI, request headers | Filtered headers | Strips sensitive headers on cross-origin redirects | `parallel-plan.md` §5 (E), `todo.md` DEEP-14 |
| 17 | Wave 2 / F | Process & Job Lifecycle Service | Explicit service owning child process tables, signal groups, and bounded tail outputs | Command, argv, working directory, timeout | Job handle, stdout/stderr stream | Escalates from graceful SIGTERM to SIGKILL on timeout | `parallel-plan.md` §5 (F), `todo.md` DEEP-05 |
| 18 | Wave 2 / F | Process Stress Anomaly Isolation | Deterministic harness to isolate process cancellation and stderr drain timing anomalies | Process stress test suite, concurrency parameters | Execution trace and timing logs | Identifies root cause of stderr EOF races (RISK-01) | `parallel-plan.md` §5 (F), `todo.md` RISK-01 |
| 19 | Wave 3 / G | Headless Agent Execution Loop | Turn-based agent execution machine operating purely on application and transport ports | Context handle, initial prompt | Terminal execution report | Handles loop errors, budget exhaustion, or user Stop | `parallel-plan.md` §6 (G), `todo.md` MOD-01 |
| 20 | Wave 3 / G | History Store & Protocol Wall | Queue maintaining write-time invariants and validating all messages before wire transmission | User/assistant messages, tool results | Validated wire-ready payload | Sanitizes malformed tool call pairs; repairs broken turns | `parallel-plan.md` §6 (G), `todo.md` ARCH-07 |
| 21 | Wave 3 / G | Unified Debit Accounting | Shared debiting across loop turns, retries, healing attempts, and compaction | Debit event, turn type | Updated budget status | Halts loop if overall budget is exhausted | `parallel-plan.md` §6 (G), `todo.md` DEEP-09 |
| 22 | Wave 3 / H | Decoupled View & Stream Service | Renders streaming agent transcripts into Emacs buffers using coalesced rendering queues | Stream chunks, view handle | Updated buffer display | Preserves draft, point position, and user narrowing | `parallel-plan.md` §6 (H), `todo.md` ARCH-06 |
| 23 | Wave 3 / H | Owned Metadata & Catalog Service | Caches provider models, dynamic capabilities, and refusal metadata per connection snapshot | Provider connection snapshot | Model catalog, capability descriptor | Differentiates between disabled provider vs empty catalog | `parallel-plan.md` §6 (H), `todo.md` ARCH-19 |
| 24 | Wave 3 / H | Plan Dispatcher Port | Manages preparation, user editing, and dispatching of structured task plans | Task prompt, plan context | Executable plan record | Rejects concurrent plan claims; protects user edits | `parallel-plan.md` §6 (H), `todo.md` MOD-06 |
| 25 | Wave 3 / I | Boundary Log Redaction | Proactive redaction of credentials, bearer tokens, and structured secrets before logging | Log message, metadata | Redacted log entry | Fails closed on redactor error (never writes raw text) | `parallel-plan.md` §6 (I), `todo.md` DEEP-06 |
| 26 | Wave 3 / I | Strict Retention Cap | Enforces fixed byte and line limits on logging buffers immediately after every write | Buffer write event, retention limit | Trimmed log buffer | Trims oldest entries while preserving valid Unicode points | `parallel-plan.md` §6 (I), `todo.md` DEEP-07 |
| 27 | Wave 4 / J | LSP Diagnostic Snapshot Port | Captures checker, server, session, and source revisions into immutable diagnostic snapshots | Buffer, file path, LSP client | Typed diagnostic snapshot | Returns `unavailable` if LSP server is disconnected | `parallel-plan.md` §7 (J), `todo.md` DEEP-01 |
| 28 | Wave 4 / J | Exact Coordinate Conversion | Converts between LSP UTF-16/32 character offsets and Emacs buffer points on widened buffers | LSP position, buffer text | Exact Emacs buffer point | Returns `nil` on invalid surrogate or out-of-range position | `parallel-plan.md` §7 (J), `todo.md` DEEP-13 |
| 29 | Wave 4 / J | Versioned Diagnostic Verification | Pulls fresh diagnostics tied to file modification ticks for post-edit self-healing (COMPAT-01) | File revision, server capability | Fresh diagnostic delta | Falls back to `unavailable` if server lacks versioned pull | `parallel-plan.md` §7 (J), `todo.md` COMPAT-01 |
| 30 | Wave 4 / K | Encapsulated Debugger Adapter | Exposes control, inspection, and lifecycle ports over Dape without modifying Dape itself | Debug launch config, project context | Debug session handle | Returns `unavailable` if Dape or DAP server is missing | `parallel-plan.md` §7 (K), `todo.md` ARCH-05 |
| 31 | Wave 4 / K | Debugger Active Unload & Advice Removal | Cleanly terminates debug sessions, sockets, and advice on package unload | Unload request | Cleaned environment | Removes all advice; kills orphan debug servers | `parallel-plan.md` §7 (K), `todo.md` ARCH-17 |
| 32 | Wave 4 / L | Atomic Persistence & Session Storage | Saves conversation sessions using temp files and atomic rename with 0600 permissions | Session record, destination directory | Persisted file path | Leaves original intact on write failure or disk full | `parallel-plan.md` §7 (L), `todo.md` DEEP-11 |
| 33 | Wave 4 / L | Multi-Writer Conflict Resolution | Detects external disk modifications and concurrent writers before committing file changes | Expected revision, disk state | Commit success or conflict error | Halts write and reports conflict on disk divergence | `parallel-plan.md` §7 (L), `todo.md` DEEP-10 |
| 34 | Wave 4 / L | Storage Data Lifecycle & Quota | Enforces storage quotas and retention policies on session archives and temp files | Storage directory, quota limits | Cleanup report | Deletes only owned artifacts; never follows symlinks | `parallel-plan.md` §7 (L), `todo.md` DEEP-15 |
| 35 | Wave 5 / M | Backend Execution-Owner Port | Abstracts agent loops behind an execution-owner SPI, supporting native and fake backends | Backend descriptor, session context | Backend lifecycle handle | Unsupported capabilities (e.g. resume) return `unavailable` | `parallel-plan.md` §8 (M), `todo.md` MOD-08 |
| 36 | Wave 5 / M | Fake Agent Backend Fixture | In-memory agent implementation providing deterministic tool calls, approvals, and events | Scripted test scenarios | Verified agent event sequence | Emulates disconnects, out-of-order events, and resets | `parallel-plan.md` §8 (M), `todo.md` DEEP-16 |
| 37 | Wave 5 / N | Programmatic Egress Policy | Enforces network and filesystem egress rules at programmatic gates based on connection snapshot | Request target, destination URL, payload | Permitted request or security denial | Blocks requests to unlisted hosts or cross-origin targets | `parallel-plan.md` §8 (N), `todo.md` DEEP-08/14 |
| 38 | Wave 5 / N | Structured Tool Argv Verification | Sanitizes tool arguments, enforces `--` delimiters, and validates canonical roots | Tool executable, argument list | Validated process invocation | Rejects option injections, shell expansions, and escape paths | `parallel-plan.md` §8 (N), `todo.md` ARCH-02 |
| 39 | Wave 5 / O | Test Docstring & Header Hygiene | Corrects checkdoc formatting, missing `;;; Code:` tags, and argument references in 18 legacy test files | 18 allowlisted test files | Clean checkdoc output | Never modifies test logic, assertions, or synthetic fixtures | `parallel-plan.md` §8 (O), `todo.md` TEST-01 |

---

## 5. Edge Cases & Observed Behaviors Table

| # | Feature | Input / Condition | Observed / Documented Behavior |
|---|---|---|---|
| 1 | Single-Active-Run | Concurrent claim request on already running application instance | Second claim is immediately rejected with explicit error; active run is unaffected. |
| 2 | Application Reset | Reset initiated on Session A while Session B has active request | Session A state, counters, and history are cleared; Session B request, process, and circuit state remain untouched. |
| 3 | Run Budget | Subtask or tool execution attempts to reset or overwrite parent budget | Subtask shares parent budget; local reset attempt is ignored; total consumption accumulates across subtasks. |
| 4 | Edit Approval | Session configuration or active mode changes while edit approval is pending | Cached approval is invalidated; continuation fails; user must review and approve under new configuration. |
| 5 | Edit Rollback | User modifies target file while a multi-file batch rollback is in progress | Rollback detects foreign writer / disk modification conflict; aborts rollback for that file and reports conflict without overwriting user edits. |
| 6 | Edit Service | Save-hook alters file content upon commit | Final save-hook transformation is reconciled into the transaction outcome; disk revision is updated. |
| 7 | Credential Discovery | Remote `auth-source` or GPG agent requires interactive password entry | Worker returns explicit `unavailable`; Emacs UI thread never blocks or prompts interactively. |
| 8 | Credential Discovery | Request cancelled or timeout reached while worker process is searching disk | Worker process is killed; timer cancelled; no leaked child process or late callback. |
| 9 | Tool Execution | Tool invoked via alias in readonly mode | Execution gate enforces readonly check regardless of alias; unauthorized write action is rejected. |
| 10 | Tool Execution | Tool unregisters while long-running asynchronous execution is in flight | Gate drains running task or cancels it via async handle before unloading module code. |
| 11 | Transport (HTTP/SSE) | Inbound SSE stream contains 1 MB single line without newline delimiter | Stream bounds parser triggers limit violation; emits single terminal error; cleans up socket without memory overflow. |
| 12 | Transport (HTTP/SSE) | Server emits Unicode emoji split across two TCP packets | SSE parser buffers partial bytes and reconstructs valid UTF-8 sequence without character corruption. |
| 13 | Transport (Redirect) | Server returns 302 redirect from `api.example.com` to `evil.com` | Redirection logic strips `Authorization` and sensitive headers before dispatching request to new origin. |
| 14 | Process Lifecycle | Child process ignores `SIGTERM` on cancellation | Timeout fires; escalation sends `SIGKILL` to process group; prevents zombie processes. |
| 15 | Process Lifecycle | High concurrency ERT test execution causes stderr drain timing delay (RISK-01) | Deterministic event loop stepping waits for stderr EOF before closing process handle. |
| 16 | History Store | History contains orphan assistant tool-call without matching tool-result | Protocol wall repairs turn structure or sanitizes payload before dispatching to provider API. |
| 17 | Compaction | Compaction summary returns empty string or provider error | Loop handles failed compaction safely; does not corrupt existing history; terminates gracefully if context is full. |
| 18 | Chat View | Rapid SSE stream arrives while user is actively typing in draft prompt | Stream render queue batches updates and updates transcript without moving user point or losing keystrokes. |
| 19 | Chat View | User closes chat buffer while plan preparation is running asynchronously | View close cleanly unbinds listeners; cancels async preparation task; prevents error on missing buffer. |
| 20 | Log Privacy | Log writer encountered nested JSON structure containing API key in subfield | Common redaction layer recursively masks known secret keys before writing to log buffer. |
| 21 | Log Retention | Single log entry exceeds maximum buffer retention cap | Log buffer writes entry, immediately trims oldest content, and respects byte cap while preserving valid character boundaries. |
| 22 | LSP Coordinates | Symbol replacement spans wide Unicode characters (e.g. non-BMP emojis) | Widened buffer character conversion maps exact UTF-16 offset; replaces exact symbol without offset drift. |
| 23 | LSP Freshness | Eglot server provides only unversioned push diagnostics (COMPAT-01) | System does not treat unversioned push as verified clean; returns `unavailable` unless pull capability exists. |
| 24 | Dape Debugger | User initiates Stop during asynchronous adapter compilation | Compilation process killed; socket closed; state machine transitions to stopped without hanging. |
| 25 | Dape Unload | Package unload triggered while debugging session is active | Active unload advice cancels sessions, tears down sockets, restores original functions, and returns timers to baseline. |
| 26 | Persistence Writer | Concurrent write attempt from another Emacs process on same session file | File lock / revision mismatch detects conflict; write is rejected; active session data is not overwritten. |
| 27 | Persistence Storage | Disk becomes full during session file write | Atomic publication fails in temp file; original session file remains completely intact and uncorrupted. |
| 28 | Fake Backend | External agent emits out-of-order execution events | Backend adapter buffers or rejects out-of-order events; maintains single execution owner invariant. |
| 29 | Egress Security | Malicious prompt in project file attempts injection to fetch external URL | Egress policy gate checks target against approved provider connection snapshot and denies outbound request. |
| 30 | Structured Tool Trust | Tool argument contains shell metacharacters or leading option flags (`-rf`) | Structured runner invokes executable directly with argv array and `--` separator; prevents option injection. |

---

## 6. Comprehensive TODO Item Cross-Reference Matrix

| TODO ID | Priority & Type | Core Description | Primary Owner | Wave & Package | Resolution / Boundary Condition |
|---|---|---|---|---|---|
| **CONFIG-01** | P2 · K | Synchronous auth-source execution blocking async credential boundary | Worker 3 | Wave 1 / Package C | Eliminated via cancellable background worker; `unavailable` on interactive auth. |
| **RISK-01** | P2 · D | Process cancellation / stderr closure stress anomaly | Worker 3 | Wave 2 / Package F | Instrumented with deterministic event harness; left open if not reproduced. |
| **RISK-02** | P2 · D | Sampling / reasoning conditional compatibility | Worker 2 | Wave 2 / Package E | Concrete versioned error fixtures; left open if no provider contract available. |
| **COMPAT-01** | P2 | Alternative verification for unversioned Eglot push | Worker 1 | Wave 4 / Package J | Pull/versioned check implemented if capability exists; otherwise `unavailable`. |
| **ARCH-01** | Architecture | Session ownership: separate chat data from global run coordination | Workers 1, 2 | Wave 1 / A, Wave 3 / G, H | Application coordinator owns run; sessions own data; single-active-run. |
| **ARCH-02** | Architecture | Command security: distinguish argv, policy, and true OS isolation | Workers 1, 2 | Wave 2 / D, Wave 5 / N | Structured program + argv, `--` terminator, canonical path validation. |
| **ARCH-03** | Architecture | Human approval: captured continuation instead of replay | Workers 1, 2 | Wave 1 / B, Wave 2 / D | Single-use token bound to root, env, and config revision; no replay store. |
| **ARCH-04** | Architecture | Unified edit engine: block, symbol, and unified diff pipelines | Workers 2, 3 | Wave 1 / B, Wave 4 / L | Common snapshot, Ediff review, save-hook reconciliation, batch rollback. |
| **ARCH-05** | Architecture | Debugger boundary: owned connection lifecycle behind Dape adapter | Worker 2 | Wave 4 / K | Encapsulated Dape adapter; nonblocking FSM; clean active unload. |
| **ARCH-06** | Architecture | Chat view: decouple data ownership from layout; preserve UX markers | Worker 2 | Wave 3 / H | Coalesced streaming render queue; point/narrowing/IME preserved. |
| **ARCH-07** | Architecture | History: write-time invariants, protocol wall on every request | Worker 1 | Wave 3 / G | Single-queue store, turn pairing validation, protocol wall on outbound requests. |
| **ARCH-08** | Architecture | Data model: single meaning and explicit ownership | Workers 1, 2 | Wave 0, Waves 1–3 | Typed structs for lifecycle entities; canonical internal formats. |
| **ARCH-09** | Architecture | Module independence: inverted dependencies & pluggable adapters | Workers 1, 2 | Waves 2–5 (D, H, J, K, M) | Adapters pluggable via ports; core headless execution operates without them. |
| **ARCH-10** | Architecture | Domain types: named values instead of primitive obsession | All Workers | Wave 0, Wave 1 / B | `cl-defstruct` for domain values with predicates and boundary validation. |
| **ARCH-11** | Architecture | State management: single state field and explicit transition table | Workers 1, 2 | Wave 1 / A, Wave 3 / G | Explicit FSMs for run, request, approval, process, and transaction. |
| **ARCH-12** | Architecture | Prohibit global mutable runtime state: explicit owner and context | Coordinator, A | Wave 0, Wave 1 / A | All state held in context records; legacy bridges eliminated. |
| **ARCH-13** | Architecture | Readability limit: at most two nested loops, shallow control flow | All Workers | All Waves | Max 35-40 lines per function, shallow branching, early guard clauses. |
| **ARCH-14** | Architecture | Simplest complete solution: correctness, algorithm, measurement | Workers 1, 3 | Wave 3 / G, Wave 3 / I | Profiling-based optimization; no speculative frameworks or caching. |
| **ARCH-15** | Architecture | Defensive programming: validate at boundary, canonical data inside | All Workers | All Waves | Strict boundary decode/validate; internal functions rely on valid types. |
| **ARCH-16** | Architecture | Error model: named results instead of string parsing | All Workers | All Waves | Canonical `contract/result.el` error codes; no parsing error strings. |
| **ARCH-17** | Architecture | Resource contract: single owner, structured cancel, single cleanup | All Workers | All Waves | Explicit ownership of processes, timers, buffers; idempotent teardown. |
| **ARCH-18** | Architecture | Testable boundaries: contract suites, fake time, error injection | All Workers | Wave 2 / F, Wave 5 / O | Reusable contract test suites, deterministic event loop stepping. |
| **ARCH-19** | Architecture | Contract evolution: versioning, capability, and pure migration | All Workers | Waves 1, 2, 4, 5 | Explicit capability negotiation; safe handling of unknown fields. |
| **MOD-01** | Modularity | Loop/UI separation: complete existing events, isolate control calls | Workers 1, 2 | Wave 3 / G, Wave 3 / H | Headless engine runs without chat UI; passive observers cannot block loop. |
| **MOD-02** | Modularity | Tool contract: async SPI and single execution gate | Worker 1 | Wave 2 / D | Context-bearing async executor; single execution gate for direct and alias calls. |
| **MOD-03** | Modularity | Selection / discovery continuation boundary | Workers 2, 3 | Wave 1 / C, Wave 3 / H | Decoupled model discovery and selection into owned services. |
| **MOD-04** | Modularity | Transport port: loop-independent request lifecycle | Worker 2 | Wave 2 / E | Request lifecycle decoupled from loop state; logical handle owns resources. |
| **MOD-05** | Modularity | Ordered reset coordination | Worker 1 | Wave 1 / A | Critical reset order preserved; foreign sessions and circuits protected. |
| **MOD-06** | Modularity | Planning: complete owned plan record with dispatcher port | Worker 2 | Wave 3 / H | Plan dispatcher operates on application port independently of chat buffer. |
| **MOD-07** | Modularity | Runtime context: ensure isolation without unnecessary god-objects | Workers 1, 2 | Wave 1 / A, B, Wave 3 / H | Minimal context records passed to services; no monolithic engine object. |
| **MOD-08** | Modularity | Hybrid client preparation: separate LLM transport from agent backend | Worker 1 | Wave 5 / M | Execution-owner abstraction; fake agent backend fixture. |
| **DEEP-01** | Deep Issue | Post-edit verification: fresh baseline and project impact | Worker 1 | Wave 3 / G, Wave 4 / J | Multiset comparison of pre- and post-edit diagnostics; self-healing trigger. |
| **DEEP-02** | Deep Issue | Compaction policy: from single limit to measured multi-stage design | Worker 1 | Wave 3 / G | Single-compaction default preserved; overflow paths tested. |
| **DEEP-04** | Deep Issue | Prompt size and cache: preserve fixed prefix, measure savings | Worker 1 | Wave 3 / G | Stable prompt prefix boundary; no tool leakage when disabled. |
| **DEEP-05** | Deep Issue | Processes: complete job management with interactive session contract | Workers 1, 3 | Wave 2 / F, Wave 5 / M | Process session transport contract; structured process group signaling. |
| **DEEP-06** | Deep Issue | Log privacy: data minimization first, then layered redaction | Worker 3 | Wave 3 / I | Metadata-only default; proactive credential redaction before write. |
| **DEEP-07** | Deep Issue | Log performance: measure cost hypothesis, preserve retention cap | Worker 3 | Wave 3 / I | Benchmarked buffer trimming; strict byte and line retention caps. |
| **DEEP-08** | Deep Issue | Context trust boundary: project text or tool output is not authority | Worker 2 | Wave 5 / N | Provenance tracking; prompt text cannot override programmatic permissions. |
| **DEEP-09** | Deep Issue | Unified budget: limit multiplier of retry, healing, and compaction | Workers 1, 2 | Wave 1 / A, Wave 2 / E, Wave 3 / G | Shared run debit gate; prevents exponential cost expansion. |
| **DEEP-10** | Deep Issue | Multiple writers: single run does not mean single writer on disk | Worker 3 | Wave 4 / L (evidence in B) | Disk revision verification before commit; conflict detection and rejection. |
| **DEEP-11** | Deep Issue | Crash and restart: rollback is not crash recovery | Worker 3 | Wave 4 / L (evidence in B) | Atomic file publication via temp files; no resurrection of unconfirmed work. |
| **DEEP-12** | Deep Issue | Backpressure: aggregate queue and UI latency bounds | Workers 2, 3 | Wave 2 / E, F, Wave 3 / H | Enforced limits on SSE event sizes, parse queues, and UI render queues. |
| **DEEP-13** | Deep Issue | Coordinate systems: accurate text positioning across encodings | Worker 1 | Wave 4 / J, Wave 4 / K | Widened buffer character conversions supporting UTF-8, UTF-16, and UTF-32. |
| **DEEP-14** | Deep Issue | Connection trust: endpoint, credential, and capability snapshot | Workers 2, 3 | Wave 1 / C, Wave 2 / E, Wave 5 / N | Single immutable snapshot prevents credential leakage on redirects or config change. |
| **DEEP-15** | Deep Issue | Data lifecycle: log redaction does not govern all disk copies | Worker 3 | Wave 3 / I, Wave 4 / L | Permissions (0600), storage quotas, and safe deletion without following symlinks. |
| **DEEP-16** | Deep Issue | Composition correctness: verifying integrated system behaviors | Coordinator, M, N | Wave 5 / M, N, Coordinator | End-to-end integration tests and fault injection across multiple components. |
| **TEST-01** | Test Debt | Checkdoc debt in legacy ERT test sources | Worker 3 | Wave 5 / O | Fix real docstring/header debt across 18 test files; zero changes to tests. |

---

## 7. Verification Methods & Command Reference

### ERT Test Suite
```bash
emacs -Q --batch -L . \
  --eval "(progn (require 'package) (package-initialize) (dolist (f (directory-files \"tests\" nil \"^test-.*\\.el$\")) (require (intern (concat \"tests/\" (file-name-sans-extension f))))))" \
  -f ert-run-tests-batch-and-exit
```

### Strict Byte-Compilation
```bash
emacs -Q --batch -L . \
  --eval "(setq byte-compile-error-on-warn t)" \
  -f batch-byte-compile <modified_or_new_file.el>
```

### Checkdoc Verification
```bash
emacs -Q --batch \
  --eval "(progn (require 'checkdoc) (setq checkdoc-diagnostic-buffer \"*checkdoc-report*\") (checkdoc-file \"<file.el>\") (when (get-buffer \"*checkdoc-report*\") (with-current-buffer \"*checkdoc-report*\" (princ (buffer-string)))))"
```

### TLC Formal Model Checking
```bash
# Main model check
./proof/run_tlc.sh

# Specific model checks
./proof/run_tlc.sh --mode            # KarguMode
./proof/run_tlc.sh --plan            # KarguPlan
./proof/run_tlc.sh --restore         # KarguRestore
./proof/run_tlc.sh --selection        # KarguSelection
./proof/run_tlc.sh --approval         # KarguApproval
./proof/run_tlc.sh --process          # KarguProcess
./proof/run_tlc.sh --diagnostics      # KarguDiagnostics
./proof/run_tlc.sh --debug-startup    # KarguDebugStartup
./proof/run_tlc.sh --debug-close      # KarguDebugClose
./proof/run_tlc.sh --debug-watch      # KarguDebugWatch
./proof/run_tlc.sh --debug-execution  # KarguDebugExecution
./proof/run_tlc.sh --debug-selection  # KarguDebugSelection
./proof/run_tlc.sh --debug-readiness  # KarguDebugReadiness
./proof/run_tlc.sh --verification     # KarguVerification
./proof/run_tlc.sh --edit-transaction # KarguEdit
```
