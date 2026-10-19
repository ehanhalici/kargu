----------------------- MODULE KarguDebugStartup -----------------------
EXTENDS Naturals, FiniteSets, TLC

\* One startup intent through probe, approval, compile and final creation.
\* Kargu's task guard owns no compilation process/buffer/finish-hook mutation.
\* Dirty resources abstract an identity different from the captured value.
CONSTANT Resources
VARIABLES phase, dirty, localAdapter, foreignAdapter, caller, probeTimer,
          launches, deliveries, outcome, launchTimer
vars == <<phase, dirty, localAdapter, foreignAdapter, caller, probeTimer,
          launches, deliveries, outcome, launchTimer>>

Init == /\ phase = "probing" /\ dirty = {} /\ localAdapter = FALSE
        /\ foreignAdapter = FALSE /\ caller = 0 /\ probeTimer = TRUE
        /\ launches = 0 /\ deliveries = 0 /\ outcome = "pending"
        /\ launchTimer = FALSE
Pending == phase \in {"probing", "approval", "launching", "compiling"}
Valid == dirty = {} /\ ~localAdapter

Invalidate(resource) ==
    /\ Pending /\ resource \notin dirty
    /\ dirty' = dirty \cup {resource}
    /\ UNCHANGED <<phase, localAdapter, foreignAdapter, caller, probeTimer,
                    launches, deliveries, outcome, launchTimer>>
StartLocal == /\ Pending /\ ~localAdapter /\ localAdapter' = TRUE
              /\ UNCHANGED <<phase, dirty, foreignAdapter, caller, probeTimer,
                              launches, deliveries, outcome, launchTimer>>
ForeignEvent ==
    /\ Pending /\ foreignAdapter' = ~foreignAdapter
    /\ UNCHANGED <<phase, dirty, localAdapter, caller, probeTimer,
                    launches, deliveries, outcome, launchTimer>>
SwitchCaller ==
    /\ Pending /\ caller' = 1 - caller
    /\ UNCHANGED <<phase, dirty, localAdapter, foreignAdapter, probeTimer,
                    launches, deliveries, outcome, launchTimer>>
ProbeReady ==
    /\ phase = "probing" /\ Valid
    /\ phase' = "approval" /\ probeTimer' = FALSE
    /\ UNCHANGED <<dirty, localAdapter, foreignAdapter, caller,
                    launches, deliveries, outcome, launchTimer>>

Finish(result, count) ==
    /\ Pending /\ phase' = "done" /\ probeTimer' = FALSE
    /\ launchTimer' = FALSE
    /\ outcome' = result /\ launches' = count /\ deliveries' = deliveries + 1
    /\ UNCHANGED <<dirty, localAdapter, foreignAdapter, caller>>
ProbeFailure == phase = "probing" /\ Finish("error", 0)
InvalidCallback == ~Valid /\ Finish("error", 0)
Approve == /\ phase = "approval" /\ Valid
           /\ phase' = "launching" /\ launchTimer' = TRUE
           /\ UNCHANGED <<dirty, localAdapter, foreignAdapter, caller,
                           probeTimer, launches, deliveries, outcome>>
Compile == /\ phase = "launching" /\ Valid /\ phase' = "compiling"
           /\ UNCHANGED <<dirty, localAdapter, foreignAdapter, caller,
                           probeTimer, launches, deliveries, outcome, launchTimer>>
Resume == /\ phase = "compiling" /\ Valid /\ phase' = "launching"
          /\ UNCHANGED <<dirty, localAdapter, foreignAdapter, caller,
                          probeTimer, launches, deliveries, outcome, launchTimer>>
Create == phase = "launching" /\ Valid /\ Finish("started", 1)
Reject == phase = "approval" /\ Valid /\ Finish("rejected", 0)
LaunchFailure == phase \in {"launching", "compiling"} /\ Finish("error", 0)
Cancel == /\ Pending /\ phase' = "cancelled" /\ probeTimer' = FALSE
          /\ launchTimer' = FALSE
          /\ UNCHANGED <<dirty, localAdapter, foreignAdapter, caller,
                          launches, deliveries, outcome>>
LateCallback == /\ ~Pending /\ UNCHANGED vars
Next == (\E resource \in Resources : Invalidate(resource))
        \/ StartLocal \/ ForeignEvent \/ SwitchCaller \/ ProbeReady
        \/ ProbeFailure \/ InvalidCallback \/ Approve \/ Reject
        \/ Compile \/ Resume \/ Create \/ LaunchFailure \/ Cancel \/ LateCallback
Spec == Init /\ [][Next]_vars

TypeOK == /\ phase \in {"probing", "approval", "launching", "compiling", "done", "cancelled"}
          /\ dirty \subseteq Resources
          /\ localAdapter \in BOOLEAN /\ foreignAdapter \in BOOLEAN
          /\ caller \in 0..1 /\ probeTimer \in BOOLEAN
          /\ launchTimer \in BOOLEAN
          /\ launches \in 0..1 /\ deliveries \in 0..1
          /\ outcome \in {"pending", "started", "error", "rejected"}
Safety_OwnedLaunch == launches = 1 => Valid /\ outcome = "started"
Safety_Once == launches <= deliveries /\ deliveries <= 1
Safety_CancelledSilent == phase = "cancelled" => launches = 0 /\ deliveries = 0
Safety_ProbeCleanup == ~Pending => ~probeTimer
Safety_LaunchCleanup == ~Pending => ~launchTimer
Safety_NoPrematureSuccess == phase = "compiling" => launches = 0 /\ deliveries = 0
=============================================================================
