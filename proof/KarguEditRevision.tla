---------------------- MODULE KarguEditRevision ----------------------
EXTENDS Naturals, TLC

\* A retained source/approval, one candidate worker and one competing upload.
\* The two source representations are changed only by one successful join.
VARIABLES phase, source, approval, metadata, candidate, external, reserved,
          revoked, expired, starts, joins, accepted
vars == <<phase, source, approval, metadata, candidate, external, reserved,
          revoked, expired, starts, joins, accepted>>
Current == ~revoked /\ ~expired
Init == /\ phase = "review" /\ source = 1 /\ approval = 1 /\ metadata = 1
        /\ candidate = 0 /\ external = 0 /\ reserved = 1
        /\ revoked = FALSE /\ expired = FALSE /\ starts = 0 /\ joins = 0 /\ accepted = 0

Start == /\ phase = "review" /\ Current /\ source < 3 /\ starts < 3
         /\ reserved + external + 1 <= 2
         /\ phase' = "revising" /\ candidate' = source + 1
         /\ reserved' = 2 /\ starts' = starts + 1
         /\ UNCHANGED <<source, approval, metadata, external, revoked, expired, joins, accepted>>

Join(pass) ==
    /\ phase = "revising" /\ pass \in BOOLEAN
    /\ joins' = joins + 1 /\ candidate' = 0 /\ reserved' = IF Current THEN 1 ELSE 0
    /\ phase' = IF Current THEN "review" ELSE "done"
    /\ source' = IF pass /\ Current THEN candidate ELSE source
    /\ approval' = IF pass /\ Current THEN candidate ELSE approval
    /\ metadata' = IF pass /\ Current THEN candidate ELSE metadata
    /\ UNCHANGED <<external, revoked, expired, starts, accepted>>

Approve(revision) ==
    /\ phase = "review" /\ Current /\ revision = approval /\ revision = source
    /\ phase' = "authorized" /\ accepted' = revision
    /\ UNCHANGED <<source, approval, metadata, candidate, external, reserved, revoked, expired, starts, joins>>

Revoke == /\ ~revoked /\ revoked' = TRUE
          /\ UNCHANGED <<phase, source, approval, metadata, candidate, external, reserved, expired, starts, joins, accepted>>
Expire == /\ ~expired /\ expired' = TRUE
          /\ UNCHANGED <<phase, source, approval, metadata, candidate, external, reserved, revoked, starts, joins, accepted>>
Release == /\ phase \in {"review", "authorized"} /\ ~Current
           /\ phase' = "done" /\ reserved' = 0
           /\ UNCHANGED <<source, approval, metadata, candidate, external, revoked, expired, starts, joins, accepted>>
ExternalStart == /\ external = 0 /\ reserved < 2 /\ external' = 1
                 /\ UNCHANGED <<phase, source, approval, metadata, candidate, reserved, revoked, expired, starts, joins, accepted>>
ExternalJoin == /\ external = 1 /\ external' = 0
                /\ UNCHANGED <<phase, source, approval, metadata, candidate, reserved, revoked, expired, starts, joins, accepted>>

Next == Start \/ (\E pass \in BOOLEAN : Join(pass))
        \/ (\E revision \in 1..3 : Approve(revision)) \/ Revoke \/ Expire \/ Release
        \/ ExternalStart \/ ExternalJoin
        \/ (phase = "done" /\ external = 0 /\ UNCHANGED vars)
Spec == Init /\ [][Next]_vars
TypeOK == /\ phase \in {"review", "revising", "authorized", "done"}
          /\ source \in 1..3 /\ approval \in 1..3 /\ metadata \in 1..3 /\ candidate \in 0..3
          /\ external \in 0..1 /\ reserved \in 0..2 /\ revoked \in BOOLEAN /\ expired \in BOOLEAN
          /\ starts \in Nat /\ joins \in Nat /\ accepted \in 0..3
AtomicRevision == source = approval /\ source = metadata
Capacity == reserved + external <= 2
ActualJoinBeforeRelease == /\ joins <= starts /\ starts - joins <= 1
                          /\ (phase = "revising") = (starts = joins + 1)
                          /\ (phase = "revising" => reserved = 2)
ExactConsent == phase = "authorized" => accepted = source
=============================================================================
