---------------------------- MODULE KarguState ----------------------------
(***************************************************************************)
(* Formal specification of Kargu Centralized State Store & Transitions.    *)
(* Faithfully mirrors:                                                     *)
(*   - `kargu/state/store.el`       (State plist store & mutex/hooks)      *)
(*   - `kargu/state/selectors.el`   (Pure queries: mode, status, busy, etc)*)
(*   - `kargu/state/transitions.el` (Validated lifecycle mutations)        *)
(***************************************************************************)

EXTENDS Naturals, Sequences, FiniteSets, TLC

(***************************************************************************)
(* State Domains & Constants                                               *)
(***************************************************************************)

StateStatuses == {
    ":idle",
    ":requesting",
    ":waiting-model",
    ":executing-tools",
    ":verifying",
    ":compacting",
    ":pause",
    ":done",
    ":limit",
    ":stopped",
    ":error"
}

StateModes == {"ask", "plan", "debug", "agent"}

StateEfforts == {"none", "low", "medium", "high", "off"}

(***************************************************************************)
(* Pure State Schema                                                       *)
(***************************************************************************)

MakeState(status, mode, provider, model, effort, busy, pTokens, cTokens) == [
    status     |-> status,
    mode       |-> mode,
    provider   |-> provider,
    model      |-> model,
    effort     |-> effort,
    busy       |-> busy,
    pTokens    |-> pTokens,
    cTokens    |-> cTokens,
    totalTokens|-> pTokens + cTokens
]

InitState(defaultMode, defaultProvider, defaultModel) == [
    status     |-> ":idle",
    mode       |-> defaultMode,
    provider   |-> defaultProvider,
    model      |-> defaultModel,
    effort     |-> "none",
    busy       |-> FALSE,
    pTokens    |-> 0,
    cTokens    |-> 0,
    totalTokens|-> 0
]

(***************************************************************************)
(* Status classes (mirror `kargu-state-transition-status' and              *)
(* `kargu-state-busy-p')                                                   *)
(***************************************************************************)

\* Waiting for the user (`:pause') is not busy, but the run is still alive.
BusyOf(status) ==
    status \notin {":idle", ":stopped", ":error", ":done", ":limit", ":pause"}

\* A run exists.  `kargu-state-set-mode' refuses while this holds.
RunLiveStatus(status) ==
    status \notin {":idle", ":done", ":limit", ":stopped", ":error"}

(***************************************************************************)
(* Pure State Selectors (Mirrors `kargu/state/selectors.el')                *)
(***************************************************************************)

GetStatus(st)   == st.status
GetMode(st)     == st.mode
GetProvider(st) == st.provider
GetModel(st)    == st.model
GetEffort(st)   == st.effort
GetBusy(st)     == st.busy \/ BusyOf(st.status)
GetTotalTokens(st) == st.totalTokens

(***************************************************************************)
(* Lifecycle Transitions (Mirrors `kargu/state/transitions.el')            *)
(***************************************************************************)

\* Transition status updates both status and busy flag coherently
TransitionStatus(st, nextStatus) ==
    [st EXCEPT !.status = nextStatus, !.busy = BusyOf(nextStatus)]

\* Transition mode: refused (state unchanged) while a run exists
TransitionMode(st, nextMode) ==
    IF nextMode \in StateModes /\ ~RunLiveStatus(st.status)
    THEN [st EXCEPT !.mode = nextMode]
    ELSE st

\* Transition provider
TransitionProvider(st, nextProvider) ==
    [st EXCEPT !.provider = nextProvider]

\* Transition model
TransitionModel(st, nextModel) ==
    [st EXCEPT !.model = nextModel]

\* Transition reasoning effort
TransitionEffort(st, nextEffort) ==
    IF nextEffort \in StateEfforts
    THEN [st EXCEPT !.effort = nextEffort]
    ELSE st

\* Record cumulative tokens
RecordTokens(st, promptIncr, compIncr) ==
    [st EXCEPT !.pTokens = st.pTokens + promptIncr,
               !.cTokens = st.cTokens + compIncr,
               !.totalTokens = st.totalTokens + promptIncr + compIncr]

(***************************************************************************)
(* State Invariants                                                        *)
(***************************************************************************)

StateInvariant(st) ==
    /\ st.status \in StateStatuses
    /\ st.mode \in StateModes
    /\ st.effort \in StateEfforts
    /\ st.busy \in BOOLEAN
    /\ st.totalTokens = st.pTokens + st.cTokens
    /\ st.busy = BusyOf(st.status)

=============================================================================
