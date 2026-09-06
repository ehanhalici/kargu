--------------------------- MODULE KarguContract ---------------------------
(***************************************************************************)
(* Formal specification of Kargu Contract, Ingress/Egress Constraints,    *)
(* Type Predicates, and Railway-Oriented Result Types.                     *)
(* Faithfully mirrors:                                                     *)
(*   - `kargu/contract.el`  (Ingress assertion, type predicates)           *)
(*   - `kargu/result.el`    (Railway-Oriented Result type: ok / err)       *)
(*   - `kargu/constants.el` (Role, mode, and tool definitions)             *)
(***************************************************************************)

EXTENDS Naturals, Sequences, FiniteSets, TLC

(***************************************************************************)
(* Roles, Modes, and Tool Categories                                       *)
(***************************************************************************)

Roles == {"system", "user", "assistant", "tool"}

AllModes == {"ask", "plan", "debug", "agent"}

MutatingToolNames == {"edit_file", "write_file", "bash", "apply_patch",
                       "edit", "write", "patch",
                       "debug_toggle_breakpoint",
                       "git_commit", "git_stage", "git_unstage",
                       "git_branch", "git_stash"}
ReadOnlyToolNames == {"read_file", "lsp_skeleton", "grep"}
AllToolNames      == MutatingToolNames \cup ReadOnlyToolNames

(***************************************************************************)
(* Message Schema                                                          *)
(***************************************************************************)

MakeMsg(role, content, tool_calls, call_id, name) == [
    role         |-> role,
    content      |-> content,
    tool_calls   |-> tool_calls,
    tool_call_id |-> call_id,
    name         |-> name
]

IsSystem(m)    == m.role = "system"
IsUser(m)      == m.role = "user"
IsAssistant(m) == m.role = "assistant"
IsTool(m)      == m.role = "tool"

HasToolCalls(m) == IsAssistant(m) /\ Len(m.tool_calls) > 0

(***************************************************************************)
(* Contract Predicates (Mirrors `kargu/contract.el')                       *)
(***************************************************************************)

ContractMode(mode) ==
    mode \in AllModes

ContractRole(role) ==
    role \in Roles

ContractToolCall(c) ==
    /\ c.id # ""
    /\ c.name \in AllToolNames

ContractToolCalls(calls) ==
    \A k \in 1..Len(calls) : ContractToolCall(calls[k])

ContractMessage(m) ==
    /\ ContractRole(m.role)
    /\ ContractToolCalls(m.tool_calls)

ContractHistory(hist) ==
    /\ \A i \in 1..Len(hist) : ContractMessage(hist[i])
    /\ Len(hist) > 0 => IsSystem(hist[1])

ContractPrompt(p) ==
    p # ""

(***************************************************************************)
(* Railway-Oriented Programming (ROP) (Mirrors `kargu/result.el')          *)
(***************************************************************************)

Ok(val) == [type |-> "ok", val |-> val, error |-> ""]
Err(msg) == [type |-> "err", val |-> FALSE, error |-> msg]

IsOk(res) == res.type = "ok"
IsErr(res) == res.type = "err"

Unwrap(res) ==
    IF IsOk(res) THEN res.val ELSE Assert(FALSE, res.error)

(***************************************************************************)
(* Ingress Assertion (Mirrors `kargu-contract-assert')                     *)
(***************************************************************************)

AssertIngress(cond, msg) ==
    Assert(cond, msg)

=============================================================================
