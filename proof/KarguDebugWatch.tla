------------------------- MODULE KarguDebugWatch -------------------------
EXTENDS Naturals, Sequences, TLC

\* A two-expression snapshot evaluated by one guarded inspection task.
CONSTANT Resources
VARIABLES phase, dirty, caller, requests, deliveries, outcome,
          deadlineTimer, childTimer
vars == <<phase, dirty, caller, requests, deliveries, outcome,
          deadlineTimer, childTimer>>

Init == /\ phase = "dispatch" /\ dirty = {} /\ caller = 0
        /\ requests = <<>> /\ deliveries = 0 /\ outcome = "pending"
        /\ deadlineTimer = TRUE /\ childTimer = FALSE
Pending == phase \in {"dispatch", "reply"}
Valid == dirty = {}

Invalidate(resource) ==
    /\ Pending /\ resource \notin dirty
    /\ dirty' = dirty \cup {resource}
    /\ UNCHANGED <<phase, caller, requests, deliveries, outcome,
                    deadlineTimer, childTimer>>
SwitchCaller ==
    /\ Pending /\ caller' = 1 - caller
    /\ UNCHANGED <<phase, dirty, requests, deliveries, outcome,
                    deadlineTimer, childTimer>>
Dispatch ==
    /\ phase = "dispatch" /\ Valid /\ Len(requests) < 2
    /\ phase' = "reply" /\ childTimer' = TRUE
    /\ requests' = Append(requests, Valid)
    /\ UNCHANGED <<dirty, caller, deliveries, outcome, deadlineTimer>>
ReplyNext ==
    /\ phase = "reply" /\ Valid /\ Len(requests) < 2
    /\ phase' = "dispatch" /\ childTimer' = FALSE
    /\ UNCHANGED <<dirty, caller, requests, deliveries, outcome, deadlineTimer>>
Finish(result) ==
    /\ Pending /\ phase' = "done"
    /\ deliveries' = deliveries + 1 /\ outcome' = result
    /\ deadlineTimer' = FALSE /\ childTimer' = FALSE
    /\ UNCHANGED <<dirty, caller, requests>>
ReplyLast == phase = "reply" /\ Valid /\ Len(requests) = 2 /\ Finish("reported")
InvalidCallback == ~Valid /\ Finish("unavailable")
Deadline == Finish("timeout")
Cancel ==
    /\ Pending /\ phase' = "cancelled"
    /\ deadlineTimer' = FALSE /\ childTimer' = FALSE
    /\ UNCHANGED <<dirty, caller, requests, deliveries, outcome>>
LateReply == /\ ~Pending /\ UNCHANGED vars
Next == (\E resource \in Resources : Invalidate(resource))
        \/ SwitchCaller \/ Dispatch \/ ReplyNext \/ ReplyLast
        \/ InvalidCallback \/ Deadline \/ Cancel \/ LateReply
Spec == Init /\ [][Next]_vars

TypeOK == /\ phase \in {"dispatch", "reply", "done", "cancelled"}
          /\ dirty \subseteq Resources /\ caller \in 0..1
          /\ requests \in Seq(BOOLEAN) /\ Len(requests) <= 2
          /\ deliveries \in 0..1
          /\ outcome \in {"pending", "reported", "unavailable", "timeout"}
          /\ deadlineTimer \in BOOLEAN /\ childTimer \in BOOLEAN
Safety_OwnedRequests == \A i \in 1..Len(requests) : requests[i]
Safety_OwnedReport == outcome = "reported" => Valid /\ Len(requests) = 2
Safety_CancelledSilent == phase = "cancelled" => deliveries = 0
Safety_ClosedResources == ~Pending => ~deadlineTimer /\ ~childTimer
=============================================================================
