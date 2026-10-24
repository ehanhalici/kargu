//! Bounded I/O observations; only the supervisor decides lifecycle transitions.

use crate::{domain::IdleTimeout, error::CoreError};
use std::time::Duration;
use tokio::{sync::watch, time::Instant};

#[derive(Clone, Copy)]
struct Sample {
    last: Instant,
    longest_gap: Duration,
}

/// Cloneable I/O observation endpoint; it cannot cancel or complete a job.
#[derive(Clone)]
pub(super) struct Activity(Option<watch::Sender<Sample>>);
impl Activity {
    pub fn record(&self) {
        if let Some(sender) = &self.0 {
            sender.send_modify(|sample| {
                let now = Instant::now().max(sample.last);
                sample.longest_gap = sample.longest_gap.max(now.duration_since(sample.last));
                sample.last = now;
            });
        }
    }
}

pub(super) struct IdleMonitor {
    observations: Option<watch::Receiver<Sample>>,
    timeout: IdleTimeout,
}
impl IdleMonitor {
    pub fn new(timeout: IdleTimeout) -> (Activity, Self) {
        let (publisher, observations) = if timeout.duration().is_some() {
            let (tx, rx) = watch::channel(Sample {
                last: Instant::now(),
                longest_gap: Duration::ZERO,
            });
            (Some(tx), Some(rx))
        } else {
            (None, None)
        };
        (
            Activity(publisher),
            Self {
                observations,
                timeout,
            },
        )
    }

    pub async fn expired(&mut self) -> Result<(), CoreError> {
        let (Some(duration), Some(observations)) =
            (self.timeout.duration(), self.observations.as_mut())
        else {
            return std::future::pending().await;
        };
        loop {
            let sample = *observations.borrow_and_update();
            // Preserve the longest observed gap across coalesced events. A late
            // pulse must not revive a timeout while this task was descheduled.
            if sample.longest_gap >= duration {
                return Ok(());
            }
            let until = sample
                .last
                .checked_add(duration)
                .ok_or(CoreError::ArithmeticOverflow)?;
            tokio::select! { biased;
                changed = observations.changed() => changed.map_err(|_| CoreError::CleanupFailed)?,
                _ = tokio::time::sleep_until(until) => {
                    let latest = *observations.borrow_and_update();
                    if latest.longest_gap >= duration || Instant::now().duration_since(latest.last) >= duration {
                        return Ok(());
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[tokio::test(start_paused = true)]
    async fn late_coalesced_activity_cannot_revive_expired_idle() -> TestResult {
        let (activity, mut monitor) =
            IdleMonitor::new(IdleTimeout::try_from(Some(Duration::from_millis(100)))?);
        tokio::time::advance(Duration::from_millis(40)).await;
        activity.record();
        tokio::time::advance(Duration::from_millis(101)).await;
        activity.record();
        activity.record();
        let now = Instant::now();
        monitor.expired().await?;
        assert_eq!(Instant::now(), now);
        Ok(())
    }

    #[tokio::test(start_paused = true)]
    async fn active_io_resets_idle_but_disabled_idle_has_no_timer() -> TestResult {
        let (activity, mut monitor) =
            IdleMonitor::new(IdleTimeout::try_from(Some(Duration::from_millis(100)))?);
        for _ in 0..5 {
            tokio::time::advance(Duration::from_millis(40)).await;
            activity.record();
        }
        let now = Instant::now();
        monitor.expired().await?;
        assert_eq!(
            Instant::now().duration_since(now),
            Duration::from_millis(100)
        );
        let (_activity, mut disabled) = IdleMonitor::new(IdleTimeout::DISABLED);
        assert!(
            tokio::time::timeout(Duration::from_secs(1), disabled.expired())
                .await
                .is_err()
        );
        Ok(())
    }
}
