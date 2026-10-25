//! Envelope, lifecycle and take-once correlation contracts.

use kargu_core::application::host::Host;
use kargu_core::domain::RequestScope;
use kargu_core::ipc::pending::{PendingFailure, PendingRequests, RegisterError};
use kargu_core::ipc::protocol::{Message, RpcId, decode};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::time::Instant;

#[test]
fn scoped_raw_metadata_support_does_not_change_ipc_numeric_or_object_kinds()
-> Result<(), Box<dyn std::error::Error>> {
    let envelope = r#"{"jsonrpc":"2.0","id":"fixture","method":"ping","params":{"tuning":{"temperature":0.2},"count":18446744073709551615,"opaque":{"$serde_json::private::Number":"0.2"}}}"#;
    let Message::Call { params, .. } = decode(envelope)? else {
        return Err("expected a call".into());
    };
    assert!(
        params
            .pointer("/tuning/temperature")
            .is_some_and(Value::is_number)
    );
    assert_eq!(params.get("count").and_then(Value::as_u64), Some(u64::MAX));
    assert!(params.get("opaque").is_some_and(Value::is_object));
    let _: kargu_core::api::policy::RequestTuning =
        serde_json::from_value(params.get("tuning").ok_or("missing tuning")?.clone())?;
    assert!(decode(r#"{"jsonrpc":"2.0","method":"ping","params":{"tuning":{"temperature":0.2,"temperature":0.3}}}"#).is_err());
    Ok(())
}

#[test]
fn strict_envelopes_and_null_results() -> Result<(), Box<dyn std::error::Error>> {
    match decode(r#"{"jsonrpc":"2.0","id":0,"result":null}"#)? {
        Message::Response { id, outcome } => {
            assert_eq!(id, RpcId::Integer(0));
            assert_eq!(outcome, Ok(Value::Null));
        }
        _ => return Err("expected response".into()),
    }
    for text in [
        r#"{"jsonrpc":"2.0","method":"ping","id":null}"#,
        r#"{"jsonrpc":"2.0","id":1,"result":null,"error":{}}"#,
        r#"{"jsonrpc":"2.0","id":1}"#,
        r#"{"jsonrpc":"2.0","method":"ping","result":true}"#,
        r#"{"jsonrpc":"2.0","method":"ping","params":false}"#,
        r#"[]"#,
        r#"{"jsonrpc":"1.0","method":"ping"}"#,
    ] {
        assert_eq!(decode(text).err().map(|e| e.code), Some(-32600));
    }
    for text in [
        r#"{"jsonrpc":"2.0","method":"ping","method":"shutdown"}"#,
        r#"{"jsonrpc":"2.0","method":"ping","params":{"secret":1,"secret":2}}"#,
        r#"{"jsonrpc":"2.0","method":"ping"} false"#,
    ] {
        assert_eq!(decode(text).err().map(|e| e.code), Some(-32700));
    }
    assert!(matches!(
        decode(r#"{"jsonrpc":"2.0","id":"r:1","method":"editor/call_tool"}"#),
        Ok(Message::Call { id: Some(_), .. })
    ));
    Ok(())
}

#[test]
fn handshake_and_owner_bound_lifecycle() -> Result<(), Box<dyn std::error::Error>> {
    let mut host = Host::new();
    assert!(
        host.dispatch("application/create", json!({}), true)
            .result
            .is_err()
    );
    assert!(
        host.dispatch(
            "initialize",
            json!({"protocol_major":2,"protocol_minor":0,
        "client_version":"test","capabilities":[],"limits":{"max_frame_bytes":4096}}),
            true
        )
        .result
        .is_err()
    );
    let init = host
        .dispatch(
            "initialize",
            json!({"protocol_major":1,"protocol_minor":4,
        "client_version":"test","capabilities":[],"limits":{"max_frame_bytes":4096}}),
            true,
        )
        .result?;
    assert_eq!(init["protocol_minor"], 0);
    assert_eq!(host.frame_limit().as_usize(), 4096);
    assert!(
        host.dispatch("application/create", json!({}), true)
            .result
            .is_err()
    );
    host.dispatch("initialized", json!({}), false).result?;
    // A notification cannot create state or claim a run.
    assert!(
        host.dispatch("application/create", json!({}), false)
            .result
            .is_err()
    );
    let first = host
        .dispatch("application/create", json!({}), true)
        .result?;
    let second = host
        .dispatch("application/create", json!({}), true)
        .result?;
    let session = host
        .dispatch(
            "session/create",
            json!({"application_id":first["application_id"]}),
            true,
        )
        .result?;
    let own = json!({"application_id":first["application_id"],"session_id":session["session_id"]});
    let foreign =
        json!({"application_id":second["application_id"],"session_id":session["session_id"]});
    assert!(
        host.dispatch("session/close", foreign, true)
            .result
            .is_err()
    );
    assert_eq!(
        host.dispatch("session/snapshot", own.clone(), true)
            .result?["state"],
        "idle"
    );
    assert!(
        host.dispatch("session/prompt", own.clone(), true)
            .result
            .is_err()
    );
    host.dispatch("session/close", own.clone(), true).result?;
    assert!(host.dispatch("session/snapshot", own, true).result.is_err());
    assert_eq!(
        host.dispatch("shutdown", json!({}), true).result?,
        Value::Null
    );
    assert!(host.is_shutdown());
    assert!(
        host.dispatch("application/create", json!({}), true)
            .result
            .is_err()
    );
    assert!(host.dispatch("exit", json!({}), false).exit);
    Ok(())
}

#[tokio::test]
async fn pending_is_bounded_scoped_and_take_once() -> Result<(), Box<dyn std::error::Error>> {
    let mut pending = PendingRequests::default();
    let owner = RequestScope::try_from("owner".to_owned())?;
    let foreign = RequestScope::try_from("foreign".to_owned())?;
    let id = RpcId::String("r:epoch:1".into());
    let waiter = pending.register(
        id.clone(),
        owner.clone(),
        Instant::now() + Duration::from_secs(1),
    )?;
    assert!(matches!(
        pending.register(id.clone(), foreign.clone(), Instant::now()),
        Err(RegisterError::Duplicate)
    ));
    pending.cancel(&id, &foreign);
    assert_eq!(pending.len(), 1);
    pending.resolve(&id, Ok(Value::Null));
    pending.resolve(&id, Ok(json!("duplicate")));
    assert_eq!(waiter.await??, Value::Null);
    let waiter = pending.register(id.clone(), owner.clone(), Instant::now())?;
    pending.resolve(&id, Ok(json!("late")));
    assert!(matches!(waiter.await?, Err(PendingFailure::Timeout)));
    let waiter = pending.register(
        id.clone(),
        owner.clone(),
        Instant::now() + Duration::from_secs(1),
    )?;
    pending.cancel(&id, &owner);
    assert!(matches!(waiter.await?, Err(PendingFailure::Cancelled)));
    let waiter = pending.register(id, owner.clone(), Instant::now() + Duration::from_secs(1))?;
    pending.disconnect();
    assert!(matches!(waiter.await?, Err(PendingFailure::Disconnected)));
    let mut waiters = Vec::new();
    for n in 0..128 {
        waiters.push(pending.register(RpcId::Integer(n), owner.clone(), Instant::now())?);
    }
    assert!(matches!(
        pending.register(RpcId::Integer(129), owner.clone(), Instant::now()),
        Err(RegisterError::Full)
    ));
    pending.expire(Instant::now());
    assert!(pending.is_empty());
    for waiter in waiters {
        assert!(matches!(waiter.await?, Err(PendingFailure::Timeout)));
    }
    Ok(())
}
