//! Per-conversation mode state and transition admission.
//!
//! Tracks the active Mode (Ask, Plan, Debug, Agent) and monotonic revision.
//! Mode transitions are admitted by the native actor:
//! - Unknown modes fail closed.
//! - Transition to debug requires successful debug preparation; failed/cancelled
//!   preparation preserves the previous mode.
//! - Changes while an active run is in progress are rejected with CoreError::Busy.
//! - Once an active run starts, its settings capture and freeze its mode.

use crate::{application::Mode, error::CoreError};
use serde::{Deserialize, Serialize};

/// Monotonic committed mode revision within one conversation.
#[derive(Clone, Copy, Debug, Default, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(try_from = "u64")]
pub struct ModeRevision(u64);

impl ModeRevision {
    /// Revision of a newly created conversation's default mode.
    pub const ZERO: Self = Self(0);

    /// Borrow the revision at a serialization boundary.
    pub const fn as_u64(self) -> u64 {
        self.0
    }

    fn next(self) -> Result<Self, CoreError> {
        self.0
            .checked_add(1)
            .map(Self)
            .ok_or(CoreError::ArithmeticOverflow)
    }
}

impl TryFrom<u64> for ModeRevision {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, CoreError> {
        Ok(Self(value))
    }
}

/// Whether debugger preparation succeeded.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct DebugReady(bool);

impl DebugReady {
    /// Wrap raw readiness flag.
    pub const fn new(ready: bool) -> Self {
        Self(ready)
    }

    /// Extract underlying readiness flag.
    pub const fn get(self) -> bool {
        self.0
    }
}

impl From<bool> for DebugReady {
    fn from(value: bool) -> Self {
        Self(value)
    }
}

/// Whether an active run locks mode transitions for the conversation.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ModeLock(bool);

impl ModeLock {
    /// Wrap raw lock flag.
    pub const fn new(locked: bool) -> Self {
        Self(locked)
    }

    /// Extract underlying lock flag.
    pub const fn is_locked(self) -> bool {
        self.0
    }
}

impl From<bool> for ModeLock {
    fn from(value: bool) -> Self {
        Self(value)
    }
}

/// Mode transition intent.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ModeIntent {
    mode: Mode,
    debug_ready: DebugReady,
}

impl ModeIntent {
    /// Create a validated mode transition intent.
    pub const fn new(mode: Mode, debug_ready: DebugReady) -> Self {
        Self { mode, debug_ready }
    }

    /// Desired target mode.
    pub const fn mode(self) -> Mode {
        self.mode
    }

    /// Whether debugger preparation succeeded.
    pub const fn debug_ready(self) -> DebugReady {
        self.debug_ready
    }
}

/// Committed session mode and monotonic revision.
#[derive(Clone, Debug, Serialize)]
pub struct SessionMode {
    revision: ModeRevision,
    mode: Mode,
    debug_ready: DebugReady,
}

impl Default for SessionMode {
    fn default() -> Self {
        Self {
            revision: ModeRevision::ZERO,
            mode: Mode::Ask,
            debug_ready: DebugReady::new(false),
        }
    }
}

impl SessionMode {
    /// Construct committed mode with initial zero revision.
    pub const fn with_mode(mode: Mode) -> Self {
        Self {
            revision: ModeRevision::ZERO,
            mode,
            debug_ready: DebugReady::new(false),
        }
    }

    /// Current monotonic revision.
    pub const fn revision(&self) -> ModeRevision {
        self.revision
    }

    /// Current mode.
    pub const fn mode(&self) -> Mode {
        self.mode
    }

    /// Whether debug mode was admitted with verified preparation.
    pub const fn debug_ready(&self) -> DebugReady {
        self.debug_ready
    }

    /// Commit a mode transition from the observed expected revision.
    pub fn commit(
        &mut self,
        expected: ModeRevision,
        intent: ModeIntent,
        locked: ModeLock,
    ) -> Result<(), CoreError> {
        if locked.is_locked() {
            return Err(CoreError::Busy);
        }
        if expected != self.revision {
            return Err(CoreError::StaleOwner);
        }
        if intent.mode() == Mode::Debug && !intent.debug_ready().get() {
            return Err(CoreError::Unavailable);
        }
        if intent.mode() != self.mode || intent.debug_ready() != self.debug_ready {
            self.revision = self.revision.next()?;
            self.mode = intent.mode();
            self.debug_ready = intent.debug_ready();
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_mode_initial_state_is_ask_zero() {
        let store = SessionMode::default();
        assert_eq!(store.revision(), ModeRevision::ZERO);
        assert_eq!(store.mode(), Mode::Ask);
        assert!(!store.debug_ready().get());
    }

    #[test]
    fn session_mode_transitions_and_increments_revision() {
        let mut store = SessionMode::default();
        let intent = ModeIntent::new(Mode::Plan, DebugReady::new(false));
        assert!(
            store
                .commit(ModeRevision::ZERO, intent, ModeLock::new(false))
                .is_ok()
        );
        assert_eq!(store.revision(), ModeRevision(1));
        assert_eq!(store.mode(), Mode::Plan);
    }

    #[test]
    fn session_mode_rejects_stale_revision() {
        let mut store = SessionMode::default();
        let intent = ModeIntent::new(Mode::Agent, DebugReady::new(false));
        let err = store.commit(ModeRevision(5), intent, ModeLock::new(false));
        assert!(matches!(err, Err(CoreError::StaleOwner)));
        assert_eq!(store.mode(), Mode::Ask);
    }

    #[test]
    fn session_mode_rejects_when_locked() {
        let mut store = SessionMode::default();
        let intent = ModeIntent::new(Mode::Agent, DebugReady::new(false));
        let err = store.commit(ModeRevision::ZERO, intent, ModeLock::new(true));
        assert!(matches!(err, Err(CoreError::Busy)));
        assert_eq!(store.mode(), Mode::Ask);
    }

    #[test]
    fn session_mode_debug_without_ready_fails_and_preserves_mode() {
        let mut store = SessionMode::default();
        let intent = ModeIntent::new(Mode::Debug, DebugReady::new(false));
        let err = store.commit(ModeRevision::ZERO, intent, ModeLock::new(false));
        assert!(matches!(err, Err(CoreError::Unavailable)));
        assert_eq!(store.mode(), Mode::Ask);
        assert_eq!(store.revision(), ModeRevision::ZERO);
    }

    #[test]
    fn session_mode_debug_with_ready_succeeds() {
        let mut store = SessionMode::default();
        let intent = ModeIntent::new(Mode::Debug, DebugReady::new(true));
        assert!(
            store
                .commit(ModeRevision::ZERO, intent, ModeLock::new(false))
                .is_ok()
        );
        assert_eq!(store.mode(), Mode::Debug);
        assert!(store.debug_ready().get());
        assert_eq!(store.revision(), ModeRevision(1));
    }
}
