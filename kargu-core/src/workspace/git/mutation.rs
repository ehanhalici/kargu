//! Closed Git writes: resolve once, review once, issue once, never retry a write.

mod intent;
mod scope;
use super::{
    super::command::{Preparation, ReadTimeout},
    repository::Repository,
};
use crate::{
    application::{Mode, RunSettings, ToolOutcome},
    constants::{limits, timeouts},
    domain::{
        CapturePolicy, ConfigRevision, OutputLimit, PolicyRevision, SuccessCodes, ToolCallLimit,
        ToolName,
    },
    error::CoreError,
    security::{CommandEnvironment, CommandInput, CommandSpec},
};
use intent::{Branch, Mutation, Paths};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::BTreeMap, ffi::OsString, path::PathBuf};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct MutationInput {
    root: PathBuf,
    mode: Mode,
    query: Mutation,
    timeout_ms: ReadTimeout,
    output_bytes: OutputLimit,
    environment: BTreeMap<String, String>,
    config_revision: ConfigRevision,
    policy_revision: PolicyRevision,
}
pub(crate) struct MutationPreparation {
    input: MutationInput,
    repository: Repository,
    phase: MutationPhase,
}
enum MutationPhase {
    Layout,
    Resolve {
        directory: PathBuf,
        common: PathBuf,
        snapshot: std::sync::Arc<crate::security::ActionSnapshot>,
    },
    Unborn {
        directory: PathBuf,
        common: PathBuf,
        snapshot: std::sync::Arc<crate::security::ActionSnapshot>,
    },
}
pub(crate) struct MutationPrepared {
    pub command: CommandSpec,
    pub settings: RunSettings,
    pub tool: ToolName,
    pub reply: MutationReply,
}
pub(crate) enum MutationReply {
    Prepare(Box<MutationPreparation>),
    Report(MutationReport),
}
pub(crate) struct MutationReport {
    pub intent: Value,
    pub output: OutputLimit,
    label: &'static str,
    retained: Option<String>,
}
impl MutationInput {
    pub(crate) fn prepare(self, context: &Preparation) -> Result<MutationPrepared, CoreError> {
        context.check()?;
        if self.mode != Mode::Agent {
            return Err(CoreError::Rejected);
        }
        let repository = Repository::try_from(self.root.clone())?;
        // Validate every model path before even a read-only Git child starts.
        if let Mutation::Stage { paths } | Mutation::Unstage { paths } = &self.query {
            for path in &paths.0 {
                scope::relative(repository.workspace.path(), path)?;
            }
        }
        let limit = OutputLimit::try_from(65536usize)?;
        let command = repository
            .command(
                vec![
                    "rev-parse".into(),
                    "--path-format=absolute".into(),
                    "--git-dir".into(),
                    "--git-common-dir".into(),
                    "--show-object-format".into(),
                    "--show-ref-format".into(),
                ],
                Some(timeouts::WORKSPACE_READ),
                limit,
            )?
            .with_success_codes(SuccessCodes::ZeroOrOne);
        let settings = repository.settings(Some(timeouts::WORKSPACE_READ))?;
        Ok(MutationPrepared {
            command,
            settings,
            tool: ToolName::try_from("git_mutation_prepare".to_owned())?,
            reply: MutationReply::Prepare(Box::new(MutationPreparation {
                input: self,
                repository,
                phase: MutationPhase::Layout,
            })),
        })
    }
}
impl MutationPreparation {
    pub(crate) fn next(
        self,
        output: Vec<u8>,
        outcome: ToolOutcome,
        code: Option<i32>,
        context: &Preparation,
    ) -> Result<MutationPrepared, CoreError> {
        context.check()?;
        if outcome != ToolOutcome::Ok {
            return Err(match outcome {
                ToolOutcome::Cancelled => CoreError::Cancelled,
                ToolOutcome::Timeout => CoreError::Deadline,
                _ => CoreError::InvalidToolOutput,
            });
        }
        let text = std::str::from_utf8(&output).map_err(|_| CoreError::InvalidToolOutput)?;
        match &self.phase {
            MutationPhase::Layout => {
                let mut lines = text.lines();
                let directory = PathBuf::from(lines.next().ok_or(CoreError::InvalidToolOutput)?);
                let common = PathBuf::from(lines.next().ok_or(CoreError::InvalidToolOutput)?);
                if !matches!(lines.next(), Some("sha1" | "sha256"))
                    || !matches!(lines.next(), Some("files" | "reftable"))
                    || lines.next().is_some()
                {
                    return Err(CoreError::InvalidToolOutput);
                }
                let snapshot = std::sync::Arc::new(scope::capture(
                    self.repository.workspace.path(),
                    &directory,
                    &common,
                    &self.input.query,
                    context,
                )?);
                let args = vec![
                    "rev-parse".into(),
                    "--verify".into(),
                    "--quiet".into(),
                    self.input.query.resolve().into(),
                ];
                self.preflight(
                    args,
                    SuccessCodes::ZeroOrOne,
                    MutationPhase::Resolve {
                        directory,
                        common,
                        snapshot,
                    },
                )
            }
            MutationPhase::Resolve {
                directory,
                common,
                snapshot,
            } => {
                snapshot.revalidate()?;
                let object = text.trim();
                if !object.is_empty()
                    && (!matches!(object.len(), 40 | 64)
                        || !object.bytes().all(|b| b.is_ascii_hexdigit()))
                {
                    return Err(CoreError::InvalidToolOutput);
                }
                let (directory, common, snapshot) =
                    (directory.clone(), common.clone(), snapshot.clone());
                if object.is_empty() && matches!(self.input.query, Mutation::Unstage { .. }) {
                    let reference = scope::unborn_reference(&directory, context)?;
                    return self.preflight(
                        vec!["show-ref".into(), "--exists".into(), reference.into()],
                        SuccessCodes::ZeroOrTwo,
                        MutationPhase::Unborn {
                            directory,
                            common,
                            snapshot,
                        },
                    );
                }
                self.final_command(
                    directory,
                    common,
                    snapshot,
                    if object.is_empty() {
                        None
                    } else {
                        Some(object)
                    },
                    context,
                )
            }
            MutationPhase::Unborn {
                directory,
                common,
                snapshot,
            } => {
                snapshot.revalidate()?;
                if code != Some(2) {
                    return Err(CoreError::Rejected);
                }
                let (directory, common, snapshot) =
                    (directory.clone(), common.clone(), snapshot.clone());
                self.final_command(directory, common, snapshot, None, context)
            }
        }
    }
    fn preflight(
        mut self,
        args: Vec<OsString>,
        codes: SuccessCodes,
        phase: MutationPhase,
    ) -> Result<MutationPrepared, CoreError> {
        let snapshot = match &phase {
            MutationPhase::Resolve { snapshot, .. } | MutationPhase::Unborn { snapshot, .. } => {
                snapshot.clone()
            }
            MutationPhase::Layout => return Err(CoreError::InvalidToolOutput),
        };
        let command = self
            .repository
            .command(
                args,
                Some(timeouts::WORKSPACE_READ),
                OutputLimit::try_from(65536usize)?,
            )?
            .with_action_snapshot(snapshot)
            .with_success_codes(codes);
        let settings = self.repository.settings(Some(timeouts::WORKSPACE_READ))?;
        self.phase = phase;
        Ok(MutationPrepared {
            command,
            settings,
            tool: ToolName::try_from("git_mutation_prepare".to_owned())?,
            reply: MutationReply::Prepare(Box::new(self)),
        })
    }
    fn final_command(
        self,
        directory: PathBuf,
        common: PathBuf,
        snapshot: std::sync::Arc<crate::security::ActionSnapshot>,
        object: Option<&str>,
        context: &Preparation,
    ) -> Result<MutationPrepared, CoreError> {
        let input = self.input;
        let root = self.repository.workspace.path();
        context.check()?;
        snapshot.revalidate()?;
        let mut argv = vec![
            OsString::from("--no-pager"),
            "--no-lazy-fetch".into(),
            "--literal-pathspecs".into(),
            format!(
                "--git-dir={}",
                directory.to_str().ok_or(CoreError::Rejected)?
            )
            .into(),
            format!("--work-tree={}", root.to_str().ok_or(CoreError::Rejected)?).into(),
        ];
        argv.extend(input.query.arguments(object, root)?);
        let mut environment: BTreeMap<OsString, OsString> = input
            .environment
            .iter()
            .filter(|(k, _)| {
                !k.starts_with("GIT_")
                    || matches!(
                        k.as_str(),
                        "GIT_CONFIG_GLOBAL" | "GIT_CONFIG_SYSTEM" | "GIT_CONFIG_NOSYSTEM"
                    )
                    || k.starts_with("GIT_AUTHOR_")
                    || k.starts_with("GIT_COMMITTER_")
            })
            .map(|(k, v)| (k.into(), v.into()))
            .collect();
        environment.insert("GIT_TERMINAL_PROMPT".into(), "0".into());
        // An explicit editor PATH determines both Git and its approved hooks.
        let program = scope::executable(&environment)?;
        let timeout = input.timeout_ms.duration();
        let settings = match timeout {
            Some(t) => RunSettings::new(
                Mode::Agent,
                self.repository.workspace.clone(),
                ToolCallLimit::default(),
                t.checked_add(timeouts::APPROVAL)
                    .ok_or(CoreError::ArithmeticOverflow)?,
                input.config_revision,
                input.policy_revision,
            )?,
            None => RunSettings::persistent(
                Mode::Agent,
                self.repository.workspace.clone(),
                ToolCallLimit::default(),
                input.config_revision,
                input.policy_revision,
            ),
        };
        let command = CommandSpec::try_from(CommandInput {
            program,
            arguments: argv,
            working_directory: root.to_owned(),
            timeout,
            environment: CommandEnvironment::try_from(environment)?,
        })?
        .with_read_target(directory)?
        .with_read_target(common)?
        .with_action_snapshot(snapshot)
        .with_capture(CapturePolicy::Complete)
        .with_output_limit(input.output_bytes);
        let label = match &input.query {
            Mutation::Stage { .. } => "Staged",
            Mutation::Unstage { .. } => "Unstaged",
            Mutation::Commit { .. } => "Commit successful",
            Mutation::BranchCreate { .. } => "Created and switched to branch",
            Mutation::BranchSwitch { .. } => "Switched to branch",
            Mutation::BranchDelete { .. } => "Deleted branch",
            _ => "Stash",
        };
        let intent = json!({"query":input.query,"root":input.root});
        let retained = if matches!(input.query, Mutation::StashApply { .. }) {
            object.map(str::to_owned)
        } else {
            None
        };
        Ok(MutationPrepared {
            command,
            settings,
            tool: input.query.tool()?,
            reply: MutationReply::Report(MutationReport {
                intent,
                output: input.output_bytes,
                label,
                retained,
            }),
        })
    }
}
impl MutationReport {
    pub(crate) fn text(
        &self,
        stdout: &[u8],
        stderr: &[u8],
        outcome: ToolOutcome,
    ) -> Result<String, CoreError> {
        let out = std::str::from_utf8(stdout).map_err(|_| CoreError::InvalidToolOutput)?;
        let err = std::str::from_utf8(stderr).map_err(|_| CoreError::InvalidToolOutput)?;
        let mut text = if outcome == ToolOutcome::Ok {
            format!("{}:\n{out}{err}", self.label)
        } else {
            format!(
                "Git mutation {outcome:?}; changes may be partial or unknown. Do not replay automatically.\n{out}{err}"
            )
        };
        if let Some(object) = &self.retained {
            text.push_str(&format!(
                "\nStash {object} retained; delete manually with Git/Magit if desired."
            ));
        }
        if text.len() > limits::MAX_FRAME_BYTES / 2 {
            return Err(CoreError::Limit);
        }
        Ok(text)
    }
}
