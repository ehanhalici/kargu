---------------------- MODULE KarguDebugSelection ----------------------
EXTENDS Naturals, Sequences, TLC

\* One captured context read, or navigation followed by its captured read.
\* UI selection is independent of the thread/frame sent in DAP requests.
NoReport == <<2, 2>>
Captured == <<0, 0>>
VARIABLES phase, navigation, ui, target, present, valid, moved, authorized,
          requests, report, deliveries
vars == <<phase, navigation, ui, target, present, valid, moved, authorized,
          requests, report, deliveries>>
Pending == phase \in {"stack", "scopes", "variables"}
Init == /\ phase = "stack" /\ navigation \in BOOLEAN
        /\ ui = Captured /\ target = Captured /\ present = TRUE /\ valid = TRUE
        /\ moved = FALSE /\ authorized = FALSE /\ requests = <<>>
        /\ report = NoReport /\ deliveries = 0
Select(t, f) ==
    /\ Pending /\ ui' = <<t, f>>
    /\ UNCHANGED <<phase, navigation, target, present, valid, moved,
                    authorized, requests, report, deliveries>>
RemoveFrame ==
    /\ phase = "stack" /\ present /\ present' = FALSE
    /\ UNCHANGED <<phase, navigation, ui, target, valid, moved,
                    authorized, requests, report, deliveries>>
Invalidate ==
    /\ Pending /\ valid /\ valid' = FALSE
    /\ UNCHANGED <<phase, navigation, ui, target, present, moved,
                    authorized, requests, report, deliveries>>
Failure ==
    /\ Pending /\ (~valid \/ (phase = "stack" /\ (~present \/ (navigation /\ ui # Captured))))
    /\ phase' = "error" /\ deliveries' = deliveries + 1
    /\ UNCHANGED <<navigation, ui, target, present, valid, moved,
                    authorized, requests, report>>
StackReply ==
    /\ phase = "stack" /\ valid /\ present /\ (~navigation \/ ui = Captured)
    /\ phase' = "scopes"
    /\ target' = IF navigation THEN <<0, 1>> ELSE Captured
    /\ ui' = IF navigation THEN <<0, 1>> ELSE ui
    /\ moved' = navigation /\ authorized' = (navigation /\ ui = Captured)
    /\ requests' = Append(requests, IF navigation THEN <<0, 1>> ELSE Captured)
    /\ UNCHANGED <<navigation, present, valid, report, deliveries>>
ScopesReply ==
    /\ phase = "scopes" /\ valid /\ phase' = "variables"
    /\ requests' = Append(requests, target)
    /\ UNCHANGED <<navigation, ui, target, present, valid, moved,
                    authorized, report, deliveries>>
VariablesReply ==
    /\ phase = "variables" /\ valid /\ phase' = "done"
    /\ report' = target /\ deliveries' = deliveries + 1
    /\ UNCHANGED <<navigation, ui, target, present, valid, moved, authorized, requests>>
Cancel ==
    /\ Pending /\ phase' = "cancelled"
    /\ UNCHANGED <<navigation, ui, target, present, valid, moved,
                    authorized, requests, report, deliveries>>
LateReply == /\ ~Pending /\ UNCHANGED vars
Next == (\E t \in 0..1, f \in 0..1 : Select(t, f))
        \/ RemoveFrame \/ Invalidate \/ Failure \/ StackReply \/ ScopesReply
        \/ VariablesReply \/ Cancel \/ LateReply
Spec == Init /\ [][Next]_vars

TypeOK == /\ phase \in {"stack", "scopes", "variables", "done", "error", "cancelled"}
          /\ navigation \in BOOLEAN /\ ui \in (0..1) \X (0..1)
          /\ target \in (0..1) \X (0..1)
          /\ present \in BOOLEAN /\ valid \in BOOLEAN /\ moved \in BOOLEAN
          /\ authorized \in BOOLEAN /\ requests \in Seq((0..1) \X (0..1))
          /\ Len(requests) <= 2 /\ report \in ({NoReport} \cup ((0..1) \X (0..1)))
          /\ deliveries \in 0..1
Safety_PinnedRequests == \A i \in 1..Len(requests) : requests[i] = target
Safety_ConsistentReport == phase = "done" => valid /\ report = target /\ Len(requests) = 2
Safety_NavigationConsent == moved => navigation /\ authorized
Safety_NoFallback == ~present => Len(requests) = 0
Safety_CancelledSilent == phase = "cancelled" => deliveries = 0
=============================================================================
