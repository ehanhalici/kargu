# Kargu TLA+ specification

This directory holds the TLA+ specification of Kargu's agent loop and protocol wall, and the TLC configuration that checks it. The specification follows the Elisp code; when a transition changes in the code, the specification changes with it (`skills.md`).

The check is exhaustive over a bounded model. It is a proof for those bounds, not for every parameter value.

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

`KarguApproval.tla` / `ApprovalMC.cfg` refine one captured permission operation.
Run `proof/run_tlc.sh --approval` for an exhaustive scan. Eight independent
authority checks can become stale before or after approval; approval is claimed
before entering its continuation, and cancellation prevents later starts.
The 2026-10-21 scan explored 8,194 generated states, 1,536 distinct states,
depth 11, with no error. ERT covers directory replacement, owner closure,
environment/policy changes, reentrant and duplicate decisions, and cancellation
of only the owned UI prompt. This is not a proof of shell analysis, OS isolation,
exactly-once external effects or filesystem compare-and-swap.

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
| `MaxUpstreamRetries` | 1 |
| `CompactionThreshold` | 4 |
| `CompactKeepCount` | 3 |
| `CircuitFailureThreshold` | 3 |

`StateConstraint` limits the search to two generations (runs and resets), a history of at most 12 messages and a turn cap of at most `2 * MaxIterations`.

### Result of the last run

Run on 2026-10-18 with TLC 2.19, 24 workers:

```
Model checking completed. No error has been found.
729094900 states generated, 85318093 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 43.
Finished in 10min 02s
```

Changing a guard breaks the check: with the `~noTools` guard removed from `ModelReceiveToolCalls`, a simulation reports `Safety_ToolsOffMeansNoToolWork` violated within a second. The numbers above are those of a real run; repeat it after every change to the specification and replace them.
