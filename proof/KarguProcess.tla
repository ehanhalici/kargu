--------------------------- MODULE KarguProcess ---------------------------
EXTENDS Naturals, TLC

\* One invocation of tools/process.el. Complete stdout records are bounded;
\* oversized records and stderr are abstracted by a byte-failure event.
\* Kernel signals and EOF delivery are external events, not assumed instant.
CONSTANT MaxLines
VARIABLES phase, ready, mainClosed, stderrClosed, timerLive, lines,
          limited, byteFailure, timedOut, stopRequested, deliveries, outcome
vars == <<phase, ready, mainClosed, stderrClosed, timerLive, lines,
          limited, byteFailure, timedOut, stopRequested, deliveries, outcome>>

Init ==
    /\ phase = "starting" /\ ready = FALSE
    /\ mainClosed = FALSE /\ stderrClosed \in BOOLEAN
    /\ timerLive = FALSE /\ lines = 0
    /\ limited = FALSE /\ byteFailure = FALSE /\ timedOut = FALSE
    /\ stopRequested = FALSE /\ deliveries = 0 /\ outcome = "pending"

ArmTimer ==
    /\ phase = "starting" /\ ~timerLive
    /\ timerLive' = TRUE
    /\ UNCHANGED <<phase, ready, mainClosed, stderrClosed, lines, limited,
                    byteFailure, timedOut, stopRequested, deliveries, outcome>>

Publish ==
    /\ phase = "starting"
    /\ phase' = "running" /\ ready' = TRUE
    /\ UNCHANGED <<mainClosed, stderrClosed, timerLive, lines, limited,
                    byteFailure, timedOut, stopRequested, deliveries, outcome>>

ReceiveLine(oversized) ==
    /\ phase # "closed" /\ ~mainClosed /\ ~stopRequested
    /\ lines < MaxLines
    /\ lines' = lines + 1 /\ limited' = (lines' = MaxLines)
    /\ byteFailure' = oversized
    /\ stopRequested' = (limited' \/ oversized)
    /\ stderrClosed' = (stderrClosed \/ stopRequested')
    /\ UNCHANGED <<phase, ready, mainClosed, timerLive, timedOut,
                    deliveries, outcome>>

ByteOverflow ==
    /\ phase # "closed" /\ ~stopRequested
    /\ byteFailure' = TRUE /\ stopRequested' = TRUE /\ stderrClosed' = TRUE
    /\ UNCHANGED <<phase, ready, mainClosed, timerLive, lines, limited,
                    timedOut, deliveries, outcome>>

Cancel ==
    /\ phase # "closed" /\ ~stopRequested
    /\ stopRequested' = TRUE /\ stderrClosed' = TRUE
    /\ UNCHANGED <<phase, ready, mainClosed, timerLive, lines, limited,
                    byteFailure, timedOut, deliveries, outcome>>

Deadline ==
    /\ phase # "closed" /\ timerLive /\ ~timedOut
    /\ timedOut' = TRUE /\ stopRequested' = TRUE /\ stderrClosed' = TRUE
    /\ UNCHANGED <<phase, ready, mainClosed, timerLive, lines, limited,
                    byteFailure, deliveries, outcome>>

MainExit ==
    /\ phase # "closed" /\ ~mainClosed
    /\ mainClosed' = TRUE
    /\ UNCHANGED <<phase, ready, stderrClosed, timerLive, lines, limited,
                    byteFailure, timedOut, stopRequested, deliveries, outcome>>

StderrEOF ==
    /\ phase # "closed" /\ ~stderrClosed
    /\ stderrClosed' = TRUE
    /\ UNCHANGED <<phase, ready, mainClosed, timerLive, lines, limited,
                    byteFailure, timedOut, stopRequested, deliveries, outcome>>

Deliver ==
    /\ phase = "running" /\ mainClosed /\ stderrClosed
    /\ phase' = "closed" /\ timerLive' = FALSE
    /\ deliveries' = deliveries + 1
    /\ outcome' = IF byteFailure \/ timedOut THEN "failure"
                   ELSE IF limited THEN "limited" ELSE "finished"
    /\ UNCHANGED <<ready, mainClosed, stderrClosed, lines, limited,
                    byteFailure, timedOut, stopRequested>>

StartupFailure ==
    /\ phase = "starting"
    /\ phase' = "closed" /\ mainClosed' = TRUE /\ stderrClosed' = TRUE
    /\ timerLive' = FALSE /\ stopRequested' = TRUE
    /\ deliveries' = deliveries + 1 /\ outcome' = "startup-failure"
    /\ UNCHANGED <<ready, lines, limited, byteFailure, timedOut>>

Quiescent == /\ phase = "closed" /\ UNCHANGED vars
Next == ArmTimer \/ Publish \/ (\E oversized \in BOOLEAN : ReceiveLine(oversized))
        \/ ByteOverflow \/ Cancel \/ Deadline \/ MainExit \/ StderrEOF
        \/ Deliver \/ StartupFailure \/ Quiescent
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in {"starting", "running", "closed"}
    /\ <<ready, mainClosed, stderrClosed, timerLive, limited,
          byteFailure, timedOut, stopRequested>> \in BOOLEAN \X BOOLEAN \X BOOLEAN
           \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN
    /\ lines \in 0..MaxLines /\ deliveries \in 0..1
    /\ outcome \in {"pending", "finished", "limited", "failure", "startup-failure"}
Safety_DeliveryReady == deliveries > 0 =>
    phase = "closed" /\ (ready \/ outcome = "startup-failure")
Safety_ClosedResources == phase = "closed" =>
    mainClosed /\ stderrClosed /\ ~timerLive
Safety_LimitStopsProducer == limited => stopRequested
Safety_LimitedDoesNotHideFailure == outcome = "limited" =>
    limited /\ ~byteFailure /\ ~timedOut
Safety_FinishedNotLimited == outcome = "finished" =>
    ~limited /\ ~byteFailure /\ ~timedOut
=============================================================================
