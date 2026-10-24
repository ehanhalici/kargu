//! Deferred application close retains capacity until all services have drained.

use super::protocol::{self, Fault, RpcId};
use crate::{application::host::Host, constants::limits, domain::ApplicationId, error::CoreError};
use serde_json::{Value, json};
use std::collections::HashMap;

struct Closing {
    application: ApplicationId,
    publish: bool,
}
#[derive(Default)]
pub(super) struct Lifecycle {
    closing: HashMap<RpcId, Closing>,
}
impl Lifecycle {
    pub fn contains(&self, id: &RpcId) -> bool {
        self.closing.contains_key(id)
    }
    pub fn is_empty(&self) -> bool {
        self.closing.is_empty()
    }
    pub fn start(&mut self, host: &mut Host, id: RpcId, params: Value) -> Result<(), Fault> {
        if self.closing.len() >= limits::MAX_PENDING || self.contains(&id) {
            return Err(Fault {
                code: crate::constants::protocol::error_codes::RESOURCE_LIMIT,
                status: "resource_limit",
                message: "Application close capacity reached",
            });
        }
        let application = host.close_application(params)?;
        self.closing.insert(
            id,
            Closing {
                application,
                publish: true,
            },
        );
        Ok(())
    }
    pub fn cancel(&mut self, id: &RpcId) {
        if let Some(close) = self.closing.get_mut(id) {
            close.publish = false;
        }
    }
    pub fn collect(
        &mut self,
        host: &mut Host,
        busy: impl Fn(&ApplicationId) -> bool,
    ) -> Result<Vec<Value>, CoreError> {
        let ids: Vec<_> = self.closing.keys().cloned().collect();
        let mut replies = Vec::new();
        for id in ids {
            let closing = self.closing.get(&id).ok_or(CoreError::CleanupFailed)?;
            if busy(&closing.application) || !host.release_application(&closing.application)? {
                continue;
            }
            let closing = self.closing.remove(&id).ok_or(CoreError::CleanupFailed)?;
            if closing.publish {
                replies.push(protocol::success(&id, json!({"status":"closed"})));
            }
        }
        Ok(replies)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    type TestResult = Result<(), Box<dyn std::error::Error>>;
    fn owner() -> Result<(Host, Value), Box<dyn std::error::Error>> {
        let mut host = Host::new();
        host.dispatch("initialize",json!({"protocol_major":1,"protocol_minor":0,"client_version":"lifecycle-test","capabilities":[],"limits":{"max_frame_bytes":1048576}}),true).result.map_err(|_|"initialize")?;
        host.dispatch("initialized", json!({}), false)
            .result
            .map_err(|_| "initialized")?;
        let app = host
            .dispatch("application/create", json!({}), true)
            .result
            .map_err(|_| "application")?;
        Ok((host, app))
    }
    #[test]
    fn worker_drain_reserves_capacity_and_closing_owner_cannot_create_sessions() -> TestResult {
        let (mut host, app) = owner()?;
        let mut lifecycle = Lifecycle::default();
        lifecycle
            .start(
                &mut host,
                RpcId::parse(&json!("close")).ok_or("id")?,
                app.clone(),
            )
            .map_err(|_| "close")?;
        assert!(host.dispatch("session/create", app, true).result.is_err());
        for _ in 1..limits::MAX_APPLICATIONS {
            assert!(
                host.dispatch("application/create", json!({}), true)
                    .result
                    .is_ok()
            );
        }
        assert!(
            host.dispatch("application/create", json!({}), true)
                .result
                .is_err()
        );
        assert!(lifecycle.collect(&mut host, |_| true)?.is_empty());
        assert!(
            host.dispatch("application/create", json!({}), true)
                .result
                .is_err()
        );
        assert_eq!(lifecycle.collect(&mut host, |_| false)?.len(), 1);
        assert!(
            host.dispatch("application/create", json!({}), true)
                .result
                .is_ok()
        );
        Ok(())
    }
    #[test]
    fn cancelled_close_waiter_does_not_undo_revocation_or_skip_drain() -> TestResult {
        let (mut host, app) = owner()?;
        let id = RpcId::parse(&json!("close")).ok_or("id")?;
        let mut lifecycle = Lifecycle::default();
        lifecycle
            .start(&mut host, id.clone(), app.clone())
            .map_err(|_| "close")?;
        lifecycle.cancel(&id);
        assert!(!lifecycle.is_empty());
        assert!(lifecycle.collect(&mut host, |_| true)?.is_empty());
        assert!(!lifecycle.is_empty());
        assert!(
            host.dispatch("session/create", app.clone(), true)
                .result
                .is_err()
        );
        assert!(lifecycle.collect(&mut host, |_| false)?.is_empty());
        assert!(lifecycle.is_empty());
        assert!(host.dispatch("session/create", app, true).result.is_err());
        Ok(())
    }
}
