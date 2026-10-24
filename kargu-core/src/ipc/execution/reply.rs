//! Captured adapter result formatting, separate from process lifecycle authority.

use crate::{
    application::ToolOutcome,
    constants::limits,
    domain::ByteLimit,
    error::CoreError,
    process::{CapturedOutput, ProcessResult},
    workspace::git::StatusReport,
    workspace::grep::GrepReport,
};
use serde_json::{Value, json};

pub(super) enum Reply {
    Command,
    Grep(GrepReport),
    GitStatus(StatusReport),
}
impl Reply {
    pub fn capture_limit(&self) -> Result<ByteLimit, CoreError> {
        ByteLimit::try_from(match self {
            Self::Command => limits::SEARCH_RESULT_BYTES,
            Self::Grep(report) => report.output_limit.as_usize().max(1),
            Self::GitStatus(report) => report.output_limit.as_usize().max(1),
        })
    }
    pub fn render(
        &self,
        result: &ProcessResult,
        output: &CapturedOutput,
    ) -> Result<Value, CoreError> {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        let notice = if output.truncated {
            "\n... (output truncated)"
        } else {
            ""
        };
        let text = match self {
            Self::GitStatus(report) if result.outcome == ToolOutcome::Ok => report.text(
                std::str::from_utf8(&output.stdout).map_err(|_| CoreError::InvalidToolOutput)?,
            )?,
            Self::Grep(report) if result.outcome == ToolOutcome::Ok => {
                let mut text = report.text(&stdout)?;
                if !stderr.is_empty() {
                    text.push_str(&stderr);
                }
                text
            }
            _ => format!("{stdout}{stderr}{notice}"),
        };
        Ok(
            json!({"outcome":result.outcome,"exit_code":result.exit_code,"signal":result.signal,
            "cleanup_complete":result.cleanup_complete,"capture_stop":result.capture_stop,
            "stdout":stdout,"stderr":stderr,"truncated":output.truncated,"text":text}),
        )
    }
}
