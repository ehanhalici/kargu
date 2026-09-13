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
(* Pure State Selectors (Mirrors `kargu/state/selectors.el')                *)
(***************************************************************************)

GetStatus(st)   == st.status
GetMode(st)     == st.mode
GetProvider(st) == st.provider
GetModel(st)    == st.model
GetEffort(st)   == st.effort
GetBusy(st)     == st.busy \/ (st.status \notin {":idle", ":stopped", ":error"})
GetTotalTokens(st) == st.totalTokens

(***************************************************************************)
(* Lifecycle Transitions (Mirrors `kargu/state/transitions.el')            *)
(***************************************************************************)

\* Transition status updates both status and busy flag coherently
TransitionStatus(st, nextStatus) ==
    LET nextBusy == nextStatus \notin {":idle", ":stopped", ":error"}
    IN [st EXCEPT !.status = nextStatus, !.busy = nextBusy]

\* Transition mode with safety validation
TransitionMode(st, nextMode) ==
    IF nextMode \in StateModes
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
    /\ (st.status \in {":idle", ":stopped", ":error"} => st.busy = FALSE)
    /\ (st.status \notin {":idle", ":stopped", ":error"} => st.busy = TRUE)

=============================================================================
