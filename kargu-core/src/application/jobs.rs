//! Session-owned process-service scopes, separate from the single agent claim.

use super::{ApplicationActor, RunHandle, RunPurpose, RunSettings};
use crate::{constants::limits, domain::SessionId, error::CoreError};

impl ApplicationActor {
    /// Admit an explicitly owned service job without taking another agent turn.
    /// Its resources and call ledger must still drain before this job is released.
    pub fn admit_job(
        &mut self,
        session: &SessionId,
        settings: RunSettings,
    ) -> Result<RunHandle, CoreError> {
        self.check_admission()?;
        if self.job_runs.len() >= limits::APPLICATION_JOBS {
            return Err(CoreError::Limit);
        }
        let run = self.capture_run(session, settings, RunPurpose::ProcessJob)?;
        let handle = run.handle.clone();
        self.job_runs.insert(handle.scope().run_id().clone(), run);
        Ok(handle)
    }
    pub(super) fn check_admission(&self) -> Result<(), CoreError> {
        if self
            .active
            .iter()
            .chain(self.job_runs.values())
            .chain(self.editor_runs.values())
            .any(|run| run.cleanup_failed)
        {
            return Err(CoreError::CleanupFailed);
        }
        Ok(())
    }
}
