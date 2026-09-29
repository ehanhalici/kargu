# Kargu TLA+ specification

This directory holds the TLA+ specification of Kargu's agent loop and protocol wall, and the TLC configuration that checks it. The specification follows the Elisp code; when a transition changes in the code, the specification changes with it (`skills.md`).

The check is exhaustive over a bounded model. It is a proof for those bounds, not for every parameter value.

## 1. Modules

```
proof/
├── KarguContract.tla   # Roles, modes, message schema, contract predicates
├── KarguProtocol.tla   # The protocol wall (repair order) and compaction
├── KarguCircuit.tla    # Circuit breaker; response classification events
├── KarguTools.tla      # Mode gate; doom-loop signatures
├── KarguState.tla      # State store statuses; busy and run-live classes
├── KarguLoop.tla       # The loop: states, actions, safety invariants
├── MC.tla / MC.cfg     # TLC harness: parameters, invariants, deadlock check
├── run_tlc.sh          # Exhaustive scan (default) or --simulate
└── README.md           # This file
```

| TLA+ module | Elisp source | What it states |
|---|---|---|
| `KarguContract.tla` | `kargu/contract/{constants,types,assert,result}.el` | Roles, modes, tool names, `ContractMessage`, `ContractHistory`, ingress assertions. |
| `KarguProtocol.tla` | `kargu/history/{repair,protocol,compact}.el` | `ValidateHistory` in the code's order, `ProtocolFirewallValid`, `ApplyCompaction`. |
| `KarguCircuit.tla` | `kargu/api/circuit.el`, `kargu/loop/machine.el` | Breaker transitions and the ten response events. |
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

Response path (`kargu/loop--on-response`): `ModelReceiveAnswer`, `ModelReceiveToolCalls`, `ModelReceiveLengthTruncated`, `ModelReceiveOverflow`, `ModelReceiveEmpty`, `ModelReceiveUpstreamError` (retryable), `ModelReceiveError` (other failures and the content filter), `ModelReceiveToolsUnsupported`.

Tools and healing: `ExecuteNextTool`, `DoomApprove`, `DoomStop`, `VerifyFiles`. An edit is verified only while healing rounds remain; with the budget spent the run goes on.

Also: `StartRun`, `FollowUpPrompt`, `SetMode` (only while no run is live), `ResetSession`, `CompactionFinish` (a failed or empty summary ends the run in `ERROR`), `UserStop` (from any live state; the finish repairs the history), `CircuitCooldownCanaryAction`.

### The protocol wall

`ValidateHistory(hist, fix)` follows `kargu--validate-history`:

1. take the head system message out (create one if missing) and drop every other system message;
2. one forward scan drops orphan tool results and, when any other turn arrives, flushes the calls still open with a synthetic result, in call order;
3. merge consecutive user turns, merge consecutive assistant text turns and fold a text turn into the assistant turn with calls after it;
4. only then, when `fix = "strip"`, remove trailing assistant turns.

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

Run on 2026-09-29 with TLC 2.19, 24 workers:

```
Model checking completed. No error has been found.
295099059 states generated, 62445693 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 43.
Finished in 04min 46s
```

Changing a guard breaks the check: with the `~noTools` guard removed from `ModelReceiveToolCalls`, a simulation reports `Safety_ToolsOffMeansNoToolWork` violated within a second. The numbers above are those of a real run; repeat it after every change to the specification and replace them.
