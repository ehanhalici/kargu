------------------------- MODULE KarguEditJournal -------------------------
EXTENDS Naturals, Sequences, FiniteSets

\* A single create-new journal, at most three records. Fsync preserves the
\* durable prefix in this abstraction; hardware/filesystem durability is assumed.
\* This models journal evidence only, not an editor or a permission grant.
Terminal == {"receipt", "not_dispatched", "unknown_final"}
Events == {"issue", "unknown"} \cup Terminal
Good(s) == s \in {<<"issue">>, <<"issue", "unknown">>}
               \cup {<<"issue", t>> : t \in Terminal}
               \cup {<<"issue", "unknown", t>> : t \in Terminal}
CanAppend(s,e) == /\ Len(s) < 3
                  /\ (IF Len(s)=0 THEN e="issue"
                      ELSE IF s= <<"issue">> THEN e \in {"unknown"} \cup Terminal
                      ELSE s= <<"issue","unknown">> /\ e \in Terminal)

VARIABLES phase, records, durable, pending, tail, valid, issueValid,
          private, binding, observed, seen, seenTail, seenValid, seenIssueValid
vars == <<phase, records, durable, pending, tail, valid, issueValid,
          private, binding, observed, seen, seenTail, seenValid, seenIssueValid>>

Init == /\ phase="fresh" /\ records= <<>> /\ durable=0 /\ pending="none"
        /\ tail=FALSE /\ valid=TRUE /\ issueValid=TRUE
        /\ private=TRUE /\ binding=TRUE /\ observed="none"
        /\ seen= <<>> /\ seenTail=FALSE /\ seenValid=TRUE /\ seenIssueValid=TRUE

Begin(e) == /\ phase \in {"fresh","owned"} /\ private /\ binding /\ valid
            /\ CanAppend(records,e)
            /\ phase'="writing" /\ pending'=e
            /\ UNCHANGED <<records,durable,tail,valid,issueValid,private,binding,
                           observed,seen,seenTail,seenValid,seenIssueValid>>

WriteComplete == /\ phase="writing"
                 /\ records'=Append(records,pending) /\ tail'=FALSE
                 /\ phase'="written"
                 /\ UNCHANGED <<durable,pending,valid,issueValid,private,binding,
                                observed,seen,seenTail,seenValid,seenIssueValid>>

Sync == /\ phase="written" /\ private /\ binding /\ valid
        /\ durable'=Len(records)
        /\ phase'=IF pending \in Terminal THEN "closed" ELSE "owned"
        /\ pending'="none"
        /\ UNCHANGED <<records,tail,valid,issueValid,private,binding,
                       observed,seen,seenTail,seenValid,seenIssueValid>>

Fail(partial) == /\ phase \in {"writing","written","owned"}
                 /\ partial \in BOOLEAN
                 /\ phase'="closed" /\ pending'="none"
                 /\ tail'=IF phase="writing" THEN partial ELSE tail
                 /\ UNCHANGED <<records,durable,valid,issueValid,private,binding,
                                observed,seen,seenTail,seenValid,seenIssueValid>>

Crash(keep,partial) ==
    /\ phase \in {"writing","written","owned"}
    /\ keep \in durable..Len(records) /\ partial \in BOOLEAN
    /\ records'=SubSeq(records,1,keep)
    /\ tail'=partial /\ phase'="closed" /\ pending'="none"
    /\ UNCHANGED <<durable,valid,issueValid,private,binding,
                   observed,seen,seenTail,seenValid,seenIssueValid>>

Corrupt(first) == /\ phase # "fresh" /\ valid /\ first \in BOOLEAN
                  /\ valid'=FALSE /\ issueValid'=IF first THEN FALSE ELSE issueValid
                  /\ UNCHANGED <<phase,records,durable,pending,tail,private,binding,
                                 observed,seen,seenTail,seenValid,seenIssueValid>>

Replace == /\ binding /\ binding'=FALSE
           /\ UNCHANGED <<phase,records,durable,pending,tail,valid,issueValid,private,
                          observed,seen,seenTail,seenValid,seenIssueValid>>
Expose == /\ private /\ private'=FALSE
          /\ UNCHANGED <<phase,records,durable,pending,tail,valid,issueValid,binding,
                         observed,seen,seenTail,seenValid,seenIssueValid>>

Recover == /\ phase="closed" /\ private /\ binding /\ observed="none"
           /\ seen'=records /\ seenTail'=tail /\ seenValid'=valid /\ seenIssueValid'=issueValid
           /\ observed'=IF Len(records)=0 \/ ~issueValid THEN "unconfirmed"
                        ELSE IF valid /\ ~tail /\ Good(records) /\ records[Len(records)] \in Terminal
                             THEN "resolved" ELSE "unknown"
           /\ UNCHANGED <<phase,records,durable,pending,tail,valid,issueValid,private,binding>>

Next == (\E e \in Events : Begin(e)) \/ WriteComplete \/ Sync
        \/ (\E partial \in BOOLEAN : Fail(partial))
        \/ (\E keep \in 0..3, partial \in BOOLEAN : Crash(keep,partial))
        \/ (\E first \in BOOLEAN : Corrupt(first)) \/ Replace \/ Expose \/ Recover
        \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars

TypeOK == /\ phase \in {"fresh","owned","writing","written","closed"}
          /\ records \in UNION {[1..n -> Events] : n \in 0..3}
          /\ durable \in 0..Len(records) /\ pending \in Events \cup {"none"}
          /\ tail \in BOOLEAN /\ valid \in BOOLEAN /\ issueValid \in BOOLEAN
          /\ private \in BOOLEAN /\ binding \in BOOLEAN
          /\ observed \in {"none","unconfirmed","unknown","resolved"}
          /\ seen \in UNION {[1..n -> Events] : n \in 0..3}
          /\ seenTail \in BOOLEAN /\ seenValid \in BOOLEAN /\ seenIssueValid \in BOOLEAN
BoundedPrefix == Len(records)<=3 /\ (Len(records)>0 => Good(records))
ExclusiveRecovery == observed # "none" => phase="closed"
NoPrematureResolution == observed="resolved" =>
    /\ Len(seen)>1 /\ Good(seen) /\ seen[Len(seen)] \in Terminal
    /\ ~seenTail /\ seenValid /\ seenIssueValid
UnknownWithoutTerminal == observed="unknown" =>
    Len(seen)>0 /\ seenIssueValid /\ (seenTail \/ ~seenValid \/ seen[Len(seen)] \notin Terminal)
=============================================================================
