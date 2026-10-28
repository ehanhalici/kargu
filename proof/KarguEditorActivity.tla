------------------------ MODULE KarguEditorActivity ------------------------
EXTENDS Naturals, FiniteSets, TLC
\* Physical editor ownership, complementary to the native issuance/IO model.
\* Native publication abstracts its already-proved gate/preflight/journal sync.
\* A handler may yield inside hooks; EOF/replacement is not its actual return.
CONSTANT Tickets
ASSUME Cardinality(Tickets)=2
Symmetry == Permutations(Tickets)
Phases == {"fresh","acquiring","running","settling","finished"}
VARIABLES phase, owner, epoch, connected, fence, revoked, published,
          physical, starts, allowed
vars == <<phase,owner,epoch,connected,fence,revoked,published,physical,starts,allowed>>

Init == /\ phase=[t \in Tickets |-> "fresh"] /\ owner=[t \in Tickets |-> 1]
        /\ epoch=1 /\ connected={1} /\ fence=0 /\ revoked={} /\ published={}
        /\ physical={} /\ starts=[t \in Tickets |-> 0] /\ allowed={}

Acquire(t) == /\ phase[t]="fresh" /\ fence=0 /\ epoch \in connected
              /\ phase'=[phase EXCEPT ![t]="acquiring"] /\ fence'=t
              /\ owner'=[owner EXCEPT ![t]=epoch]
              /\ UNCHANGED <<epoch,connected,revoked,published,physical,starts,allowed>>

Publish(t) == /\ phase[t]="acquiring" /\ owner[t] \in connected /\ t \notin published
              /\ published'=published \cup {t}
              /\ UNCHANGED <<phase,owner,epoch,connected,fence,revoked,physical,starts,allowed>>

Deliver(t) == /\ phase[t]="acquiring" /\ t \in published /\ owner[t] \in connected
              /\ LET run == t \notin revoked IN
                  /\ phase'=[phase EXCEPT ![t]=IF run THEN "running" ELSE "settling"]
                  /\ physical'=IF run THEN physical \cup {t} ELSE physical
                  /\ starts'=IF run THEN [starts EXCEPT ![t]=@+1] ELSE starts
                  /\ allowed'=IF run THEN allowed \cup {t} ELSE allowed
              /\ UNCHANGED <<owner,epoch,connected,fence,revoked,published>>

Error(t) == /\ phase[t]="acquiring" /\ t \notin published /\ owner[t] \in connected
            /\ phase'=[phase EXCEPT ![t]="finished"] /\ fence'=0
            /\ UNCHANGED <<owner,epoch,connected,revoked,published,physical,starts,allowed>>

Revoke(t) == /\ phase[t] \in {"acquiring","running","settling"} /\ t \notin revoked
             /\ revoked'=revoked \cup {t}
             /\ UNCHANGED <<phase,owner,epoch,connected,fence,published,physical,starts,allowed>>

Return(t) == /\ phase[t]="running"
             /\ phase'=[phase EXCEPT ![t]=IF owner[t] \in connected THEN "settling" ELSE "finished"]
             /\ physical'=physical \ {t}
             /\ fence'=IF owner[t] \in connected THEN fence ELSE 0
             /\ UNCHANGED <<owner,epoch,connected,revoked,published,starts,allowed>>

Ack(t) == /\ phase[t]="settling" /\ owner[t] \in connected
          /\ phase'=[phase EXCEPT ![t]="finished"] /\ fence'=0
          /\ UNCHANGED <<owner,epoch,connected,revoked,published,physical,starts,allowed>>

Disconnect(e) ==
    /\ e \in connected /\ connected'=connected \ {e}
    /\ LET affected == {t \in Tickets : owner[t]=e /\ phase[t] \in {"acquiring","running","settling"}}
       IN /\ revoked'=revoked \cup affected
          /\ phase'=[t \in Tickets |-> IF t \in affected /\ phase[t]#"running" THEN "finished" ELSE phase[t]]
          /\ fence'=IF fence \in affected /\ fence \notin physical THEN 0 ELSE fence
    /\ UNCHANGED <<owner,epoch,published,physical,starts,allowed>>

Reconnect == /\ epoch=1 /\ 1 \notin connected /\ epoch'=2 /\ connected'=connected \cup {2}
             /\ UNCHANGED <<phase,owner,fence,revoked,published,physical,starts,allowed>>

Next == (\E t \in Tickets : Acquire(t) \/ Publish(t) \/ Deliver(t) \/ Error(t) \/ Revoke(t) \/ Return(t) \/ Ack(t))
        \/ (\E e \in {1,2} : Disconnect(e)) \/ Reconnect \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars

TypeOK == /\ phase \in [Tickets -> Phases] /\ owner \in [Tickets -> {1,2}]
          /\ epoch \in {1,2} /\ connected \subseteq {1,2} /\ fence \in Tickets \cup {0}
          /\ revoked \subseteq Tickets /\ published \subseteq Tickets /\ physical \subseteq Tickets
          /\ starts \in [Tickets -> 0..1] /\ allowed \subseteq Tickets
PhysicalFence == physical \subseteq {fence}
OnePhysicalWriter == Cardinality(physical)<=1
ObserverOwnership == {t \in Tickets : phase[t] \in {"acquiring","running","settling"}} = ({fence} \cap Tickets)
NoReplay == \A t \in Tickets : starts[t]<=1
IssuedBeforeEntry == \A t \in Tickets : starts[t]=1 => t \in published /\ t \in allowed
ActualUnwind == physical={t \in Tickets : phase[t]="running"}
=============================================================================
