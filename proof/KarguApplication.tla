------------------------- MODULE KarguApplication -------------------------
EXTENDS Naturals, FiniteSets

\* Labels may be reused; authority is the application/claim tuple instead.
CONSTANT Apps
Claims == Apps \X (1..2)
VARIABLES phase, epoch, request, resources, delivered
vars == <<phase, epoch, request, resources, delivered>>

Init == /\ phase = [a \in Apps |-> "idle"]
        /\ epoch = [a \in Apps |-> 0]
        /\ request = [a \in Apps |-> 0]
        /\ resources = [a \in Apps |-> {}]
        /\ delivered = [c \in Claims |-> 0]

Claim(a) ==
    /\ phase[a] = "idle" /\ epoch[a] < 2
    /\ phase' = [phase EXCEPT ![a] = "preparing"]
    /\ epoch' = [epoch EXCEPT ![a] = @ + 1]
    /\ request' = [request EXCEPT ![a] = epoch[a] + 1]
    /\ resources' = [resources EXCEPT ![a] = {"process", "timer", "task", "prompt"}]
    /\ UNCHANGED delivered

Prepared(a) ==
    /\ phase[a] = "preparing"
    /\ phase' = [phase EXCEPT ![a] = "running"]
    /\ UNCHANGED <<epoch, request, resources, delivered>>

BeginClose(a) ==
    /\ phase[a] \in {"preparing", "running"}
    /\ phase' = [phase EXCEPT ![a] = "closing"]
    /\ UNCHANGED <<epoch, request, resources, delivered>>

BeginReset(a) ==
    /\ phase[a] \in {"preparing", "running", "idle"}
    /\ phase' = [phase EXCEPT ![a] = "resetting"]
    /\ UNCHANGED <<epoch, request, resources, delivered>>

Drain(a) ==
    /\ phase[a] \in {"closing", "resetting"}
    /\ resources' = [resources EXCEPT ![a] = {}]
    /\ request' = [request EXCEPT ![a] = 0]
    /\ UNCHANGED <<phase, epoch, delivered>>

Release(a) ==
    /\ phase[a] \in {"closing", "resetting"}
    /\ resources[a] = {} /\ request[a] = 0
    /\ phase' = [phase EXCEPT ![a] = "idle"]
    /\ UNCHANGED <<epoch, request, resources, delivered>>

Deliver(c, caller) ==
    /\ caller \in Apps
    /\ phase[c[1]] = "running" /\ epoch[c[1]] = c[2]
    /\ request[c[1]] = c[2] /\ delivered[c] = 0
    /\ delivered' = [delivered EXCEPT ![c] = 1]
    /\ UNCHANGED <<phase, epoch, request, resources>>

Next == (\E a \in Apps : Claim(a) \/ Prepared(a) \/ BeginClose(a) \/ BeginReset(a) \/ Drain(a) \/ Release(a))
        \/ (\E c \in Claims, caller \in Apps : Deliver(c, caller))
Spec == Init /\ [][Next]_vars
TypeOK == /\ phase \in [Apps -> {"idle", "preparing", "running", "closing", "resetting"}]
          /\ epoch \in [Apps -> 0..2] /\ request \in [Apps -> 0..2]
          /\ resources \in [Apps -> SUBSET {"process", "timer", "task", "prompt"}]
          /\ delivered \in [Claims -> 0..1]
IdleOwnsNothing == \A a \in Apps : phase[a] = "idle" => resources[a] = {} /\ request[a] = 0
CurrentRequest == \A a \in Apps : request[a] # 0 => request[a] = epoch[a]
=============================================================================
