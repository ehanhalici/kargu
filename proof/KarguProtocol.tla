--------------------------- MODULE KarguProtocol ---------------------------
(***************************************************************************)
(* Complete formal specification of Kargu's LLM message protocol,         *)
(* history validation invariants, and message transformations.             *)
(* Faithfully mirrors:                                                     *)
(*   - `kargu/contract/constants.el`                                       *)
(*   - `kargu/history/protocol.el` (`kargu--history-add`)                  *)
(*   - `kargu/history/repair.el` (`kargu--validate-history`)               *)
(*   - `kargu/history/compact.el` (`kargu-history-apply-compaction`)       *)
(***************************************************************************)

EXTENDS Naturals, Sequences, FiniteSets, TLC, KarguContract

(***************************************************************************)
(* Modes alias for backward compatibility                                  *)
(***************************************************************************)

Modes == AllModes

LastRole(hist) ==
    IF Len(hist) = 0 THEN "none" ELSE hist[Len(hist)].role

(***************************************************************************)
(* Protocol Firewall Invariants (Checked before every model request)       *)
(***************************************************************************)

(* 1. First message in history must be system prompt *)
FirstMessageIsSystem(hist) ==
    Len(hist) > 0 => IsSystem(hist[1])

(* 2. History must NEVER end on an assistant turn *)
NoTrailingAssistant(hist) ==
    Len(hist) > 0 => ~IsAssistant(hist[Len(hist)])

(* 3. Every assistant tool call must be answered by matching tool result *)
AllToolCallsAnswered(hist) ==
    \A i \in 1..Len(hist) :
        HasToolCalls(hist[i]) =>
            LET numCalls == Len(hist[i].tool_calls)
            IN
            /\ (i + numCalls) <= Len(hist)
            /\ \A k \in 1..numCalls :
                /\ IsTool(hist[i + k])
                /\ hist[i + k].tool_call_id = hist[i].tool_calls[k].id

(* 4. No orphan tool results without a preceding assistant call *)
NoOrphanToolResults(hist) ==
    \A j \in 1..Len(hist) :
        IsTool(hist[j]) =>
            \E i \in 1..(j-1) :
                /\ HasToolCalls(hist[i])
                /\ \E k \in 1..Len(hist[i].tool_calls) :
                    hist[i].tool_calls[k].id = hist[j].tool_call_id

(* 5. Consecutive user messages must be merged *)
NoConsecutiveUser(hist) ==
    \A i \in 1..(Len(hist) - 1) :
        ~(IsUser(hist[i]) /\ IsUser(hist[i+1]))

(* 6. Assistant text turns must have string content *)
AssistantContentNonEmpty(hist) ==
    \A i \in 1..Len(hist) :
        (IsAssistant(hist[i]) /\ Len(hist[i].tool_calls) = 0) =>
            hist[i].content # ""

(* 7. History must contain at least one user prompt *)
HasAtLeastOneUser(hist) ==
    \E i \in 1..Len(hist) : IsUser(hist[i])

(* Combined Protocol Firewall Invariant *)
ProtocolFirewallValid(hist) ==
    /\ FirstMessageIsSystem(hist)
    /\ NoTrailingAssistant(hist)
    /\ AllToolCallsAnswered(hist)
    /\ NoOrphanToolResults(hist)
    /\ NoConsecutiveUser(hist)
    /\ AssistantContentNonEmpty(hist)
    /\ HasAtLeastOneUser(hist)

(***************************************************************************)
(* `kargu--validate-history' (kargu/history/repair.el)                     *)
(*                                                                         *)
(* Repair order, exactly as in the code:                                   *)
(*   1. The head system message is taken out (or created); every other     *)
(*      system message is dropped.                                         *)
(*   2. One forward scan drops orphan tool results and, when any other     *)
(*      turn arrives, flushes the calls still unanswered with a synthetic  *)
(*      result.                                                            *)
(*   3. Consecutive user turns are merged; consecutive assistant text      *)
(*      turns are merged, and an assistant text turn is folded into the    *)
(*      assistant turn with calls that follows it.                         *)
(*   4. Only then, in `strip' mode, trailing assistant turns are removed.  *)
(*      A trailing assistant turn with calls was answered in step 2, so it *)
(*      is no longer trailing.                                             *)
(***************************************************************************)

\* Strips trailing assistant messages
RECURSIVE DropTrailingAssistants(_)
DropTrailingAssistants(hist) ==
    IF Len(hist) > 0 /\ IsAssistant(hist[Len(hist)])
    THEN DropTrailingAssistants(SubSeq(hist, 1, Len(hist) - 1))
    ELSE hist

\* The ids of a sequence, as a set
IdSet(ids) == {ids[i] : i \in 1..Len(ids)}

\* Flushes pending tool calls by appending synthetic error results, in the
\* order the calls were made (`kargu--flush-pending' sorts by sequence).
FlushPending(outSeq, pendingIds, idToName) ==
    outSeq \o [k \in 1..Len(pendingIds) |->
                MakeMsg("tool",
                        "ERROR: interrupted before response",
                        << >>,
                        pendingIds[k],
                        idToName[pendingIds[k]])]

\* Step 2: forward scan.  System turns are dropped, orphan tool results are
\* dropped, every other turn flushes what is still pending.  PENDINGIDS is
\* a sequence: the unanswered call ids of the last assistant turn, in order.
RECURSIVE Pass1(_, _, _, _)
Pass1(inSeq, outSeq, pendingIds, idToName) ==
    IF inSeq = << >>
    THEN [out |-> outSeq, pending |-> pendingIds, names |-> idToName]
    ELSE LET m == Head(inSeq)
             rest == Tail(inSeq)
         IN
         IF IsSystem(m)
         THEN Pass1(rest, outSeq, pendingIds, idToName)
         ELSE IF IsTool(m)
         THEN IF m.tool_call_id \in IdSet(pendingIds)
              THEN Pass1(rest,
                         outSeq \o <<m>>,
                         SelectSeq(pendingIds, LAMBDA id : id # m.tool_call_id),
                         idToName)
              ELSE Pass1(rest, outSeq, pendingIds, idToName)  \* orphan result
         ELSE IF HasToolCalls(m)
         THEN LET newIds   == [k \in 1..Len(m.tool_calls) |-> m.tool_calls[k].id]
                  newNames == [id \in IdSet(newIds) |->
                                m.tool_calls[CHOOSE k \in 1..Len(m.tool_calls) : m.tool_calls[k].id = id].name]
                  combined == [id \in (DOMAIN idToName) \cup IdSet(newIds) |->
                                IF id \in DOMAIN idToName THEN idToName[id] ELSE newNames[id]]
              IN Pass1(rest,
                       FlushPending(outSeq, pendingIds, idToName) \o <<m>>,
                       newIds,
                       combined)
         ELSE \* user turn or assistant text turn
              Pass1(rest,
                    FlushPending(outSeq, pendingIds, idToName) \o <<m>>,
                    << >>,
                    idToName)

\* Step 3a: merge consecutive user turns
RECURSIVE MergeConsecutiveUsers(_)
MergeConsecutiveUsers(seq) ==
    IF Len(seq) <= 1 THEN seq
    ELSE LET h1 == seq[1]
             h2 == seq[2]
             rst == SubSeq(seq, 3, Len(seq))
         IN
         IF IsUser(h1) /\ IsUser(h2)
         THEN LET merged == MakeMsg("user",
                                    h1.content \o "\n\n" \o h2.content,
                                    << >>, "", "")
              IN MergeConsecutiveUsers(<<merged>> \o rst)
         ELSE <<h1>> \o MergeConsecutiveUsers(SubSeq(seq, 2, Len(seq)))

\* Step 3b: an assistant text turn followed by another assistant turn becomes
\* one turn; the calls (if any) of the second are kept.
RECURSIVE MergeConsecutiveAssistants(_)
MergeConsecutiveAssistants(seq) ==
    IF Len(seq) <= 1 THEN seq
    ELSE LET h1 == seq[1]
             h2 == seq[2]
             rst == SubSeq(seq, 3, Len(seq))
         IN
         IF IsAssistant(h1) /\ ~HasToolCalls(h1) /\ IsAssistant(h2)
         THEN LET merged == MakeMsg("assistant",
                                    h1.content \o "\n\n" \o h2.content,
                                    h2.tool_calls, "", "")
              IN MergeConsecutiveAssistants(<<merged>> \o rst)
         ELSE <<h1>> \o MergeConsecutiveAssistants(SubSeq(seq, 2, Len(seq)))

DefaultSystemMsg == MakeMsg("system", "SYSTEM_PROMPT", << >>, "", "")

\* Complete history repair.  FIX is "strip" for a request; any other value
\* (a finished or interrupted run) keeps a trailing assistant answer.
ValidateHistory(hist, fix) ==
    IF Assert(ContractHistory(hist), "Ingress contract violation in ValidateHistory")
    THEN
        LET hasSys   == Len(hist) > 0 /\ IsSystem(hist[1])
            sysMsg   == IF hasSys THEN hist[1] ELSE DefaultSystemMsg
            body     == IF hasSys THEN SubSeq(hist, 2, Len(hist)) ELSE hist
            p1       == Pass1(body, << >>, << >>, [x \in {} |-> ""])
            flushed  == FlushPending(p1.out, p1.pending, p1.names)
            merged   == MergeConsecutiveAssistants(MergeConsecutiveUsers(flushed))
            trimmed  == IF fix = "strip" THEN DropTrailingAssistants(merged) ELSE merged
        IN <<sysMsg>> \o trimmed
    ELSE hist

(***************************************************************************)
(* Compaction (`kargu/history/compact.el')                                 *)
(*                                                                         *)
(* The summary becomes a `COMPACTION_ACK:' user turn answered by a fixed   *)
(* assistant turn.  The kept tail starts on a user turn when it holds one  *)
(* (`kargu-history-compact-tail'); compaction turns are never kept.        *)
(***************************************************************************)

SummaryTexts == {"Summary of previous turns"}

AckUserText(summary) == "COMPACTION_ACK: Prior work summary:\n" \o summary
AckAssistantText == "Acknowledged. Continuing from the summary."

IsCompactionMsg(m) ==
    \/ IsUser(m) /\ m.content \in {AckUserText(s) : s \in SummaryTexts}
    \/ IsAssistant(m) /\ m.content = AckAssistantText

RECURSIVE FilterSystemAndAck(_)
FilterSystemAndAck(seq) ==
    IF seq = << >> THEN << >>
    ELSE LET h == Head(seq)
             t == FilterSystemAndAck(Tail(seq))
         IN IF IsSystem(h) \/ IsCompactionMsg(h)
            THEN t
            ELSE <<h>> \o t

TakeTail(seq, n) ==
    IF Len(seq) <= n THEN seq
    ELSE SubSeq(seq, Len(seq) - n + 1, Len(seq))

\* Drop leading turns up to the first user turn, if the tail has one
DropToFirstUser(seq) ==
    IF \E i \in 1..Len(seq) : IsUser(seq[i])
    THEN LET first == CHOOSE i \in 1..Len(seq) :
                        IsUser(seq[i]) /\ \A j \in 1..(i-1) : ~IsUser(seq[j])
         IN SubSeq(seq, first, Len(seq))
    ELSE seq

ApplyCompaction(hist, summaryText, keepCount) ==
    IF Assert(ContractHistory(hist), "Ingress contract violation in ApplyCompaction")
    THEN
        LET sysMsg  == IF Len(hist) > 0 /\ IsSystem(hist[1]) THEN hist[1] ELSE DefaultSystemMsg
            tail    == DropToFirstUser(TakeTail(FilterSystemAndAck(hist), keepCount))
            ackUser == MakeMsg("user", AckUserText(summaryText), << >>, "", "")
            ackAsst == MakeMsg("assistant", AckAssistantText, << >>, "", "")
        IN ValidateHistory(<<sysMsg, ackUser, ackAsst>> \o tail, "keep")
    ELSE hist

=============================================================================
