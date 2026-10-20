---------------------------- MODULE KarguPlan ----------------------------
EXTENDS Naturals, FiniteSets, TLC

\* kargu/plan/store.el and dispatch.el.  An epoch abstracts a captured
\* project/session pair; changing either invalidates the same owner guard.
\* current[o] represents o's buffer-local authoritative record reference;
\* the review holds a reference to the same record, not another state store.
\* CloseChat/CloseView also abstract change-major-mode-hook cleanup before
\* either buffer loses its local ownership/reference.  Reusing a plan view
\* does not reset its major mode, and remains the Create replacement action.
\* view[p] means a live review referencing p, not just a live buffer.  Create
\* assumes distinct per-owner views; cross-owner reuse is rejected at ingress
\* in Elisp and covered by ERT, rather than modeled as an admitted action.
CONSTANTS Owners, MaxPlans
PlanIds == Owners \X (1..MaxPlans)
States == {"absent", "pending", "dispatching", "approved", "rejected",
           "superseded", "cancelled"}

VARIABLES generation, current, epoch, captured, alive, view, status,
          started, admitted, runLive
vars == <<generation, current, epoch, captured, alive, view, status,
          started, admitted, runLive>>

Init ==
    /\ generation = [o \in Owners |-> 0]
    /\ current = [o \in Owners |-> 0]
    /\ epoch = [o \in Owners |-> 1]
    /\ captured = [p \in PlanIds |-> 1]
    /\ alive = [o \in Owners |-> TRUE]
    /\ view = [p \in PlanIds |-> FALSE]
    /\ status = [p \in PlanIds |-> "absent"]
    /\ started = [p \in PlanIds |-> 0]
    /\ admitted = [p \in PlanIds |-> <<p[1], 1>>]
    /\ runLive = FALSE

Current(p) == alive[p[1]] /\ view[p] /\ current[p[1]] = p[2]
              /\ captured[p] = epoch[p[1]]

Create(o) ==
    /\ alive[o] /\ generation[o] < MaxPlans
    /\ LET next == generation[o] + 1
           p == <<o, next>>
           old == <<o, current[o]>>
       IN /\ generation' = [generation EXCEPT ![o] = next]
          /\ current' = [current EXCEPT ![o] = next]
          /\ captured' = [captured EXCEPT ![p] = epoch[o]]
          /\ view' = [view EXCEPT ![p] = TRUE]
          /\ status' = [q \in PlanIds |->
                        IF q = p THEN "pending"
                        ELSE IF q = old THEN "superseded" ELSE status[q]]
    /\ UNCHANGED <<epoch, alive, started, admitted, runLive>>

Claim(p) ==
    /\ Current(p) /\ status[p] = "pending" /\ ~runLive
    /\ status' = [status EXCEPT ![p] = "dispatching"]
    /\ UNCHANGED <<generation, current, epoch, captured, alive, view,
                    started, admitted, runLive>>

\* The caller can be viewing either project.  Dispatch still uses the
\* captured record owner, never the caller or a globally selected chat.
Dispatch(p, caller) ==
    /\ caller \in Owners
    /\ Current(p) /\ status[p] = "dispatching" /\ ~runLive
    /\ status' = [status EXCEPT ![p] = "approved"]
    /\ started' = [started EXCEPT ![p] = @ + 1]
    /\ admitted' = [admitted EXCEPT ![p] = <<p[1], epoch[p[1]]>>]
    /\ runLive' = TRUE
    /\ UNCHANGED <<generation, current, epoch, captured, alive, view>>

StartupFailure(p) ==
    /\ status[p] = "dispatching"
    /\ status' = [status EXCEPT ![p] = IF Current(p) THEN "pending" ELSE "cancelled"]
    /\ UNCHANGED <<generation, current, epoch, captured, alive, view,
                    started, admitted, runLive>>

Reject(p) ==
    /\ Current(p) /\ status[p] = "pending"
    /\ status' = [status EXCEPT ![p] = "rejected"]
    /\ UNCHANGED <<generation, current, epoch, captured, alive, view,
                    started, admitted, runLive>>

ChangeOwner(o) ==
    /\ alive[o] /\ epoch[o] = 1
    /\ epoch' = [epoch EXCEPT ![o] = 2]
    /\ UNCHANGED <<generation, current, captured, alive, view, status,
                    started, admitted, runLive>>

CloseChat(o) ==
    /\ alive[o]
    /\ alive' = [alive EXCEPT ![o] = FALSE]
    /\ status' = [p \in PlanIds |-> IF p = <<o, current[o]>>
                                    THEN "cancelled" ELSE status[p]]
    /\ current' = [current EXCEPT ![o] = 0]
    /\ UNCHANGED <<generation, epoch, captured, view, started, admitted, runLive>>

CloseView(p) ==
    /\ view[p] /\ current[p[1]] = p[2]
    /\ view' = [view EXCEPT ![p] = FALSE]
    /\ status' = [status EXCEPT ![p] = "cancelled"]
    /\ current' = [current EXCEPT ![p[1]] = 0]
    /\ UNCHANGED <<generation, epoch, captured, alive, started, admitted, runLive>>

RunFinish == /\ runLive /\ runLive' = FALSE
             /\ UNCHANGED <<generation, current, epoch, captured, alive,
                             view, status, started, admitted>>
Quiescent == /\ \A o \in Owners : ~alive[o]
             /\ ~runLive /\ UNCHANGED vars

Next == (\E o \in Owners : Create(o) \/ ChangeOwner(o) \/ CloseChat(o))
        \/ (\E p \in PlanIds : Claim(p) \/ StartupFailure(p) \/ Reject(p) \/ CloseView(p))
        \/ (\E p \in PlanIds, caller \in Owners : Dispatch(p, caller))
        \/ RunFinish \/ Quiescent
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ generation \in [Owners -> 0..MaxPlans]
    /\ current \in [Owners -> 0..MaxPlans]
    /\ epoch \in [Owners -> 1..2]
    /\ captured \in [PlanIds -> 1..2]
    /\ alive \in [Owners -> BOOLEAN]
    /\ view \in [PlanIds -> BOOLEAN]
    /\ status \in [PlanIds -> States]
    /\ started \in [PlanIds -> 0..1]
    /\ admitted \in [PlanIds -> (Owners \X (1..2))]
    /\ runLive \in BOOLEAN

Safety_OwnedDispatch == \A p \in PlanIds :
    started[p] > 0 => admitted[p] = <<p[1], captured[p]>>
Safety_NoResurrectedDecisions == \A p \in PlanIds :
    status[p] \in {"pending", "dispatching"} => current[p[1]] = p[2]
Safety_OneClaimPerOwner == \A o \in Owners :
    Cardinality({p \in PlanIds : p[1] = o /\ status[p] = "dispatching"}) <= 1
Safety_NoRejectedDispatch == \A p \in PlanIds :
    status[p] = "rejected" => started[p] = 0

=============================================================================
