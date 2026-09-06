--------------------------- MODULE KarguProtocol ---------------------------
(***************************************************************************)
(* Complete formal specification of Kargu's LLM message protocol,         *)
(* history validation invariants, and message transformations.             *)
(* Faithfully mirrors:                                                     *)
(*   - `kargu/constants.el`                                                *)
(*   - `kargu/history.el` (`kargu--validate-history`, `kargu--history-add`)*)
(*   - `kargu/history/compact.el` (`kargu-history-apply-compaction`)       *)
(*   - `kargu/api/response.el` (`kargu-response-record-assistant`)         *)
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
(* Complete Implementation of `kargu--validate-history'                    *)
(* Faithfully mirrors lines 167-302 of `kargu/history.el'.                 *)
(***************************************************************************)

\* Strips trailing assistant messages when fix is 'strip'
RECURSIVE DropTrailingAssistants(_)
DropTrailingAssistants(hist) ==
    IF Len(hist) > 0 /\ IsAssistant(hist[Len(hist)])
    THEN DropTrailingAssistants(SubSeq(hist, 1, Len(hist) - 1))
    ELSE hist

\* Flushes pending tool calls by appending synthetic error results
FlushPending(outSeq, pendingIds, idToName) ==
    IF pendingIds = {}
    THEN outSeq
    ELSE LET orderedIds == CHOOSE seq \in [1..Cardinality(pendingIds) -> pendingIds] :
                            \A x, y \in 1..Cardinality(pendingIds) : x # y => seq[x] # seq[y]
             synResults == [k \in 1..Cardinality(pendingIds) |->
                 MakeMsg("tool",
                         "ERROR: this tool call was never answered (run interrupted). Treat it as a failed tool result and recover.",
                         << >>,
                         orderedIds[k],
                         idToName[orderedIds[k]])]
         IN outSeq \o synResults

\* Pass 1: Forward scan - Drops orphan tool results and tracks answered calls
RECURSIVE Pass1(_, _, _, _, _)
Pass1(inSeq, outSeq, pendingIds, seenIds, idToName) ==
    IF inSeq = << >>
    THEN [out |-> outSeq, pending |-> pendingIds, seen |-> seenIds, names |-> idToName]
    ELSE LET m == Head(inSeq)
             rest == Tail(inSeq)
         IN
         IF IsAssistant(m) /\ HasToolCalls(m)
         THEN LET newIds   == {m.tool_calls[k].id : k \in 1..Len(m.tool_calls)}
                  newNames == [id \in newIds |->
                                m.tool_calls[CHOOSE k \in 1..Len(m.tool_calls) : m.tool_calls[k].id = id].name]
                  combinedNames == [id \in (DOMAIN idToName) \cup newIds |->
                                      IF id \in DOMAIN idToName THEN idToName[id] ELSE newNames[id]]
              IN Pass1(rest,
                       FlushPending(outSeq, pendingIds, idToName) \o <<m>>,
                       newIds,
                       seenIds \cup newIds,
                       combinedNames)
         ELSE IF IsTool(m)
         THEN IF m.tool_call_id \in pendingIds
              THEN Pass1(rest,
                         outSeq \o <<m>>,
                         pendingIds \ {m.tool_call_id},
                         seenIds,
                         idToName)
              ELSE Pass1(rest, outSeq, pendingIds, seenIds, idToName)  \* Drop orphan tool result
         ELSE IF IsUser(m) \/ IsSystem(m)
         THEN Pass1(rest,
                    FlushPending(outSeq, pendingIds, idToName) \o <<m>>,
                    {},
                    seenIds,
                    idToName)
         ELSE Pass1(rest, outSeq \o <<m>>, pendingIds, seenIds, idToName)

\* Pass 2: Merges consecutive user turns
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

\* Complete history repair function with Ingress / Egress assertion
ValidateHistory(hist, fix) ==
    IF Assert(ContractHistory(hist), "Ingress contract violation in ValidateHistory")
    THEN
        LET stripped == IF fix = "strip" THEN DropTrailingAssistants(hist) ELSE hist
            p1       == Pass1(stripped, << >>, {}, {}, [x \in {} |-> ""])
            flushed  == FlushPending(p1.out, p1.pending, p1.names)
            merged   == MergeConsecutiveUsers(flushed)
            repaired == IF Len(merged) = 0 \/ ~IsSystem(merged[1])
                        THEN <<MakeMsg("system", "SYSTEM_PROMPT", << >>, "", "")>> \o merged
                        ELSE merged
        IN repaired
    ELSE hist

(***************************************************************************)
(* Compaction Transformation (`kargu/history/compact.el')                  *)
(***************************************************************************)

RECURSIVE FilterSystemAndAck(_)
FilterSystemAndAck(seq) ==
    IF seq = << >> THEN << >>
    ELSE LET h == Head(seq)
             t == FilterSystemAndAck(Tail(seq))
         IN IF IsSystem(h) \/ h.content = "COMPACTION_ACK"
            THEN t
            ELSE <<h>> \o t

TakeTail(seq, n) ==
    IF Len(seq) <= n THEN seq
    ELSE SubSeq(seq, Len(seq) - n + 1, Len(seq))

ApplyCompaction(hist, summaryText, keepCount) ==
    IF Assert(ContractHistory(hist), "Ingress contract violation in ApplyCompaction")
    THEN
        LET sysMsg  == IF Len(hist) > 0 /\ IsSystem(hist[1])
                       THEN hist[1]
                       ELSE MakeMsg("system", "SYSTEM_PROMPT", << >>, "", "")
            nonSys  == FilterSystemAndAck(hist)
            tail    == TakeTail(nonSys, keepCount)
            ackMsg  == MakeMsg("assistant", "COMPACTION_ACK", << >>, "", "")
            sumMsg  == MakeMsg("user", summaryText, << >>, "", "")
            newHist == <<sysMsg, sumMsg, ackMsg>> \o tail
        IN ValidateHistory(newHist, "strip")
    ELSE hist

=============================================================================
