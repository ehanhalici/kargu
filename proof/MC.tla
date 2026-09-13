--------------------------------- MODULE MC ---------------------------------
(***************************************************************************)
(* Realistic, comprehensive Model Checking instantiation of KarguLoop.     *)
(* Explores all edge cases, user cancellations, provider & network errors, *)
(* circuit breaker trips, AI response errors, diagnostic healing loops,    *)
(* compaction, mode safety gating, and doom loop detection.                *)
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
    \/ RequestSend
    \/ \E txt \in {"Here is the answer."} : ModelReceiveAnswer(txt)
    \/ \E calls \in ToolCallSequences : ModelReceiveToolCalls(calls)
    \/ ModelReceiveLengthTruncated
    \/ ModelReceiveOverflow
    \/ ModelReceiveEmpty
    \/ ModelReceiveUpstreamError
    \/ ExecuteNextTool
    \/ VerifyFiles(TRUE)
    \/ VerifyFiles(FALSE)
    \/ CompactionFinish(TRUE)
    \/ CompactionFinish(FALSE)
    \/ UserStop
    \/ CircuitCooldownCanaryAction
    \/ LoopPause
    \/ PauseDecisionContinue(MaxIterations)
    \/ PauseDecisionStop

MCSpec == Init /\ [][MCNext]_vars

StateConstraint ==
    /\ generation <= 2
    /\ Len(history) <= 12

=============================================================================
