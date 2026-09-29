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

CircuitStates == {"CLOSED", "OPEN", "HALF_OPEN"}

(***************************************************************************)
(* Circuit Breaker Transitions (Pure Functional Model)                     *)
(***************************************************************************)

CircuitAllowRequest(cState) ==
    cState # "OPEN"

CircuitRecordSuccess ==
    [state |-> "CLOSED", failures |-> 0]

CircuitRecordFailure(cState, cFailures, threshold) ==
    LET newFailures == cFailures + 1
    IN IF cState = "HALF_OPEN" \/ newFailures >= threshold
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
(*   upstream-retry    retryable error with retries left                   *)
(*   error             any other error: the user decides                   *)
(*   content-filter    the provider blocked the reply: the user decides    *)
(*   tools / length / answer / empty                                       *)
(***************************************************************************)

ClassificationEvents == {
    "stale", "overflow", "tools-unsupported", "upstream-retry", "error",
    "content-filter", "tools", "length", "answer", "empty"
}

=============================================================================
