//! Owned preflight phases; each process drains before the next phase is prepared.

use super::{GitPrepared, GitReadReply, ReadPlan};
use crate::{
    application::ToolOutcome,
    domain::{OutputLimit, SuccessCodes},
    error::CoreError,
    workspace::{
        command::Preparation,
        git::profile::{CONFIG_KEYS, CapturedProfile, Layout, SafeConfig},
    },
};
use std::ffi::OsString;
use zeroize::Zeroizing;

pub(crate) struct GitReadPreparation(Phase);
enum Phase {
    Layout(ReadPlan),
    Configuration { plan: ReadPlan, layout: Layout },
}
impl GitReadPreparation {
    pub(super) fn layout(plan: ReadPlan) -> Result<GitPrepared, CoreError> {
        let timeout = plan.deadline.remaining()?;
        let command = plan.repository.command(
            vec![
                "rev-parse".into(),
                "--path-format=absolute".into(),
                "--git-dir".into(),
                "--git-common-dir".into(),
                "--show-object-format".into(),
                "--show-ref-format".into(),
            ],
            timeout,
            plan.preflight_output,
        )?;
        let settings = plan.repository.settings(timeout)?;
        let tool = plan.query.tool()?;
        Ok(GitPrepared {
            command,
            settings,
            tool,
            reply: GitReadReply::Prepare(Box::new(Self(Phase::Layout(plan)))),
        })
    }
    pub(crate) fn output_limit(&self) -> OutputLimit {
        match &self.0 {
            Phase::Layout(plan) | Phase::Configuration { plan, .. } => plan.preflight_output,
        }
    }
    pub(crate) fn next(
        self,
        output: Vec<u8>,
        outcome: ToolOutcome,
        preparation: &Preparation,
    ) -> Result<GitPrepared, CoreError> {
        preparation.check()?;
        match outcome {
            ToolOutcome::Ok => {}
            ToolOutcome::Timeout => return Err(CoreError::Deadline),
            ToolOutcome::Cancelled => return Err(CoreError::Cancelled),
            ToolOutcome::OutcomeUnknown => return Err(CoreError::CleanupFailed),
            ToolOutcome::Rejected => return Err(CoreError::Rejected),
            ToolOutcome::Failed => return Err(CoreError::InvalidToolOutput),
        }
        let output = Zeroizing::new(output);
        match self.0 {
            Phase::Layout(plan) => {
                let layout = Layout::try_from(output.as_slice())?;
                preparation.check()?;
                let timeout = plan.deadline.remaining()?;
                let arguments: Vec<OsString> = vec![
                    "config".into(),
                    "--null".into(),
                    "--get-regexp".into(),
                    CONFIG_KEYS.into(),
                ];
                let command = plan
                    .repository
                    .command(arguments, timeout, plan.preflight_output)?
                    .with_success_codes(SuccessCodes::ZeroOrOne);
                let settings = plan.repository.settings(timeout)?;
                let tool = plan.query.tool()?;
                Ok(GitPrepared {
                    command,
                    settings,
                    tool,
                    reply: GitReadReply::Prepare(Box::new(Self(Phase::Configuration {
                        plan,
                        layout,
                    }))),
                })
            }
            Phase::Configuration { plan, layout } => {
                let config = SafeConfig::try_from(output.as_slice())?;
                let profile = CapturedProfile::capture(&layout, config, preparation)?;
                plan.final_query(Some(profile))
            }
        }
    }
}
