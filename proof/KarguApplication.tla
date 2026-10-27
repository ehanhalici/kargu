------------------------- MODULE KarguApplication -------------------------
EXTENDS Naturals, FiniteSets

\* Labels may be reused; authority is the application/claim tuple instead.
CONSTANT Apps
Claims == Apps \X (1..2)
PreparationParts == {"project", "connection", "skills"}
VARIABLES phase, epoch, request, resources, delivered, prepared
vars == <<phase, epoch, request, resources, delivered, prepared>>

Init == /\ phase = [a \in Apps |-> "idle"]
        /\ epoch = [a \in Apps |-> 0]
        /\ request = [a \in Apps |-> 0]
        /\ resources = [a \in Apps |-> {}]
        /\ delivered = [c \in Claims |-> 0]
        /\ prepared = [a \in Apps |-> {}]

Claim(a) ==
    /\ phase[a] = "idle" /\ epoch[a] < 2
    /\ phase' = [phase EXCEPT ![a] = "preparing"]
    /\ epoch' = [epoch EXCEPT ![a] = @ + 1]
    /\ request' = [request EXCEPT ![a] = epoch[a] + 1]
    /\ resources' = [resources EXCEPT ![a] = {"process", "timer", "task", "prompt"}]
    /\ prepared' = [prepared EXCEPT ![a] = {}]
    /\ UNCHANGED delivered

\* Project probes, connection and skills complete under one captured claim. A model
\* without tools uses a no-work skills completion with the same ordering.
PreparationReady(c, part, caller) ==
    /\ caller \in Apps /\ part \in PreparationParts
    /\ phase[c[1]] = "preparing" /\ epoch[c[1]] = c[2]
    /\ request[c[1]] = c[2] /\ part \notin prepared[c[1]]
    /\ (part = "project" \/ "project" \in prepared[c[1]])
    /\ (part # "skills" \/ "connection" \in prepared[c[1]])
    /\ prepared' = [prepared EXCEPT ![c[1]] = @ \cup {part}]
    /\ UNCHANGED <<phase, epoch, request, resources, delivered>>

Prepared(a) ==
    /\ phase[a] = "preparing"
    /\ prepared[a] = PreparationParts
    /\ phase' = [phase EXCEPT ![a] = "running"]
    /\ UNCHANGED <<epoch, request, resources, delivered, prepared>>

BeginClose(a) ==
    /\ phase[a] \in {"preparing", "running"}
    /\ phase' = [phase EXCEPT ![a] = "closing"]
    /\ UNCHANGED <<epoch, request, resources, delivered, prepared>>

BeginReset(a) ==
    /\ phase[a] \in {"preparing", "running", "idle"}
    /\ phase' = [phase EXCEPT ![a] = "resetting"]
    /\ UNCHANGED <<epoch, request, resources, delivered, prepared>>

Drain(a) ==
    /\ phase[a] \in {"closing", "resetting"}
    /\ resources' = [resources EXCEPT ![a] = {}]
    /\ request' = [request EXCEPT ![a] = 0]
    /\ prepared' = [prepared EXCEPT ![a] = {}]
    /\ UNCHANGED <<phase, epoch, delivered>>

Release(a) ==
    /\ phase[a] \in {"closing", "resetting"}
    /\ resources[a] = {} /\ request[a] = 0
    /\ phase' = [phase EXCEPT ![a] = "idle"]
    /\ UNCHANGED <<epoch, request, resources, delivered, prepared>>

Deliver(c, caller) ==
    /\ caller \in Apps
    /\ phase[c[1]] = "running" /\ epoch[c[1]] = c[2]
    /\ request[c[1]] = c[2] /\ delivered[c] = 0
    /\ delivered' = [delivered EXCEPT ![c] = 1]
    /\ UNCHANGED <<phase, epoch, request, resources, prepared>>

Next == (\E a \in Apps : Claim(a) \/ Prepared(a) \/ BeginClose(a) \/ BeginReset(a) \/ Drain(a) \/ Release(a))
        \/ (\E c \in Claims, caller \in Apps : Deliver(c, caller))
        \/ (\E c \in Claims, part \in PreparationParts, caller \in Apps : PreparationReady(c, part, caller))
Spec == Init /\ [][Next]_vars
TypeOK == /\ phase \in [Apps -> {"idle", "preparing", "running", "closing", "resetting"}]
          /\ epoch \in [Apps -> 0..2] /\ request \in [Apps -> 0..2]
          /\ resources \in [Apps -> SUBSET {"process", "timer", "task", "prompt"}]
          /\ delivered \in [Claims -> 0..1]
          /\ prepared \in [Apps -> SUBSET PreparationParts]
IdleOwnsNothing == \A a \in Apps : phase[a] = "idle" => resources[a] = {} /\ request[a] = 0
CurrentRequest == \A a \in Apps : request[a] # 0 => request[a] = epoch[a]
RunningPrepared == \A a \in Apps : phase[a] = "running" => prepared[a] = PreparationParts
PreparationOrder == \A a \in Apps :
    /\ ("skills" \in prepared[a] => "connection" \in prepared[a])
    /\ ("connection" \in prepared[a] => "project" \in prepared[a])
=============================================================================
