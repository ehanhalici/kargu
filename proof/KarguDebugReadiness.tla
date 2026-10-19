----------------------- MODULE KarguDebugReadiness -----------------------
EXTENDS Naturals, FiniteSets, TLC

\* Candidates abstract BOTH the launch token and canonical project/root check.
\* Distinct adapter objects cannot reappear after removal. Deferred launch
\* prevention is checked separately by KarguDebugStartup's compile guard.
Adapters == {0, 1}
None == 2
VARIABLES phase, launching, valid, live, seen, candidates, paused, bound,
          resources, deliveries, authorized
vars == <<phase, launching, valid, live, seen, candidates, paused, bound,
          resources, deliveries, authorized>>
Pending == phase = "waiting"
Init == /\ phase = "waiting" /\ launching \in BOOLEAN /\ valid = TRUE
        /\ live = IF launching THEN {} ELSE {0}
        /\ seen = live /\ candidates = {} /\ paused = {}
        /\ bound = IF launching THEN None ELSE 0
        /\ resources = TRUE /\ deliveries = 0 /\ authorized = FALSE
Appear(i, owned) ==
    /\ Pending /\ i \notin seen /\ live' = live \cup {i} /\ seen' = seen \cup {i}
    /\ candidates' = IF owned THEN candidates \cup {i} ELSE candidates
    /\ UNCHANGED <<phase, launching, valid, paused, bound, resources, deliveries, authorized>>
Stop(i) ==
    /\ Pending /\ i \in live /\ paused' = paused \cup {i}
    /\ UNCHANGED <<phase, launching, valid, live, seen, candidates, bound,
                    resources, deliveries, authorized>>
Remove(i) ==
    /\ Pending /\ i \in live /\ live' = live \ {i}
    /\ candidates' = candidates \ {i} /\ paused' = paused \ {i}
    /\ UNCHANGED <<phase, launching, valid, seen, bound, resources, deliveries, authorized>>
Invalidate == /\ Pending /\ valid /\ valid' = FALSE
              /\ UNCHANGED <<phase, launching, live, seen, candidates, paused, bound,
                              resources, deliveries, authorized>>
Adopt == /\ Pending /\ valid /\ launching /\ bound = None
         /\ Cardinality(candidates) = 1 /\ bound' \in candidates
         /\ UNCHANGED <<phase, launching, valid, live, seen, candidates, paused,
                         resources, deliveries, authorized>>
Allowed == valid /\ bound \in live /\ bound \in paused
           /\ (~launching \/ (Cardinality(candidates) = 1 /\ bound \in candidates))
Ready == /\ Pending /\ Allowed /\ phase' = "ready" /\ resources' = FALSE
         /\ deliveries' = 1 /\ authorized' = TRUE
         /\ UNCHANGED <<launching, valid, live, seen, candidates, paused, bound>>
FinishError == /\ Pending /\ valid /\ phase' = "error" /\ resources' = FALSE
               /\ deliveries' = 1
               /\ UNCHANGED <<launching, valid, live, seen, candidates, paused, bound, authorized>>
Deadline == FinishError
Failure == /\ ((bound # None /\ bound \notin live) \/ Cardinality(candidates) > 1)
           /\ FinishError
Cancel == /\ Pending /\ phase' = "cancelled" /\ resources' = FALSE
          /\ UNCHANGED <<launching, valid, live, seen, candidates, paused, bound,
                          deliveries, authorized>>
ForeignOrLateEvent == UNCHANGED vars
Next == (\E i \in Adapters, owned \in BOOLEAN : Appear(i, owned))
        \/ (\E i \in Adapters : Stop(i) \/ Remove(i))
        \/ Invalidate \/ Adopt \/ Ready \/ Deadline \/ Failure \/ Cancel \/ ForeignOrLateEvent
Spec == Init /\ [][Next]_vars

TypeOK == /\ phase \in {"waiting", "ready", "error", "cancelled"}
          /\ launching \in BOOLEAN /\ valid \in BOOLEAN
          /\ live \subseteq Adapters /\ seen \subseteq Adapters /\ live \subseteq seen
          /\ candidates \subseteq live /\ paused \subseteq live
          /\ bound \in Adapters \cup {None} /\ resources \in BOOLEAN
          /\ deliveries \in 0..1 /\ authorized \in BOOLEAN
Safety_OwnedReady == phase = "ready" => authorized /\ Allowed
Safety_Cleanup == ~Pending => ~resources
Safety_CancelledSilent == phase = "cancelled" => deliveries = 0
Safety_NoUnownedSuccess == deliveries = 1 /\ ~authorized => phase = "error"
=============================================================================
