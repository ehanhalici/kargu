---------------------------- MODULE KarguEdit ----------------------------
EXTENDS Naturals, TLC

\* Bounded abstraction: two reviewed files, process-local rollback, one
\* foreign replacement per file. No OS compare-and-swap or crash guarantee.
\* Wave 1 Package B: Single-owner edit service, policy revision, service close.
Files == {0, 1}
VARIABLES phase, reviewed, writes, disk, foreign, stale, policyStale, serviceClosed, deliveries
vars == <<phase, reviewed, writes, disk, foreign, stale, policyStale, serviceClosed, deliveries>>

Init == /\ phase = "review" /\ reviewed = {}
        /\ writes = {} /\ disk = [f \in Files |-> "original"]
        /\ foreign = {} /\ stale = FALSE /\ policyStale = FALSE
        /\ serviceClosed = FALSE /\ deliveries = 0

Review(f) ==
    /\ phase = "review" /\ f \notin reviewed
    /\ reviewed' = reviewed \cup {f}
    /\ UNCHANGED <<phase, writes, disk, foreign, stale, policyStale, serviceClosed, deliveries>>

Change(f) ==
    /\ f \notin foreign /\ phase # "done"
    /\ foreign' = foreign \cup {f} /\ disk' = [disk EXCEPT ![f] = "foreign"]
    /\ UNCHANGED <<phase, reviewed, writes, stale, policyStale, serviceClosed, deliveries>>

Retire ==
    /\ ~stale /\ stale' = TRUE
    /\ UNCHANGED <<phase, reviewed, writes, disk, foreign, policyStale, serviceClosed, deliveries>>

PolicyChange ==
    /\ ~policyStale /\ policyStale' = TRUE
    /\ UNCHANGED <<phase, reviewed, writes, disk, foreign, stale, serviceClosed, deliveries>>

CloseService ==
    /\ ~serviceClosed /\ phase # "done"
    /\ serviceClosed' = TRUE
    /\ phase' = IF phase \in {"commit", "rollback"} THEN "rollback" ELSE "done"
    /\ UNCHANGED <<reviewed, writes, disk, foreign, stale, policyStale, deliveries>>

Prepare ==
    /\ phase = "review" /\ reviewed = Files
    /\ phase' = IF stale \/ policyStale \/ serviceClosed \/ foreign # {} THEN "rollback" ELSE "commit"
    /\ UNCHANGED <<reviewed, writes, disk, foreign, stale, policyStale, serviceClosed, deliveries>>

Commit(f) ==
    /\ phase = "commit" /\ ~stale /\ ~policyStale /\ ~serviceClosed /\ f \notin writes
    /\ disk[f] = "original" /\ disk' = [disk EXCEPT ![f] = "owned"]
    /\ writes' = writes \cup {f}
    /\ UNCHANGED <<phase, reviewed, foreign, stale, policyStale, serviceClosed, deliveries>>

Fail ==
    /\ phase \in {"review", "commit"} /\ phase' = "rollback"
    /\ UNCHANGED <<reviewed, writes, disk, foreign, stale, policyStale, serviceClosed, deliveries>>

Rollback(f) ==
    /\ phase = "rollback" /\ f \in writes
    /\ disk' = IF disk[f] = "owned" THEN [disk EXCEPT ![f] = "original"] ELSE disk
    /\ writes' = writes \ {f}
    /\ UNCHANGED <<phase, reviewed, foreign, stale, policyStale, serviceClosed, deliveries>>

Deliver ==
    /\ (phase = "commit" /\ writes = Files) \/ (phase = "rollback" /\ writes = {})
    /\ phase' = "done" /\ deliveries' = deliveries + 1
    /\ UNCHANGED <<reviewed, writes, disk, foreign, stale, policyStale, serviceClosed>>

Next == (\E f \in Files : Review(f) \/ Change(f) \/ Commit(f) \/ Rollback(f))
        \/ Retire \/ PolicyChange \/ CloseService \/ Prepare \/ Fail \/ Deliver
        \/ (phase = "done" /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars

TypeOK == /\ phase \in {"review", "commit", "rollback", "done"}
          /\ reviewed \subseteq Files /\ writes \subseteq Files
          /\ disk \in [Files -> {"original", "owned", "foreign"}]
          /\ foreign \subseteq Files /\ stale \in BOOLEAN
          /\ policyStale \in BOOLEAN /\ serviceClosed \in BOOLEAN
          /\ deliveries \in 0..1

Safety_ReviewBeforeWrite == writes # {} => reviewed = Files
Safety_PreserveForeign == \A f \in foreign : disk[f] = "foreign"
Safety_Once == deliveries <= 1
Safety_NoPrematureDelivery == deliveries = 1 => phase = "done"
Safety_PolicyInvalidatedNoWrite == (policyStale /\ writes = {}) => \A f \in Files : disk[f] # "owned"
Safety_ClosedServiceNoOwnedWrites == (serviceClosed /\ phase = "done") => \A f \in Files : disk[f] # "owned"
=============================================================================
