----------------------------- MODULE KarguMode -----------------------------
EXTENDS Naturals, FiniteSets

\* A preparation never publishes its mode until its captured owner is current
\* and application admission is still idle.  Callback caller is irrelevant.
CONSTANT Owners
VARIABLES epoch, mode, intent, pending, captured, delivered, work, frozen
vars == <<epoch, mode, intent, pending, captured, delivered, work, frozen>>
Intents == Owners \X (1..2)
Init == /\ epoch = [o \in Owners |-> 0]
        /\ mode = [o \in Owners |-> "ask"]
        /\ intent = [o \in Owners |-> 0]
        /\ pending = {}
        /\ captured = [i \in Intents |-> 0]
        /\ delivered = [i \in Intents |-> 0]
        /\ work = {} /\ frozen = [o \in Owners |-> "ask"]

Prepare(o) ==
    /\ work = {} /\ intent[o] < 2
    /\ LET i == <<o, intent[o] + 1>> IN
       /\ intent' = [intent EXCEPT ![o] = @ + 1]
       /\ pending' = (pending \ {j \in Intents : j[1] = o}) \cup {i}
       /\ captured' = [captured EXCEPT ![i] = epoch[o]]
    /\ UNCHANGED <<epoch, mode, delivered, work, frozen>>

Ready(i, caller) ==
    /\ caller \in Owners /\ i \in pending
    /\ pending' = pending \ {i}
    /\ delivered' = [delivered EXCEPT ![i] = @ + 1]
    /\ mode' = IF epoch[i[1]] = captured[i] /\ work = {}
                    /\ intent[i[1]] = i[2]
               THEN [mode EXCEPT ![i[1]] = "agent"] ELSE mode
    /\ UNCHANGED <<epoch, intent, captured, work, frozen>>

Invalidate(o) ==
    /\ epoch[o] = 0 /\ epoch' = [epoch EXCEPT ![o] = 1]
    /\ pending' = pending \ {i \in Intents : i[1] = o}
    /\ UNCHANGED <<mode, intent, captured, delivered, work, frozen>>

Start(o) == /\ work = {} /\ work' = {o} /\ frozen' = mode
            /\ UNCHANGED <<epoch, mode, intent, pending, captured, delivered>>
Finish == /\ work # {} /\ work' = {}
          /\ UNCHANGED <<epoch, mode, intent, pending, captured, delivered, frozen>>
Next == (\E o \in Owners : Prepare(o) \/ Invalidate(o) \/ Start(o))
        \/ (\E i \in Intents, caller \in Owners : Ready(i, caller)) \/ Finish
Spec == Init /\ [][Next]_vars
TypeOK == /\ epoch \in [Owners -> 0..1]
          /\ mode \in [Owners -> {"ask", "agent"}]
          /\ intent \in [Owners -> 0..2]
          /\ pending \subseteq Intents
          /\ captured \in [Intents -> 0..1]
          /\ delivered \in [Intents -> 0..1]
          /\ work \subseteq Owners /\ Cardinality(work) <= 1
          /\ frozen \in [Owners -> {"ask", "agent"}]
FrozenDuringWork == work # {} => mode = frozen
CurrentPending == \A i \in pending : intent[i[1]] = i[2]
=============================================================================
