//! Captured adapter result formatting, separate from process lifecycle authority.

use crate::workspace::git::mutation::{MutationPreparation, MutationReport};
use crate::{
    application::ToolOutcome,
    constants::limits,
    domain::ByteLimit,
    error::CoreError,
    process::{CapturedOutput, ProcessResult},
    workspace::git::{GitReadPreparation, GitReadReport, RunningGitReadReport},
    workspace::grep::GrepReport,
};
use serde_json::{Value, json};

pub(super) enum Reply {
    GitMutationPrepare(Box<MutationPreparation>),
    GitMutation(MutationReport),
    Command,
    Grep(GrepReport),
    GitRead(Box<GitReadReport>),
    GitPrepare(Box<GitReadPreparation>),
}
impl Reply {
    pub fn approval_intent(&self) -> Option<&Value> {
        match self {
            Self::GitMutation(r) => Some(&r.intent),
            _ => None,
        }
    }
    pub fn discard(self) -> Result<(), CoreError> {
        match self {
            Self::GitRead(report) => (*report).discard(),
            _ => Ok(()),
        }
    }
    pub fn issued(self) -> RunningReply {
        match self {
            Self::GitMutationPrepare(p) => RunningReply::GitMutationPrepare(p),
            Self::GitMutation(r) => RunningReply::GitMutation(r),
            Self::Command => RunningReply::Command,
            Self::Grep(report) => RunningReply::Grep(report),
            Self::GitRead(report) => RunningReply::GitRead((*report).issued()),
            Self::GitPrepare(preparation) => RunningReply::GitPrepare(preparation),
        }
    }
}
pub(super) enum RunningReply {
    GitMutationPrepare(Box<MutationPreparation>),
    GitMutation(MutationReport),
    Command,
    Grep(GrepReport),
    GitRead(RunningGitReadReport),
    GitPrepare(Box<GitReadPreparation>),
}
pub(super) enum CompletedReply {
    Value(Value),
    Continue(Continuation),
}
pub(super) enum Continuation {
    GitMutation {
        preparation: Box<MutationPreparation>,
        stdout: Vec<u8>,
        outcome: ToolOutcome,
        code: Option<i32>,
    },
    GitRead {
        preparation: Box<GitReadPreparation>,
        stdout: Vec<u8>,
        outcome: ToolOutcome,
    },
}
impl Continuation {
    pub fn prepare(
        self,
        context: &crate::workspace::command::Preparation,
    ) -> Result<super::input::Prepared, CoreError> {
        match self {
            Self::GitMutation {
                preparation,
                stdout,
                outcome,
                code,
            } => preparation
                .next(stdout, outcome, code, context)
                .map(super::input::Prepared::from),
            Self::GitRead {
                preparation,
                stdout,
                outcome,
            } => preparation
                .next(stdout, outcome, context)
                .map(super::input::Prepared::from),
        }
    }
}
impl RunningReply {
    pub fn capture_limit(&self) -> Result<ByteLimit, CoreError> {
        ByteLimit::try_from(match self {
            Self::GitMutationPrepare(_) => 65536,
            Self::GitMutation(report) => report.output.as_usize().max(1),
            Self::Command => limits::SEARCH_RESULT_BYTES,
            Self::Grep(report) => report.output_limit.as_usize().max(1),
            Self::GitPrepare(preparation) => preparation.output_limit().as_usize().max(1),
            Self::GitRead(report) => report.output_limit().as_usize().max(1),
        })
    }
    pub fn complete(
        self,
        result: &ProcessResult,
        output: CapturedOutput,
    ) -> Result<CompletedReply, CoreError> {
        if let Self::GitPrepare(preparation) = self {
            if !result.cleanup_complete {
                return Err(CoreError::CleanupFailed);
            }
            return Ok(CompletedReply::Continue(Continuation::GitRead {
                preparation,
                stdout: output.stdout,
                outcome: result.outcome,
            }));
        }
        if let Self::GitMutationPrepare(preparation) = self {
            if !result.cleanup_complete {
                return Err(CoreError::CleanupFailed);
            }
            return Ok(CompletedReply::Continue(Continuation::GitMutation {
                preparation,
                stdout: output.stdout,
                outcome: result.outcome,
                code: result.exit_code,
            }));
        }
        let rendered = self.render(result, &output);
        if let Self::GitRead(report) = self {
            report.finish(result.cleanup_complete)?;
        }
        rendered.map(CompletedReply::Value)
    }
    fn render(&self, result: &ProcessResult, output: &CapturedOutput) -> Result<Value, CoreError> {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        let notice = if output.truncated {
            "\n... (output truncated)"
        } else {
            ""
        };
        let text = match self {
            Self::GitMutation(report) => {
                report.text(&output.stdout, &output.stderr, result.outcome)?
            }
            Self::GitMutationPrepare(_) => return Err(CoreError::InvalidToolOutput),
            Self::GitRead(report) => report.text(&output.stdout, &output.stderr, result.outcome)?,
            Self::GitPrepare(_) => return Err(CoreError::InvalidToolOutput),
            Self::Grep(report) if result.outcome == ToolOutcome::Ok => {
                let mut text = report.text(&stdout)?;
                if !stderr.is_empty() {
                    text.push_str(&stderr);
                }
                text
            }
            _ => format!("{stdout}{stderr}{notice}"),
        };
        let mut value = json!({"outcome":result.outcome,"exit_code":result.exit_code,"signal":result.signal,
            "cleanup_complete":result.cleanup_complete,"capture_stop":result.capture_stop,
            "stdout":stdout,"stderr":stderr,"truncated":output.truncated,"text":text});
        if let Self::GitRead(report) = self {
            value
                .as_object_mut()
                .ok_or(CoreError::InvalidToolOutput)?
                .insert("coverage".to_owned(), json!(report.coverage()));
        }
        Ok(value)
    }
}
