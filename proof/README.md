# Kargu TLA+ specification

This directory holds the TLA+ specification of Kargu's agent loop and protocol wall, and the TLC configuration that checks it. The specification follows the Elisp code; when a transition changes in the code, the specification changes with it (`skills.md`).

The check is exhaustive over a bounded model. It is a proof for those bounds, not for every parameter value.

## Atomic native review revisions (2026-10-29)

`proof/run_tlc.sh --edit-revision` checks `KarguEditRevision`: a source and
approval record, a candidate worker, a competing upload, revocation and expiry.
Only successful worker join updates source revision, approval digest metadata
and revision together. Cancellation retains the worker and candidate reservation
until actual join; authorization consumes the exact current revision. Exhaustive
BFS completes **714 generated / 272 distinct states**, depth 13, empty queue,
with deadlock checking enabled. Keeping the old approval while adopting a new
source violates `AtomicRevision` in the mutant check. Filesystem and text truth
are covered separately by native pipe regressions, rather than assumed proven by
this bounded ledger model.

## Receipt verification and cleanup audit (2026-10-29)

`--edit-issuance` now includes the verification worker between editor quiescence
and terminal journal IO. Both workers must actually join before releasing the
claim/lease/reservation. Source revocation does not erase already verified effects.
A positive committed result requires successful verification. BFS completes
3,633 generated / 959 distinct states, depth 17, empty queue. Replacing verification
with a quiescence flag violates `PositiveReceiptsVerified` in the mutant fixture.
Disk/hash truth remains an explicit abstract input here; native real-file receipt
regressions separately check the validation boundary. Native process-local rollback and an opt-in revised batch UI now exist; full
consumer cutover remains incomplete. See `docs/task3-audit-2026-10-29.md`.

## Native editor activity across connection replacement (2026-10-28)

`proof/run_tlc.sh --editor-activity` checks `KarguEditorActivity` /
`EditorActivityMC`: two activities, two connection epochs, pending issuance,
late token delivery, revoke, synchronous handler return, terminal ACK and EOF.
A single physical Emacs fence survives EOF/reconnect until the old handler
actually unwinds. Publication assumes the gate/preflight/journal ordering checked
by `--edit-issuance`; native IO joins remain that model's responsibility.
It does not prove arbitrary asynchronous effects scheduled by editor hooks.

Standard BFS completed with 933 generated / 356 distinct states, depth 15 and an
empty queue. The early-release-on-EOF mutant violates `PhysicalFence` after 20
distinct states. Eleven held-peer ERT tests exercise the actual bridge/controller,
and the real CRLF/Unicode pipe fixture now applies through it. Positive native
receipt ingestion and production consumer cutover remain open in todo task 3.

## Native edit preparation and exact checker verdict (2026-10-28)

`KarguEditPreparation.tla` / `EditPreparationMC.cfg` cover two opaque preparation
IDs, two separately typed source-owner IDs and one application's bounded byte
reservations. File reads/patch inspection share a bounded worker pool with
external reads; patch metadata preparation, Git and final snapshot IO have actual
start/join accounting. Cancel, source close, expiry and source changes can happen
before collection. Reservations remain held while any worker/process is unjoined;
Git follows whole-batch capture, and ready publication follows actual drain.
The model uses all four independent identity-renaming permutations, preserving
both IDs and both owners. It checks safety invariants, not liveness, concrete
filesystem operations, encoding, hashes, review decisions or editor effects.

The earlier restricted sandbox denied the RMI listener used by BFS mode.
For invariant-only configurations, the supported
[depth-first iterative-deepening option](https://github.com/tlaplus/tlaplus/blob/master/general/docs/current-tools.md)
can run without that listener. The wrapper accepts it before a named model:

```sh
proof/run_tlc.sh --dfid 128 --edit-preparation
proof/run_tlc.sh --dfid 64 --edit-transaction
proof/run_tlc.sh --dfid 64 --application
proof/run_tlc.sh --dfid 64 --approval
proof/run_tlc.sh --dfid 64 --process
```

After the sandbox restriction was removed, the standard BFS commands for these
five models also completed without errors, with an empty queue:

| Model | Generated | Distinct |
|---|---:|---:|
| Native preparation, editor admission and preflight, identity symmetry | 1,568,116 | 319,746 |
| Edit transaction | 1,849 | 560 |
| Application | 17,545 | 4,624 |
| Approval, shared command/editor kinds | 360,452 | 49,152 |
| Process | 535 | 179 |

Earlier unsymmetrized DFID attempts ended in the installed tool's fingerprint
statistics with `ArithmeticException: Division by zero`; those are failed runs,
not proof evidence. The completed native model uses disjoint opaque IDs and
ordinary identity symmetry. A temporary mutation that freed an active reservation
on Cancel was rejected by `ActualJoinBeforeRelease` (76 distinct states), showing
that the join barrier invariant catches that error.

`Finished in` and exit zero alone are insufficient: with the installed checker,
`--dfid 2 --edit-transaction` returns zero after only nine states without declaring
complete exploration. The wrapper now rejects it. Both BFS and DFID model-check
modes require the explicit full verdict; errors/counterexamples still fail.
Simulation remains labelled as simulation and cannot be combined with `--dfid`.
Declared liveness properties are not removed to make DFID run; use BFS for models
that require liveness. No partial-depth or random run is counted as exhaustive.
Earlier complete DFID scans found the same distinct-state counts. The complete
implementation acceptance still requires the native/Emacs fixtures and the
remaining editor grant, transaction, journal and consumer migration in todo 3.

## Interrupted-package integration checks (2026-10-22)

The 2026-10-27 application model also checks sequential connection and skill
preparation under the captured claim. `RunningPrepared` and `PreparationOrder`
prevent first-request admission before both barriers (tool-free runs complete
the skill barrier without IO). Late claims, Stop and reset retain the existing
drain/release boundary. The exhaustive scan completed with 13,099 generated /
3,481 distinct states, depth 33, queue empty. This abstraction does not prove
filesystem capture, metadata parsing, editor catalog revisions or concrete
worker joins; native and ERT tests cover those bounded implementation obligations.

### Configuration preparation (G02)

The connection model separates `config-reading` from credential resolution.
Cancellation in either phase stops the owned worker; a stale completion cannot
publish a connection. Its exhaustive scan visited 602,836 generated / 101,708
distinct states, depth 22, without errors. Worker responsiveness, byte limits,
same-mtime file replacement, nested string isolation and actual child cleanup
are concrete ERT obligations, not properties proved by the bounded abstraction.

### Native execution ownership (G01)

`proof/run_tlc.sh --application` exhaustively checks two applications, two
distinct claims per application (run labels may be reused), request ownership,
drain-before-release and the closing/resetting admission barrier. Callbacks may
arrive from either application's caller. The bounded model has one logical
request per claim; actual multiple model turns, resource identity, startup
reentry and late timer/process publication are ERT obligations.

G01 scans completed without errors: application 5,017 generated / 1,444 distinct
states, depth 21; mode 20,179 / 5,958, depth 17; transport 1,810 / 693, depth 12.
The unchanged main loop abstraction treats terminal cleanup atomically; the new
application model refines that cleanup into revoke/drain/release. The full main
scan also completed: 729,094,900 generated / 85,318,093 distinct states, depth 42.
These are exhaustive bounded scans, not proofs for arbitrary bounds or concrete
OS resources. Offline native tests cover cross-application HTTP, same-generation
request replacement, origin closure, reset/reentry, scoped job/edit/confirmation
cleanup, timer inheritance and exactly-once delivery. Remaining adapter/registry
and view migrations are tracked in `todo.md`, not claimed by this model.

The following exhaustive bounded scans completed without errors. Run each
with `proof/run_tlc.sh` and its flag:

| Flag | Generated | Distinct | Depth |
|---|---:|---:|---:|
| `--budget` | 1,591 | 432 | 12 |
| `--connection` | 446,212 | 77,292 | 20 |
| `--transport` | 1,810 | 693 | 12 |
| `--edit-transaction` | 1,849 | 560 | 11 |
| `--approval` | 360,452 | 49,152 | 15 |
| `--process` | 535 | 179 | 9 |
| `--process-session` | 129 | 42 | 8 |
| `--mode` | 20,179 | 5,958 | 15 |

`KarguProcessSession.tla` covers the interactive startup barrier, EOF/exit,
cancel/force ordering, bounded retained output and terminal resource cleanup.
Actual OS group ownership, PID reuse, byte slicing and foreign-job cancellation
are ERT obligations, not proofs from the abstract process model.

Budget/connection/transport models cover their local kernels, not yet-unwired
native run composition. Read-only record slots do not prove deep immutability
or secure erasure of all secret copies. The request keeps its captured budget
and breaker scope across retries; ERT checks provider switching, stale claims,
delayed approval, actual plaintext credential workers, and asynchronous Git
patch ownership. The main model was not rerun at that integration baseline;
the subsequent G01 scan is recorded above. History/backend/egress consumer
work remains in `todo.md`.

## Earlier model checks

`KarguEdit.tla` / `EditMC.cfg` refine the process-local reviewed batch boundary.
Run `proof/run_tlc.sh --edit-transaction`. The exhaustive 2026-10-21 scan
explored 425 generated states, 160 distinct states and depth 10 without error.
Two files, one foreign replacement per file and owner retirement cover review
before write, single delivery and rollback that preserves foreign content.
Git's actual hunk matching, save-hook reconciliation and source coordinates
are ERT obligations, not consequences of this model. Filesystem CAS, crash
recovery and power-loss durability are explicitly outside its bounds.
The existing `--verification` ownership model was also rerun exhaustively:
439 generated states, 68 distinct states, depth 6, no error. It does not prove
the semantic identity or freshness of diagnostic messages.

Debug mode admission requires a successful adapter preflight. The model
abstracts external probes as a boolean result passed to `SetMode`; failed
or obsolete probes never publish a mode transition. Probe callbacks and
mode-selection races are also covered by the offline ERT tests.

For the breaker, `HALF_OPEN` denotes an unclaimed canary slot and `PROBING`
denotes the same runtime state with `probe-inflight` set. Cancellation and
terminal non-upstream errors release that slot without clearing the failure
count or declaring the provider healthy. Retries retain ownership.
Context-overflow responses likewise release the canary without resetting the
upstream failure count; compaction is not evidence of a healthy provider.
The HTTP layer owns successful-response recording; loop response handlers
do not record it again. The abstract receive actions include that HTTP step.

The tool-call ingress contract rejects duplicate identities within a batch.
Concrete ID generation and collisions with earlier conversation turns are
covered by ERT for plain, streamed, native and legacy wire formats. The bounded
loop model treats call IDs as opaque labels, not generated UUIDs.

Transport completion is checked before a response enters the loop: an SSE
finish reason or `[DONE]` is required. Truncation and malformed events enter
the existing `ModelReceiveError` path, never `ModelReceiveToolCalls`. ERT covers
this transport boundary separately from the loop's abstract response actions.

Usage and response delivery now capture a buffer-owned session handle. ERT
checks two owners, replacement/closure, late and duplicate responses, and
owner exit during request publication. A run's owner-exit hook invokes the
existing Stop path, rejects startup in the closing owner and detaches before
completion. The post-notification startup barrier admits no HTTP effect after
Stop. These refine the existing abstract transitions rather than adding a
new loop state. The full bounded loop/protocol/circuit/state scan was rerun
after the owned session/history extraction: 729,094,900 generated states,
85,318,093 distinct states, depth 43, no error (2026-10-20).
The process ownership scan is a regression gate, not a proof of all session
or buffer lifetimes. History now belongs to the same captured session; detached
payload/persistence snapshots and queue container ownership are checked by ERT.
Tool identities are canonicalized at the owned client ingress, after transport
shape decoding. Foreign-buffer Stop and obsolete compaction callbacks cannot
repair or clear another owner's history. These preserve the protocol wall's
existing abstract transitions. Application coordination ownership remains in
`todo.md`; owned selection is refined separately below.

`KarguSelection.tla` / `SelectionMC.cfg` model immutable owned selections and
captured picker callbacks. Run `proof/run_tlc.sh --selection` for an exhaustive
scan. Session epoch, selection identity and catalog generation must still match
before a picker applies; active native work locks selection updates. Replacing
an owner invalidates its old callbacks without changing a frozen request's
settings. With two owners, two pickers per owner, two session epochs and one
selection revision per epoch, TLC explored 3,690,151 generated states, 640,440
distinct states, depth 19, with no error (2026-10-21). This bounded refinement
does not prove catalog authenticity or focus/draft UX. ERT additionally checks
atomic tuple publication, inherited versus disabled effort, and suppression of
UI continuations when a notification replaces the owner or selection.

`KarguMode.tla` / `ModeMC.cfg` refine per-session mode preparation. Run
`proof/run_tlc.sh --mode`. The exhaustive 2026-10-21 scan explored 20,179
generated states, 5,958 distinct states and depth 15 without error. It checks
single delivery, intent supersession and mode freezing during one active run,
with two owners and two intents each. ERT additionally covers actual child
resource cancellation, close/reset, directory changes, foreign callback buffers
and reentrant admission hooks. This is not a proof of atomic session restore.

`KarguRestore.tla` / `RestoreMC.cfg` refine prepared session/view publication.
Run `proof/run_tlc.sh --restore`. The exhaustive 2026-10-21 scan explored 115
generated states, 54 distinct states, depth 6 without error. This small model
checks paired publication, failure preservation, revision and busy admission;
it abstracts the local commit as one non-yielding action. ERT tests the actual
rollback with render/footer and post-install faults, draft/root/selection
changes, close/Stop, and foreign or duplicate completion. External mode-hook
effects and disk crash recovery are not proved.

`KarguDebugClose.tla` / `DebugCloseMC.cfg` refine scoped adapter shutdown.
Run `proof/run_tlc.sh --debug-close`. The exhaustive 2026-10-21 scan generated
71 states, 20 distinct states, depth 7 without error, with an owned parent/child
and a foreign adapter. It checks one release/delivery, terminate fallback,
deadline/cancellation, and completion only after resource release. ERT uses
actual JSONRPC process connections with controlled DAP callbacks, server/stderr
resources, foreign selection, duplicate sentinels, owner replacement and an
unrelated process attached to an old output buffer. This does not prove adapter
OS process trees or all Dape UI event isolation. The startup model was also
rerun exhaustively: 8,465 generated, 1,544 distinct, depth 12 without error.

The 2026-10-21 `--plan` exhaustive rerun explored 257,073 generated states,
72,313 distinct states and depth 25 without error. Its existing separate claim,
dispatch and failure transitions now also cover a held asynchronous preparer.
ERT checks real preparation failure/retry, view/owner cancellation, approved
revision and draft changes, foreign completion, duplicate decisions and
reentrant mode observers. The model does not prove UI draft equivalence itself.

`KarguApproval.tla` / `ApprovalMC.cfg` refine one captured permission operation
in the shared command/editor ledger. Run `proof/run_tlc.sh --approval` for an
exhaustive scan. Twelve independent authority checks include config/policy,
content and review revision; the captured action kind cannot be interchanged.
Approval is claimed before entering its continuation, and cancellation prevents
later starts. The 2026-10-28 scan explored 360,452 generated / 49,152 distinct
states, depth 15, with no error and an empty queue. Removing the action-kind guard
violates `Safety_ExactActionKind` after 16 distinct states. The native editor gate
tests cover actual run ownership, exact revision, single use, command coexistence,
missing presenter, policy and resource release. Existing ERT covers directory
replacement, owner closure, environment/policy changes, reentrant decisions and
cancellation of only the owned UI prompt. This is not a proof of shell analysis,
OS isolation, editor issuance/settlement, exactly-once external effects or
filesystem compare-and-swap.

Model capabilities are read from provider/model-owned metadata records.
Provider isolation, ambiguous display aliases, exact request identities and
captured inspector ownership are covered by offline ERT, including catalog
responses arriving in either order. This changes metadata ownership, not the
loop's existing tool-admission transition or its abstract capability boolean.

A local stream-watch startup failure closes the attempt before delivering an
error through the existing `ModelReceiveError` path. It never launches a plain
duplicate. Process publication is conditional on pending state and generation,
including when a transport callback completes synchronously; ERT covers this
resource-ownership boundary without adding a loop transition.

The bounded file reader uses the existing tool-process runner and asynchronous task
lifetime, without adding a process state. Its 2026-10-21 regression scan
(`proof/run_tlc.sh --process`) explored 535 generated states, 179 distinct
states, depth 9, with no error. ERT separately checks read-owner replacement,
helper cancellation/drainage, bounded prefix growth, worker JSON/UTF-8 decoding,
and preferring a newly edited live buffer over a delayed disk snapshot. The
process model does not prove filesystem atomicity or all read-owner lifetimes.

External tool processes install their completion sentinel at creation, before
startup can yield to process events. The existing starting/running/closed
barrier delays delivery until resource setup completes, even if both streams
have already closed. ERT forces that ordering for separate and merged stderr;
this repairs process notification ownership, not a loop transition.

`KarguProcess.tla` / `ProcessMC.cfg` separately model bounded process capture.
Run `proof/run_tlc.sh --process` for an exhaustive scan. The model allows exit,
EOF, cancellation and deadlines before or after startup publication; a record
limit may coincide with a byte failure. It checks single delivery, the startup
barrier, closed-stream/timer cleanup and separation of intentional limits from
hard failures. The 2026-10-19 run with a three-record bound visited 179 distinct
states (535 generated), depth 9, without an error or deadlock. It abstracts
kernel signals and stream decoding; it does not resolve the separate OS/stress
timing question in `todo.md` or rerun the main loop proof.

Debugger connection discovery is restricted to concrete adapter working
directories within the selected workspace (including inherited parent
configuration). Source targets are checked after symlink resolution. Offline
ERT covers foreign global selection, unknown directories and callback origin
reassignment. This is a resource-admission boundary, not a new loop transition;
global Dape lifecycle isolation remains tracked separately in `todo.md`.

`KarguDebugStartup.tla` / `DebugStartupMC.cfg` model one startup intent from
dependency probing through approval, deferred compilation and final adapter
creation. Run `proof/run_tlc.sh --debug-startup`
for an exhaustive scan. Five grouped resource identities, an intervening local
adapter, foreign adapter events, caller-buffer changes, rejection and run
cancellation cover startup ownership and single delivery. The 2026-10-19 scan
visited 1,544 distinct states (8,465 generated), depth 12, without an error or
deadlock. Source filename/tick/mode/directory, editor-state preservation,
actual configuration fingerprints and source-local environment checks are
exercised by offline ERT. Invalidated identities are abstracted monotonically;
this is not a model of arbitrary editor history, compilation subprocesses or
Dape's global lifecycle cleanup. ERT exercises the real Dape compile/launch
dispatch with manually released continuations, final-boundary invalidation
by startup hooks, duplicate replies, deadlines and ownerless pre-run Stop.
Only the owned task timer is released: no compilation buffer, process or
finish hook is cancelled or removed. The creation boundary is atomic in this
model; Dape's internal synchronous port retry loop is outside these bounds
and remains tracked as DAPE-05. No main-loop transition changed or was re-proved.

`KarguDebugReadiness.tla` / `DebugReadinessMC.cfg` model the separate owned
wait after launch or while an existing adapter runs. Run
`proof/run_tlc.sh --debug-readiness` for an exhaustive scan. Two adapter
identities, token/project matching, ambiguity, removal/replacement, paused
state, origin invalidation, deadlines and cancellation cover single delivery,
no foreign success and cleanup. The 2026-10-19 scan visited 464 distinct states
(1,450 generated), depth 9, without an error or deadlock. ERT additionally
tests early events before launch returns, root-only token discovery, no DAP
metadata leak, ownerless waits, source closure, reentrant consumers, timer
startup errors, Stop before a run and editor-state preservation. This bounded
resource model covers readiness notification, not deferred adapter creation;
the latter is now checked by the separate startup model above. It is not a
rerun of the main-loop proof.

`KarguDebugWatch.tla` / `DebugWatchMC.cfg` cover the guarded continuation of a
two-expression watch snapshot. Run `proof/run_tlc.sh --debug-watch` for an
exhaustive scan. Root/session/connection/origin changes, caller switching,
cancellation, late replies and deadlines cannot authorize another request
under obsolete ownership. The 2026-10-19 scan visited 412 distinct states
(1,053 generated), depth 11, without an error or deadlock. ERT additionally
checks connection-keyed weak storage, copied strings/lists, session/project
separation and that Dape's global watch list and UI are untouched. The model
abstracts individual DAP results and editor identities; the main loop and
Dape's unrelated global lifecycle hooks are not included.

Debugger source excerpts and breakpoint enumeration use a canonical workspace
path boundary. ERT rejects external files, escaping symlinks and implicit remote
reads before content access, preserves editor state and keeps foreign frame
location metadata without reading that source. This is a read-admission change,
not a new loop or asynchronous-task transition.

`KarguDebugExecution.tla` / `DebugExecutionMC.cfg` model an owned execution
wait and its captured-context child. Run `proof/run_tlc.sh --debug-execution`
for an exhaustive scan. Foreign notifications, caller switching, connection
loss, origin reassignment, deadlines and cancellation cannot publish a foreign
pause or exit. Three state generations include continued/restopped races while
an old request is pending; an initially paused cache cannot trigger collection.
The 2026-10-19 scan visited 936 distinct states (2,297 generated), depth 9,
without an error or deadlock. Offline ERT additionally checks actual dispatcher
advice, exact adapter requests, timer/listener cleanup, partial startup failures
and error propagation during context collection. This is a bounded resource
model; the main loop, startup readiness and Dape's deferred compilation are
not included. UI thread/frame selection is refined separately below.

`KarguDebugSelection.tla` / `DebugSelectionMC.cfg` model a captured context
read or a navigation followed by its new captured read. Run
`proof/run_tlc.sh --debug-selection` for an exhaustive scan. Two thread/frame
identities, UI selection changes between callbacks, missing frames, execution
invalidation and cancellation cover pinned scope/variable requests, consistent
report identity and navigation consent. Paused/running/exited/replaced thread
states and same-adapter thread events now refine admission and epoch loss;
returning to stopped cannot restore an old read. Helper writes before guarded
delivery affect private data, not the live cache. The 2026-10-19 scan visited
934 distinct states (4,553 generated), depth 8, without an error or deadlock.
ERT additionally
covers refreshed frame objects resolved by ID, initially unspecified selection,
exact DAP arguments, stale explicit selections, large numeric frame IDs,
location text, editor-state preservation and successful `up/down` navigation.
This is a bounded selection-resource refinement, not a rerun
of the main-loop proof or a claim about unimplemented startup/lifecycle isolation.
It covers partial-thread admission and conservative adapter-wide invalidation.
Thread identity replacement and exit/start reuse cannot reauthorize old reads.

`KarguDiagnostics.tla` / `DiagnosticsMC.cfg` model the owned diagnostic wait
after backend startup. Run `proof/run_tlc.sh --diagnostics` for an exhaustive
scan. Two backends with old/current generations cover forced reports, edits,
root/server replacement, buffer closure, cancellation and deadline races.
Optional Eglot pushes require matching server/document versions. Verified
evidence is not a claim that diagnostics contain no errors. The 2026-10-19
scan visited 74,222 distinct states (455,710 generated), depth 14, without an
error or deadlock. Startup, actual Flymake/Eglot dispatch, manual-mode cache
publication and editor-state preservation are covered separately by ERT.
This is a bounded resource/freshness check; the main loop is unchanged and
its existing proof was not rerun.

Diagnostic severity is normalized through Flymake's declared category before
the loop counts errors. ERT covers Eglot and custom checker categories for both
file and project records, including the existing self-healing counter. This
repairs the evidence adapter, not the loop's error-count transition.

`KarguVerification.tla` / `VerificationMC.cfg` refine verification-batch
ownership of pending edit records. Run `proof/run_tlc.sh --verification` for
an exhaustive scan. Two files with original/replacement record identities
cover cancellation at either file, duplicate/late replies, setup failure,
caller switching and reentrant next work. Cleanup releases only captured
identities; a replacement edit is never consumed by the old batch. The
2026-10-19 scan visited 68 distinct states (439 generated), depth 6, without
an error or deadlock. ERT additionally uses real Flymake waits and the actual
run-stop path to check parent/child cancellation, equal-looking replacement
records, captured absolute keys after project switching and incomplete-result
reporting. Collected means a batch completed, not that its diagnostics were
clean; freshness is modeled separately in `KarguDiagnostics`. The main loop's
existing completion/stop transitions are unchanged; their exhaustive scan
was not rerun for this resource refinement.

## 1. Modules

The separate plan artifact workflow (`kargu/plan/store.el` and `dispatch.el`)
is modeled in `KarguPlan.tla`, with `PlanMC.tla` / `PlanMC.cfg`. Run its
exhaustive check with `proof/run_tlc.sh --plan` (or through `nix-shell shell.nix`).
It bounds two owners and two plans per owner; an epoch change abstracts a
project/session reassignment. It checks owned dispatch from any caller,
single dispatch per artifact, no resurrection of replaced decisions,
one dispatch claim per owner, and no dispatch after rejection. Closing either
the source chat or review invalidates the artifact; failed startup only restores
a still-current decision. The 2026-10-19 exhaustive run visited 72,313 distinct
states (257,073 generated), depth 25, with no error or deadlock. This is an
artifact-ownership check, not a proof that global chat/session state has already
been isolated. The main loop transitions are unchanged by this refactoring;
their existing bounded model and results remain separate.

```
proof/
├── KarguContract.tla   # Roles, modes, message schema, contract predicates
├── KarguProtocol.tla   # The protocol wall (repair order) and compaction
├── KarguCircuit.tla    # Circuit breaker; response classification events
├── KarguTools.tla      # Mode gate; doom-loop signatures
├── KarguState.tla      # State store statuses; busy and run-live classes
├── KarguLoop.tla       # The loop: states, actions, safety invariants
├── MC.tla / MC.cfg     # TLC harness: parameters, invariants, deadlock check
├── KarguSelection.tla  # Owned immutable selection and stale picker admission
├── SelectionMC.*      # Bounded session-selection harness
├── KarguProcess.tla    # One-shot process capture and completion ownership
├── ProcessMC.*        # Bounded process-capture harness
├── KarguDiagnostics.tla # Owned diagnostic evidence and cancellation
├── DiagnosticsMC.*    # Bounded diagnostic-wait harness
├── KarguDebugStartup.tla # Owned adapter probing and launch approval
├── DebugStartupMC.*   # Bounded debugger-startup harness
├── KarguDebugWatch.tla # Owned sequential watch evaluation
├── DebugWatchMC.*     # Bounded watch-continuation harness
├── KarguDebugExecution.tla # Captured adapter execution and context replies
├── DebugExecutionMC.* # Bounded execution-wait harness
├── KarguDebugSelection.tla # Pinned thread/frame reads and guarded navigation
├── DebugSelectionMC.* # Bounded selection-callback harness
├── KarguVerification.tla # Captured pending-edit records and batch cleanup
├── VerificationMC.*  # Bounded verification-batch harness
├── run_tlc.sh          # Exhaustive loop or focused resource checks
└── README.md           # This file
```

| TLA+ module | Elisp source | What it states |
|---|---|---|
| `KarguContract.tla` | `kargu/contract/{constants,types,assert,result}.el` | Roles, modes, tool names, `ContractMessage`, `ContractHistory`, ingress assertions. |
| `KarguProtocol.tla` | `kargu/history/{repair,protocol,compact}.el` | `ValidateHistory` in the code's order, `ProtocolFirewallValid`, `ApplyCompaction`. |
| `KarguCircuit.tla` | `kargu/api/circuit.el`, `kargu/loop/machine.el` | Breaker transitions and response classification events. |
| `KarguTools.tla` | `kargu/loop/tools.el`, `kargu/loop.el` | `GateToolAllowed`, `DoomLoopDetected`, `PushSig`. |
| `KarguState.tla` | `kargu/state/*.el` | `BusyOf`, `RunLiveStatus`, `TransitionStatus`, `TransitionMode`, `StateInvariant`. |
| `KarguLoop.tla` | `kargu/loop.el`, `kargu/loop/*.el` | The state machine; every action names the handler it mirrors. |

## 2. What the loop model covers

States: `IDLE`, `REQUEST`, `WAIT_MODEL`, `EXEC_TOOLS`, `DOOM_WAIT`, `VERIFY_FILES`, `COMPACT_WAIT`, `PAUSE`, `RECOVER`, `DONE`, `LIMIT`, `ERROR`, `STOPPED`.

The code never blocks while it waits for the user. Three states stand for those waits, each answered by a callback:

| State | Code | Exits |
|---|---|---|
| `PAUSE` | `kargu-loop--prompt-continue` | `PauseDecisionContinue` (cap grows by one batch), `PauseDecisionStop` (`LIMIT`) |
| `RECOVER` | `kargu-loop--recover-or-finish` | `RecoverRetry` (breaker reset), `RecoverStop` (`ERROR`) |
| `DOOM_WAIT` | `kargu-loop--request-doom-approval` | `DoomApprove` (run the call, signatures cleared), `DoomStop` (`ERROR`, open calls answered) |

Request path (`kargu-loop--on-request`): `RequestCompact`, `RequestPause`, `RequestSend`, `RequestBlocked` (open breaker).

Response path (`kargu/loop--on-response`): `ModelReceiveAnswer`, `ModelReceiveToolCalls`, `ModelReceiveLengthTruncated`, `ModelReceiveThought`, `ModelReceiveOverflow`, `ModelReceiveEmpty`, `ModelReceiveUpstreamError` (retryable), `ModelReceiveError` (other failures and the content filter), `ModelReceiveToolsUnsupported`.

Tools and healing: `ExecuteNextTool`, `DoomApprove`, `DoomStop`, `VerifyFiles`. An edit is verified only while healing rounds remain; with the budget spent the run goes on.

Also: `StartRun`, `FollowUpPrompt`, `SetMode` (only while no run is live), `ResetSession`, `CompactionFinish` (a failed or empty summary ends the run in `ERROR`), `UserStop` (from any live state; the finish repairs the history), `CircuitCooldownCanaryAction`.

`RequestStartFailure` closes a run when initial request construction or startup
raises synchronously. Prompt wrapping happens before the run is published;
failure after publication follows the regular error cleanup and releases an
owned canary. ERT also checks that a subsequent run can start immediately.

`ModelCallbackFailure` closes a live run when its response continuation raises,
even after a handler entered another live state. It cancels owned work, repairs
open tool calls and releases the canary. API response delivery is claimed before
history storage or user continuation; ERT checks synchronous and asynchronous
exceptions, duplicate deliveries and replacement by a newer request or run.

### The protocol wall

`ValidateHistory(hist, fix)` follows `kargu--validate-history`:

1. take the head system message out (create one if missing) and drop every other system message;
2. one forward scan drops orphan tool results and, when any other turn arrives, flushes the calls still open with a synthetic result, in call order;
3. merge consecutive user turns, merge consecutive assistant text turns and fold a text turn into the assistant turn with calls after it;
4. only then, when `fix = "strip"`, remove trailing assistant turns.
5. when no user remains, insert `Continue.` immediately after the system turn.

The forward scan drops empty assistant text turns before merging and turns
empty user content into a minimal `Continue.` nudge. Constant ingress fixtures
in `MC.tla` check empty, system-only, assistant-only, orphan
tool and empty-assistant histories. The bounded model represents text content;
ERT additionally checks mixed text/attachment blocks and preservation of their
order when user or assistant turns are merged.

`ModelReceiveThought` returns reasoning-only replies to `REQUEST` without an
independent empty-response retry budget. The global turn cap still pauses the
run before another request, as checked by exhaustive scanning and repeated-reply
ERT coverage. Read-only branch/stash listing does not grant mutation rights.
Synthetic thought/retry notices are abstracted away in the bounded model.

Truncated replies have one automatic continuation below the turn cap.
Further truncation, truncation at the cap, and exhausted empty-response retries
finish in `ERROR`, never in the successful `DONE` state.

The bounded loop abstracts request size with `CompactionThreshold`. ERT checks
the concrete short-window calculation and serialized history/schema estimate;
the model does not implement a provider tokenizer or image token accounting.

A request uses `"strip"`. A finished or stopped run and a compaction keep a trailing answer.

## 3. Invariants

TLC checks these in every reachable state, together with a deadlock check:

| Invariant | Meaning |
|---|---|
| `TypeOK` | Every variable stays in its domain: one compaction and one truncation continue per run, at most two doom signatures, `iterations <= turnCap`, a valid contract history. |
| `Safety_ProtocolFirewallInWaitModel` | A request in flight was sent with a history that satisfies the whole wall (law 4). |
| `Safety_ModeSafety` | In `ask`, `plan` and `debug` no edit is verified (mutating tools are gated). |
| `Safety_StateStoreCoherent` | Each loop state maps to a valid status of the state store, the store's busy flag agrees, and "run live" holds exactly in live loop states. The mode cannot change while a run is live (law 3). |
| `Safety_BoundedIterations` | Model round trips never pass the run's turn cap; only a user's `Continue` moves it. |
| `Safety_AllTerminalStatesAnswered` | In `DONE`, `LIMIT`, `ERROR` and `STOPPED` every assistant tool call has its result. |
| `Safety_NoToolQueueOutsideExec` | Outside `EXEC_TOOLS`, `DOOM_WAIT` and `VERIFY_FILES` the queue and the pending call are empty. |
| `Safety_NoPendingVerifyOutsideVerify` | No file waits for diagnostics outside `VERIFY_FILES`. |
| `Safety_CircuitBreakerSoundness` | No request is in flight while the breaker is `OPEN`. |
| `Safety_NoAbandonedCanary` | A claimed canary exists only while a model request is in flight. |
| `Safety_ToolsOffMeansNoToolWork` | With tools off no tool work is in progress (law 5). |
| `Safety_WaitingForUserIsIdle` | In `PAUSE` and `RECOVER` nothing else is in flight. |
| `Safety_CompactingMatchesState` | The compaction flag holds exactly in `COMPACT_WAIT`. |

Three invariants of the earlier specification are gone because another one already covers them: `Safety_SingleCompaction` and `Safety_ContractIntegrity` are part of `TypeOK`, and `Safety_InterruptedToolCallsAnswered` is a special case of `Safety_AllTerminalStatesAnswered`.

## 4. Running

```bash
./proof/run_tlc.sh                   # exhaustive scan: this is the proof
./proof/run_tlc.sh --simulate 20000  # random behaviors: a smoke test, not a proof
./proof/run_tlc.sh -workers 4 MC.tla # anything else goes to TLC unchanged
```

The script needs `tlc`; without it in `PATH` it enters `nix-shell ../shell.nix`. Its exit status is 0 only when TLC finished and printed no error, no violated invariant and no deadlock. TLC's working files go to a temporary directory.

### Bounds (`MC.cfg`)

| Constant | Value |
|---|---|
| `MaxIterations` | 3 (also the size of one `Continue`) |
| `MaxHealing` | 2 |
| `MaxEmptyRetries` | 1 |
| `CompactionThreshold` | 4 |
| `CompactKeepCount` | 3 |
| `CircuitFailureThreshold` | 3 |

`StateConstraint` limits the search to two generations (runs and resets), a history of at most 12 messages and a turn cap of at most `2 * MaxIterations`.

The loop does not have an additional upstream retry counter. A terminal
transport failure enters RECOVER; only an explicit user recovery may open a
new logical request. Physical retries belong to the transport owner. The main
model still abstracts that transport/circuit boundary: it is not a refinement
proof of the native HTTP worker, reverse observer or circuit registry.

### Result of the last run

Run on 2026-10-25, 24 workers, after removing the second loop retry authority:

```
Model checking completed. No error has been found.
537324349 states generated, 63188083 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 45.
Finished in 07min 42s at (2026-10-25 11:32:39 Europe/Istanbul)
```

Changing a guard breaks the check: with the `~noTools` guard removed from `ModelReceiveToolCalls`, a simulation reports `Safety_ToolsOffMeansNoToolWork` violated within a second. The numbers above are those of a real run; repeat it after every change to the specification and replace them.

### Prepared editor admission extension (2026-10-28)

The native preparation model now includes consuming `ready → claim → review /
authorized`, an actual claim-worker start/join, and explicit release of unissued
editor actions. Claimed byte/record ownership survives source close, abort and
expiry. `ClaimOwnership` prevents cancellation from silently removing a reviewed
or authorized claim before native cleanup. Starts/joins still track actual IO
workers, independently of whether a permission decision remains pending.

The exhaustive BFS scan completed with 480,956 generated / 97,230 distinct states,
depth 28 and no states left on the queue. Replacing retained-claim cancellation
with the old worker-only release predicate violates `ClaimOwnership` after 765
distinct states. These are admission/resource safety checks; journalled editor
issuance, live preflight, actual save hooks, receipt settlement and rollback are
outside this model. Native pipe tests cover source/session identity, stale revision,
single-use decision, tiny frames, foreground-command coexistence and owner closure;
a held blocking worker checks the actual join-before-capacity-release path.

### Bounded native edit journal (2026-10-28)

`proof/run_tlc.sh --edit-journal` checks `KarguEditJournal` / `EditJournalMC`.
It models create-new ownership, at most three records, writes separated from sync,
a synced-prefix crash abstraction, cancellation/failure, uncertainty, foreign
binding/permission/integrity changes and detached read-only recovery. A recovery
snapshot cannot become terminal from an issuance-only prefix, partial tail,
invalid chain or missing receipt commitment. Exclusive writer ownership prevents
recovery from observing an active writer as a completed journal.

The exhaustive scan completed 4,077 generated / 1,116 distinct states, depth 14,
with no states left on the queue. Removing the terminal-record predicate from
recovery violates `NoPrematureResolution` after 49 distinct states. Synced-prefix
persistence is an assumption; this does not prove filesystem/hardware durability,
actual editor dispatch, receipt truth, source hashes, rollback or liveness. The
Rust file fixtures independently check real locks, create-new behavior, private
permissions, fd-rooted identity, special-file refusal, every terminal-record byte
cut, source-free schema and bounded recovery. IPC issuance/receipt integration
remains part of todo 3.

### Complete native editor preflight (2026-10-28)

The native preparation model now adds one witness per abstract target before
`authorized → preflight → preflighted`. Two-file patches and one-file proposals
exercise incomplete prefixes and independent target ordering. Preflight retains
the same source reservation and an actual worker start/join; cancel/close/expiry
cannot free it while the worker remains live. Worker admission shares the command
bound. Source changes can invalidate observations; the model does not assume an
atomic filesystem/Emacs snapshot or authorize a write.

`--edit-preparation` completes 1,568,116 generated / 319,746 distinct states at
depth 36, with an empty queue. Removing the full-witness-set guard violates
`CompletePreflight` after 775 distinct states. Native pipe tests independently
check document identity/tick/coding, dirty/read-only flags, base hash, disk revision,
duplicate file/document identities, earlier-target replacement and 1 KiB framing.
A held worker verifies actual join-before-release in the controller. Journalled
issuance, actual Emacs mutation and receipt/rollback remain outside this model.

### Journalled native issuance and quiescence (2026-10-28)

`proof/run_tlc.sh --edit-issuance` checks `KarguEditIssuance` / `EditIssuanceMC`.
Two already authorized/preflighted edit identities share one writer fence.
Recording, sync, actual joins, dispatch, revocation, explicit receipt/quiescence,
settlement and connection retirement are distinct transitions. A signal alone
cannot free issued ownership. Cleanup IO retains the reservation until its real
join. After EOF no new token may be delivered, and unfinished external activity
can remain unconfirmed while the native connection records unknown and retires.

The exhaustive scan completes 1,631 generated / 440 distinct states, depth 15,
with an empty queue. Releasing an issued claim on revoke violates
`HoldIssuedUntilReceipt` after 53 distinct states; omitting sync evidence violates
`JournalBeforeDispatch` after 24. This model composes native resource stages and
assumes a truthful quiescence input. It does not prove an external Emacs handler
stopped on EOF or a platform fence across connection epochs. Actual IO fixtures
check cross-process file locks, sync-before-token, nonce/scope/revision/replay,
retired-owner settlement, failed settlement and EOF unknown; held controller
completions check real join and timeout retention. Existing v1 journal payloads
without nonce/fingerprint fields retain their old integrity bytes, verified with
an independently encoded legacy record chain.
