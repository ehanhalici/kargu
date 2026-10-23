---------------------- MODULE KarguDebugExecution ----------------------
EXTENDS Naturals, TLC

\* An execution wait plus its one captured-context child request.
\* Initial paused state is an old cache, not proof of a new command stop.
VARIABLES phase, origin, live, paused, generation, reportGeneration,
          foreign, caller, requests, deliveries, outcome,
          listener, pollTimer, actionTimer, deadlineTimer, childTimer
vars == <<phase, origin, live, paused, generation, reportGeneration,
          foreign, caller, requests, deliveries, outcome,
          listener, pollTimer, actionTimer, deadlineTimer, childTimer>>
Init == /\ phase = "running" /\ origin = TRUE /\ live = TRUE /\ paused = TRUE
        /\ generation = 0 /\ reportGeneration = 0 /\ foreign = FALSE /\ caller = 0
        /\ requests = 0 /\ deliveries = 0 /\ outcome = "pending"
        /\ listener = TRUE /\ pollTimer = TRUE /\ actionTimer = TRUE
        /\ deadlineTimer = TRUE /\ childTimer = FALSE
Pending == phase \in {"running", "reporting"}
Fresh == origin /\ live /\ paused /\ generation = reportGeneration

OwnedStop ==
    /\ Pending /\ origin /\ live /\ generation < 3
    /\ generation' = generation + 1 /\ paused' = TRUE
    /\ phase' = IF phase = "running" THEN "reporting" ELSE phase
    /\ reportGeneration' = IF phase = "running" THEN generation + 1 ELSE reportGeneration
    /\ requests' = IF phase = "running" THEN requests + 1 ELSE requests
    /\ childTimer' = TRUE
    /\ UNCHANGED <<origin, live, foreign, caller, deliveries, outcome,
                    listener, pollTimer, actionTimer, deadlineTimer>>
OwnedContinue ==
    /\ Pending /\ origin /\ live /\ generation < 3
    /\ generation' = generation + 1 /\ paused' = FALSE
    /\ UNCHANGED <<phase, origin, live, reportGeneration, foreign, caller,
                    requests, deliveries, outcome, listener, pollTimer,
                    actionTimer, deadlineTimer, childTimer>>
ForeignEvent ==
    /\ Pending /\ foreign' = ~foreign
    /\ UNCHANGED <<phase, origin, live, paused, generation, reportGeneration,
                    caller, requests, deliveries, outcome, listener, pollTimer,
                    actionTimer, deadlineTimer, childTimer>>
SwitchCaller ==
    /\ Pending /\ caller' = 1 - caller
    /\ UNCHANGED <<phase, origin, live, paused, generation, reportGeneration,
                    foreign, requests, deliveries, outcome, listener, pollTimer,
                    actionTimer, deadlineTimer, childTimer>>
ReassignOrigin ==
    /\ Pending /\ origin /\ origin' = FALSE
    /\ UNCHANGED <<phase, live, paused, generation, reportGeneration, foreign,
                    caller, requests, deliveries, outcome, listener, pollTimer,
                    actionTimer, deadlineTimer, childTimer>>
DropConnection ==
    /\ Pending /\ live /\ live' = FALSE
    /\ UNCHANGED <<phase, origin, paused, generation, reportGeneration, foreign,
                    caller, requests, deliveries, outcome, listener, pollTimer,
                    actionTimer, deadlineTimer, childTimer>>
Finish(result) ==
    /\ Pending /\ phase' = "done" /\ outcome' = result
    /\ deliveries' = deliveries + 1
    /\ listener' = FALSE /\ pollTimer' = FALSE /\ actionTimer' = FALSE
    /\ deadlineTimer' = FALSE /\ childTimer' = FALSE
    /\ UNCHANGED <<origin, live, paused, generation, reportGeneration,
                    foreign, caller, requests>>
Reply == phase = "reporting" /\ Finish(IF Fresh THEN "paused" ELSE "unavailable")
OwnedExit == origin /\ Finish("exited")
PollInvalid == (~origin \/ ~live) /\ Finish("unavailable")
ActionDeadline == phase = "running" /\ origin /\ live /\ Finish("running")
FullDeadline == Finish("timeout")
Cancel ==
    /\ Pending /\ phase' = "cancelled"
    /\ listener' = FALSE /\ pollTimer' = FALSE /\ actionTimer' = FALSE
    /\ deadlineTimer' = FALSE /\ childTimer' = FALSE
    /\ UNCHANGED <<origin, live, paused, generation, reportGeneration,
                    foreign, caller, requests, deliveries, outcome>>
LateEvent == /\ ~Pending /\ UNCHANGED vars
Next == OwnedStop \/ OwnedContinue \/ ForeignEvent \/ SwitchCaller
        \/ ReassignOrigin \/ DropConnection \/ Reply \/ OwnedExit
        \/ PollInvalid \/ ActionDeadline \/ FullDeadline \/ Cancel \/ LateEvent
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in {"running", "reporting", "done", "cancelled"}
    /\ origin \in BOOLEAN /\ live \in BOOLEAN /\ paused \in BOOLEAN
    /\ generation \in 0..3 /\ reportGeneration \in 0..3
    /\ foreign \in BOOLEAN /\ caller \in 0..1
    /\ requests \in 0..1 /\ deliveries \in 0..1
    /\ outcome \in {"pending", "paused", "exited", "running", "unavailable", "timeout"}
    /\ listener \in BOOLEAN /\ pollTimer \in BOOLEAN /\ actionTimer \in BOOLEAN
    /\ deadlineTimer \in BOOLEAN /\ childTimer \in BOOLEAN
Safety_OwnedReport == outcome = "paused" => Fresh /\ requests = 1 /\ reportGeneration > 0
Safety_OwnedExit == outcome = "exited" => origin
Safety_NoOldStop == phase = "reporting" => reportGeneration > 0 /\ requests = 1
Safety_CancelledSilent == phase = "cancelled" => deliveries = 0
Safety_ClosedResources == ~Pending => ~listener /\ ~pollTimer /\ ~actionTimer
                                      /\ ~deadlineTimer /\ ~childTimer
=============================================================================
