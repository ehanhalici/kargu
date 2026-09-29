--------------------------------- MODULE MC ---------------------------------
(***************************************************************************)
(* Model Checking instantiation of KarguLoop.  Every action of the loop    *)
(* is enabled: user cancellation and pauses, provider and network errors,  *)
(* the circuit breaker, healing rounds, compaction, mode gating and doom   *)
(* approval.                                                               *)
(***************************************************************************)

EXTENDS KarguLoop

ToolCallPoolVal == <<
    [id |-> "c1", name |-> "edit_file",   arguments |-> "file1.el"],
    [id |-> "c2", name |-> "read_file",   arguments |-> "file1.el"],
    [id |-> "c3", name |-> "bash",        arguments |-> "make test"],
    [id |-> "c4", name |-> "edit_file",   arguments |-> "file2.el"],
    [id |-> "c5", name |-> "grep",        arguments |-> "defun"],
    [id |-> "c6", name |-> "apply_patch", arguments |-> "diff1"]
>>

ToolCallSequences ==
    { <<ToolCallPoolVal[1]>>,
      <<ToolCallPoolVal[2]>>,
      <<ToolCallPoolVal[3]>>,
      <<ToolCallPoolVal[5]>>,
      <<ToolCallPoolVal[6]>>,
      <<ToolCallPoolVal[1], ToolCallPoolVal[2]>>,
      <<ToolCallPoolVal[2], ToolCallPoolVal[1]>>,
      <<ToolCallPoolVal[3], ToolCallPoolVal[5]>>,
      <<ToolCallPoolVal[1], ToolCallPoolVal[4]>>,
      <<ToolCallPoolVal[2], ToolCallPoolVal[5]>>,
      <<ToolCallPoolVal[1], ToolCallPoolVal[4], ToolCallPoolVal[6]>> }

MCNext ==
    \/ StartRun("Write test code")
    \/ FollowUpPrompt("Refactor the code")
    \/ \E m \in AllModes : SetMode(m)
    \/ ResetSession
    \/ RequestCompact
    \/ RequestPause
    \/ RequestSend
    \/ RequestBlocked
    \/ \E txt \in {"Here is the answer."} : ModelReceiveAnswer(txt)
    \/ \E calls \in ToolCallSequences : ModelReceiveToolCalls(calls)
    \/ ModelReceiveLengthTruncated
    \/ ModelReceiveOverflow
    \/ ModelReceiveEmpty
    \/ ModelReceiveUpstreamError
    \/ ModelReceiveError
    \/ ModelReceiveToolsUnsupported
    \/ RecoverRetry
    \/ RecoverStop
    \/ ExecuteNextTool
    \/ DoomApprove
    \/ DoomStop
    \/ VerifyFiles(TRUE)
    \/ VerifyFiles(FALSE)
    \/ CompactionFinish(TRUE)
    \/ CompactionFinish(FALSE)
    \/ UserStop
    \/ CircuitCooldownCanaryAction
    \/ PauseDecisionContinue
    \/ PauseDecisionStop

MCSpec == Init /\ [][MCNext]_vars

StateConstraint ==
    /\ generation <= 2
    /\ Len(history) <= 12
    /\ turnCap <= 2 * MaxIterations

=============================================================================
