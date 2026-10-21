-------------------------- MODULE KarguApproval --------------------------
EXTENDS Naturals, TLC

\* permission/execute.el: one captured request, no replay and one claimed
\* continuation. Current abstracts identity checks, not the contents of
\* a shell program or an OS sandbox. Changes never rewrite the request.
CONSTANT AuthorityFields
VARIABLES phase, current, starts, deliveries, admitted, resource
vars == <<phase, current, starts, deliveries, admitted, resource>>

Init == /\ phase = "approval"
        /\ current = [f \in AuthorityFields |-> TRUE]
        /\ starts = 0 /\ deliveries = 0
        /\ admitted = [f \in AuthorityFields |-> FALSE]
        /\ resource = TRUE

Change(f) == /\ current[f]
             /\ current' = [current EXCEPT ![f] = FALSE]
             /\ UNCHANGED <<phase, starts, deliveries, admitted, resource>>

Approve == /\ phase = "approval" /\ \A f \in AuthorityFields : current[f]
           /\ phase' = "executing" /\ starts' = starts + 1
           /\ admitted' = current
           /\ UNCHANGED <<current, deliveries, resource>>

Refuse == /\ phase = "approval"
          /\ phase' = "closed" /\ deliveries' = deliveries + 1
          /\ resource' = FALSE
          /\ UNCHANGED <<current, starts, admitted>>

Finish == /\ phase = "executing"
          /\ phase' = "closed" /\ deliveries' = deliveries + 1
          /\ resource' = FALSE
          /\ UNCHANGED <<current, starts, admitted>>

Cancel == /\ phase # "closed" /\ phase' = "closed" /\ resource' = FALSE
          /\ UNCHANGED <<current, starts, deliveries, admitted>>

Quiescent == /\ phase = "closed" /\ UNCHANGED vars
Next == (\E f \in AuthorityFields : Change(f)) \/ Approve \/ Refuse
        \/ Finish \/ Cancel \/ Quiescent
Spec == Init /\ [][Next]_vars

TypeOK == /\ phase \in {"approval", "executing", "closed"}
          /\ current \in [AuthorityFields -> BOOLEAN]
          /\ admitted \in [AuthorityFields -> BOOLEAN]
          /\ starts \in 0..1 /\ deliveries \in 0..1
          /\ resource \in BOOLEAN
Safety_Authority == starts > 0 => \A f \in AuthorityFields : admitted[f]
Safety_ClosedResources == (phase = "closed") <=> ~resource
Safety_ResultAfterClaim == deliveries > 0 => phase = "closed"

=============================================================================
