-------------------------- MODULE KarguTransport --------------------------
EXTENDS Naturals, TLC

CONSTANTS
    Providers,
    MaxRequests,
    MaxRetries,
    Threshold,
    MaxStreamBytes

VARIABLES
    req_state,
    req_provider,
    req_attempt,
    req_stream_bytes,
    budget_spent,
    budget_status,
    circuit_state,
    circuit_failures,
    circuit_probe,
    resources,
    callbacks_delivered

vars == <<req_state, req_provider, req_attempt, req_stream_bytes,
          budget_spent, budget_status, circuit_state, circuit_failures,
          circuit_probe, resources, callbacks_delivered>>

Init ==
    /\ req_state = "idle"
    /\ req_provider = "none"
    /\ req_attempt = 0
    /\ req_stream_bytes = 0
    /\ budget_spent = 0
    /\ budget_status = "ok"
    /\ circuit_state = [p \in Providers |-> "closed"]
    /\ circuit_failures = [p \in Providers |-> 0]
    /\ circuit_probe = [p \in Providers |-> FALSE]
    /\ resources = {}
    /\ callbacks_delivered = 0

CircuitAllow(p) ==
    /\ circuit_state[p] # "open"
    /\ ~(circuit_state[p] = "half_open" /\ circuit_probe[p])

StartRequest(p) ==
    /\ req_state \in {"idle", "finished", "cancelled", "error"}
    /\ CircuitAllow(p)
    /\ budget_status = "ok"
    /\ budget_spent < MaxRequests
    /\ budget_spent' = budget_spent + 1
    /\ budget_status' = IF budget_spent + 1 >= MaxRequests THEN "exhausted" ELSE "ok"
    /\ circuit_probe' = [circuit_probe EXCEPT ![p] = (circuit_state[p] = "half_open")]
    /\ req_state' = "in_flight"
    /\ req_provider' = p
    /\ req_attempt' = 1
    /\ req_stream_bytes' = 0
    /\ resources' = {"process", "watch_timer"}
    /\ callbacks_delivered' = 0
    /\ UNCHANGED <<circuit_state, circuit_failures>>

ReceiveChunk(bytes) ==
    /\ req_state = "in_flight"
    /\ LET newBytes == req_stream_bytes + bytes IN
       IF newBytes > MaxStreamBytes
       THEN /\ req_state' = "error"
            /\ req_stream_bytes' = newBytes
            /\ resources' = {}
            /\ callbacks_delivered' = 1
            /\ LET p == req_provider
                   newF == IF circuit_failures[p] < Threshold THEN circuit_failures[p] + 1 ELSE Threshold IN
               /\ circuit_failures' = [circuit_failures EXCEPT ![p] = newF]
               /\ circuit_state' = [circuit_state EXCEPT ![p] =
                                    IF circuit_state[p] = "half_open" \/ newF >= Threshold
                                    THEN "open" ELSE circuit_state[p]]
               /\ circuit_probe' = [circuit_probe EXCEPT ![p] = FALSE]
            /\ UNCHANGED <<req_provider, req_attempt, budget_spent, budget_status>>
       ELSE /\ req_stream_bytes' = newBytes
            /\ UNCHANGED <<req_state, req_provider, req_attempt, budget_spent,
                           budget_status, circuit_state, circuit_failures,
                           circuit_probe, resources, callbacks_delivered>>

DeliverSuccess ==
    /\ req_state = "in_flight"
    /\ req_state' = "finished"
    /\ resources' = {}
    /\ callbacks_delivered' = 1
    /\ LET p == req_provider IN
       /\ circuit_state' = [circuit_state EXCEPT ![p] = "closed"]
       /\ circuit_failures' = [circuit_failures EXCEPT ![p] = 0]
       /\ circuit_probe' = [circuit_probe EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<req_provider, req_attempt, req_stream_bytes, budget_spent, budget_status>>

FailAndRetry ==
    /\ req_state = "in_flight"
    /\ req_attempt < MaxRetries
    /\ budget_status = "ok"
    /\ budget_spent < MaxRequests
    /\ budget_spent' = budget_spent + 1
    /\ budget_status' = IF budget_spent + 1 >= MaxRequests THEN "exhausted" ELSE "ok"
    /\ req_state' = "retrying"
    /\ resources' = {"retry_timer"}
    /\ req_attempt' = req_attempt + 1
    /\ UNCHANGED <<req_provider, req_stream_bytes, circuit_state,
                   circuit_failures, circuit_probe, callbacks_delivered>>

FireRetry ==
    /\ req_state = "retrying"
    /\ req_state' = "in_flight"
    /\ resources' = {"process", "watch_timer"}
    /\ req_stream_bytes' = 0
    /\ UNCHANGED <<req_provider, req_attempt, budget_spent, budget_status,
                   circuit_state, circuit_failures, circuit_probe, callbacks_delivered>>

FailTerminal ==
    /\ req_state = "in_flight"
    /\ req_state' = "error"
    /\ resources' = {}
    /\ callbacks_delivered' = 1
    /\ LET p == req_provider
           newF == IF circuit_failures[p] < Threshold THEN circuit_failures[p] + 1 ELSE Threshold IN
       /\ circuit_failures' = [circuit_failures EXCEPT ![p] = newF]
       /\ circuit_state' = [circuit_state EXCEPT ![p] =
                            IF circuit_state[p] = "half_open" \/ newF >= Threshold
                            THEN "open" ELSE circuit_state[p]]
       /\ circuit_probe' = [circuit_probe EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<req_provider, req_attempt, req_stream_bytes, budget_spent, budget_status>>

Cancel ==
    /\ req_state \in {"in_flight", "retrying"}
    /\ req_state' = "cancelled"
    /\ resources' = {}
    /\ LET p == req_provider IN
       /\ circuit_probe' = [circuit_probe EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<req_provider, req_attempt, req_stream_bytes, budget_spent,
                   budget_status, circuit_state, circuit_failures, callbacks_delivered>>

Cooldown(p) ==
    /\ circuit_state[p] = "open"
    /\ circuit_state' = [circuit_state EXCEPT ![p] = "half_open"]
    /\ UNCHANGED <<req_state, req_provider, req_attempt, req_stream_bytes,
                   budget_spent, budget_status, circuit_failures,
                   circuit_probe, resources, callbacks_delivered>>

Quiescent ==
    /\ req_state \in {"idle", "finished", "cancelled", "error"}
    /\ UNCHANGED vars

Next ==
    \/ (\E p \in Providers : StartRequest(p))
    \/ (\E b \in 1..2 : ReceiveChunk(b))
    \/ DeliverSuccess
    \/ FailAndRetry
    \/ FireRetry
    \/ FailTerminal
    \/ Cancel
    \/ (\E p \in Providers : Cooldown(p))
    \/ Quiescent

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ req_state \in {"idle", "in_flight", "retrying", "finished", "cancelled", "error"}
    /\ req_attempt \in 0..MaxRetries
    /\ req_stream_bytes \in 0..(MaxStreamBytes + 2)
    /\ budget_spent \in 0..MaxRequests
    /\ budget_status \in {"ok", "exhausted"}
    /\ circuit_state \in [Providers -> {"closed", "open", "half_open"}]
    /\ circuit_failures \in [Providers -> 0..Threshold]
    /\ circuit_probe \in [Providers -> BOOLEAN]
    /\ resources \subseteq {"process", "retry_timer", "watch_timer"}
    /\ callbacks_delivered \in 0..1

Safety_BudgetNeverExceeded ==
    budget_spent <= MaxRequests

Safety_SingleHandleOwnership ==
    /\ req_state \in {"idle", "finished", "cancelled", "error"} => resources = {}
    /\ req_state = "retrying" => resources = {"retry_timer"}
    /\ req_state = "in_flight" => resources = {"process", "watch_timer"}

Safety_CircuitIsolation ==
    \A p1, p2 \in Providers :
        (p1 # p2 /\ circuit_state[p1] = "open") =>
            (circuit_failures[p2] < Threshold => circuit_state[p2] # "open")

Safety_StreamBoundsEnforced ==
    (req_stream_bytes <= MaxStreamBytes) \/ (req_state = "error")

Safety_SingleCallbackDelivery ==
    callbacks_delivered <= 1

=============================================================================
