-------------------------- MODULE KarguConnection --------------------------
EXTENDS Naturals, TLC

CONSTANTS Sessions, Endpoints, MaxRev, MaxRetries

VARIABLES
    session,
    endpoint,
    config_rev,
    phase,
    worker_alive,
    worker_session,
    worker_endpoint,
    worker_rev,
    snapshot,
    request_active,
    request_snapshot,
    retry_count

vars == <<session, endpoint, config_rev, phase, worker_alive,
          worker_session, worker_endpoint, worker_rev,
          snapshot, request_active, request_snapshot, retry_count>>

NoSnapshot == [
    session |-> "none",
    endpoint |-> "none",
    rev |-> 0,
    wiped |-> FALSE,
    valid |-> FALSE
]

Init ==
    /\ session \in Sessions
    /\ endpoint \in Endpoints
    /\ config_rev = 0
    /\ phase = "idle"
    /\ worker_alive = FALSE
    /\ worker_session = "none"
    /\ worker_endpoint = "none"
    /\ worker_rev = 0
    /\ snapshot = NoSnapshot
    /\ request_active = FALSE
    /\ request_snapshot = NoSnapshot
    /\ retry_count = 0

BumpConfig ==
    /\ config_rev < MaxRev
    /\ config_rev' = config_rev + 1
    /\ UNCHANGED <<session, endpoint, phase, worker_alive,
                   worker_session, worker_endpoint, worker_rev,
                   snapshot, request_active, request_snapshot, retry_count>>

SwitchSession(s) ==
    /\ s # session
    /\ session' = s
    /\ UNCHANGED <<endpoint, config_rev, phase, worker_alive,
                   worker_session, worker_endpoint, worker_rev,
                   snapshot, request_active, request_snapshot, retry_count>>

ChangeEndpoint(ep) ==
    /\ ep # endpoint
    /\ endpoint' = ep
    /\ UNCHANGED <<session, config_rev, phase, worker_alive,
                   worker_session, worker_endpoint, worker_rev,
                   snapshot, request_active, request_snapshot, retry_count>>

StartResolve ==
    /\ phase \in {"idle", "ready", "cancelled"}
    /\ phase' = "resolving"
    /\ worker_alive' = TRUE
    /\ worker_session' = session
    /\ worker_endpoint' = endpoint
    /\ worker_rev' = config_rev
    /\ UNCHANGED <<session, endpoint, config_rev, snapshot,
                   request_active, request_snapshot, retry_count>>

CancelResolve ==
    /\ phase = "resolving"
    /\ phase' = "cancelled"
    /\ worker_alive' = FALSE
    /\ UNCHANGED <<session, endpoint, config_rev, worker_session,
                   worker_endpoint, worker_rev, snapshot,
                   request_active, request_snapshot, retry_count>>

WorkerDeliver ==
    /\ phase = "resolving"
    /\ worker_alive
    /\ worker_alive' = FALSE
    /\ IF worker_session = session /\ worker_endpoint = endpoint /\ worker_rev = config_rev
       THEN /\ phase' = "ready"
            /\ snapshot' = [session |-> worker_session,
                            endpoint |-> worker_endpoint,
                            rev |-> worker_rev,
                            wiped |-> FALSE,
                            valid |-> TRUE]
       ELSE /\ phase' = "idle"  \* Stale resolution discarded; snapshot untouched
            /\ snapshot' = snapshot
    /\ UNCHANGED <<session, endpoint, config_rev, worker_session,
                   worker_endpoint, worker_rev, request_active,
                   request_snapshot, retry_count>>

StartRequest ==
    /\ ~request_active
    /\ snapshot.valid
    /\ snapshot.session = session
    /\ snapshot.endpoint = endpoint
    /\ ~snapshot.wiped
    /\ request_active' = TRUE
    /\ request_snapshot' = snapshot
    /\ retry_count' = 0
    /\ UNCHANGED <<session, endpoint, config_rev, phase, worker_alive,
                   worker_session, worker_endpoint, worker_rev, snapshot>>

RetryRequest ==
    /\ request_active
    /\ retry_count < MaxRetries
    /\ retry_count' = retry_count + 1
    /\ UNCHANGED <<session, endpoint, config_rev, phase, worker_alive,
                   worker_session, worker_endpoint, worker_rev, snapshot,
                   request_active, request_snapshot>>

FinishRequest ==
    /\ request_active
    /\ request_active' = FALSE
    /\ request_snapshot' = NoSnapshot
    /\ retry_count' = 0
    /\ UNCHANGED <<session, endpoint, config_rev, phase, worker_alive,
                   worker_session, worker_endpoint, worker_rev, snapshot>>

WipeScope ==
    /\ snapshot.valid
    /\ ~snapshot.wiped
    /\ snapshot' = [snapshot EXCEPT !.wiped = TRUE]
    /\ UNCHANGED <<session, endpoint, config_rev, phase, worker_alive,
                   worker_session, worker_endpoint, worker_rev,
                   request_active, request_snapshot, retry_count>>

Quiescent ==
    /\ ~worker_alive
    /\ ~request_active
    /\ UNCHANGED vars

Next ==
    \/ BumpConfig
    \/ (\E s \in Sessions : SwitchSession(s))
    \/ (\E ep \in Endpoints : ChangeEndpoint(ep))
    \/ StartResolve
    \/ CancelResolve
    \/ WorkerDeliver
    \/ StartRequest
    \/ RetryRequest
    \/ FinishRequest
    \/ WipeScope
    \/ Quiescent

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ session \in Sessions
    /\ endpoint \in Endpoints
    /\ config_rev \in 0..MaxRev
    /\ phase \in {"idle", "resolving", "ready", "cancelled"}
    /\ worker_alive \in BOOLEAN
    /\ worker_session \in Sessions \cup {"none"}
    /\ worker_endpoint \in Endpoints \cup {"none"}
    /\ worker_rev \in 0..MaxRev
    /\ snapshot \in [session : Sessions \cup {"none"},
                     endpoint : Endpoints \cup {"none"},
                     rev : 0..MaxRev,
                     wiped : BOOLEAN,
                     valid : BOOLEAN]
    /\ request_active \in BOOLEAN
    /\ request_snapshot \in [session : Sessions \cup {"none"},
                            endpoint : Endpoints \cup {"none"},
                            rev : 0..MaxRev,
                            wiped : BOOLEAN,
                            valid : BOOLEAN]
    /\ retry_count \in 0..MaxRetries

Safety_StaleDiscard ==
    /\ (snapshot.valid => snapshot.rev <= config_rev)
    /\ (phase = "ready" => snapshot.valid /\ snapshot.rev = worker_rev /\ snapshot.session = worker_session /\ snapshot.endpoint = worker_endpoint)

Safety_RetryPreservesSnapshot ==
    request_active => request_snapshot.valid

Safety_NoOrphanWorker ==
    worker_alive <=> (phase = "resolving")

Safety_WipedCannotLeak ==
    request_active => ~request_snapshot.wiped

=============================================================================
