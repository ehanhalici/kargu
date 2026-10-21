--------------------------- MODULE KarguRestore ---------------------------
EXTENDS Naturals

\* Atomic publication is a single non-yielding local step. ERT fault injection
\* checks the concrete rollback implementation; external mode-hook side effects
\* are not transactional and are outside this bounded refinement.
VARIABLES owner, view, revision, captured, phase, busy, built, published
vars == <<owner, view, revision, captured, phase, busy, built, published>>
Init == /\ owner = "old" /\ view = "old" /\ revision = 0 /\ captured = 0
        /\ phase = "idle" /\ busy = FALSE /\ built = FALSE /\ published = 0
Prepare == /\ phase = "idle" /\ ~busy
           /\ phase' = "preparing" /\ captured' = revision
           /\ UNCHANGED <<owner, view, revision, busy, built, published>>
Ready == /\ phase = "preparing" /\ phase' = "ready" /\ built' = TRUE
         /\ UNCHANGED <<owner, view, revision, captured, busy, published>>
Failure == /\ phase \in {"preparing", "ready"} /\ phase' = "failed"
           /\ UNCHANGED <<owner, view, revision, captured, busy, built, published>>
Publish == /\ phase = "ready" /\ built /\ ~busy /\ captured = revision
           /\ owner' = "new" /\ view' = "new" /\ phase' = "committed"
           /\ published' = published + 1
           /\ UNCHANGED <<revision, captured, busy, built>>
Edit == /\ revision = 0 /\ revision' = 1
        /\ UNCHANGED <<owner, view, captured, phase, busy, built, published>>
Replace == /\ revision = 0 /\ revision' = 1 /\ owner' = "other" /\ view' = "other"
           /\ UNCHANGED <<captured, phase, busy, built, published>>
Start == /\ ~busy /\ busy' = TRUE
         /\ UNCHANGED <<owner, view, revision, captured, phase, built, published>>
Finish == /\ busy /\ busy' = FALSE
          /\ UNCHANGED <<owner, view, revision, captured, phase, built, published>>
Next == Prepare \/ Ready \/ Failure \/ Publish \/ Edit \/ Replace \/ Start \/ Finish
Spec == Init /\ [][Next]_vars
TypeOK == /\ owner \in {"old", "new", "other"} /\ view = owner
          /\ revision \in 0..1 /\ captured \in 0..1 /\ busy \in BOOLEAN
          /\ phase \in {"idle", "preparing", "ready", "committed", "failed"}
          /\ built \in BOOLEAN /\ published \in 0..1
OnlyCommittedPublishes == published = 1 => phase = "committed"
FailedKeepsOldOrNewerOwner == phase = "failed" => owner \in {"old", "other"}
=============================================================================
