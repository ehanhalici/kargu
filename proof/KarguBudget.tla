---------------------------- MODULE KarguBudget ----------------------------
EXTENDS Naturals, TLC

CONSTANTS MaxRequests, CompactionLimit, TokenLimit, Deadline
VARIABLES requests_spent, compactions_spent, tokens_spent, current_time, status

vars == <<requests_spent, compactions_spent, tokens_spent, current_time, status>>

Init ==
    /\ requests_spent = 0
    /\ compactions_spent = 0
    /\ tokens_spent = 0
    /\ current_time = 0
    /\ status = "ok"

DebitNormal ==
    /\ status = "ok"
    /\ IF current_time >= Deadline
       THEN /\ status' = "exhausted_deadline"
            /\ UNCHANGED <<requests_spent, compactions_spent, tokens_spent, current_time>>
       ELSE IF requests_spent >= MaxRequests
            THEN /\ status' = "exhausted_requests"
                 /\ UNCHANGED <<requests_spent, compactions_spent, tokens_spent, current_time>>
            ELSE /\ requests_spent' = requests_spent + 1
                 /\ UNCHANGED <<compactions_spent, tokens_spent, current_time, status>>

DebitRetry ==
    /\ status = "ok"
    /\ IF current_time >= Deadline
       THEN /\ status' = "exhausted_deadline"
            /\ UNCHANGED <<requests_spent, compactions_spent, tokens_spent, current_time>>
       ELSE IF requests_spent >= MaxRequests
            THEN /\ status' = "exhausted_requests"
                 /\ UNCHANGED <<requests_spent, compactions_spent, tokens_spent, current_time>>
            ELSE /\ requests_spent' = requests_spent + 1
                 /\ UNCHANGED <<compactions_spent, tokens_spent, current_time, status>>

DebitHeal ==
    /\ status = "ok"
    /\ IF current_time >= Deadline
       THEN /\ status' = "exhausted_deadline"
            /\ UNCHANGED <<requests_spent, compactions_spent, tokens_spent, current_time>>
       ELSE IF requests_spent >= MaxRequests
            THEN /\ status' = "exhausted_requests"
                 /\ UNCHANGED <<requests_spent, compactions_spent, tokens_spent, current_time>>
            ELSE /\ requests_spent' = requests_spent + 1
                 /\ UNCHANGED <<compactions_spent, tokens_spent, current_time, status>>

DebitCompaction ==
    /\ status = "ok"
    /\ IF current_time >= Deadline
       THEN /\ status' = "exhausted_deadline"
            /\ UNCHANGED <<requests_spent, compactions_spent, tokens_spent, current_time>>
       ELSE IF compactions_spent >= CompactionLimit
            THEN /\ status' = "exhausted_compactions"
                 /\ UNCHANGED <<requests_spent, compactions_spent, tokens_spent, current_time>>
            ELSE /\ compactions_spent' = compactions_spent + 1
                 /\ UNCHANGED <<requests_spent, tokens_spent, current_time, status>>

RecordTokens(amount) ==
    /\ status # "sealed"
    /\ tokens_spent + amount <= TokenLimit + 2
    /\ tokens_spent' = tokens_spent + amount
    /\ IF status = "ok" /\ tokens_spent + amount > TokenLimit
       THEN status' = "exhausted_tokens"
       ELSE status' = status
    /\ UNCHANGED <<requests_spent, compactions_spent, current_time>>

ExpireDeadline ==
    /\ current_time <= Deadline
    /\ current_time' = current_time + 1
    /\ IF current_time' >= Deadline /\ status = "ok"
       THEN status' = "exhausted_deadline"
       ELSE status' = status
    /\ UNCHANGED <<requests_spent, compactions_spent, tokens_spent>>

Seal ==
    /\ status # "sealed"
    /\ status' = "sealed"
    /\ UNCHANGED <<requests_spent, compactions_spent, tokens_spent, current_time>>

Quiescent ==
    /\ status # "ok"
    /\ UNCHANGED vars

Next ==
    \/ DebitNormal
    \/ DebitRetry
    \/ DebitHeal
    \/ DebitCompaction
    \/ (\E amt \in 1..2 : RecordTokens(amt))
    \/ ExpireDeadline
    \/ Seal
    \/ Quiescent

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ requests_spent \in 0..MaxRequests
    /\ compactions_spent \in 0..CompactionLimit
    /\ tokens_spent \in 0..(TokenLimit + 2)
    /\ current_time \in 0..(Deadline + 1)
    /\ status \in {"ok", "exhausted_requests", "exhausted_deadline", "exhausted_tokens", "exhausted_compactions", "sealed"}

BudgetNeverExceeded ==
    /\ requests_spent <= MaxRequests
    /\ compactions_spent <= CompactionLimit

SingleCompactionBound ==
    compactions_spent <= 1

DeadlineEnforced ==
    current_time >= Deadline => status # "ok"

=============================================================================
