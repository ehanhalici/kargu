----------------------------- MODULE KarguLoop -----------------------------
(***************************************************************************)
(* Complete, one-to-one formal specification of Kargu's Autonomous Agent   *)
(* Loop state machine, tool queuing, mode safety gating, self-healing,     *)
(* history compaction, circuit breaker, multi-turn conversations,          *)
(* mode switching, and session resets.                                     *)
(*                                                                         *)
(* Modules composed:                                                       *)
(*   - `KarguContract.tla` (Roles, modes, message schemas, invariants)     *)
(*   - `KarguProtocol.tla` (Protocol firewall, history validation, ROP)   *)
(*   - `KarguCircuit.tla`  (Circuit breaker state machine, thresholds)     *)
(*   - `KarguTools.tla`    (Tool queue, mode gating, doom loop detection)  *)
(***************************************************************************)

EXTENDS Naturals, Sequences, FiniteSets, TLC,
        KarguContract, KarguProtocol, KarguCircuit, KarguTools, KarguState

CONSTANTS
    MaxIterations,          \* Cap on model roundtrips per run (e.g. 2..4)
    MaxHealing,             \* Cap on auto-diagnostic healing rounds (e.g. 1..3)
    MaxEmptyRetries,        \* Cap on empty response retries (e.g. 1..2)
    MaxUpstreamRetries,     \* Cap on 502/overload retries (e.g. 1..2)
    CompactionThreshold,    \* Minimum history length to trigger compaction
    CompactKeepCount,       \* Number of recent messages to preserve in tail
    MutatingTools,          \* {"edit_file", "write_file", "bash"}
    ReadOnlyTools,          \* {"read_file", "lsp_skeleton", "grep"}
    ToolCallPool,           \* Sequence of prototype tool calls
    CircuitFailureThreshold \* Consecutive failures to trip circuit (default 4)

(***************************************************************************)
(* States of the Agent Loop                                                *)
(***************************************************************************)

States == {
    "IDLE",         \* Ready for initial user prompt
    "REQUEST",      \* Preparing and classifying next request
    "WAIT_MODEL",   \* HTTP/SSE request in flight to LLM
    "EXEC_TOOLS",   \* Processing assistant tool call queue
    "VERIFY_FILES", \* Collecting LSP diagnostics for post-edit healing
    "COMPACT_WAIT", \* Compacting history via summary turn
    "PAUSE",        \* Awaiting user decision at turn limit (interactive continuation)
    "DONE",         \* Run finished successfully (final answer delivered)
    "ERROR",        \* Run aborted due to error (doom loop, API fail, etc.)
    "STOPPED"       \* Run cancelled by user (`kargu-loop-stop`)
}

(***************************************************************************)
(* Variables                                                               *)
(***************************************************************************)

VARIABLES
    state,                  \* Current state \in States
    history,                \* Sequence of message records
    activeMode,             \* Current interaction mode \in AllModes
    iterations,             \* Model roundtrip counter (0..MaxIterations+1)
    healing,                \* Self-healing error round counter (0..MaxHealing)
    verifications,          \* Number of LSP verification checks performed
    emptyRetries,           \* Number of empty response retries (0..MaxEmptyRetries)
    upstreamRetries,        \* Number of upstream retries (0..MaxUpstreamRetries)
    compactions,            \* Compaction counter (0..1)
    lengthContinues,        \* Max-token length continue counter (0..1)
    doomSigs,               \* Sequence of recent tool signatures (for doom loop)
    pendingToolQueue,       \* Tool calls remaining in current assistant turn
    pendingToolCall,        \* Currently executing tool call
    pendingVerifyFiles,     \* Files needing LSP diagnostics after edit
    noTools,                \* Gate: tools disabled on max steps or compaction
    compacting,             \* Boolean: currently inside compaction turn
    runStatus,              \* Finish status ("none", "done", "limit", "error", "stopped")
    generation,             \* Generation counter (`kargu--generation`)
    circuitState,           \* Circuit breaker state \in CircuitStates
    circuitFailures          \* Consecutive failures counter (0..CircuitFailureThreshold)

vars == <<state, history, activeMode, iterations, healing, verifications,
          emptyRetries, upstreamRetries, compactions, lengthContinues,
          doomSigs, pendingToolQueue, pendingToolCall, pendingVerifyFiles,
          noTools, compacting, runStatus, generation,
          circuitState, circuitFailures>>

(***************************************************************************)
(* Initial State                                                           *)
(***************************************************************************)

Init ==
    /\ state              = "IDLE"
    /\ history            = << >>
    /\ activeMode         \in AllModes
    /\ iterations         = 0
    /\ healing            = 0
    /\ verifications      = 0
    /\ emptyRetries       = 0
    /\ upstreamRetries    = 0
    /\ compactions        = 0
    /\ lengthContinues    = 0
    /\ doomSigs           = << >>
    /\ pendingToolQueue   = << >>
    /\ pendingToolCall    = [id |-> "none", name |-> "none", arguments |-> ""]
    /\ pendingVerifyFiles = {}
    /\ noTools            = FALSE
    /\ compacting         = FALSE
    /\ runStatus          = "none"
    /\ generation         = 0
    /\ circuitState       = "CLOSED"
    /\ circuitFailures    = 0

(***************************************************************************)
(* Actions with Ingress & Egress Contracts                                 *)
(***************************************************************************)

(* 1. StartRun: User sends initial prompt to start an agent run *)
StartRun(prompt) ==
    /\ AssertIngress(ContractPrompt(prompt), "StartRun: Prompt must be non-empty")
    /\ state = "IDLE"
    /\ LET sysMsg  == MakeMsg("system", "system-prompt-" \o activeMode, << >>, "none", "none")
           usrMsg  == MakeMsg("user", prompt, << >>, "none", "none")
           newHist == IF Len(history) = 0 THEN <<sysMsg, usrMsg>> ELSE Append(history, usrMsg)
       IN
       /\ history            ' = newHist
       /\ state              ' = "REQUEST"
       /\ iterations         ' = 0
       /\ healing            ' = 0
       /\ verifications      ' = 0
       /\ emptyRetries       ' = 0
       /\ upstreamRetries    ' = 0
       /\ compactions        ' = 0
       /\ lengthContinues    ' = 0
       /\ doomSigs           ' = << >>
       /\ pendingToolQueue   ' = << >>
       /\ pendingToolCall    ' = [id |-> "none", name |-> "none", arguments |-> ""]
       /\ pendingVerifyFiles ' = {}
       /\ noTools            ' = FALSE
       /\ compacting         ' = FALSE
       /\ runStatus          ' = "none"
       /\ generation         ' = generation + 1
       /\ UNCHANGED <<activeMode, circuitState, circuitFailures>>

(* 2. FollowUpPrompt: User sends follow-up in multi-turn conversation *)
FollowUpPrompt(prompt) ==
    /\ AssertIngress(ContractPrompt(prompt), "FollowUpPrompt: Prompt must be non-empty")
    /\ state \in {"DONE", "STOPPED"}
    /\ state              ' = "REQUEST"
    /\ runStatus          ' = "none"
    /\ history            ' = Append(history, MakeMsg("user", prompt, << >>, "none", "none"))
    /\ iterations         ' = 0
    /\ healing            ' = 0
    /\ verifications      ' = 0
    /\ emptyRetries       ' = 0
    /\ upstreamRetries    ' = 0
    /\ compactions        ' = 0
    /\ lengthContinues    ' = 0
    /\ doomSigs           ' = << >>
    /\ pendingToolQueue   ' = << >>
    /\ pendingToolCall    ' = [id |-> "none", name |-> "none", arguments |-> ""]
    /\ pendingVerifyFiles ' = {}
    /\ noTools            ' = FALSE
    /\ compacting         ' = FALSE
    /\ generation         ' = generation + 1
    /\ UNCHANGED <<activeMode, circuitState, circuitFailures>>

(* 3. SetMode: User switches mode when no run is active *)
SetMode(newMode) ==
    /\ AssertIngress(ContractMode(newMode), "SetMode: Mode must satisfy ContractMode")
    /\ state \in {"IDLE", "DONE", "ERROR", "STOPPED"}
    /\ newMode # activeMode
    /\ activeMode ' = newMode
    /\ UNCHANGED <<state, history, iterations, healing, verifications,
                   emptyRetries, upstreamRetries, compactions, lengthContinues,
                   doomSigs, pendingToolQueue, pendingToolCall, pendingVerifyFiles,
                   noTools, compacting, runStatus, generation,
                   circuitState, circuitFailures>>

(* 4. ResetSession: Resets conversation history and loop counters *)
ResetSession ==
    /\ state              ' = "IDLE"
    /\ history            ' = << >>
    /\ runStatus          ' = "none"
    /\ iterations         ' = 0
    /\ healing            ' = 0
    /\ verifications      ' = 0
    /\ emptyRetries       ' = 0
    /\ upstreamRetries    ' = 0
    /\ compactions        ' = 0
    /\ lengthContinues    ' = 0
    /\ doomSigs           ' = << >>
    /\ pendingToolQueue   ' = << >>
    /\ pendingToolCall    ' = [id |-> "none", name |-> "none", arguments |-> ""]
    /\ pendingVerifyFiles ' = {}
    /\ noTools            ' = FALSE
    /\ compacting         ' = FALSE
    /\ generation         ' = generation + 1
    /\ circuitState       ' = "CLOSED"
    /\ circuitFailures    ' = 0
    /\ UNCHANGED activeMode

(* 5. RequestSend: Classify and dispatch next model request *)
RequestSend ==
    /\ state = "REQUEST"
    /\ AssertIngress(CircuitAllowRequest(circuitState), "RequestSend: Circuit must allow request")
    /\ IF ~compacting /\ compactions < 1 /\ Len(history) >= CompactionThreshold
       THEN
           \* Trigger compaction turn
           /\ state       ' = "COMPACT_WAIT"
           /\ compacting  ' = TRUE
           /\ compactions ' = compactions + 1
           /\ iterations  ' = iterations + 1
           /\ noTools     ' = TRUE
           /\ UNCHANGED <<history, activeMode, healing, verifications,
                          emptyRetries, upstreamRetries, lengthContinues,
                          doomSigs, pendingToolQueue, pendingToolCall,
                          pendingVerifyFiles, runStatus, generation,
                          circuitState, circuitFailures>>
       ELSE
           \* Send normal request to model
           IF iterations >= MaxIterations
           THEN
               \* Iteration limit reached: finish run with limit
               /\ state      ' = "DONE"
               /\ runStatus  ' = "limit"
               /\ UNCHANGED <<history, activeMode, iterations, healing, verifications,
                              emptyRetries, upstreamRetries, compactions, lengthContinues,
                              doomSigs, pendingToolQueue, pendingToolCall,
                              pendingVerifyFiles, noTools, compacting, generation,
                              circuitState, circuitFailures>>
           ELSE
               LET onLastStep == (iterations + 1) >= MaxIterations
                   cleanHist  == ValidateHistory(history, "strip")
               IN
               /\ AssertIngress(ProtocolFirewallValid(cleanHist), "RequestSend: Ingress history must be valid")
               /\ state       ' = "WAIT_MODEL"
               /\ history     ' = cleanHist
               /\ iterations  ' = iterations + 1
               /\ noTools     ' = onLastStep
               /\ UNCHANGED <<activeMode, healing, verifications, emptyRetries,
                              upstreamRetries, compactions, lengthContinues,
                              doomSigs, pendingToolQueue, pendingToolCall,
                              pendingVerifyFiles, compacting, runStatus, generation,
                              circuitState, circuitFailures>>

(* 6. ModelReceiveAnswer: Model returns textual answer *)
ModelReceiveAnswer(answerText) ==
    /\ state = "WAIT_MODEL"
    /\ AssertIngress(answerText # "", "ModelReceiveAnswer: Answer text must not be empty")
    /\ LET asstMsg == MakeMsg("assistant", answerText, << >>, "none", "none")
       IN
       /\ history         ' = Append(history, asstMsg)
       /\ state           ' = "DONE"
       /\ runStatus       ' = IF noTools /\ iterations >= MaxIterations THEN "limit" ELSE "done"
       /\ circuitState    ' = "CLOSED"
       /\ circuitFailures ' = 0
       /\ UNCHANGED <<activeMode, iterations, healing, verifications,
                      emptyRetries, upstreamRetries, compactions, lengthContinues,
                      doomSigs, pendingToolQueue, pendingToolCall,
                      pendingVerifyFiles, noTools, compacting, generation>>

(* 7. ModelReceiveToolCalls: Model dispatches tool calls *)
ModelReceiveToolCalls(calls) ==
    /\ state = "WAIT_MODEL"
    /\ ~noTools
    /\ AssertIngress(ContractToolCalls(calls) /\ Len(calls) > 0, "ModelReceiveToolCalls: Invalid tool calls")
    /\ LET asstMsg == MakeMsg("assistant", "", calls, "none", "none")
       IN
       /\ history          ' = Append(history, asstMsg)
       /\ pendingToolQueue ' = calls
       /\ state            ' = "EXEC_TOOLS"
       /\ circuitState     ' = "CLOSED"
       /\ circuitFailures  ' = 0
       /\ UNCHANGED <<activeMode, iterations, healing, verifications,
                      emptyRetries, upstreamRetries, compactions, lengthContinues,
                      doomSigs, pendingToolCall, pendingVerifyFiles,
                      noTools, compacting, runStatus, generation>>

(* 8. ModelReceiveLengthTruncated: Context truncated by token limit *)
ModelReceiveLengthTruncated ==
    /\ state = "WAIT_MODEL"
    /\ IF lengthContinues < 1
       THEN
           /\ lengthContinues ' = lengthContinues + 1
           /\ state           ' = "REQUEST"
           /\ runStatus       ' = "none"
       ELSE
           /\ state           ' = "DONE"
           /\ runStatus       ' = "limit"
           /\ UNCHANGED lengthContinues
    /\ circuitState    ' = "CLOSED"
    /\ circuitFailures ' = 0
    /\ UNCHANGED <<history, activeMode, iterations, healing, verifications,
                   emptyRetries, upstreamRetries, compactions, doomSigs,
                   pendingToolQueue, pendingToolCall, pendingVerifyFiles,
                   noTools, compacting, generation>>

(* 9. ModelReceiveOverflow: Context overflow *)
ModelReceiveOverflow ==
    /\ state = "WAIT_MODEL"
    /\ IF compactions < 1
       THEN
           /\ state       ' = "REQUEST"
           /\ noTools     ' = TRUE
           /\ runStatus   ' = "none"
       ELSE
           /\ state       ' = "DONE"
           /\ runStatus   ' = "limit"
           /\ UNCHANGED noTools
    /\ circuitState    ' = "CLOSED"
    /\ circuitFailures ' = 0
    /\ UNCHANGED <<history, activeMode, iterations, healing, verifications,
                   emptyRetries, upstreamRetries, compactions, lengthContinues,
                   doomSigs, pendingToolQueue, pendingToolCall,
                   pendingVerifyFiles, compacting, generation>>

(* 10. ModelReceiveEmpty: Model returns empty response *)
ModelReceiveEmpty ==
    /\ state = "WAIT_MODEL"
    /\ IF emptyRetries < MaxEmptyRetries
       THEN
           /\ emptyRetries ' = emptyRetries + 1
           /\ state        ' = "REQUEST"
           /\ runStatus    ' = "none"
       ELSE
           /\ state        ' = "ERROR"
           /\ runStatus    ' = "error"
           /\ UNCHANGED emptyRetries
    /\ UNCHANGED <<history, activeMode, iterations, healing, verifications,
                   upstreamRetries, compactions, lengthContinues, doomSigs,
                   pendingToolQueue, pendingToolCall, pendingVerifyFiles,
                   noTools, compacting, generation, circuitState, circuitFailures>>

(* 11. ModelReceiveUpstreamError: Upstream provider or network error *)
ModelReceiveUpstreamError ==
    /\ state = "WAIT_MODEL"
    /\ LET cb == CircuitRecordFailure(circuitState, circuitFailures, CircuitFailureThreshold)
       IN
       /\ circuitState    ' = cb.state
       /\ circuitFailures ' = cb.failures
       /\ IF upstreamRetries < MaxUpstreamRetries /\ cb.state # "OPEN"
          THEN
              /\ upstreamRetries ' = upstreamRetries + 1
              /\ state           ' = "REQUEST"
              /\ runStatus       ' = "none"
          ELSE
              /\ state           ' = "ERROR"
              /\ runStatus       ' = "error"
              /\ UNCHANGED upstreamRetries
       /\ UNCHANGED <<history, activeMode, iterations, healing, verifications,
                      emptyRetries, compactions, lengthContinues, doomSigs,
                      pendingToolQueue, pendingToolCall, pendingVerifyFiles,
                      noTools, compacting, generation>>

(* 12. ExecuteNextTool: Process sequential tool calls *)
ExecuteNextTool ==
    /\ state = "EXEC_TOOLS"
    /\ pendingToolQueue # << >>
    /\ LET call == Head(pendingToolQueue)
           sig  == ToolSignature(call)
       IN
       /\ AssertIngress(ContractToolCall(call), "ExecuteNextTool: Call must satisfy ContractToolCall")
       /\ IF DoomLoopDetected(doomSigs, sig)
          THEN
              \* Doom loop: 3 identical tool calls. Abort run immediately.
              LET doomResult == MakeToolResult(call.id, call.name,
                                 "ERROR: identical tool call repeated 3 times in a row (doom loop). Stopping.")
                  tailQueue  == Tail(pendingToolQueue)
                  flushedRest == [k \in 1..Len(tailQueue) |->
                                  MakeToolResult(tailQueue[k].id, tailQueue[k].name,
                                                 "ERROR: run stopped (doom loop).")]
              IN
              /\ history            ' = history \o <<doomResult>> \o flushedRest
              /\ pendingToolQueue   ' = << >>
              /\ pendingToolCall    ' = [id |-> "none", name |-> "none", arguments |-> ""]
              /\ pendingVerifyFiles ' = {}
              /\ state              ' = "ERROR"
              /\ runStatus          ' = "error"
              /\ doomSigs           ' = <<sig>> \o doomSigs
              /\ UNCHANGED <<activeMode, iterations, healing, verifications,
                             emptyRetries, upstreamRetries, compactions, lengthContinues,
                             noTools, compacting, generation, circuitState, circuitFailures>>
          ELSE
              \* Check mode safety gate
              LET allowed == GateToolAllowed(call.name, activeMode)
                  outText == IF allowed
                             THEN "tool-result-for-" \o call.id
                             ELSE GateToolError(call.name, activeMode)
                  result  == MakeToolResult(call.id, call.name, outText)
                  isMut   == allowed /\ IsMutatingTool(call.name)
              IN
              /\ history          ' = Append(history, result)
              /\ pendingToolQueue ' = Tail(pendingToolQueue)
              /\ doomSigs         ' = <<sig>> \o doomSigs
              /\ IF isMut
                 THEN
                     /\ pendingVerifyFiles ' = {call.arguments}
                     /\ pendingToolCall    ' = call
                     /\ state              ' = "VERIFY_FILES"
                 ELSE
                     /\ pendingVerifyFiles ' = {}
                     /\ pendingToolCall    ' = [id |-> "none", name |-> "none", arguments |-> ""]
                     /\ state              ' = IF Tail(pendingToolQueue) = << >>
                                               THEN "REQUEST"
                                               ELSE "EXEC_TOOLS"
              /\ UNCHANGED <<activeMode, iterations, healing, verifications,
                             emptyRetries, upstreamRetries, compactions, lengthContinues,
                             noTools, compacting, runStatus, generation,
                             circuitState, circuitFailures>>

(* 13. VerifyFiles: LSP diagnostics post-edit healing *)
VerifyFiles(diagnosticError) ==
    /\ state = "VERIFY_FILES"
    /\ pendingVerifyFiles # {}
    /\ verifications ' = verifications + 1
    /\ pendingVerifyFiles ' = {}
    /\ pendingToolCall    ' = [id |-> "none", name |-> "none", arguments |-> ""]
    /\ state              ' = IF pendingToolQueue = << >> THEN "REQUEST" ELSE "EXEC_TOOLS"
    /\ IF diagnosticError /\ healing < MaxHealing
       THEN
           /\ healing ' = healing + 1
       ELSE
           /\ UNCHANGED healing
    /\ UNCHANGED <<history, activeMode, iterations, emptyRetries, upstreamRetries,
                   compactions, lengthContinues, doomSigs, pendingToolQueue,
                   noTools, compacting, runStatus, generation,
                   circuitState, circuitFailures>>

(* 14. CompactionFinish: Summary completed *)
CompactionFinish(success) ==
    /\ state = "COMPACT_WAIT"
    /\ AssertIngress(ContractHistory(history), "CompactionFinish: Ingress history must be valid")
    /\ IF success
       THEN
           /\ history    ' = ApplyCompaction(history, "Summary of previous turns", CompactKeepCount)
           /\ state      ' = "REQUEST"
           /\ compacting ' = FALSE
           /\ noTools    ' = FALSE
       ELSE
           /\ state      ' = "REQUEST"
           /\ compacting ' = FALSE
           /\ noTools    ' = FALSE
           /\ UNCHANGED history
    /\ UNCHANGED <<activeMode, iterations, healing, verifications,
                   emptyRetries, upstreamRetries, compactions, lengthContinues,
                   doomSigs, pendingToolQueue, pendingToolCall, pendingVerifyFiles,
                   runStatus, generation, circuitState, circuitFailures>>

(* 15. UserStop: Asynchronous cancellation (`kargu-loop-stop') *)
UserStop ==
    /\ state \in {"WAIT_MODEL", "EXEC_TOOLS", "VERIFY_FILES"}
    /\ LET cleanHist == ValidateHistory(history, "strip")
       IN
       /\ history            ' = cleanHist
       /\ state              ' = "STOPPED"
       /\ runStatus          ' = "stopped"
       /\ pendingToolQueue   ' = << >>
       /\ pendingToolCall    ' = [id |-> "none", name |-> "none", arguments |-> ""]
       /\ pendingVerifyFiles ' = {}
       /\ UNCHANGED <<activeMode, iterations, healing, verifications,
                      emptyRetries, upstreamRetries, compactions, lengthContinues,
                      doomSigs, noTools, compacting, generation,
                      circuitState, circuitFailures>>

(* 16. CircuitCooldownCanary: Transition from OPEN to HALF_OPEN after cooldown *)
CircuitCooldownCanaryAction ==
    /\ circuitState = "OPEN"
    /\ circuitState ' = "HALF_OPEN"
    /\ UNCHANGED <<state, history, activeMode, iterations, healing, verifications,
                   emptyRetries, upstreamRetries, compactions, lengthContinues,
                   doomSigs, pendingToolQueue, pendingToolCall, pendingVerifyFiles,
                   noTools, compacting, runStatus, generation, circuitFailures>>

(* 17. LoopPause: Turn limit reached; awaiting user's continue/stop decision *)
(* Mirrors `kargu-loop--prompt-continue' in `kargu/loop/machine.el' and     *)
(* the interactive `kargu-loop/ui.el' continue/stop button UI.              *)
LoopPause ==
    /\ state = "REQUEST"
    /\ iterations >= MaxIterations
    /\ state ' = "PAUSE"
    /\ UNCHANGED <<history, activeMode, iterations, healing, verifications,
                   emptyRetries, upstreamRetries, compactions, lengthContinues,
                   doomSigs, pendingToolQueue, pendingToolCall, pendingVerifyFiles,
                   noTools, compacting, runStatus, generation,
                   circuitState, circuitFailures>>

(* 18a. PauseDecisionContinue: User grants more turns, run resumes from REQUEST *)
PauseDecisionContinue(extraIterations) ==
    /\ state = "PAUSE"
    /\ extraIterations > 0
    /\ state      ' = "REQUEST"
    /\ iterations ' = iterations - extraIterations  \* resets relative counter
    /\ noTools    ' = FALSE
    /\ runStatus  ' = "none"
    /\ UNCHANGED <<history, activeMode, healing, verifications,
                   emptyRetries, upstreamRetries, compactions, lengthContinues,
                   doomSigs, pendingToolQueue, pendingToolCall, pendingVerifyFiles,
                   compacting, generation, circuitState, circuitFailures>>

(* 18b. PauseDecisionStop: User stops; run finishes at limit *)
PauseDecisionStop ==
    /\ state = "PAUSE"
    /\ state     ' = "DONE"
    /\ runStatus ' = "limit"
    /\ UNCHANGED <<history, activeMode, iterations, healing, verifications,
                   emptyRetries, upstreamRetries, compactions, lengthContinues,
                   doomSigs, pendingToolQueue, pendingToolCall, pendingVerifyFiles,
                   noTools, compacting, generation, circuitState, circuitFailures>>

(***************************************************************************)
(* Safety Invariants Verified by TLC                                       *)
(***************************************************************************)

TypeOK ==
    /\ state \in States
    /\ ContractHistory(history)
    /\ activeMode \in AllModes
    /\ circuitState \in CircuitStates
    /\ circuitFailures \in 0..CircuitFailureThreshold
    /\ iterations \in 0..(MaxIterations + 1)
    /\ healing \in 0..MaxHealing
    /\ verifications \in Nat
    /\ emptyRetries \in 0..MaxEmptyRetries
    /\ upstreamRetries \in 0..MaxUpstreamRetries
    /\ compactions \in 0..1
    /\ lengthContinues \in 0..1
    /\ noTools \in BOOLEAN
    /\ compacting \in BOOLEAN
    /\ runStatus \in {"none", "done", "limit", "error", "stopped"}
    /\ generation \in Nat

Safety_ProtocolFirewallInWaitModel ==
    state = "WAIT_MODEL" => ProtocolFirewallValid(history)

Safety_ModeSafety ==
    (activeMode \notin MutatingModes) =>
        (/\ state # "VERIFY_FILES"
         /\ pendingVerifyFiles = {})

Safety_SingleCompaction ==
    compactions <= 1

Safety_BoundedIterations ==
    state = "WAIT_MODEL" => iterations <= MaxIterations

Safety_InterruptedToolCallsAnswered ==
    state = "STOPPED" => AllToolCallsAnswered(history)

Safety_AllTerminalStatesAnswered ==
    state \in {"DONE", "ERROR", "STOPPED"} => AllToolCallsAnswered(history)

Safety_NoToolQueueOutsideExec ==
    state \notin {"EXEC_TOOLS", "VERIFY_FILES"} =>
        (/\ pendingToolQueue = <<>>
         /\ pendingToolCall.id = "none")

Safety_NoPendingVerifyOutsideVerify ==
    state # "VERIFY_FILES" => pendingVerifyFiles = {}

Safety_CircuitBreakerSoundness ==
    state = "WAIT_MODEL" => circuitState # "OPEN"

Safety_ContractIntegrity ==
    ContractHistory(history)

(* PAUSE state: no request in flight and no pending tool queue *)
Safety_PauseIsIdle ==
    state = "PAUSE" =>
        (/\ pendingToolQueue = <<>>
         /\ pendingToolCall.id = "none"
         /\ pendingVerifyFiles = {})

=============================================================================
