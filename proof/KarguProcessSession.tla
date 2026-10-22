----------------------- MODULE KarguProcessSession -----------------------
EXTENDS Naturals, TLC

\* Interactive stdin transport only.  Kernel process groups and UTF-8 byte
\* slicing are ERT obligations; a numeric PID is not an ownership proof.
CONSTANT MaxBytes
VARIABLES phase, live, bufferLive, idleLive, graceLive, published,
          deliveries, retained, forced
vars == <<phase, live, bufferLive, idleLive, graceLive, published,
          deliveries, retained, forced>>

Init ==
    /\ phase = "starting" /\ live = FALSE /\ bufferLive = TRUE /\ published = FALSE
    /\ idleLive = FALSE /\ graceLive = FALSE
    /\ deliveries = 0 /\ retained = 0 /\ forced = FALSE

Spawn ==
    /\ phase = "starting" /\ ~live
    /\ live' = TRUE
    /\ UNCHANGED <<phase, bufferLive, idleLive, graceLive, published,
                   deliveries, retained, forced>>

Publish ==
    /\ phase = "starting" /\ live
    /\ phase' = "running" /\ published' = TRUE /\ idleLive' = TRUE
    /\ UNCHANGED <<live, bufferLive, graceLive, deliveries, retained, forced>>

EarlyExit ==
    /\ phase = "starting"
    /\ phase' = "closed" /\ live' = FALSE /\ bufferLive' = FALSE
    /\ published' = TRUE /\ deliveries' = 1
    /\ UNCHANGED <<idleLive, graceLive, retained, forced>>

SpawnFailure ==
    /\ phase = "starting"
    /\ phase' = "closed" /\ live' = FALSE /\ bufferLive' = FALSE
    /\ UNCHANGED <<idleLive, graceLive, published, deliveries, retained, forced>>

Output(n) ==
    /\ phase \in {"running", "closing"} /\ live
    /\ retained' = IF retained + n > MaxBytes THEN MaxBytes ELSE retained + n
    /\ idleLive' = TRUE
    /\ UNCHANGED <<phase, live, bufferLive, graceLive, published, deliveries, forced>>

Close ==
    /\ phase = "running"
    /\ phase' = "closing"
    /\ UNCHANGED <<live, bufferLive, idleLive, graceLive, published,
                   deliveries, retained, forced>>

Interrupt ==
    /\ phase \in {"running", "closing"} /\ live /\ ~graceLive
    /\ phase' = "closing" /\ graceLive' = TRUE /\ idleLive' = FALSE
    /\ UNCHANGED <<live, bufferLive, published, deliveries, retained, forced>>

Force ==
    /\ phase \in {"running", "closing"} /\ live /\ ~forced
    /\ live' = FALSE /\ forced' = TRUE /\ graceLive' = FALSE /\ idleLive' = FALSE
    /\ UNCHANGED <<phase, bufferLive, published, deliveries, retained>>

Exit ==
    /\ phase \in {"running", "closing"} /\ live
    /\ live' = FALSE /\ graceLive' = FALSE /\ idleLive' = FALSE
    /\ UNCHANGED <<phase, bufferLive, published, deliveries, retained, forced>>

Finish ==
    /\ phase \in {"running", "closing"} /\ ~live
    /\ phase' = "closed" /\ bufferLive' = FALSE
    /\ graceLive' = FALSE /\ idleLive' = FALSE /\ deliveries' = 1
    /\ UNCHANGED <<live, published, retained, forced>>

LateForce ==
    /\ ~live
    /\ UNCHANGED vars

Next == Spawn \/ Publish \/ EarlyExit \/ SpawnFailure
        \/ (\E n \in 1..2 : Output(n)) \/ Close \/ Interrupt \/ Force
        \/ Exit \/ Finish \/ LateForce
Spec == Init /\ [][Next]_vars
TypeOK ==
    /\ phase \in {"starting", "running", "closing", "closed"}
    /\ <<live, bufferLive, idleLive, graceLive, published, forced>>
       \in BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN
    /\ deliveries \in 0..1 /\ retained \in 0..MaxBytes
Safety_ClosedResources == phase = "closed" => ~live /\ ~bufferLive /\ ~idleLive /\ ~graceLive
Safety_DeliveryReady == deliveries > 0 => published /\ phase = "closed"
Safety_ForceOwned == forced => published
Safety_ByteBound == retained <= MaxBytes
=============================================================================
