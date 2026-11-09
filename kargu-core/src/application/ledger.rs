//! The actor as the run ledger the execution gates and supervisors settle against.

use super::ApplicationActor;
use crate::{
    domain::{MessageId, ToolCallId, ToolName, ToolSafetyLevel, ToolStepId},
    error::CoreError,
    run::{RunHandle, RunLedger, ToolOutcome},
};

impl RunLedger for ApplicationActor {
    fn validate(&self, run: &RunHandle) -> Result<(), CoreError> {
        ApplicationActor::validate(self, run)
    }
    fn validate_owner(&self, run: &RunHandle) -> Result<(), CoreError> {
        ApplicationActor::validate_owner(self, run)
    }
    fn claim_step(
        &mut self,
        run: &RunHandle,
        call: (&ToolCallId, &ToolStepId),
        tool: (&ToolName, ToolSafetyLevel),
    ) -> Result<(), CoreError> {
        ApplicationActor::claim_step(self, run, call.0, call.1, tool.0, tool.1)
    }
    fn reserve_call(
        &mut self,
        run: &RunHandle,
        id: ToolCallId,
        tool: (ToolName, ToolSafetyLevel),
    ) -> Result<(), CoreError> {
        ApplicationActor::reserve_call(self, run, id, tool.0, tool.1)
    }
    fn mark_action_started(
        &mut self,
        run: &RunHandle,
        action: (&ToolCallId, Option<&ToolStepId>),
    ) -> Result<(), CoreError> {
        ApplicationActor::mark_action_started(self, run, action.0, action.1)
    }
    fn complete_action(
        &mut self,
        run: &RunHandle,
        action: (&ToolCallId, Option<&ToolStepId>),
        outcome: ToolOutcome,
    ) -> Result<(), CoreError> {
        ApplicationActor::complete_action(self, run, action.0, action.1, outcome)
    }
    fn complete_history_call(
        &mut self,
        run: &RunHandle,
        id: &ToolCallId,
        result: (ToolOutcome, &str),
    ) -> Result<MessageId, CoreError> {
        ApplicationActor::complete_history_call(self, run, id, result.0, result.1)
    }
    fn quarantine(&mut self, run: &RunHandle) -> Result<(), CoreError> {
        ApplicationActor::quarantine(self, run)
    }
}
