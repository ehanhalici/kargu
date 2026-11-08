//! Typed DTOs and lifecycle boundaries for DAP debugger integration.

use super::{
    coordinates::SourceRange,
    types::{DebugConnectionId, FrameId, SensorText, SourceLine, StopGeneration, ThreadId},
};
use crate::error::CoreError;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Execution status of the target debugger.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DebugStatus {
    /// Debuggee process is actively running.
    Running,
    /// Debuggee process is stopped at a breakpoint, step, or exception.
    Stopped,
    /// Debug session has terminated.
    Terminated,
    /// Debuggee process has exited.
    Exited,
}

/// A stack frame in a stopped thread.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct StackFrameDto {
    /// Frame identifier within the stop generation.
    id: FrameId,
    /// Frame function or symbol name.
    name: String,
    /// Thread owning this frame.
    thread_id: ThreadId,
    /// Source file path, if known.
    #[serde(skip_serializing_if = "Option::is_none")]
    file: Option<PathBuf>,
    /// Source range inside the file, if known.
    #[serde(skip_serializing_if = "Option::is_none")]
    range: Option<SourceRange>,
}

/// A variable in a frame scope.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct VariableDto {
    /// Variable identifier name.
    name: String,
    /// Evaluated string value.
    value: SensorText,
    /// Optional language type string.
    #[serde(skip_serializing_if = "Option::is_none")]
    var_type: Option<String>,
    /// Child variables reference for structured types.
    #[serde(skip_serializing_if = "Option::is_none")]
    children_reference: Option<u64>,
}

/// A breakpoint report from the debugger.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BreakpointDto {
    /// Breakpoint identifier.
    id: u64,
    /// Whether the breakpoint is verified by the runtime.
    verified: bool,
    /// Breakpoint target file path.
    #[serde(skip_serializing_if = "Option::is_none")]
    file: Option<PathBuf>,
    /// Breakpoint target source line.
    #[serde(skip_serializing_if = "Option::is_none")]
    line: Option<SourceLine>,
    /// Optional failure or diagnostic message.
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
}

/// An evaluated watch expression.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WatchDto {
    /// Evaluated watch expression string.
    expression: String,
    /// Result value text, if evaluation succeeded.
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<SensorText>,
    /// Error message, if evaluation failed.
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

/// A debugger thread.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ThreadDto {
    /// Thread identifier.
    id: ThreadId,
    /// Thread label or name.
    name: String,
}

/// Detached canonical debugger snapshot.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DebugContextSnapshot {
    /// Active debug connection identity.
    connection_id: DebugConnectionId,
    /// Stop generation epoch.
    stop_generation: StopGeneration,
    /// Current thread identifier.
    thread_id: ThreadId,
    /// Target execution status.
    status: DebugStatus,
    /// Active stack frame, if stopped.
    #[serde(skip_serializing_if = "Option::is_none")]
    current_frame: Option<StackFrameDto>,
    /// Local variables in the active frame scope.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    local_variables: Vec<VariableDto>,
    /// Stack trace frames for the active thread.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    stack_frames: Vec<StackFrameDto>,
    /// Known threads in the debug session.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    threads: Vec<ThreadDto>,
}

impl DebugContextSnapshot {
    /// Validate that an incoming request matches this exact connection and stop generation.
    pub fn validate_epoch(
        &self,
        connection_id: &DebugConnectionId,
        stop_generation: StopGeneration,
    ) -> Result<(), CoreError> {
        if &self.connection_id != connection_id || self.stop_generation != stop_generation {
            return Err(CoreError::StaleOwner);
        }
        Ok(())
    }

    /// Render a concise context summary for LLM prompt ingestion.
    pub fn render_summary(&self, max_variables: usize) -> String {
        let mut out = String::new();
        out.push_str(&format!(
            "Debugger [connection={}, stop_epoch={}, status={:?}]:\n",
            self.connection_id.as_str(),
            self.stop_generation.get(),
            self.status,
        ));
        if let Some(frame) = &self.current_frame {
            let loc = if let (Some(f), Some(r)) = (&frame.file, &frame.range) {
                format!(
                    " at {}:L{}:C{}",
                    f.display(),
                    r.start().line.get(),
                    r.start().column.get()
                )
            } else {
                String::new()
            };
            out.push_str(&format!(
                "  Current Frame: #{}: {}{}\n",
                frame.id.get(),
                frame.name,
                loc
            ));
        }
        if !self.local_variables.is_empty() {
            out.push_str("  Local Variables:\n");
            let total = self.local_variables.len();
            for var in self.local_variables.iter().take(max_variables) {
                let ty = var
                    .var_type
                    .as_deref()
                    .map(|t| format!(" ({t})"))
                    .unwrap_or_default();
                out.push_str(&format!(
                    "    - {}{}: {}\n",
                    var.name,
                    ty,
                    var.value.as_str()
                ));
            }
            if total > max_variables {
                out.push_str(&format!(
                    "    ... ({} more variables)\n",
                    total - max_variables
                ));
            }
        }
        out
    }
}
