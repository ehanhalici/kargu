//! Bounded, cancellable readonly config I/O. Publication remains an editor port.

mod domain;
mod file;
use self::domain::{CandidatePaths, ReadTimeout};
use super::{ConfigurationSource, ParseInput, RefreshGeneration};
use crate::error::CoreError;
pub(crate) use domain::ConfigurationPath;
pub(crate) use domain::ReadTimeout as ConfigurationTimeout;
use serde::Deserialize;
use serde_json::{Value, json};
use std::time::{Duration, Instant};
use tokio_util::sync::CancellationToken;

/// Exact local file candidates supplied by the trusted editor, never the model.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReadInput {
    paths: CandidatePaths,
    generation: RefreshGeneration,
    timeout_ms: ReadTimeout,
}

/// Private editor handoff; intentionally no generic Debug or Serialize surface.
/// ```compile_fail
/// use kargu_core::configuration::read::ReadOutput;
/// fn serialize(value: &ReadOutput) { let _ = serde_json::to_string(value); }
/// ```
/// ```compile_fail
/// use kargu_core::configuration::read::ReadOutput;
/// fn diagnose(value: &ReadOutput) { let _ = format!("{value:?}"); }
/// ```
pub struct ReadOutput(Value);
impl ReadOutput {
    pub(crate) fn into_editor_value(self) -> Value {
        self.0
    }
}

impl ReadInput {
    pub(crate) fn timeout(&self) -> Duration {
        self.timeout_ms.duration()
    }

    /// Execute under a worker-owned token/deadline; no application state writes.
    pub fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<ReadOutput, CoreError> {
        checkpoint(cancel, deadline)?;
        let first = self.paths.0.first().ok_or(CoreError::Rejected)?;
        for candidate in &self.paths.0 {
            checkpoint(cancel, deadline)?;
            let canonical = match candidate.0.canonicalize() {
                Ok(path) => path,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error.into()),
            };
            checkpoint(cancel, deadline)?;
            let bytes = file::CapturedFile::open(&candidate.0, canonical, cancel, deadline)?
                .read(cancel, deadline)?;
            let source = std::str::from_utf8(&bytes).map_err(|_| CoreError::InvalidValue {
                field: "configuration_encoding",
            })?;
            let source =
                ConfigurationSource::try_from(source.to_owned()).map_err(|_| CoreError::Limit)?;
            let mut value = ParseInput {
                source,
                generation: self.generation,
            }
            .resolve();
            value
                .as_object_mut()
                .ok_or(CoreError::Limit)?
                .insert("path".into(), json!(candidate.0));
            checkpoint(cancel, deadline)?;
            return Ok(ReadOutput(value));
        }
        checkpoint(cancel, deadline)?;
        Ok(ReadOutput(
            json!({"status":"absent", "generation":self.generation,"path":first.0}),
        ))
    }
}

fn checkpoint(cancel: &CancellationToken, deadline: Instant) -> Result<(), CoreError> {
    if cancel.is_cancelled() {
        Err(CoreError::Cancelled)
    } else if Instant::now() >= deadline {
        Err(CoreError::Deadline)
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn revoked_or_expired_input_never_performs_file_io() -> Result<(), Box<dyn std::error::Error>> {
        for cancelled in [true, false] {
            let input: ReadInput = serde_json::from_value(
                json!({"paths":["/dev/zero"], "generation":0,"timeout_ms":5000}),
            )?;
            let cancel = CancellationToken::new();
            if cancelled {
                cancel.cancel();
            }
            let result = input.execute(&cancel, Instant::now());
            assert!(matches!(
                (cancelled, result),
                (true, Err(CoreError::Cancelled)) | (false, Err(CoreError::Deadline))
            ));
        }
        Ok(())
    }
}
