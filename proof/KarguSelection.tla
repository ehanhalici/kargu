-------------------------- MODULE KarguSelection --------------------------
EXTENDS Naturals, FiniteSets, TLC

\* kargu/selection.el and the native model-list continuations.  Version is
\* the identity of an immutable provider/model/effort tuple, not equality
\* of its fields.  Equal-value writes still replace that identity.  Epoch
\* abstracts replacement of a session frame, even with the same saved ID.
\* The catalog generation makes a newer picker supersede an older one.
CONSTANTS Owners, MaxPickers, MaxVersions
Pickers == Owners \X (1..MaxPickers)
States == {"absent", "pending", "applied", "discarded"}

VARIABLES epoch, version, alive, generation, latest, capturedEpoch,
          capturedVersion, status, applied, admitted, workLive,
          workOwner, workEpoch, workVersion
vars == <<epoch, version, alive, generation, latest, capturedEpoch,
          capturedVersion, status, applied, admitted, workLive,
          workOwner, workEpoch, workVersion>>

Init ==
    /\ epoch = [o \in Owners |-> 1]
    /\ version = [o \in Owners |-> 0]
    /\ alive = [o \in Owners |-> TRUE]
    /\ generation = [o \in Owners |-> 0]
    /\ latest = [o \in Owners |-> 0]
    /\ capturedEpoch = [p \in Pickers |-> 1]
    /\ capturedVersion = [p \in Pickers |-> 0]
    /\ status = [p \in Pickers |-> "absent"]
    /\ applied = [p \in Pickers |-> 0]
    /\ admitted = [p \in Pickers |-> <<p[1], 1, 0>>]
    /\ workLive = FALSE
    /\ workOwner = CHOOSE o \in Owners : TRUE
    /\ workEpoch = 1
    /\ workVersion = 0

Open(o) ==
    /\ alive[o] /\ generation[o] < MaxPickers /\ ~workLive
    /\ LET next == generation[o] + 1
           p == <<o, next>>
       IN /\ generation' = [generation EXCEPT ![o] = next]
          /\ latest' = [latest EXCEPT ![o] = next]
          /\ capturedEpoch' = [capturedEpoch EXCEPT ![p] = epoch[o]]
          /\ capturedVersion' = [capturedVersion EXCEPT ![p] = version[o]]
          /\ status' = [status EXCEPT ![p] = "pending"]
    /\ UNCHANGED <<epoch, version, alive, applied, admitted,
                    workLive, workOwner, workEpoch, workVersion>>

Current(p) == alive[p[1]] /\ epoch[p[1]] = capturedEpoch[p]
              /\ version[p[1]] = capturedVersion[p]
              /\ latest[p[1]] = p[2]

\* A catalog callback can arrive while the caller views either owner.
\* The native adapter re-enters the captured owner before committing.
Confirm(p, caller) ==
    /\ caller \in Owners /\ status[p] = "pending"
    /\ LET accept == Current(p) /\ ~workLive /\ version[p[1]] < MaxVersions
       IN /\ status' = [status EXCEPT ![p] = IF accept THEN "applied" ELSE "discarded"]
          /\ version' = IF accept THEN [version EXCEPT ![p[1]] = @ + 1] ELSE version
          /\ applied' = IF accept THEN [applied EXCEPT ![p] = @ + 1] ELSE applied
          /\ admitted' = IF accept THEN
                 [admitted EXCEPT ![p] = <<p[1], epoch[p[1]], version[p[1]]>>]
               ELSE admitted
    /\ UNCHANGED <<epoch, alive, generation, latest, capturedEpoch,
                    capturedVersion, workLive, workOwner, workEpoch, workVersion>>

Update(o) ==
    /\ alive[o] /\ ~workLive /\ version[o] < MaxVersions
    /\ version' = [version EXCEPT ![o] = @ + 1]
    /\ UNCHANGED <<epoch, alive, generation, latest, capturedEpoch,
                    capturedVersion, status, applied, admitted,
                    workLive, workOwner, workEpoch, workVersion>>

Replace(o) ==
    /\ alive[o] /\ epoch[o] = 1
    /\ epoch' = [epoch EXCEPT ![o] = 2]
    /\ version' = [version EXCEPT ![o] = 0]
    /\ UNCHANGED <<alive, generation, latest, capturedEpoch,
                    capturedVersion, status, applied, admitted,
                    workLive, workOwner, workEpoch, workVersion>>

Close(o) ==
    /\ alive[o] /\ alive' = [alive EXCEPT ![o] = FALSE]
    /\ UNCHANGED <<epoch, version, generation, latest, capturedEpoch,
                    capturedVersion, status, applied, admitted,
                    workLive, workOwner, workEpoch, workVersion>>

StartWork(o) ==
    /\ alive[o] /\ ~workLive
    /\ workLive' = TRUE /\ workOwner' = o
    /\ workEpoch' = epoch[o] /\ workVersion' = version[o]
    /\ UNCHANGED <<epoch, version, alive, generation, latest, capturedEpoch,
                    capturedVersion, status, applied, admitted>>

FinishWork ==
    /\ workLive /\ workLive' = FALSE
    /\ UNCHANGED <<epoch, version, alive, generation, latest, capturedEpoch,
                    capturedVersion, status, applied, admitted,
                    workOwner, workEpoch, workVersion>>

Quiescent == /\ \A o \in Owners : ~alive[o]
             /\ ~workLive /\ UNCHANGED vars

Next == (\E o \in Owners : Open(o) \/ Update(o) \/ Replace(o) \/ Close(o) \/ StartWork(o))
        \/ (\E p \in Pickers, caller \in Owners : Confirm(p, caller))
        \/ FinishWork \/ Quiescent
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ epoch \in [Owners -> 1..2]
    /\ version \in [Owners -> 0..MaxVersions]
    /\ alive \in [Owners -> BOOLEAN]
    /\ generation \in [Owners -> 0..MaxPickers]
    /\ latest \in [Owners -> 0..MaxPickers]
    /\ capturedEpoch \in [Pickers -> 1..2]
    /\ capturedVersion \in [Pickers -> 0..MaxVersions]
    /\ status \in [Pickers -> States]
    /\ applied \in [Pickers -> 0..1]
    /\ admitted \in [Pickers -> (Owners \X (1..2) \X (0..MaxVersions))]
    /\ workLive \in BOOLEAN /\ workOwner \in Owners
    /\ workEpoch \in 1..2 /\ workVersion \in 0..MaxVersions

Safety_OwnedAdmission == \A p \in Pickers : applied[p] > 0 =>
    admitted[p] = <<p[1], capturedEpoch[p], capturedVersion[p]>>
Safety_DiscardedCannotApply == \A p \in Pickers :
    status[p] = "discarded" => applied[p] = 0
Safety_FrozenSettings ==
    workLive /\ alive[workOwner] /\ epoch[workOwner] = workEpoch =>
        version[workOwner] = workVersion

=============================================================================
