--------------------------- MODULE KarguCircuit ---------------------------
(***************************************************************************)
(* Formal specification of Kargu Circuit Breaker and API Classification.   *)
(* Faithfully mirrors:                                                     *)
(*   - `kargu/api/circuit.el`  (State machine, thresholds, transitions)     *)
(*   - `kargu/loop/machine.el` (Response classification events)            *)
(***************************************************************************)

EXTENDS Naturals, Sequences, FiniteSets, TLC, KarguContract

(***************************************************************************)
(* Circuit States & Configuration                                          *)
(***************************************************************************)

(* HALF_OPEN is unclaimed; PROBING is HALF_OPEN with probe-inflight true. *)
CircuitStates == {"CLOSED", "OPEN", "HALF_OPEN", "PROBING"}

(***************************************************************************)
(* Circuit Breaker Transitions (Pure Functional Model)                     *)
(***************************************************************************)

CircuitAllowRequest(cState) ==
    cState \notin {"OPEN", "PROBING"}

CircuitClaimProbe(cState) ==
    IF cState = "HALF_OPEN" THEN "PROBING" ELSE cState

CircuitReleaseProbe(cState) ==
    IF cState = "PROBING" THEN "HALF_OPEN" ELSE cState

CircuitRecordSuccess ==
    [state |-> "CLOSED", failures |-> 0]

CircuitRecordFailure(cState, cFailures, threshold) ==
    LET newFailures == cFailures + 1
    IN IF cState \in {"HALF_OPEN", "PROBING"} \/ newFailures >= threshold
       THEN [state |-> "OPEN", failures |-> newFailures]
       ELSE [state |-> cState, failures |-> newFailures]

CircuitCooldownCanary(cState, cFailures) ==
    IF cState = "OPEN"
    THEN [state |-> "HALF_OPEN", failures |-> cFailures]
    ELSE [state |-> cState,      failures |-> cFailures]

(***************************************************************************)
(* Response classification events (mirror `kargu-loop--classify-response'  *)
(* in `kargu/loop/machine.el', in the order the classifier tries them).    *)
(*                                                                         *)
(*   stale             the run was stopped meanwhile: nothing happens      *)
(*   overflow          context window exceeded: compact once, else recover *)
(*   tools-unsupported the provider refused tool use                       *)
(*   error             terminal transport/other error: the user decides     *)
(*   content-filter    the provider blocked the reply: the user decides    *)
(*   tools / length / answer / empty                                       *)
(***************************************************************************)

ClassificationEvents == {
    "stale", "overflow", "tools-unsupported", "error",
    "content-filter", "tools", "length", "answer", "thought", "empty"
}

=============================================================================
