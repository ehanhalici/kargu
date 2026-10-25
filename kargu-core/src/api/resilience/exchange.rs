//! Consuming exchange phases. These tokens encode order, not IO authority.
//! The mailbox must still join each worker and check owner/budget/observer policy.
//!
//! Backoff cannot admit another physical attempt:
//! ```compile_fail
//! use kargu_core::api::resilience::exchange::Attempt;
//! let (_, retired) = Attempt::charged(()).retire();
//! let waiting = retired.wait();
//! waiting.admit(());
//! ```
//! An active attempt cannot register an observer before collection:
//! ```compile_fail
//! use kargu_core::api::resilience::exchange::Attempt;
//! let attempt = Attempt::charged(());
//! attempt.observe("reverse");
//! ```
//! One replay permission cannot authorize two attempts:
//! ```compile_fail
//! use kargu_core::api::resilience::exchange::Attempt;
//! let (_, retired) = Attempt::charged(()).retire();
//! let permission = retired.wait().retire().headless();
//! let first = permission.admit(());
//! let second = permission.admit(());
//! ```

/// Active physical attempt; only this phase owns an outstanding usage ticket.
#[must_use = "Join the worker and collect its ticket before advancing"]
pub struct Attempt<Ticket>(Ticket);
/// Physical IO and its accounting have been collected.
pub struct Retired(());
/// A scheduled wait still owns a live worker until it is joined.
pub struct Backoff(());
/// Backoff has been collected; configured observer policy must now be honored.
pub struct ObserverReady(());
/// An outstanding reverse call retains its exact correlation identity.
#[must_use = "Join the observer and retire its correlation before advancing"]
pub struct Observing<Correlation>(Correlation);
/// Observer completion has been collected; its result still needs classification.
pub struct Observed(());
/// Headless policy or an accepted observer permits a new admission check.
/// This is not itself a budget/owner grant.
#[must_use = "Replay still requires fresh actor-owned budget admission"]
pub struct ReplayReady(());

impl<Ticket> Attempt<Ticket> {
    /// Attach the actor's already admitted physical usage ticket.
    pub fn charged(ticket: Ticket) -> Self {
        Self(ticket)
    }
    /// Borrow only to inspect the active ticket's deadline/identity.
    pub fn ticket(&self) -> &Ticket {
        &self.0
    }
    /// Consume after worker join; the actor collects the returned ticket once.
    pub fn retire(self) -> (Ticket, Retired) {
        (self.0, Retired(()))
    }
}
impl Retired {
    /// Retain logical ownership while a separately scheduled backoff runs.
    pub fn wait(self) -> Backoff {
        Backoff(())
    }
}
impl Backoff {
    /// Consume after the actual wait worker has joined, including cancellation.
    pub fn retire(self) -> ObserverReady {
        ObserverReady(())
    }
}
impl ObserverReady {
    /// Attach a registered reverse call; no replay permission exists yet.
    pub fn observe<Correlation>(self, correlation: Correlation) -> Observing<Correlation> {
        Observing(correlation)
    }
    /// Only the captured explicit headless policy may choose this transition.
    pub fn headless(self) -> ReplayReady {
        ReplayReady(())
    }
}
impl<Correlation> Observing<Correlation> {
    /// Consume after observer join; retire the returned reverse correlation.
    pub fn retire(self) -> (Correlation, Observed) {
        (self.0, Observed(()))
    }
}
impl Observed {
    /// Only an exact, positive owned ACK may choose this transition.
    pub fn accepted(self) -> ReplayReady {
        ReplayReady(())
    }
}
impl ReplayReady {
    /// Consume after a fresh budget/owner check grants the next physical ticket.
    pub fn admit<Ticket>(self, ticket: Ticket) -> Attempt<Ticket> {
        Attempt(ticket)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn tickets_and_correlations_survive_only_their_resource_phases() {
        let (ticket, retired) = Attempt::charged(String::from("initial")).retire();
        assert_eq!(ticket, "initial");
        let observing = retired.wait().retire().observe(String::from("reverse"));
        let (correlation, observed) = observing.retire();
        assert_eq!(correlation, "reverse");
        let (ticket, retired) = observed.accepted().admit(String::from("retry")).retire();
        assert_eq!(ticket, "retry");
        let (ticket, _) = retired
            .wait()
            .retire()
            .headless()
            .admit("headless")
            .retire();
        assert_eq!(ticket, "headless");
    }
}
