----------------------------- MODULE KarguLoop -----------------------------
(***************************************************************************)
(* Formal specification of Kargu's agent loop: `kargu/loop.el' and         *)
(* `kargu/loop/*.el'.                                                      *)
(*                                                                         *)
(* One action per row of the code's handler tables:                        *)
(*   request path   `kargu-loop--on-request'  (classify -> handler)        *)
(*   response path  `kargu/loop--on-response' (classify -> handler)        *)
(*   after a tool   `kargu-loop--on-after-tool'                            *)
(*   compaction     `kargu-loop--on-compaction'                            *)
(*                                                                         *)
(* The three places where the run waits for the user are states of their   *)
(* own, because the code answers them by callback and never blocks:        *)
(*   PAUSE      turn limit reached       (`kargu-loop--prompt-continue')   *)
(*   RECOVER    request failed           (`kargu-loop--recover-or-finish') *)
(*   DOOM_WAIT  third identical tool call (`kargu-loop--request-doom-approval') *)
(*                                                                         *)
(* Modules composed:                                                       *)
(*   `KarguContract.tla' roles, modes, message schema                      *)
(*   `KarguProtocol.tla' history repair (the protocol wall)                *)
(*   `KarguCircuit.tla'  circuit breaker                                   *)
(*   `KarguTools.tla'    mode gate and doom-loop signatures                *)
(*   `KarguState.tla'    status store; the loop state maps onto it         *)
(***************************************************************************)

EXTENDS Naturals, Sequences, FiniteSets, TLC,
        KarguContract, KarguProtocol, KarguCircuit, KarguTools, KarguState

CONSTANTS
    MaxIterations,          \* Turns per batch; also the size of one `Continue'
    MaxHealing,             \* Cap on self-healing rounds (`kargu-max-healing-steps')
    MaxEmptyRetries,        \* Cap on empty-reply retries (`kargu-loop-empty-retries')
    MaxUpstreamRetries,     \* Cap on upstream retries (`kargu-loop-upstream-retries')
    CompactionThreshold,    \* History length that makes compaction due
    CompactKeepCount,       \* Messages kept after compaction
    CircuitFailureThreshold \* Consecutive failures that trip the breaker

(***************************************************************************)
(* States of the loop                                                      *)
(***************************************************************************)

States == {
    "IDLE",         \* No run yet
    "REQUEST",      \* Classifying the next request
    "WAIT_MODEL",   \* HTTP/SSE request in flight
    "EXEC_TOOLS",   \* Working through the tool queue
    "DOOM_WAIT",    \* Waiting for the user: third identical tool call
    "VERIFY_FILES", \* Collecting diagnostics after an edit
    "COMPACT_WAIT", \* Summary turn in flight
    "PAUSE",        \* Waiting for the user: turn limit reached
    "RECOVER",      \* Waiting for the user: retry or stop after a failure
    "DONE",         \* Finished with an answer
    "LIMIT",        \* Stopped at the turn limit
    "ERROR",        \* Aborted
    "STOPPED"       \* Stopped by `kargu-loop-stop'
}

RunOver == {"IDLE", "DONE", "LIMIT", "ERROR", "STOPPED"}
RunLive == States \ RunOver

\* The status the state store shows for each loop state (`kargu-loop--set-state')
StatusOf(s) ==
    CASE s = "IDLE"         -> ":idle"
      [] s = "REQUEST"      -> ":requesting"
      [] s = "WAIT_MODEL"   -> ":waiting-model"
      [] s = "RECOVER"      -> ":waiting-model"
      [] s = "EXEC_TOOLS"   -> ":executing-tools"
      [] s = "DOOM_WAIT"    -> ":executing-tools"
      [] s = "VERIFY_FILES" -> ":verifying"
      [] s = "COMPACT_WAIT" -> ":compacting"
      [] s = "PAUSE"        -> ":pause"
      [] s = "DONE"         -> ":done"
      [] s = "LIMIT"        -> ":limit"
      [] s = "ERROR"        -> ":error"
      [] s = "STOPPED"      -> ":stopped"

(***************************************************************************)
(* Variables                                                               *)
(***************************************************************************)

VARIABLES
    state,                  \* Current state \in States
    history,                \* Sequence of message records
    activeMode,             \* Interaction mode; fixed while a run is live
    iterations,             \* Model round trips of this run
    turnCap,                \* Turn cap of this run; each `Continue' adds one batch
    healing,                \* Self-healing rounds used
    verifications,          \* Verifications performed
    emptyRetries,           \* Empty-reply retries used
    upstreamRetries,        \* Upstream retries used
    compactions,            \* Compactions this run (0..1)
    lengthContinues,        \* Truncation continues this run (0..1)
    doomSigs,               \* Last two tool signatures, newest first
    pendingToolQueue,       \* Tool calls of the current assistant turn not yet run
    pendingToolCall,        \* The call whose edit is being verified
    pendingVerifyFiles,     \* Files awaiting diagnostics
    noTools,                \* `:no-tools' of the run
    savedNoTools,           \* `:saved-no-tools': `noTools' before compaction
    compacting,             \* `:compacting' of the run
    runStatus,              \* Finish status
    generation,             \* Request generation (`kargu--generation')
    circuitState,           \* Circuit breaker state
    circuitFailures         \* Consecutive failures

Counters == <<iterations, turnCap, healing, verifications, emptyRetries,
              upstreamRetries, compactions, lengthContinues>>
ToolVars == <<doomSigs, pendingToolQueue, pendingToolCall, pendingVerifyFiles>>
Flags    == <<noTools, savedNoTools, compacting>>
Circuit  == <<circuitState, circuitFailures>>

vars == <<state, history, activeMode, Counters, ToolVars, Flags,
          runStatus, generation, Circuit>>

NoCall == [id |-> "none", name |-> "none", arguments |-> ""]

(***************************************************************************)
(* Initial state                                                           *)
(***************************************************************************)

Init ==
    /\ state              = "IDLE"
    /\ history            = << >>
    /\ activeMode         \in AllModes
    /\ iterations         = 0
    /\ turnCap            = MaxIterations
    /\ healing            = 0
    /\ verifications      = 0
    /\ emptyRetries       = 0
    /\ upstreamRetries    = 0
    /\ compactions        = 0
    /\ lengthContinues    = 0
    /\ doomSigs           = << >>
    /\ pendingToolQueue   = << >>
    /\ pendingToolCall    = NoCall
    /\ pendingVerifyFiles = {}
    /\ noTools            = FALSE
    /\ savedNoTools       = FALSE
    /\ compacting         = FALSE
    /\ runStatus          = "none"
    /\ generation         = 0
    /\ circuitState       = "CLOSED"
    /\ circuitFailures    = 0

(***************************************************************************)
(* A run starts with fresh counters (`kargu-loop-send')                    *)
(***************************************************************************)

FreshRun ==
    /\ iterations         ' = 0
    /\ turnCap            ' = MaxIterations
    /\ healing            ' = 0
    /\ verifications      ' = 0
    /\ emptyRetries       ' = 0
    /\ upstreamRetries    ' = 0
    /\ compactions        ' = 0
    /\ lengthContinues    ' = 0
    /\ doomSigs           ' = << >>
    /\ pendingToolQueue   ' = << >>
    /\ pendingToolCall    ' = NoCall
    /\ pendingVerifyFiles ' = {}
    /\ noTools            ' = FALSE
    /\ savedNoTools       ' = FALSE
    /\ compacting         ' = FALSE
    /\ generation         ' = generation + 1

(***************************************************************************)
(* Actions                                                                 *)
(***************************************************************************)

(* StartRun / FollowUpPrompt: `kargu-loop-send'.  Refused while a run is    *)
(* live, so both need the run to be over.                                   *)
StartRun(prompt) ==
    /\ AssertIngress(ContractPrompt(prompt), "StartRun: Prompt must be non-empty")
    /\ state = "IDLE"
    /\ LET sysMsg == MakeMsg("system", "system-prompt-" \o activeMode, << >>, "none", "none")
           usrMsg == MakeMsg("user", prompt, << >>, "none", "none")
       IN history ' = IF Len(history) = 0 THEN <<sysMsg, usrMsg>> ELSE Append(history, usrMsg)
    /\ state     ' = "REQUEST"
    /\ runStatus ' = "none"
    /\ FreshRun
    /\ UNCHANGED <<activeMode, Circuit>>

FollowUpPrompt(prompt) ==
    /\ AssertIngress(ContractPrompt(prompt), "FollowUpPrompt: Prompt must be non-empty")
    /\ state \in {"DONE", "STOPPED", "ERROR", "LIMIT"}
    /\ history   ' = Append(history, MakeMsg("user", prompt, << >>, "none", "none"))
    /\ state     ' = "REQUEST"
    /\ runStatus ' = "none"
    /\ FreshRun
    /\ UNCHANGED <<activeMode, Circuit>>

(* SetMode: `kargu-state-set-mode' refuses while a run is live (law 3) *)
SetMode(newMode) ==
    /\ AssertIngress(ContractMode(newMode), "SetMode: Mode must satisfy ContractMode")
    /\ state \in RunOver
    /\ newMode # activeMode
    /\ activeMode ' = newMode
    /\ UNCHANGED <<state, history, Counters, ToolVars, Flags, runStatus,
                   generation, Circuit>>

(* ResetSession: `kargu-session-reset'.  The advice stops a live run first. *)
ResetSession ==
    /\ state              ' = "IDLE"
    /\ history            ' = << >>
    /\ runStatus          ' = "none"
    /\ FreshRun
    /\ circuitState       ' = "CLOSED"
    /\ circuitFailures    ' = 0
    /\ UNCHANGED activeMode

(***************************************************************************)
(* Request path: `kargu-loop--classify-request'                            *)
(*   stale (not modelled: the run is live by construction)                 *)
(*   busy  (not modelled: one compaction turn at a time)                   *)
(*   compact | send                                                        *)
(***************************************************************************)

CompactDue ==
    /\ ~compacting
    /\ compactions < 1
    /\ Len(history) >= CompactionThreshold
    /\ iterations < turnCap

(* `kargu--loop-start-compact': a compaction turn counts as an iteration *)
StartCompaction ==
    /\ compactions ' = compactions + 1
    /\ iterations  ' = iterations + 1
    /\ compacting  ' = TRUE
    /\ savedNoTools' = noTools
    /\ noTools     ' = TRUE
    /\ state       ' = "COMPACT_WAIT"

RequestCompact ==
    /\ state = "REQUEST"
    /\ CompactDue
    /\ StartCompaction
    /\ UNCHANGED <<history, activeMode, healing, verifications, emptyRetries,
                   upstreamRetries, lengthContinues, turnCap, ToolVars,
                   runStatus, generation, Circuit>>

(* `kargu-loop--request-send' at the cap: ask the user instead of sending *)
RequestPause ==
    /\ state = "REQUEST"
    /\ iterations >= turnCap
    /\ state ' = "PAUSE"
    /\ UNCHANGED <<history, activeMode, Counters, ToolVars, Flags, runStatus,
                   generation, Circuit>>

(* `kargu-loop--send-model': the wall cleans the history before it leaves *)
RequestSend ==
    /\ state = "REQUEST"
    /\ ~CompactDue
    /\ iterations < turnCap
    /\ AssertIngress(CircuitAllowRequest(circuitState), "RequestSend: Circuit must allow request")
    /\ LET cleanHist == ValidateHistory(history, "strip")
       IN /\ AssertIngress(ProtocolFirewallValid(cleanHist),
                           "RequestSend: Ingress history must be valid")
          /\ history ' = cleanHist
    /\ state      ' = "WAIT_MODEL"
    /\ iterations ' = iterations + 1
    /\ UNCHANGED <<activeMode, healing, verifications, emptyRetries,
                   upstreamRetries, compactions, lengthContinues, turnCap,
                   ToolVars, Flags, runStatus, generation, Circuit>>

(* An open breaker turns the send into an error answer (`kargu--api-post') *)
RequestBlocked ==
    /\ state = "REQUEST"
    /\ ~CompactDue
    /\ iterations < turnCap
    /\ circuitState = "OPEN"
    /\ state      ' = "RECOVER"
    /\ iterations ' = iterations + 1
    /\ UNCHANGED <<history, activeMode, healing, verifications, emptyRetries,
                   upstreamRetries, compactions, lengthContinues, turnCap,
                   ToolVars, Flags, runStatus, generation, Circuit>>

(***************************************************************************)
(* Response path: `kargu-loop--classify-response' -> `kargu/loop--on-response' *)
(***************************************************************************)

(* answer *)
ModelReceiveAnswer(answerText) ==
    /\ state = "WAIT_MODEL"
    /\ AssertIngress(answerText # "", "ModelReceiveAnswer: Answer text must not be empty")
    /\ history         ' = Append(history, MakeMsg("assistant", answerText, << >>, "none", "none"))
    /\ state           ' = "DONE"
    /\ runStatus       ' = "done"
    /\ circuitState    ' = "CLOSED"
    /\ circuitFailures ' = 0
    /\ UNCHANGED <<activeMode, Counters, ToolVars, Flags, generation>>

(* tools: only when tools are enabled for the run (`kargu-tools-enabled-p') *)
ModelReceiveToolCalls(calls) ==
    /\ state = "WAIT_MODEL"
    /\ ~noTools
    /\ AssertIngress(ContractToolCalls(calls) /\ Len(calls) > 0,
                     "ModelReceiveToolCalls: Invalid tool calls")
    /\ history          ' = Append(history, MakeMsg("assistant", "", calls, "none", "none"))
    /\ pendingToolQueue ' = calls
    /\ state            ' = "EXEC_TOOLS"
    /\ circuitState     ' = "CLOSED"
    /\ circuitFailures  ' = 0
    /\ UNCHANGED <<activeMode, Counters, doomSigs, pendingToolCall,
                   pendingVerifyFiles, Flags, runStatus, generation>>

(* length: one `Continue.' per run, and only below the cap.  Otherwise a    *)
(* truncated reply is judged as an answer or as empty.                      *)
ModelReceiveLengthTruncated ==
    /\ state = "WAIT_MODEL"
    /\ lengthContinues < 1
    /\ iterations < turnCap
    /\ lengthContinues ' = lengthContinues + 1
    /\ state           ' = "REQUEST"
    /\ circuitState    ' = "CLOSED"
    /\ circuitFailures ' = 0
    /\ UNCHANGED <<history, activeMode, iterations, turnCap, healing,
                   verifications, emptyRetries, upstreamRetries, compactions,
                   ToolVars, Flags, runStatus, generation>>

(* overflow: compact once; if that is not possible the user decides *)
ModelReceiveOverflow ==
    /\ state = "WAIT_MODEL"
    /\ circuitState    ' = "CLOSED"
    /\ circuitFailures ' = 0
    /\ IF ~compacting /\ compactions < 1 /\ iterations < turnCap
       THEN /\ StartCompaction
       ELSE /\ state ' = "RECOVER"
            /\ UNCHANGED <<compactions, iterations, compacting, savedNoTools, noTools>>
    /\ UNCHANGED <<history, activeMode, healing, verifications, emptyRetries,
                   upstreamRetries, lengthContinues, turnCap, ToolVars,
                   runStatus, generation>>

(* empty *)
ModelReceiveEmpty ==
    /\ state = "WAIT_MODEL"
    /\ IF emptyRetries < MaxEmptyRetries
       THEN /\ emptyRetries ' = emptyRetries + 1
            /\ state        ' = "REQUEST"
            /\ runStatus    ' = "none"
       ELSE /\ state        ' = "DONE"
            /\ runStatus    ' = "done"
            /\ UNCHANGED emptyRetries
    /\ UNCHANGED <<history, activeMode, iterations, turnCap, healing,
                   verifications, upstreamRetries, compactions, lengthContinues,
                   ToolVars, Flags, generation, Circuit>>

(* upstream-retry / retryable error: the HTTP layer has already recorded the *)
(* failure in the breaker.  With retries left the run retries unless the     *)
(* breaker is open; without retries the user decides.                        *)
ModelReceiveUpstreamError ==
    /\ state = "WAIT_MODEL"
    /\ LET cb == CircuitRecordFailure(circuitState, circuitFailures, CircuitFailureThreshold)
       IN /\ circuitState    ' = cb.state
          /\ circuitFailures ' = cb.failures
          /\ IF upstreamRetries < MaxUpstreamRetries
             THEN /\ upstreamRetries ' = upstreamRetries + 1
                  /\ state           ' = IF cb.state = "OPEN" THEN "RECOVER" ELSE "REQUEST"
             ELSE /\ state           ' = "RECOVER"
                  /\ UNCHANGED upstreamRetries
    /\ UNCHANGED <<history, activeMode, iterations, turnCap, healing,
                   verifications, emptyRetries, compactions, lengthContinues,
                   ToolVars, Flags, runStatus, generation>>

(* error / content-filter: any other failure.  The breaker is not touched. *)
ModelReceiveError ==
    /\ state = "WAIT_MODEL"
    /\ state ' = "RECOVER"
    /\ UNCHANGED <<history, activeMode, Counters, ToolVars, Flags, runStatus,
                   generation, Circuit>>

(* tools-unsupported: the provider refused tool use.  Agent mode cannot work *)
(* without tools and ends; other modes retry tool-free.                      *)
ModelReceiveToolsUnsupported ==
    /\ state = "WAIT_MODEL"
    /\ ~noTools
    /\ IF activeMode = "agent"
       THEN /\ state     ' = "ERROR"
            /\ runStatus ' = "error"
            /\ UNCHANGED noTools
       ELSE /\ state     ' = "REQUEST"
            /\ noTools   ' = TRUE
            /\ UNCHANGED runStatus
    /\ UNCHANGED <<history, activeMode, Counters, ToolVars, savedNoTools,
                   compacting, generation, Circuit>>

(***************************************************************************)
(* RECOVER: the user's answer to `kargu-loop--recover-or-finish'           *)
(***************************************************************************)

RecoverRetry ==
    /\ state = "RECOVER"
    /\ state           ' = "REQUEST"
    /\ upstreamRetries ' = 0
    /\ circuitState    ' = "CLOSED"
    /\ circuitFailures ' = 0
    /\ UNCHANGED <<history, activeMode, iterations, turnCap, healing,
                   verifications, emptyRetries, compactions, lengthContinues,
                   ToolVars, Flags, runStatus, generation>>

RecoverStop ==
    /\ state = "RECOVER"
    /\ state     ' = "ERROR"
    /\ runStatus ' = "error"
    /\ UNCHANGED <<history, activeMode, Counters, ToolVars, Flags, generation, Circuit>>

(***************************************************************************)
(* Tools: `kargu--loop-run-call' and `kargu-loop--classify-after-tool'     *)
(***************************************************************************)

(* Run CALL, store its result and move on.  NEWSIGS is the signature history *)
(* afterwards.  An applied edit is verified while the healing budget lasts;  *)
(* with the budget spent the files are consumed and the run goes on.         *)
ToolStep(call, newSigs) ==
    LET allowed == GateToolAllowed(call.name, activeMode)
        outText == IF allowed THEN "tool-result-for-" \o call.id
                   ELSE GateToolError(call.name, activeMode)
        result  == MakeToolResult(call.id, call.name, outText)
        verify  == allowed /\ IsMutatingTool(call.name) /\ healing < MaxHealing
    IN
    /\ history          ' = Append(history, result)
    /\ pendingToolQueue ' = Tail(pendingToolQueue)
    /\ doomSigs         ' = newSigs
    /\ pendingVerifyFiles ' = IF verify THEN {call.arguments} ELSE {}
    /\ pendingToolCall  ' = IF verify THEN call ELSE NoCall
    /\ state            ' = IF verify THEN "VERIFY_FILES"
                            ELSE IF Tail(pendingToolQueue) = << >> THEN "REQUEST"
                            ELSE "EXEC_TOOLS"
    /\ UNCHANGED <<activeMode, Counters, Flags, runStatus, generation, Circuit>>

ExecuteNextTool ==
    /\ state = "EXEC_TOOLS"
    /\ pendingToolQueue # << >>
    /\ LET call == Head(pendingToolQueue)
           sig  == ToolSignature(call)
       IN /\ AssertIngress(ContractToolCall(call),
                           "ExecuteNextTool: Call must satisfy ContractToolCall")
          /\ IF DoomLoopDetected(doomSigs, sig)
             THEN /\ state ' = "DOOM_WAIT"
                  /\ UNCHANGED <<history, activeMode, Counters, doomSigs,
                                 pendingToolQueue, pendingToolCall,
                                 pendingVerifyFiles, Flags, runStatus,
                                 generation, Circuit>>
             ELSE ToolStep(call, PushSig(doomSigs, sig))

(* The user approves the repeated call: the signatures reset and the call runs *)
DoomApprove ==
    /\ state = "DOOM_WAIT"
    /\ ToolStep(Head(pendingToolQueue), << >>)

(* The user refuses: every call of the turn is answered and the run ends *)
DoomStop ==
    /\ state = "DOOM_WAIT"
    /\ LET call == Head(pendingToolQueue)
           rest == Tail(pendingToolQueue)
           doomResult == MakeToolResult(call.id, call.name,
                            "ERROR: identical tool call repeated 3 times in a row (doom loop). Stopping.")
           flushed == [k \in 1..Len(rest) |->
                        MakeToolResult(rest[k].id, rest[k].name, "ERROR: run stopped (doom loop).")]
       IN history ' = history \o <<doomResult>> \o flushed
    /\ pendingToolQueue   ' = << >>
    /\ pendingToolCall    ' = NoCall
    /\ pendingVerifyFiles ' = {}
    /\ state              ' = "ERROR"
    /\ runStatus          ' = "error"
    /\ UNCHANGED <<activeMode, Counters, doomSigs, Flags, generation, Circuit>>

(* VerifyFiles: `kargu--loop-verify-files'.  Entered only with budget left. *)
VerifyFiles(diagnosticError) ==
    /\ state = "VERIFY_FILES"
    /\ pendingVerifyFiles # {}
    /\ verifications      ' = verifications + 1
    /\ pendingVerifyFiles ' = {}
    /\ pendingToolCall    ' = NoCall
    /\ state              ' = IF pendingToolQueue = << >> THEN "REQUEST" ELSE "EXEC_TOOLS"
    /\ healing            ' = IF diagnosticError /\ healing < MaxHealing
                              THEN healing + 1 ELSE healing
    /\ UNCHANGED <<history, activeMode, iterations, turnCap, emptyRetries,
                   upstreamRetries, compactions, lengthContinues, doomSigs,
                   pendingToolQueue, Flags, runStatus, generation, Circuit>>

(***************************************************************************)
(* Compaction result: `kargu-loop--on-compaction'                          *)
(***************************************************************************)

CompactionFinish(success) ==
    /\ state = "COMPACT_WAIT"
    /\ AssertIngress(ContractHistory(history), "CompactionFinish: Ingress history must be valid")
    /\ compacting ' = FALSE
    /\ noTools    ' = savedNoTools
    /\ savedNoTools ' = FALSE
    /\ IF success
       THEN /\ history  ' = ApplyCompaction(history, "Summary of previous turns", CompactKeepCount)
            /\ state    ' = "REQUEST"
            /\ UNCHANGED runStatus
       ELSE /\ state     ' = "ERROR"      \* failed or empty summary ends the run
            /\ runStatus ' = "error"
            /\ UNCHANGED history
    /\ UNCHANGED <<activeMode, Counters, ToolVars, generation, Circuit>>

(***************************************************************************)
(* User decisions and cancellation                                         *)
(***************************************************************************)

(* `kargu-loop-stop': from any live state.  The finish repairs the history, *)
(* which answers every open tool call, and keeps a trailing answer.         *)
UserStop ==
    /\ state \in RunLive
    /\ history            ' = ValidateHistory(history, "keep")
    /\ state              ' = "STOPPED"
    /\ runStatus          ' = "stopped"
    /\ pendingToolQueue   ' = << >>
    /\ pendingToolCall    ' = NoCall
    /\ pendingVerifyFiles ' = {}
    /\ compacting         ' = FALSE
    /\ noTools            ' = FALSE
    /\ savedNoTools       ' = FALSE
    /\ UNCHANGED <<activeMode, Counters, doomSigs, generation, Circuit>>

(* `kargu-loop--apply-continue-decision' :continue: one more batch *)
PauseDecisionContinue ==
    /\ state = "PAUSE"
    /\ state     ' = "REQUEST"
    /\ turnCap   ' = turnCap + MaxIterations
    /\ UNCHANGED <<history, activeMode, iterations, healing, verifications,
                   emptyRetries, upstreamRetries, compactions, lengthContinues,
                   ToolVars, Flags, runStatus, generation, Circuit>>

(* :stop *)
PauseDecisionStop ==
    /\ state = "PAUSE"
    /\ state     ' = "LIMIT"
    /\ runStatus ' = "limit"
    /\ UNCHANGED <<history, activeMode, Counters, ToolVars, Flags, generation, Circuit>>

(* The breaker leaves OPEN after its cooldown (`kargu-circuit--cooling-p') *)
CircuitCooldownCanaryAction ==
    /\ circuitState = "OPEN"
    /\ circuitState ' = "HALF_OPEN"
    /\ UNCHANGED <<state, history, activeMode, Counters, ToolVars, Flags,
                   runStatus, generation, circuitFailures>>

(***************************************************************************)
(* Safety invariants                                                       *)
(***************************************************************************)

TypeOK ==
    /\ state \in States
    /\ ContractHistory(history)
    /\ activeMode \in AllModes
    /\ circuitState \in CircuitStates
    /\ circuitFailures \in 0..CircuitFailureThreshold
    /\ iterations \in 0..turnCap
    /\ turnCap \in Nat /\ turnCap >= MaxIterations
    /\ healing \in 0..MaxHealing
    /\ verifications \in Nat
    /\ emptyRetries \in 0..MaxEmptyRetries
    /\ upstreamRetries \in 0..MaxUpstreamRetries
    /\ compactions \in 0..1       \* one compaction per run
    /\ lengthContinues \in 0..1   \* one `Continue.' per truncation
    /\ Len(doomSigs) <= 2
    /\ noTools \in BOOLEAN
    /\ savedNoTools \in BOOLEAN
    /\ compacting \in BOOLEAN
    /\ runStatus \in {"none", "done", "limit", "error", "stopped"}
    /\ generation \in Nat

\* Law 4: every request leaves through the wall
Safety_ProtocolFirewallInWaitModel ==
    state = "WAIT_MODEL" => ProtocolFirewallValid(history)

\* Read-only modes never edit and never verify
Safety_ModeSafety ==
    (activeMode \notin MutatingModes) =>
        (/\ state # "VERIFY_FILES"
         /\ pendingVerifyFiles = {})

\* Law 3: the mode does not change while a run is live, and the loop state
\* always maps onto a valid status of the state store
Safety_StateStoreCoherent ==
    /\ StateInvariant(TransitionStatus(InitState(activeMode, "provider", "model"), StatusOf(state)))
    /\ RunLiveStatus(StatusOf(state)) <=> state \in RunLive

\* One turn cap per run, moved only by a user's Continue
Safety_BoundedIterations ==
    iterations <= turnCap

\* Every terminal state has answered every tool call (finish repairs history)
Safety_AllTerminalStatesAnswered ==
    state \in {"DONE", "LIMIT", "ERROR", "STOPPED"} => AllToolCallsAnswered(history)

Safety_NoToolQueueOutsideExec ==
    state \notin {"EXEC_TOOLS", "DOOM_WAIT", "VERIFY_FILES"} =>
        (/\ pendingToolQueue = <<>>
         /\ pendingToolCall.id = "none")

Safety_NoPendingVerifyOutsideVerify ==
    state # "VERIFY_FILES" => pendingVerifyFiles = {}

\* A model request is never sent through an open breaker
Safety_CircuitBreakerSoundness ==
    state = "WAIT_MODEL" => circuitState # "OPEN"

\* Law 5: with tools off, no tool work is in progress
Safety_ToolsOffMeansNoToolWork ==
    noTools => state \notin {"EXEC_TOOLS", "DOOM_WAIT", "VERIFY_FILES"}

\* Where the run waits for the user, nothing else is in flight
Safety_WaitingForUserIsIdle ==
    state \in {"PAUSE", "RECOVER"} =>
        (/\ pendingToolQueue = <<>>
         /\ pendingToolCall.id = "none"
         /\ pendingVerifyFiles = {}
         /\ ~compacting)

\* The compaction flag is set exactly while the summary turn is in flight
Safety_CompactingMatchesState ==
    compacting <=> state = "COMPACT_WAIT"

=============================================================================
