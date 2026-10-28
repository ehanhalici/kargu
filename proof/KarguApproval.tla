-------------------------- MODULE KarguApproval --------------------------
EXTENDS Naturals, TLC

\* Shared native command/editor ledger: one immutable request, exact action
\* kind/revision, no replay and one claimed continuation. Current abstracts
\* authority checks, not filesystem preflight, issuance or an OS sandbox.
CONSTANT AuthorityFields
VARIABLES phase, current, starts, deliveries, admitted, resource, capturedKind, admittedKind
vars == <<phase, current, starts, deliveries, admitted, resource, capturedKind, admittedKind>>
ActionKinds == {"command", "editor"}

Init == /\ phase = "approval"
        /\ current = [f \in AuthorityFields |-> TRUE]
        /\ starts = 0 /\ deliveries = 0
        /\ admitted = [f \in AuthorityFields |-> FALSE]
        /\ resource = TRUE
        /\ capturedKind \in ActionKinds /\ admittedKind = "none"

Change(f) == /\ current[f]
             /\ current' = [current EXCEPT ![f] = FALSE]
             /\ UNCHANGED <<phase, starts, deliveries, admitted, resource, capturedKind, admittedKind>>

Approve(kind) == /\ phase = "approval" /\ \A f \in AuthorityFields : current[f]
           /\ kind = capturedKind
           /\ admittedKind' = kind
           /\ phase' = "executing" /\ starts' = starts + 1
           /\ admitted' = current
           /\ UNCHANGED <<current, deliveries, resource, capturedKind>>

Refuse == /\ phase = "approval"
          /\ phase' = "closed" /\ deliveries' = deliveries + 1
          /\ resource' = FALSE
          /\ UNCHANGED <<current, starts, admitted, capturedKind, admittedKind>>

Finish == /\ phase = "executing"
          /\ phase' = "closed" /\ deliveries' = deliveries + 1
          /\ resource' = FALSE
          /\ UNCHANGED <<current, starts, admitted, capturedKind, admittedKind>>

Cancel == /\ phase # "closed" /\ phase' = "closed" /\ resource' = FALSE
          /\ UNCHANGED <<current, starts, deliveries, admitted, capturedKind, admittedKind>>

Quiescent == /\ phase = "closed" /\ UNCHANGED vars
Next == (\E f \in AuthorityFields : Change(f)) \/ (\E kind \in ActionKinds : Approve(kind)) \/ Refuse
        \/ Finish \/ Cancel \/ Quiescent
Spec == Init /\ [][Next]_vars

TypeOK == /\ phase \in {"approval", "executing", "closed"}
          /\ current \in [AuthorityFields -> BOOLEAN]
          /\ admitted \in [AuthorityFields -> BOOLEAN]
          /\ starts \in 0..1 /\ deliveries \in 0..1
          /\ resource \in BOOLEAN
          /\ capturedKind \in ActionKinds
          /\ admittedKind \in ActionKinds \cup {"none"}
Safety_ExactActionKind == starts > 0 => admittedKind = capturedKind
Safety_Authority == starts > 0 => \A f \in AuthorityFields : admitted[f]
Safety_ClosedResources == (phase = "closed") <=> ~resource
Safety_ResultAfterClaim == deliveries > 0 => phase = "closed"

=============================================================================
