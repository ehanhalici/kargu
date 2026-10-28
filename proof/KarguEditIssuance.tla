------------------------ MODULE KarguEditIssuance ------------------------
EXTENDS Naturals, FiniteSets, TLC

\* Starts from authorized, complete preflight observations. Filesystem sync and
\* receipt truth are abstract outcomes. No actual editor or cross-epoch fence is
\* proved here; EOF may leave an old editor pending while this connection retires.
CONSTANT Tickets
ASSUME Cardinality(Tickets)=2
Symmetry == Permutations(Tickets)
Phases == {"free","ready","recording","synced","issued","verifying","settling"}
IO == {"recording","synced","verifying","settling"}
Writer == {"recording","synced","issued","verifying","settling"}
VARIABLES phase, used, current, connected, claims, synced, delivered,
          receipts, pending, starts, joins, deliveries, terminal, cutoff, verified, committed
vars == <<phase,used,current,connected,claims,synced,delivered,receipts,
          pending,starts,joins,deliveries,terminal,cutoff,verified,committed>>

Init == /\ phase=[t \in Tickets |-> "free"] /\ used={} /\ current=Tickets
        /\ connected=TRUE /\ claims={} /\ synced={} /\ delivered={}
        /\ receipts={} /\ pending={} /\ terminal={} /\ cutoff={} /\ verified={} /\ committed={}
        /\ starts=[t \in Tickets |-> 0] /\ joins=[t \in Tickets |-> 0]
        /\ deliveries=[t \in Tickets |-> 0]

Begin(t) == /\ connected /\ t \notin used /\ t \in current
            /\ phase'=[phase EXCEPT ![t]="ready"] /\ used'=used \cup {t}
            /\ claims'=claims \cup {t}
            /\ UNCHANGED <<current,connected,synced,delivered,receipts,pending,starts,joins,deliveries,terminal,cutoff,verified,committed>>

StartRecord(t) == /\ connected /\ phase[t]="ready" /\ t \in current
                  /\ {q \in Tickets : phase[q] \in Writer}={}
                  /\ phase'=[phase EXCEPT ![t]="recording"]
                  /\ starts'=[starts EXCEPT ![t]=@+1]
                  /\ UNCHANGED <<used,current,connected,claims,synced,delivered,receipts,pending,joins,deliveries,terminal,cutoff,verified,committed>>

Sync(t) == /\ phase[t]="recording"
           /\ phase'=[phase EXCEPT ![t]="synced"] /\ synced'=synced \cup {t}
           /\ UNCHANGED <<used,current,connected,claims,delivered,receipts,pending,starts,joins,deliveries,terminal,cutoff,verified,committed>>

RecordErrorJoin(t) == /\ phase[t] \in {"recording","synced"}
                      /\ phase'=[phase EXCEPT ![t]="free"]
                      /\ joins'=[joins EXCEPT ![t]=@+1] /\ claims'=claims \ {t}
                      /\ UNCHANGED <<used,current,connected,synced,delivered,receipts,pending,starts,deliveries,terminal,cutoff,verified,committed>>

RecordJoin(t,publish) ==
    /\ phase[t]="synced" /\ publish \in BOOLEAN
    /\ LET issue == connected /\ t \in current /\ publish IN
        /\ joins'=[joins EXCEPT ![t]=@+1]
        /\ phase'=[phase EXCEPT ![t]=IF issue THEN "issued" ELSE "settling"]
        /\ starts'=IF issue THEN starts ELSE [starts EXCEPT ![t]=@+1]
        /\ delivered'=IF issue THEN delivered \cup {t} ELSE delivered
        /\ pending'=IF issue THEN pending \cup {t} ELSE pending
        /\ deliveries'=IF issue THEN [deliveries EXCEPT ![t]=@+1] ELSE deliveries
    /\ UNCHANGED <<used,current,connected,claims,synced,receipts,terminal,cutoff,verified,committed>>

\* A timeout, source close or Stop revokes new dispatch but does not join an
\* editor. It cannot manufacture a receipt or release the issued reservation.
Revoke(t) == /\ t \in current /\ current'=current \ {t}
              /\ UNCHANGED <<phase,used,connected,claims,synced,delivered,receipts,pending,starts,joins,deliveries,terminal,cutoff,verified,committed>>
ReleaseReady(t) == /\ phase[t]="ready" /\ (t \notin current \/ ~connected)
                   /\ phase'=[phase EXCEPT ![t]="free"] /\ claims'=claims \ {t}
                   /\ UNCHANGED <<used,current,connected,synced,delivered,receipts,pending,starts,joins,deliveries,terminal,cutoff,verified,committed>>

Quiescent(t) == /\ connected /\ phase[t]="issued"
                /\ receipts'=receipts \cup {t} /\ pending'=pending \ {t}
                /\ phase'=[phase EXCEPT ![t]="settling"]
                /\ starts'=[starts EXCEPT ![t]=@+1]
                /\ UNCHANGED <<used,current,connected,claims,synced,delivered,joins,deliveries,terminal,cutoff,verified,committed>>

Receipt(t) == /\ connected /\ phase[t]="issued"
                /\ receipts'=receipts \cup {t} /\ pending'=pending \ {t}
                /\ phase'=[phase EXCEPT ![t]="verifying"]
                /\ starts'=[starts EXCEPT ![t]=@+1]
                /\ UNCHANGED <<used,current,connected,claims,synced,delivered,joins,deliveries,terminal,cutoff,verified,committed>>

\* Verification is a fresh cleanup lifetime after real editor quiescence.
\* Source revoke/retirement cannot discard already observed external effects.
VerifyJoin(t,ok) == /\ phase[t]="verifying" /\ ok \in BOOLEAN
                    /\ phase'=[phase EXCEPT ![t]="settling"]
                    /\ joins'=[joins EXCEPT ![t]=@+1]
                    /\ starts'=[starts EXCEPT ![t]=@+1]
                    /\ verified'=IF ok THEN verified \cup {t} ELSE verified
                    /\ UNCHANGED <<used,current,connected,claims,synced,delivered,receipts,pending,deliveries,terminal,cutoff,committed>>

Disconnect == /\ connected /\ connected'=FALSE /\ current'={}
              /\ cutoff'=delivered
              /\ UNCHANGED <<phase,used,claims,synced,delivered,receipts,pending,starts,joins,deliveries,terminal,verified,committed>>

RetireUnknown(t) == /\ ~connected /\ phase[t]="issued"
                    /\ phase'=[phase EXCEPT ![t]="settling"]
                    /\ starts'=[starts EXCEPT ![t]=@+1]
                    /\ UNCHANGED <<used,current,connected,claims,synced,delivered,receipts,pending,joins,deliveries,terminal,cutoff,verified,committed>>

FinishJoin(t,ok) == /\ phase[t]="settling" /\ ok \in BOOLEAN
                    /\ phase'=[phase EXCEPT ![t]="free"]
                    /\ joins'=[joins EXCEPT ![t]=@+1] /\ claims'=claims \ {t}
                    /\ terminal'=IF ok THEN terminal \cup {t} ELSE terminal
                    /\ committed'=IF ok /\ t \in verified THEN committed \cup {t} ELSE committed
                    /\ UNCHANGED <<used,current,connected,synced,delivered,receipts,pending,starts,deliveries,cutoff,verified>>

Next == (\E t \in Tickets : Begin(t) \/ StartRecord(t) \/ Sync(t) \/ RecordErrorJoin(t)
                          \/ Revoke(t) \/ ReleaseReady(t) \/ Quiescent(t) \/ Receipt(t) \/ RetireUnknown(t)
                          \/ (\E publish \in BOOLEAN : RecordJoin(t,publish))
                          \/ (\E ok \in BOOLEAN : VerifyJoin(t,ok) \/ FinishJoin(t,ok)))
        \/ Disconnect \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars

TypeOK == /\ phase \in [Tickets -> Phases] /\ connected \in BOOLEAN
          /\ used \subseteq Tickets /\ current \subseteq Tickets /\ claims \subseteq Tickets
          /\ synced \subseteq Tickets /\ delivered \subseteq Tickets /\ receipts \subseteq Tickets
          /\ pending \subseteq Tickets /\ terminal \subseteq Tickets /\ cutoff \subseteq Tickets
          /\ verified \subseteq Tickets /\ committed \subseteq Tickets
          /\ starts \in [Tickets -> 0..3] /\ joins \in [Tickets -> 0..3] /\ deliveries \in [Tickets -> 0..1]
OneWriter == Cardinality({t \in Tickets : phase[t] \in Writer})<=1
ClaimOwnership == claims={t \in Tickets : phase[t]#"free"}
ActualJoinBeforeRelease == \A t \in Tickets :
    /\ joins[t]<=starts[t] /\ starts[t]-joins[t]<=1
    /\ (starts[t]>joins[t])=(phase[t] \in IO)
JournalBeforeDispatch == delivered \subseteq synced
HoldIssuedUntilReceipt == \A t \in Tickets : connected /\ t \in delivered /\ t \notin receipts =>
    /\ t \in claims /\ phase[t]="issued" /\ t \in pending
NoNewDispatchAfterEOF == ~connected => delivered=cutoff
NoReplay == \A t \in Tickets : deliveries[t]<=1
TerminalAfterReceiptOrNoDispatch == \A t \in terminal :
    t \in synced /\ (connected /\ t \in delivered => t \in receipts)
PositiveReceiptsVerified == committed \subseteq verified \cap receipts \cap terminal
=============================================================================
