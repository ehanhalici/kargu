------------------------- MODULE KarguVerification -------------------------
EXTENDS Naturals, TLC

\* One two-file verification task, with captured original change records.
\* 0 = absent, 1 = captured edit identity, 2 = a newer edit identity.
Files == {0, 1}
VARIABLES phase, records, replaced, cursor, caller, deliveries, outcome, nextWork
vars == <<phase, records, replaced, cursor, caller, deliveries, outcome, nextWork>>
Init == /\ phase = "waiting" /\ records = [f \in Files |-> 1]
        /\ replaced = {} /\ cursor = 0 /\ caller = 0
        /\ deliveries = 0 /\ outcome = "pending" /\ nextWork = FALSE
Clean(source) == [f \in Files |-> IF source[f] = 1 THEN 0 ELSE source[f]]
NewEdit(f) ==
    /\ f \notin replaced
    /\ records' = [records EXCEPT ![f] = 2] /\ replaced' = replaced \cup {f}
    /\ UNCHANGED <<phase, cursor, caller, deliveries, outcome, nextWork>>
SwitchCaller ==
    /\ caller' = 1 - caller
    /\ UNCHANGED <<phase, records, replaced, cursor, deliveries, outcome, nextWork>>
Reply(f) ==
    /\ phase = "waiting" /\ f = cursor /\ cursor < 2
    /\ cursor' = cursor + 1
    /\ phase' = IF cursor = 1 THEN "done" ELSE phase
    /\ records' = IF cursor = 1 THEN Clean(records) ELSE records
    /\ deliveries' = IF cursor = 1 THEN deliveries + 1 ELSE deliveries
    /\ outcome' = IF cursor = 1 THEN "collected" ELSE outcome
    /\ UNCHANGED <<replaced, caller, nextWork>>
Failure ==
    /\ phase = "waiting" /\ phase' = "done" /\ records' = Clean(records)
    /\ deliveries' = deliveries + 1 /\ outcome' = "unavailable"
    /\ UNCHANGED <<replaced, cursor, caller, nextWork>>
Cancel ==
    /\ phase = "waiting" /\ phase' = "cancelled" /\ records' = Clean(records)
    /\ UNCHANGED <<replaced, cursor, caller, deliveries, outcome, nextWork>>
NextWork ==
    /\ phase = "done" /\ ~nextWork
    /\ nextWork' = TRUE /\ records' = [records EXCEPT ![0] = 2]
    /\ replaced' = replaced \cup {0}
    /\ UNCHANGED <<phase, cursor, caller, deliveries, outcome>>
RepeatCleanup ==
    /\ phase # "waiting" /\ records' = Clean(records)
    /\ UNCHANGED <<phase, replaced, cursor, caller, deliveries, outcome, nextWork>>
LateReply(f) ==
    /\ (phase # "waiting" \/ f # cursor) /\ UNCHANGED vars
Next == (\E f \in Files : NewEdit(f) \/ Reply(f) \/ LateReply(f))
        \/ SwitchCaller \/ Failure \/ Cancel \/ NextWork \/ RepeatCleanup
Spec == Init /\ [][Next]_vars

TypeOK == /\ phase \in {"waiting", "done", "cancelled"}
          /\ records \in [Files -> 0..2] /\ replaced \subseteq Files
          /\ cursor \in 0..2 /\ caller \in 0..1 /\ deliveries \in 0..1
          /\ outcome \in {"pending", "collected", "unavailable"}
          /\ nextWork \in BOOLEAN
Safety_NoSignalLeak == phase # "waiting" => \A f \in Files : records[f] # 1
Safety_PreserveNewEdits == \A f \in replaced : records[f] = 2
Safety_Once == /\ (phase = "cancelled" => deliveries = 0)
               /\ (phase = "done" => deliveries = 1)
Safety_CollectedAll == outcome = "collected" => cursor = 2
Safety_NextWorkPreserved == nextWork => records[0] = 2 /\ phase = "done"
=============================================================================
