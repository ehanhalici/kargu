---------------------- MODULE KarguEditPreparation ----------------------
EXTENDS Naturals, FiniteSets, TLC

\* Two fresh preparation IDs, two source owners, one application. Cost 2 is a
\* patch's full byte reservation; cost 1 abstracts a smaller file proposal.
\* A start/join pair represents an actual owned worker or supervised process.
\* Counters are independent of Cancel/Close: signalling cannot fabricate join.
CONSTANTS PreparationIds, SourceOwners
ASSUME /\ PreparationIds \cap SourceOwners = {}
       /\ Cardinality(PreparationIds) = 2 /\ Cardinality(SourceOwners) = 2
Tickets == PreparationIds
Owners == SourceOwners
Symmetry == {[x \in Tickets \cup Owners |-> IF x \in Tickets THEN p[x] ELSE q[x]] :
             p \in Permutations(Tickets), q \in Permutations(Owners)}
Stages == {"free", "upload", "inspect", "collect", "read", "prepare",
           "git", "finalize", "discard", "ready", "claim", "review", "authorized"}
Active == {"inspect", "read", "prepare", "git", "finalize", "discard", "claim"}
VARIABLES stage, kind, owner, used, closed, revoked, expired, changed,
          starts, joins, captured, quiesced, external, claims
vars == <<stage, kind, owner, used, closed, revoked, expired, changed,
          starts, joins, captured, quiesced, external, claims>>

Busy(t) == stage[t] \in Active
Retained(t) == Busy(t) \/ t \in claims
Current(t) == owner[t] \notin closed /\ t \notin revoked /\ t \notin expired
Eligible(t) == owner[t] \notin closed /\ t \notin revoked
               /\ t \notin expired /\ t \notin changed
Occupied == {t \in Tickets : stage[t] # "free"}
Reserved == Cardinality({t \in Occupied : kind[t] = "file"})
            + 2 * Cardinality({t \in Occupied : kind[t] = "patch"})
Reads == Cardinality({t \in Tickets : stage[t] \in {"inspect", "read"}})
Commands == Cardinality({t \in Tickets : stage[t] \in {"prepare", "git", "finalize", "discard", "claim"}})

Init == /\ stage = [t \in Tickets |-> "free"]
        /\ kind = [t \in Tickets |-> "file"] /\ owner = [t \in Tickets |-> "unassigned"]
        /\ used = {} /\ closed = {} /\ revoked = {} /\ expired = {} /\ changed = {}
        /\ starts = [t \in Tickets |-> 0] /\ joins = [t \in Tickets |-> 0]
        /\ captured = {} /\ quiesced = {} /\ external = 0 /\ claims = {}

Begin(t, o, k) ==
    /\ t \notin used /\ o \notin closed
    /\ Reserved + (IF k = "patch" THEN 2 ELSE 1) <= 2
    /\ stage' = [stage EXCEPT ![t] = "upload"]
    /\ kind' = [kind EXCEPT ![t] = k] /\ owner' = [owner EXCEPT ![t] = o]
    /\ used' = used \cup {t}
    /\ UNCHANGED <<closed, revoked, expired, changed, starts, joins, captured, quiesced, external, claims>>

StartRead(t) ==
    /\ stage[t] = "upload" /\ Eligible(t) /\ Reads + external < 2
    /\ stage' = [stage EXCEPT ![t] = IF kind[t] = "patch" THEN "inspect" ELSE "read"]
    /\ starts' = [starts EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<kind, owner, used, closed, revoked, expired, changed, joins, captured, quiesced, external, claims>>

RejectAdmission(t) ==
    /\ stage[t] = "upload" /\ Reads + external = 2
    /\ stage' = [stage EXCEPT ![t] = "free"]
    /\ UNCHANGED <<kind, owner, used, closed, revoked, expired, changed, starts, joins, captured, quiesced, external, claims>>

InspectJoin(t) ==
    /\ stage[t] = "inspect"
    /\ joins' = [joins EXCEPT ![t] = @ + 1]
    /\ stage' = [stage EXCEPT ![t] = IF Eligible(t) THEN "collect" ELSE "free"]
    /\ UNCHANGED <<kind, owner, used, closed, revoked, expired, changed, starts, captured, quiesced, external, claims>>

StartPatch(t) ==
    /\ stage[t] = "collect" /\ Eligible(t) /\ Commands = 0
    /\ stage' = [stage EXCEPT ![t] = "prepare"]
    /\ starts' = [starts EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<kind, owner, used, closed, revoked, expired, changed, joins, captured, quiesced, external, claims>>

PrepareJoin(t) ==
    /\ stage[t] = "prepare"
    \* Whole-batch capture precedes Git; refusal still owns a cleanup worker.
    /\ captured' = captured \cup {t}
    /\ joins' = [joins EXCEPT ![t] = @ + 1]
    /\ starts' = [starts EXCEPT ![t] = @ + 1]
    /\ stage' = [stage EXCEPT ![t] = IF Eligible(t) THEN "git" ELSE "discard"]
    /\ UNCHANGED <<kind, owner, used, closed, revoked, expired, changed, quiesced, external, claims>>

ProcessJoin(t) ==
    /\ stage[t] = "git"
    \* The process tree and pipes are quiescent before final snapshot IO starts.
    /\ quiesced' = quiesced \cup {t}
    /\ joins' = [joins EXCEPT ![t] = @ + 1]
    /\ starts' = [starts EXCEPT ![t] = @ + 1]
    /\ stage' = [stage EXCEPT ![t] = "finalize"]
    /\ UNCHANGED <<kind, owner, used, closed, revoked, expired, changed, captured, external, claims>>

FinalJoin(t) ==
    /\ stage[t] \in {"read", "finalize", "discard"}
    /\ joins' = [joins EXCEPT ![t] = @ + 1]
    /\ stage' = [stage EXCEPT ![t] = IF stage[t] # "discard" /\ Eligible(t)
                                      THEN "ready" ELSE "free"]
    /\ UNCHANGED <<kind, owner, used, closed, revoked, expired, changed, starts, captured, quiesced, external, claims>>

StartClaim(t) ==
    /\ stage[t] = "ready" /\ Current(t) /\ Commands = 0
    /\ stage' = [stage EXCEPT ![t] = "claim"]
    /\ starts' = [starts EXCEPT ![t] = @ + 1]
    /\ claims' = claims \cup {t}
    /\ UNCHANGED <<kind, owner, used, closed, revoked, expired, changed, joins, captured, quiesced, external>>

ClaimJoin(t, after) ==
    /\ stage[t] = "claim" /\ after \in {"review", "authorized"}
    /\ joins' = [joins EXCEPT ![t] = @ + 1]
    /\ stage' = [stage EXCEPT ![t] = IF Current(t) THEN after ELSE "free"]
    /\ claims' = IF Current(t) THEN claims ELSE claims \ {t}
    /\ UNCHANGED <<kind, owner, used, closed, revoked, expired, changed, starts, captured, quiesced, external>>

AcceptReview(t) ==
    /\ stage[t] = "review" /\ Current(t)
    /\ stage' = [stage EXCEPT ![t] = "authorized"]
    /\ UNCHANGED <<kind, owner, used, closed, revoked, expired, changed, starts, joins, captured, quiesced, external, claims>>

ReleaseClaim(t) ==
    /\ stage[t] \in {"review", "authorized"}
    /\ stage' = [stage EXCEPT ![t] = "free"]
    /\ claims' = claims \ {t}
    /\ UNCHANGED <<kind, owner, used, closed, revoked, expired, changed, starts, joins, captured, quiesced, external>>

Abort(t) ==
    /\ stage[t] # "free" /\ t \notin revoked
    /\ revoked' = revoked \cup {t}
    /\ stage' = [stage EXCEPT ![t] = IF Retained(t) THEN @ ELSE "free"]
    /\ UNCHANGED <<kind, owner, used, closed, expired, changed, starts, joins, captured, quiesced, external, claims>>

Expire(t) ==
    /\ stage[t] # "free" /\ t \notin expired
    /\ expired' = expired \cup {t}
    /\ stage' = [stage EXCEPT ![t] = IF Retained(t) THEN @ ELSE "free"]
    /\ UNCHANGED <<kind, owner, used, closed, revoked, changed, starts, joins, captured, quiesced, external, claims>>

Close(o) ==
    /\ o \notin closed /\ closed' = closed \cup {o}
    /\ revoked' = revoked \cup {t \in used : owner[t] = o}
    /\ stage' = [t \in Tickets |-> IF owner[t] = o /\ ~Retained(t) THEN "free" ELSE stage[t]]
    /\ UNCHANGED <<kind, owner, used, expired, changed, starts, joins, captured, quiesced, external, claims>>

Change(t) ==
    /\ stage[t] \in Active \cup {"ready", "review", "authorized"} /\ t \notin changed
    /\ changed' = changed \cup {t}
    /\ UNCHANGED <<stage, kind, owner, used, closed, revoked, expired, starts, joins, captured, quiesced, external, claims>>

ExternalStart == /\ external < 2 - Reads /\ external' = external + 1
                 /\ UNCHANGED <<stage, kind, owner, used, closed, revoked, expired, changed, starts, joins, captured, quiesced, claims>>
ExternalJoin == /\ external > 0 /\ external' = external - 1
                /\ UNCHANGED <<stage, kind, owner, used, closed, revoked, expired, changed, starts, joins, captured, quiesced, claims>>

Next == (\E t \in Tickets : StartRead(t) \/ RejectAdmission(t) \/ InspectJoin(t)
                          \/ StartPatch(t) \/ PrepareJoin(t) \/ ProcessJoin(t) \/ FinalJoin(t)
                          \/ Abort(t) \/ Expire(t) \/ Change(t)
                          \/ StartClaim(t) \/ AcceptReview(t) \/ ReleaseClaim(t)
                          \/ (\E after \in {"review", "authorized"} : ClaimJoin(t,after)))
        \/ (\E t \in Tickets, o \in Owners, k \in {"file", "patch"} : Begin(t,o,k))
        \/ (\E o \in Owners : Close(o)) \/ ExternalStart \/ ExternalJoin
        \/ (used = Tickets /\ (\A t \in Tickets : stage[t] \in {"free", "ready"})
                           /\ external = 0 /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars
TypeOK == /\ stage \in [Tickets -> Stages] /\ kind \in [Tickets -> {"file", "patch"}]
          /\ owner \in [Tickets -> Owners \cup {"unassigned"}] /\ used \subseteq Tickets /\ closed \subseteq Owners
          /\ revoked \subseteq Tickets /\ expired \subseteq Tickets /\ changed \subseteq Tickets
          /\ starts \in [Tickets -> 0..5] /\ joins \in [Tickets -> 0..5]
          /\ captured \subseteq Tickets /\ quiesced \subseteq Tickets /\ external \in 0..2 /\ claims \subseteq Tickets
ClaimOwnership == claims = {t \in Tickets : stage[t] \in {"claim", "review", "authorized"}}
Capacity == /\ Reserved <= 2 /\ Reads + external <= 2 /\ Commands <= 1
ActualJoinBeforeRelease == \A t \in Tickets :
    /\ joins[t] <= starts[t]
    /\ starts[t] - joins[t] <= 1
    /\ (starts[t] > joins[t]) = Busy(t)
ReadyAfterDrain == \A t \in Tickets : stage[t] = "ready" =>
    /\ starts[t] = joins[t]
    /\ (kind[t] = "patch" => t \in captured /\ t \in quiesced)
ReadyOwnerCurrent == \A t \in Tickets : stage[t] = "ready" =>
    owner[t] \notin closed /\ t \notin revoked /\ t \notin expired
GitAfterFullCapture == \A t \in Tickets : stage[t] \in {"git", "finalize"} => t \in captured
=============================================================================
