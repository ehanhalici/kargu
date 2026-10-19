------------------------- MODULE KarguDiagnostics -------------------------
EXTENDS Naturals, TLC

\* One owned wait in lsp/freshness.el and settle.el after backend startup.
\* Verified means evidence is fresh, not that diagnostics contain no errors.
CONSTANT Backends
NoReport == <<2, 0>>
UnknownVersion == 3
VARIABLES phase, document, root, server, alive, generation, backendTick,
          disabled, reports, eglot, publication, deliveries, outcome,
          pollTimer, deadlineTimer
vars == <<phase, document, root, server, alive, generation, backendTick,
          disabled, reports, eglot, publication, deliveries, outcome,
          pollTimer, deadlineTimer>>

Init ==
    /\ phase = "waiting" /\ document = 1 /\ root = 0 /\ server = 0
    /\ alive = TRUE /\ generation = [b \in Backends |-> 0]
    /\ backendTick = [b \in Backends |-> 1]
    /\ disabled = {} /\ reports = [b \in Backends |-> NoReport]
    /\ eglot \in BOOLEAN /\ publication = <<UnknownVersion, 0, 1>>
    /\ deliveries = 0 /\ outcome = "pending"
    /\ pollTimer = TRUE /\ deadlineTimer = TRUE

Valid == alive /\ document = 1 /\ root = 0 /\ server = 0
         /\ disabled = {} /\ \A b \in Backends : generation[b] = 0
Fresh == (\A b \in Backends : reports[b] = <<0, 1>>)
         /\ (~eglot \/ publication = <<1, 0, 1>>)

Report(b, g, force) ==
    /\ phase = "waiting"
    /\ reports' = IF g = generation[b] /\ backendTick[b] = document
                   THEN [reports EXCEPT ![b] = <<g, document>>]
                   ELSE IF force THEN [reports EXCEPT ![b] = NoReport]
                   ELSE reports
    /\ UNCHANGED <<phase, document, root, server, alive, generation,
                    backendTick, disabled, eglot, publication, deliveries,
                    outcome, pollTimer, deadlineTimer>>

Restart(b) ==
    /\ phase = "waiting" /\ generation[b] = 0
    /\ generation' = [generation EXCEPT ![b] = 1]
    /\ backendTick' = [backendTick EXCEPT ![b] = document]
    /\ reports' = [reports EXCEPT ![b] = NoReport]
    /\ UNCHANGED <<phase, document, root, server, alive, disabled,
                    eglot, publication, deliveries, outcome, pollTimer, deadlineTimer>>

Disable(b) ==
    /\ phase = "waiting" /\ b \notin disabled
    /\ disabled' = disabled \cup {b}
    /\ UNCHANGED <<phase, document, root, server, alive, generation,
                    backendTick, reports, eglot, publication, deliveries,
                    outcome, pollTimer, deadlineTimer>>

Notify(version, source) ==
    /\ phase = "waiting" /\ eglot
    /\ publication' = IF source = server THEN <<version, source, document>>
                       ELSE publication
    /\ UNCHANGED <<phase, document, root, server, alive, generation,
                    backendTick, disabled, reports, eglot, deliveries,
                    outcome, pollTimer, deadlineTimer>>

Edit == /\ phase = "waiting" /\ document = 1 /\ document' = 2
        /\ UNCHANGED <<phase, root, server, alive, generation, backendTick,
                        disabled, reports, eglot, publication, deliveries,
                        outcome, pollTimer, deadlineTimer>>
ChangeRoot == /\ phase = "waiting" /\ root = 0 /\ root' = 1
              /\ UNCHANGED <<phase, document, server, alive, generation, backendTick,
                              disabled, reports, eglot, publication, deliveries,
                              outcome, pollTimer, deadlineTimer>>
ReplaceServer == /\ phase = "waiting" /\ server = 0 /\ server' = 1
                 /\ UNCHANGED <<phase, document, root, alive, generation, backendTick,
                                 disabled, reports, eglot, publication, deliveries,
                                 outcome, pollTimer, deadlineTimer>>
CloseBuffer == /\ phase = "waiting" /\ alive /\ alive' = FALSE
               /\ UNCHANGED <<phase, document, root, server, generation, backendTick,
                               disabled, reports, eglot, publication, deliveries,
                               outcome, pollTimer, deadlineTimer>>

Finish(result) ==
    /\ phase = "waiting" /\ phase' = "done"
    /\ deliveries' = deliveries + 1 /\ outcome' = result
    /\ pollTimer' = FALSE /\ deadlineTimer' = FALSE
    /\ UNCHANGED <<document, root, server, alive, generation, backendTick,
                    disabled, reports, eglot, publication>>
PollFresh == Valid /\ Fresh /\ Finish("verified")
PollInvalid == ~Valid /\ Finish("unavailable")
Deadline == Finish("timeout")
Cancel ==
    /\ phase = "waiting" /\ phase' = "cancelled"
    /\ pollTimer' = FALSE /\ deadlineTimer' = FALSE
    /\ UNCHANGED <<document, root, server, alive, generation, backendTick,
                    disabled, reports, eglot, publication, deliveries, outcome>>
Quiescent == /\ phase # "waiting" /\ UNCHANGED vars
Next == (\E b \in Backends, g \in 0..1, force \in BOOLEAN : Report(b, g, force))
        \/ (\E b \in Backends : Restart(b) \/ Disable(b))
        \/ (\E version \in 0..UnknownVersion, source \in 0..1 : Notify(version, source))
        \/ Edit \/ ChangeRoot \/ ReplaceServer \/ CloseBuffer
        \/ PollFresh \/ PollInvalid \/ Deadline \/ Cancel \/ Quiescent
Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in {"waiting", "done", "cancelled"}
    /\ document \in 1..2 /\ root \in 0..1 /\ server \in 0..1
    /\ alive \in BOOLEAN /\ eglot \in BOOLEAN
    /\ generation \in [Backends -> 0..1] /\ backendTick \in [Backends -> 1..2]
    /\ disabled \subseteq Backends
    /\ reports \in [Backends -> ({NoReport} \cup ((0..1) \X (1..2)))]
    /\ publication \in (0..UnknownVersion) \X (0..1) \X (1..2)
    /\ deliveries \in 0..1
    /\ outcome \in {"pending", "verified", "unavailable", "timeout"}
    /\ pollTimer \in BOOLEAN /\ deadlineTimer \in BOOLEAN
Safety_VerifiedEvidence == outcome = "verified" => Valid /\ Fresh
Safety_CancelledNoDelivery == phase = "cancelled" => deliveries = 0
Safety_ClosedResources == phase # "waiting" => ~pollTimer /\ ~deadlineTimer
=============================================================================
