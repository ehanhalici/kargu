---------------------------- MODULE KarguTools ----------------------------
(***************************************************************************)
(* Formal specification of Kargu Tool Execution, Mode Safety Gating,      *)
(* Doom Loop Detection, and Diagnostic Verification Queues.                *)
(* Faithfully mirrors:                                                     *)
(*   - `kargu/loop/tools.el` (Execution, doom loop, tool queue)            *)
(*   - `kargu/loop/heal.el`  (LSP post-edit diagnostics verification)      *)
(***************************************************************************)

EXTENDS Naturals, Sequences, FiniteSets, TLC, KarguContract

(***************************************************************************)
(* Mode Safety Gate (Mirrors `kargu-loop--gate-tool')                      *)
(***************************************************************************)

MutatingModes == {"agent"}

IsMutatingTool(name) ==
    name \in MutatingToolNames

GateToolAllowed(name, mode) ==
    IsMutatingTool(name) => (mode \in MutatingModes)

GateToolError(name, mode) ==
    IF GateToolAllowed(name, mode)
    THEN ""
    ELSE "ERROR: tool forbidden in active mode"

(***************************************************************************)
(* Doom Loop Detection (Mirrors `kargu--loop-doom-p')                      *)
(* Detects 3 consecutive identical tool calls (same name and arguments).   *)
(***************************************************************************)

ToolSignature(call) ==
    call.name \o ":" \o call.arguments

DoomLoopDetected(sigs, sig) ==
    /\ Len(sigs) >= 2
    /\ sigs[1] = sig
    /\ sigs[2] = sig

(***************************************************************************)
(* Tool Result Constructor                                                 *)
(***************************************************************************)

MakeToolResult(id, name, output) ==
    MakeMsg("tool", output, << >>, id, name)

(****************************************************************************)
(* Batch Dedup (Mirrors `kargu--loop-tools-batch-cache' in tools.el)        *)
(* Within a single assistant turn, if the same (name, arguments) pair       *)
(* appears more than once, subsequent calls reuse the first result.         *)
(****************************************************************************)

BatchDedup(calls, sig) ==
    \E k \in 1..Len(calls) :
        /\ calls[k].name \o ":" \o calls[k].arguments = sig
        /\ k < Len(calls)   \* not the first occurrence (first is executed)

IsDuplicateInBatch(calls, idx) ==
    LET sig == calls[idx].name \o ":" \o calls[idx].arguments
    IN \E k \in 1..(idx-1) : calls[k].name \o ":" \o calls[k].arguments = sig

=============================================================================
