//! Concrete OS actions inside one committed model invocation. Internal Git
//! preparation cannot create a second model call, spend its budget twice, or
//! release the foreground run. Every concrete effect still uses the shared gate.

use super::{ApplicationActor, CallAdmission, RunHandle, ToolOutcome};
use crate::{
    constants::limits,
    domain::{ToolCallId, ToolName, ToolSafetyLevel, ToolStepId},
    error::CoreError,
};

enum State {
    Prepared,
    Claimed,
    Started,
    Completed(ToolOutcome),
}

pub(super) struct ExecutionStep {
    parent: ToolCallId,
    name: ToolName,
    safety: ToolSafetyLevel,
    state: State,
}

impl ExecutionStep {
    pub(super) fn settled(&self) -> bool {
        matches!(self.state, State::Completed(_))
    }
}

impl ApplicationActor {
    pub(crate) fn action_outcome(
        &self,
        run: &RunHandle,
        parent: &ToolCallId,
        id: &ToolStepId,
    ) -> Result<Option<ToolOutcome>, CoreError> {
        let step = self
            .owned(run)?
            .steps
            .get(id)
            .ok_or(CoreError::StaleOwner)?;
        if &step.parent != parent {
            return Err(CoreError::StaleOwner);
        }
        Ok(match step.state {
            State::Completed(outcome) => Some(outcome),
            _ => None,
        })
    }
    pub(super) fn retire_call_steps(
        &mut self,
        run: &RunHandle,
        parent: &ToolCallId,
    ) -> Result<(), CoreError> {
        self.owned_mut(run)?
            .steps
            .retain(|_, step| &step.parent != parent);
        Ok(())
    }

    pub(super) fn call_steps_settled(
        &self,
        run: &RunHandle,
        parent: &ToolCallId,
    ) -> Result<Option<bool>, CoreError> {
        let mut found = false;
        for step in self
            .owned(run)?
            .steps
            .values()
            .filter(|step| &step.parent == parent)
        {
            found = true;
            if !step.settled() {
                return Ok(Some(false));
            }
        }
        Ok(found.then_some(true))
    }

    pub(crate) fn abandon_step(
        &mut self,
        run: &RunHandle,
        parent: &ToolCallId,
        id: &ToolStepId,
        outcome: ToolOutcome,
    ) -> Result<(), CoreError> {
        let step = self
            .owned(run)?
            .steps
            .get(id)
            .ok_or(CoreError::StaleOwner)?;
        if &step.parent != parent {
            return Err(CoreError::StaleOwner);
        }
        if step.settled() {
            return Ok(());
        }
        self.complete_action(run, parent, Some(id), outcome)
    }

    pub(crate) fn register_step(
        &mut self,
        run: &RunHandle,
        parent: &ToolCallId,
        requested: &ToolName,
    ) -> Result<ToolStepId, CoreError> {
        self.validate(run)?;
        let active = self.owned(run)?;
        active
            .agent
            .as_ref()
            .ok_or(CoreError::Rejected)?
            .check_dispatch(parent)?;
        let call = active.calls.get(parent).ok_or(CoreError::StaleOwner)?;
        if call.outcome.is_some() {
            return Err(CoreError::AlreadyCompleted);
        }
        let parent_definition = run.tool_registry().resolve(&call.name)?;
        let step_definition = run.tool_registry().resolve(requested)?;
        let allowed_helper = matches!(
            (call.name.as_str(), step_definition.name().as_str()),
            (
                "git_stage" | "git_unstage" | "git_commit" | "git_branch" | "git_stash",
                "git_mutation_prepare",
            ) | ("apply_patch", "edit_patch_prepare")
                | ("git_branch", "git_branches")
                | ("git_stash", "git_stashes")
                | ("edit_by_lsp", "read_file_symbols")
        );
        if parent_definition.name() != step_definition.name() && !allowed_helper {
            return Err(CoreError::Rejected);
        }
        if !parent_definition.permits_mode(run.settings().mode)
            || !step_definition.permits_mode(run.settings().mode)
        {
            return Err(CoreError::Rejected);
        }
        let mut previous = active
            .steps
            .values()
            .filter(|step| &step.parent == parent)
            .peekable();
        if previous.peek().is_none() && matches!(call.admission, CallAdmission::Claimed) {
            return Err(CoreError::AlreadyCompleted);
        }
        let mut count = 0usize;
        for step in previous {
            if !step.settled() {
                return Err(CoreError::Busy);
            }
            count = count.checked_add(1).ok_or(CoreError::ArithmeticOverflow)?;
        }
        if count >= limits::TOOL_EXECUTION_STEPS {
            return Err(CoreError::Limit);
        }
        let step = ExecutionStep {
            parent: parent.clone(),
            name: step_definition.name().clone(),
            safety: step_definition.safety(),
            state: State::Prepared,
        };
        let id = ToolStepId::new();
        let active = self.owned_mut(run)?;
        let call = active.calls.get_mut(parent).ok_or(CoreError::StaleOwner)?;
        call.admission = CallAdmission::Claimed;
        active.steps.insert(id.clone(), step);
        Ok(id)
    }

    pub(crate) fn claim_step(
        &mut self,
        run: &RunHandle,
        parent: &ToolCallId,
        id: &ToolStepId,
        name: &ToolName,
        safety: ToolSafetyLevel,
    ) -> Result<(), CoreError> {
        self.validate(run)?;
        self.owned(run)?
            .agent
            .as_ref()
            .ok_or(CoreError::Rejected)?
            .check_dispatch(parent)?;
        let step = self
            .owned_mut(run)?
            .steps
            .get_mut(id)
            .ok_or(CoreError::StaleOwner)?;
        if &step.parent != parent || &step.name != name || step.safety != safety {
            return Err(CoreError::StaleOwner);
        }
        if !matches!(step.state, State::Prepared) {
            return Err(CoreError::AlreadyCompleted);
        }
        step.state = State::Claimed;
        Ok(())
    }

    pub(crate) fn mark_action_started(
        &mut self,
        run: &RunHandle,
        parent: &ToolCallId,
        id: Option<&ToolStepId>,
    ) -> Result<(), CoreError> {
        let Some(id) = id else {
            return self.mark_started(run, parent);
        };
        self.validate(run)?;
        let active = self.owned_mut(run)?;
        let step = active.steps.get_mut(id).ok_or(CoreError::StaleOwner)?;
        if &step.parent != parent {
            return Err(CoreError::StaleOwner);
        }
        if !matches!(step.state, State::Claimed) {
            return Err(CoreError::AlreadyCompleted);
        }
        step.state = State::Started;
        let call = active.calls.get_mut(parent).ok_or(CoreError::StaleOwner)?;
        call.started = true;
        call.safety = Some(match (call.safety, step.safety) {
            (Some(ToolSafetyLevel::ExecutesArbitraryCode), _)
            | (_, ToolSafetyLevel::ExecutesArbitraryCode) => ToolSafetyLevel::ExecutesArbitraryCode,
            (Some(ToolSafetyLevel::MutatesState), _) | (_, ToolSafetyLevel::MutatesState) => {
                ToolSafetyLevel::MutatesState
            }
            _ => ToolSafetyLevel::SafeReadOnly,
        });
        Ok(())
    }

    pub(crate) fn complete_action(
        &mut self,
        run: &RunHandle,
        parent: &ToolCallId,
        id: Option<&ToolStepId>,
        outcome: ToolOutcome,
    ) -> Result<(), CoreError> {
        let Some(id) = id else {
            return self.complete_tool(run, parent, outcome);
        };
        let step = self
            .owned_mut(run)?
            .steps
            .get_mut(id)
            .ok_or(CoreError::StaleOwner)?;
        if &step.parent != parent {
            return Err(CoreError::StaleOwner);
        }
        if step.settled() {
            return Err(CoreError::AlreadyCompleted);
        }
        if matches!(outcome, ToolOutcome::Ok | ToolOutcome::OutcomeUnknown)
            && !matches!(step.state, State::Started)
        {
            return Err(CoreError::Rejected);
        }
        step.state = State::Completed(outcome);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        application::{
            Mode, RunSettings,
            agent::{AgentOptions, AssistantTurn, ModelTurnLimit},
        },
        domain::{ApplicationId, ConfigRevision, PolicyRevision, ToolCallLimit},
        policy::{ToolRegistry, Workspace},
    };
    use serde_json::json;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    fn start() -> Result<
        (
            tempfile::TempDir,
            ApplicationActor,
            RunHandle,
            crate::application::agent::AgentTool,
        ),
        Box<dyn std::error::Error>,
    > {
        let root = tempfile::tempdir()?;
        let mut actor =
            ApplicationActor::with_registry(ApplicationId::new(), ToolRegistry::standard()?);
        let session = actor.create_session();
        let run = actor.admit(
            &session,
            RunSettings::new(
                Mode::Agent,
                Workspace::try_from(root.path().to_path_buf())?,
                ToolCallLimit::try_from(1)?,
                std::time::Duration::from_secs(30),
                ConfigRevision::try_from(1)?,
                PolicyRevision::try_from(1)?,
            )?,
        )?;
        actor.start_agent(
            &run,
            AgentOptions {
                turn_limit: ModelTurnLimit::try_from(4)?,
                tools_enabled: true,
                editor_available: vec![],
            },
            Some(serde_json::from_value(
                json!({"role":"user","content":"stage fixture"}),
            )?),
        )?;
        let raw = serde_json::value::to_raw_value(
            &json!({"choices":[{"message":{"role":"assistant","tool_calls":[{
            "id":"provider-stage","type":"function","function":{"name":"git_stage","arguments":"{\"paths\":\"new.txt\"}"}}]},"finish_reason":"tool_calls"}]}),
        )?;
        actor
            .begin_model_turn(&run)?
            .complete(&mut actor, AssistantTurn::try_from(raw)?)?;
        let call = actor.next_agent_tool(&run)?;
        Ok((root, actor, run, call))
    }

    #[test]
    fn a_read_preparation_cannot_hide_a_second_call_or_claim_a_foreign_action() -> TestResult {
        let (_root, mut actor, run, call) = start()?;
        let helper = ToolName::try_from("git_mutation_prepare".to_owned())?;
        let wrong = ToolName::try_from("bash".to_owned())?;
        assert!(matches!(
            actor.register_step(&run, call.id(), &wrong),
            Err(CoreError::Rejected)
        ));
        let step = actor.register_step(&run, call.id(), &helper)?;
        assert!(matches!(
            actor.register_step(&run, call.id(), &helper),
            Err(CoreError::Busy)
        ));
        assert!(matches!(
            actor.claim_step(
                &run,
                call.id(),
                &ToolStepId::new(),
                &helper,
                ToolSafetyLevel::SafeReadOnly
            ),
            Err(CoreError::StaleOwner)
        ));
        actor.claim_step(
            &run,
            call.id(),
            &step,
            &helper,
            ToolSafetyLevel::SafeReadOnly,
        )?;
        assert!(matches!(
            actor.claim_step(
                &run,
                call.id(),
                &step,
                &helper,
                ToolSafetyLevel::SafeReadOnly
            ),
            Err(CoreError::AlreadyCompleted)
        ));
        let revision = actor.session_history(run.scope().session_id())?.revision();
        assert!(matches!(
            actor.complete_history_call(&run, call.id(), ToolOutcome::Ok, "unjoined action"),
            Err(CoreError::Busy)
        ));
        assert_eq!(
            actor.session_history(run.scope().session_id())?.revision(),
            revision
        );
        actor.mark_action_started(&run, call.id(), Some(&step))?;
        actor.complete_action(&run, call.id(), Some(&step), ToolOutcome::Ok)?;
        assert!(matches!(
            actor.register_call(&run, ToolCallId::new(), wrong),
            Err(CoreError::BudgetExceeded { .. })
        ));
        actor.cancel(&run)?;
        drop(call);
        let completion = actor.finish(&run)?;
        assert_eq!(completion.tool_results().len(), 1);
        assert_eq!(
            completion.tool_results().first().ok_or("result")?.outcome,
            ToolOutcome::Cancelled
        );
        Ok(())
    }

    #[test]
    fn unknown_is_reserved_for_started_effects_and_internal_actions_are_not_history_results()
    -> TestResult {
        for write_started in [false, true] {
            let (_root, mut actor, run, call) = start()?;
            let name = ToolName::try_from(
                if write_started {
                    "git_stage"
                } else {
                    "git_mutation_prepare"
                }
                .to_owned(),
            )?;
            let safety = if write_started {
                ToolSafetyLevel::ExecutesArbitraryCode
            } else {
                ToolSafetyLevel::SafeReadOnly
            };
            let step = actor.register_step(&run, call.id(), &name)?;
            actor.claim_step(&run, call.id(), &step, &name, safety)?;
            actor.mark_action_started(&run, call.id(), Some(&step))?;
            actor.cancel(&run)?;
            drop(call);
            let completion = actor.finish(&run)?;
            assert_eq!(completion.tool_results().len(), 1);
            assert_eq!(
                completion.tool_results().first().ok_or("result")?.outcome,
                if write_started {
                    ToolOutcome::OutcomeUnknown
                } else {
                    ToolOutcome::Cancelled
                }
            );
            let history = actor.session_history(run.scope().session_id())?;
            assert!(history.settled());
            assert_eq!(history.snapshot().len(), 3);
        }
        Ok(())
    }
}
