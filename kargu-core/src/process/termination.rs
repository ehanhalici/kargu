//! Supervisor stop cause is distinct from both OS exit and capture observations.

use crate::{
    application::ToolOutcome,
    domain::{CaptureStop, SuccessCodes},
};
use std::process::ExitStatus;

#[derive(Clone, Copy)]
pub(super) enum StopCause {
    Exited,
    Cancelled,
    Timeout,
    Capture(CaptureStop),
    Unknown,
}
impl StopCause {
    pub fn outcome(
        self,
        status: Option<&ExitStatus>,
        capture: Option<CaptureStop>,
        success: SuccessCodes,
        cleanup_complete: bool,
    ) -> ToolOutcome {
        if !cleanup_complete {
            return ToolOutcome::OutcomeUnknown;
        }
        match self {
            Self::Cancelled => ToolOutcome::Cancelled,
            Self::Timeout => ToolOutcome::Timeout,
            Self::Unknown => ToolOutcome::OutcomeUnknown,
            Self::Capture(CaptureStop::Bytes) => ToolOutcome::Failed,
            Self::Capture(CaptureStop::Records) if capture == Some(CaptureStop::Bytes) => {
                ToolOutcome::Failed
            }
            // The supervisor intentionally stopped a still-running producer.
            // Its signal exit is evidence, not a failed exhaustive search.
            Self::Capture(CaptureStop::Records) => ToolOutcome::Ok,
            Self::Exited if capture == Some(CaptureStop::Bytes) => ToolOutcome::Failed,
            Self::Exited if status.is_some_and(|status| success.accepts(status)) => ToolOutcome::Ok,
            Self::Exited => ToolOutcome::Failed,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::process::ExitStatusExt;

    #[test]
    fn invalid_output_downgrades_success_before_delivery_without_reviving_terminal_failure() {
        for outcome in [
            ToolOutcome::Ok,
            ToolOutcome::Failed,
            ToolOutcome::Cancelled,
            ToolOutcome::Timeout,
            ToolOutcome::OutcomeUnknown,
        ] {
            let mut result = crate::process::ProcessResult {
                outcome,
                exit_code: Some(0),
                signal: None,
                cleanup_complete: true,
                capture_stop: None,
            };
            result.reject_output();
            assert_eq!(
                result.outcome,
                if outcome == ToolOutcome::Ok {
                    ToolOutcome::Failed
                } else {
                    outcome
                }
            );
        }
    }

    #[test]
    fn late_capture_cannot_revive_cancel_timeout_failure_or_unknown_cleanup() {
        let success = ExitStatus::from_raw(0);
        let failure = ExitStatus::from_raw(2 << 8);
        let signal = ExitStatus::from_raw(15);
        for (cause, expected) in [
            (StopCause::Cancelled, ToolOutcome::Cancelled),
            (StopCause::Timeout, ToolOutcome::Timeout),
            (StopCause::Unknown, ToolOutcome::OutcomeUnknown),
        ] {
            assert_eq!(
                cause.outcome(
                    Some(&success),
                    Some(CaptureStop::Records),
                    SuccessCodes::ZeroOrOne,
                    true
                ),
                expected
            );
        }
        for cause in [StopCause::Exited, StopCause::Capture(CaptureStop::Records)] {
            assert_eq!(
                cause.outcome(
                    Some(&success),
                    Some(CaptureStop::Records),
                    SuccessCodes::Zero,
                    false
                ),
                ToolOutcome::OutcomeUnknown
            );
        }
        assert_eq!(
            StopCause::Exited.outcome(
                Some(&failure),
                Some(CaptureStop::Records),
                SuccessCodes::ZeroOrOne,
                true
            ),
            ToolOutcome::Failed
        );
        assert_eq!(
            StopCause::Exited.outcome(
                Some(&success),
                Some(CaptureStop::Bytes),
                SuccessCodes::Zero,
                true
            ),
            ToolOutcome::Failed
        );
        assert_eq!(
            StopCause::Capture(CaptureStop::Records).outcome(
                Some(&signal),
                Some(CaptureStop::Records),
                SuccessCodes::Zero,
                true
            ),
            ToolOutcome::Ok
        );
        assert_eq!(
            StopCause::Capture(CaptureStop::Records).outcome(
                Some(&signal),
                Some(CaptureStop::Bytes),
                SuccessCodes::Zero,
                true
            ),
            ToolOutcome::Failed
        );
    }
}
