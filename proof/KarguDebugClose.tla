-------------------------- MODULE KarguDebugClose --------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Owned, Foreign
Resources == Owned \cup Foreign
VARIABLES phase, operation, released, deliveries
vars == <<phase, operation, released, deliveries>>
Init == /\ phase = [r \in Resources |-> "open"] /\ operation = "idle"
        /\ released = [r \in Resources |-> 0] /\ deliveries = 0
Start(kind) == /\ operation = "idle" /\ kind \in {"terminating", "disconnecting"}
               /\ operation' = "pending"
               /\ phase' = [r \in Resources |-> IF r \in Owned THEN kind ELSE phase[r]]
               /\ UNCHANGED <<released, deliveries>>
Fallback(r) == /\ operation = "pending" /\ r \in Owned /\ phase[r] = "terminating"
               /\ phase' = [phase EXCEPT ![r] = "disconnecting"]
               /\ UNCHANGED <<operation, released, deliveries>>
Ack(r) == /\ operation = "pending" /\ r \in Owned
          /\ phase[r] \in {"terminating", "disconnecting"}
          /\ phase' = [phase EXCEPT ![r] = "releasing"]
          /\ UNCHANGED <<operation, released, deliveries>>
Release(r) == /\ r \in Owned /\ phase[r] = "releasing"
              /\ phase' = [phase EXCEPT ![r] = "closed"]
              /\ released' = [released EXCEPT ![r] = @ + 1]
              /\ UNCHANGED <<operation, deliveries>>
Complete == /\ operation = "pending" /\ \A r \in Owned : phase[r] = "closed"
            /\ operation' = "done" /\ deliveries' = deliveries + 1
            /\ UNCHANGED <<phase, released>>
Stop(kind) ==
    /\ operation = "pending" /\ kind \in {"cancelled", "deadline"}
    /\ operation' = kind /\ deliveries' = IF kind = "deadline" THEN 1 ELSE 0
    /\ phase' = [r \in Resources |-> IF r \in Owned THEN "closed" ELSE phase[r]]
    /\ released' = [r \in Resources |-> IF r \in Owned THEN 1 ELSE released[r]]
Late == /\ operation \in {"done", "cancelled", "deadline"} /\ UNCHANGED vars
Next == (\E kind \in {"terminating", "disconnecting"} : Start(kind))
        \/ (\E r \in Owned : Ack(r) \/ Fallback(r) \/ Release(r))
        \/ Complete \/ (\E kind \in {"cancelled", "deadline"} : Stop(kind)) \/ Late
Spec == Init /\ [][Next]_vars
TypeOK == /\ phase \in [Resources -> {"open", "terminating", "disconnecting", "releasing", "closed"}]
          /\ operation \in {"idle", "pending", "done", "cancelled", "deadline"}
          /\ released \in [Resources -> 0..1] /\ deliveries \in 0..1
ForeignUntouched == \A r \in Foreign : phase[r] = "open" /\ released[r] = 0
CallbackAfterRelease == deliveries = 1 => \A r \in Owned : phase[r] = "closed"
SilentCancellation == operation = "cancelled" => deliveries = 0
=============================================================================
