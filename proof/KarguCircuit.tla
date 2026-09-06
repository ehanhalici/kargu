--------------------------- MODULE KarguCircuit ---------------------------
(***************************************************************************)
(* Formal specification of Kargu Circuit Breaker and API Classification.   *)
(* Faithfully mirrors:                                                     *)
(*   - `kargu/api/circuit.el`  (State machine, thresholds, transitions)     *)
(*   - `kargu/api/response.el` (Response shapes, classification)           *)
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
(* API Response Classification Events (Mirrors `kargu-loop--classify')     *)
(***************************************************************************)

ClassificationEvents == {
    "tools",        \* Response contains assistant tool calls
    "answer",       \* Final assistant textual answer
    "error",        \* Upstream API error message
    "length",       \* Truncated by token limit; can continue
    "overflow",     \* Context window overflowed; triggers compaction
    "empty",        \* Empty content returned
    "upstream"      \* 502/503/network failure; triggers circuit record failure
}

=============================================================================
