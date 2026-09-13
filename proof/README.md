# Kargu TLA+ Formal Specification & Verification System

This directory contains the formal TLA+ modular specification and model-checking configuration for the Kargu autonomous agent system. It provides mathematical proof and exhaustive verification of Kargu's state transitions, contract-driven ingress/egress boundaries, protocol firewall invariants, circuit breaker lifecycle, self-healing, history compaction, and asynchronous user cancellation handling.

---

## 1. Modular Architecture

The formal specification directly mirrors Kargu's Elisp modular architecture:

```
proof/
├── KarguContract.tla   # Boundary contracts, type predicates, ROP Result types, ingress assertions
├── KarguProtocol.tla   # LLM protocol firewall, history validation, and turn transformations
├── KarguCircuit.tla    # Circuit breaker state machine (:closed, :open, :half-open), error classification
├── KarguTools.tla      # Tool queue, mode safety gating, and doom-loop detection (3-signature lock)
├── KarguState.tla      # Centralized state store, pure selectors, lifecycle transitions, and busy invariants
├── KarguLoop.tla       # Top-level orchestrator composing submodules with strict ingress/egress contracts
├── KarguLoop.cfg       # Base model checker configuration
├── MC.tla              # Model checking wrapper with realistic parameters and state bounds
├── MC.cfg              # Model checking configuration for exhaustive invariant verification
├── run_tlc.sh          # Executable runner script for TLC model checker
└── README.md           # Formal verification documentation (this file)
```

---

## 2. Architecture & Elisp Source Mapping

| TLA+ Module | Corresponding Elisp Source | System Role & Verified Invariants |
|---|---|---|
| `KarguContract.tla` | [kargu/contract.el](file:///home/emrehan/.emacs.local/kargu/kargu/contract.el)<br>[kargu/result.el](file:///home/emrehan/.emacs.local/kargu/kargu/result.el)<br>[kargu/constants.el](file:///home/emrehan/.emacs.local/kargu/kargu/constants.el) | Role types (`system`, `user`, `assistant`, `tool`), mode definitions, contract predicates (`ContractMode`, `ContractRole`, `ContractToolCall`, `ContractMessage`, `ContractHistory`), Railway-Oriented Programming (`Ok`, `Err`), and Ingress Assertions (`AssertIngress`). |
| `KarguProtocol.tla` | [kargu/history.el](file:///home/emrehan/.emacs.local/kargu/kargu/history.el)<br>[kargu/history/compact.el](file:///home/emrehan/.emacs.local/kargu/kargu/history/compact.el) | Protocol firewall invariants (`ProtocolFirewallValid`), history repair (`ValidateHistory`), orphan tool dropping, user turn merging, and compaction transformations (`ApplyCompaction`). |
| `KarguCircuit.tla` | [kargu/api/circuit.el](file:///home/emrehan/.emacs.local/kargu/kargu/api/circuit.el)<br>[kargu/api/response.el](file:///home/emrehan/.emacs.local/kargu/kargu/api/response.el) | Circuit breaker 3-state machine (`CLOSED`, `OPEN`, `HALF_OPEN`), consecutive failure thresholding (`CircuitRecordFailure`), canary recovery (`CircuitCooldownCanary`), and API response event classification. |
| `KarguTools.tla` | [kargu/loop/tools.el](file:///home/emrehan/.emacs.local/kargu/kargu/loop/tools.el)<br>[kargu/loop/heal.el](file:///home/emrehan/.emacs.local/kargu/kargu/loop/heal.el) | Tool execution queue, mode safety gate (`GateToolAllowed`: mutating tools forbidden in non-mutating modes), doom-loop detection (3 consecutive identical calls), and LSP diagnostics post-edit healing. |
| `KarguState.tla` | [kargu/state/store.el](file:///home/emrehan/.emacs.local/kargu/kargu/state/store.el)<br>[kargu/state/selectors.el](file:///home/emrehan/.emacs.local/kargu/kargu/state/selectors.el)<br>[kargu/state/transitions.el](file:///home/emrehan/.emacs.local/kargu/kargu/state/transitions.el)<br>[kargu/state/hooks.el](file:///home/emrehan/.emacs.local/kargu/kargu/state/hooks.el) | Centralized state store, pure selectors (`GetStatus`, `GetMode`, `GetBusy`, etc.), lifecycle transitions (`TransitionStatus`, `TransitionMode`, `TransitionProvider`, `TransitionModel`, `TransitionEffort`), cumulative token counters, and busy coherence invariant (`StateInvariant`). |
| `KarguLoop.tla` | [kargu/loop.el](file:///home/emrehan/.emacs.local/kargu/kargu/loop.el)<br>[kargu/loop/machine.el](file:///home/emrehan/.emacs.local/kargu/kargu/loop/machine.el) | Composed state machine (`IDLE`, `REQUEST`, `WAIT_MODEL`, `EXEC_TOOLS`, `VERIFY_FILES`, `COMPACT_WAIT`, `DONE`, `ERROR`, `STOPPED`) enforcing strict Ingress Assertions and Egress post-conditions on all actions. |

---

## 3. Strict Ingress & Egress Contracts

Every action enforces mathematical pre-conditions and post-conditions matching the Elisp contracts:

1. **`SetMode(m)`:**
   - **Ingress:** `AssertIngress(ContractMode(m))`
   - **Egress:** Mode is updated; execution state preserved.
2. **`StartRun(prompt)`:**
   - **Ingress:** `AssertIngress(ContractPrompt(prompt)) /\ state = "IDLE"`
   - **Egress:** `history' = ValidateHistory(<<sysMsg, usrMsg>>) /\ ContractHistory(history')`
3. **`RequestSend`:**
   - **Ingress:** `state = "REQUEST" /\ AssertIngress(CircuitAllowRequest(circuitState))`
   - **Egress:** `state' = "WAIT_MODEL" /\ ProtocolFirewallValid(history')`
4. **`ModelReceiveToolCalls(calls)`:**
   - **Ingress:** `state = "WAIT_MODEL" /\ AssertIngress(ContractToolCalls(calls) /\ Len(calls) > 0)`
   - **Egress:** `pendingToolQueue' = calls /\ state' = "EXEC_TOOLS" /\ circuitState' = "CLOSED"`
5. **`ExecuteNextTool`:**
   - **Ingress:** `state = "EXEC_TOOLS" /\ AssertIngress(ContractToolCall(Head(queue)))`
   - **Doom Loop Gate:** If 3 consecutive identical calls occur, immediate abort to `ERROR` and queue flush.
   - **Mode Gate:** `GateToolAllowed(call.name, activeMode)`. If forbidden, returns error result without touching filesystem.
   - **Egress:** `ContractMessage(toolResultMsg) /\ history' = history \o <<toolResultMsg>>`
6. **`VerifyFiles(diagnosticError)`:**
   - **Ingress:** `state = "VERIFY_FILES" /\ pendingVerifyFiles # {}`
   - **Egress:** If error and `healing < MaxHealing`, increments `healing` and continues; returns to `EXEC_TOOLS` if queue remains, or `REQUEST` if queue is drained.
7. **`UserStop` (Asynchronous Cancellation):**
   - **Ingress:** `state \in {"WAIT_MODEL", "EXEC_TOOLS", "VERIFY_FILES"}`
   - **Egress:** `ValidateHistory` flushes all pending tool calls with synthetic errors, guaranteeing `AllToolCallsAnswered(history') /\ state' = "STOPPED"`.

---

## 4. Verified Safety Invariants

TLC exhaustively verifies that the following 11 invariants hold across all reachable states:

1. **`TypeOK`**: All variables satisfy their finite domain types and contract bounds.
2. **`Safety_ProtocolFirewallInWaitModel`**: Whenever an HTTP/SSE request is sent to the LLM (`state = "WAIT_MODEL"`), the history strictly satisfies `ProtocolFirewallValid`.
3. **`Safety_ModeSafety`**: In non-mutating modes (`ask`, `plan`, `debug`), mutating tools are gated and `VERIFY_FILES` is **never** entered.
4. **`Safety_SingleCompaction`**: At most one compaction occurs per agent run (`compactions <= 1`).
5. **`Safety_BoundedIterations`**: Model round-trips never exceed `MaxIterations`.
6. **`Safety_InterruptedToolCallsAnswered`**: When canceled by the user (`UserStop`), all assistant tool calls receive synthetic results.
7. **`Safety_AllTerminalStatesAnswered`**: In all terminal states (`DONE`, `ERROR`, `STOPPED`), every assistant tool call is answered.
8. **`Safety_NoToolQueueOutsideExec`**: Outside `EXEC_TOOLS` and `VERIFY_FILES`, `pendingToolQueue` is guaranteed empty.
9. **`Safety_NoPendingVerifyOutsideVerify`**: `pendingVerifyFiles` is empty outside `VERIFY_FILES`.
10. **`Safety_CircuitBreakerSoundness`**: A model request is **never** sent while the circuit breaker is in `OPEN` state (`state = "WAIT_MODEL" => circuitState # "OPEN"`).
11. **`Safety_ContractIntegrity`**: Every message in history satisfies `ContractMessage` at all times.

---

## 5. Model Checker Verification Results

Execute the runner script:

```bash
./proof/run_tlc.sh
```

### Exhaustive Verification Output:
```
TLC2 Version 2.19 of 08 August 2024
Running breadth-first search Model-Checking with 24 workers on 24 cores.
Parsing modules: KarguContract, KarguProtocol, KarguCircuit, KarguTools, KarguLoop, MC
Model checking completed. No error has been found.
296470336 states generated, 42595114 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 40.
Finished in 03min 33s
---------------------------------------------------------------
TLC Model Checking Succeeded: All Protocol & Safety Invariants Verified!
```
