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

#[test]
fn session_selection_commits_only_from_the_owned_expected_revision()
-> Result<(), Box<dyn std::error::Error>> {
    let mut host = Host::new();
    host.dispatch(
        "initialize",
        json!({"protocol_major":1,"protocol_minor":0,
        "client_version":"test","capabilities":[],"limits":{"max_frame_bytes":4096}}),
        true,
    )
    .result?;
    host.dispatch("initialized", json!({}), false).result?;
    let app = host
        .dispatch("application/create", json!({}), true)
        .result?;
    let other = host
        .dispatch("application/create", json!({}), true)
        .result?;
    let session = host
        .dispatch(
            "session/create",
            json!({"application_id":app["application_id"]}),
            true,
        )
        .result?;
    let scope = json!({"application_id":app["application_id"],"session_id":session["session_id"]});
    let initial = host
        .dispatch("session/selection", scope.clone(), true)
        .result?;
    assert_eq!(initial["revision"], 0);
    assert_eq!(initial["selection"]["effort"]["kind"], "inherit");
    assert_eq!(initial["selection"]["provider"], Value::Null);

    let commit = |revision: u64, selection: Value, application: &Value| {
        json!({"application_id":application["application_id"],"session_id":session["session_id"],
            "expected_revision":revision,"selection":selection})
    };
    let desired =
        json!({"provider":"OpenAI","model":"gpt-x","effort":{"kind":"named","name":"high"}});
    let committed = host
        .dispatch(
            "session/selection/commit",
            commit(0, desired.clone(), &app),
            true,
        )
        .result?;
    assert_eq!(committed["revision"], 1);
    assert_eq!(committed["selection"]["provider"], "openai");
    assert_eq!(committed["selection"]["model"], "gpt-x");

    let stale = host
        .dispatch("session/selection/commit", commit(0, json!({}), &app), true)
        .result;
    assert_eq!(
        stale.err().map(|fault| fault.status),
        Some("stale_revision")
    );
    let foreign = host
        .dispatch(
            "session/selection/commit",
            commit(1, json!({}), &other),
            true,
        )
        .result;
    assert_eq!(foreign.err().map(|fault| fault.status), Some("stale_owner"));
    for invalid in [
        json!({"effort":{"kind":"named","name":"off"}}),
        json!({"model":""}),
        json!({"tuning":{}}),
    ] {
        let result = host
            .dispatch("session/selection/commit", commit(1, invalid, &app), true)
            .result;
        assert_eq!(
            result.err().map(|fault| fault.status),
            Some("invalid_params")
        );
    }
    let unchanged = host
        .dispatch("session/selection", scope.clone(), true)
        .result?;
    assert_eq!(unchanged["revision"], 1);
    assert_eq!(unchanged["selection"], committed["selection"]);

    let reset = host
        .dispatch("session/selection/commit", commit(1, json!({}), &app), true)
        .result?;
    assert_eq!(reset["revision"], 2);
    assert_eq!(reset["selection"]["model"], Value::Null);
    host.dispatch("session/close", scope.clone(), true).result?;
    let closed = host.dispatch("session/selection", scope, true).result;
    assert_eq!(closed.err().map(|fault| fault.status), Some("stale_owner"));
    Ok(())
}

#[test]
fn session_mode_and_tool_availability_are_owned_natively_and_fail_closed()
-> Result<(), Box<dyn std::error::Error>> {
    let mut host = Host::new();
    host.dispatch(
        "initialize",
        json!({"protocol_major":1,"protocol_minor":0,
        "client_version":"test","capabilities":[],"limits":{"max_frame_bytes":4096}}),
        true,
    )
    .result?;
    host.dispatch("initialized", json!({}), false).result?;
    let app = host
        .dispatch("application/create", json!({}), true)
        .result?;
    let session = host
        .dispatch(
            "session/create",
            json!({"application_id": app["application_id"]}),
            true,
        )
        .result?;
    let scope =
        json!({"application_id": app["application_id"], "session_id": session["session_id"]});

    // Initial state is Ask mode at revision 0
    let initial = host.dispatch("session/mode", scope.clone(), true).result?;
    assert_eq!(initial["revision"], 0);
    assert_eq!(initial["mode"], "ask");
    assert_eq!(initial["debug_ready"], false);
    let tools: Vec<&str> = initial["available_tools"]
        .as_array()
        .ok_or("available_tools array")?
        .iter()
        .filter_map(|v| v.as_str())
        .collect();
    assert!(tools.contains(&"find_files"));
    assert!(tools.contains(&"read_file"));
    assert!(
        !tools.contains(&"bash"),
        "bash must not be available in ask mode"
    );
    assert!(
        !tools.contains(&"edit_file"),
        "edit_file must not be available in ask mode"
    );
    assert!(
        !tools.contains(&"debug_start"),
        "debug_start must not be available in ask mode"
    );

    let commit = |revision: u64, mode: &str, debug_ready: bool| {
        json!({
            "application_id": app["application_id"],
            "session_id": session["session_id"],
            "expected_revision": revision,
            "mode": mode,
            "debug_ready": debug_ready
        })
    };

    // Transition to Plan mode
    let plan = host
        .dispatch("session/mode/commit", commit(0, "plan", false), true)
        .result?;
    assert_eq!(plan["revision"], 1);
    assert_eq!(plan["mode"], "plan");
    let plan_tools: Vec<&str> = plan["available_tools"]
        .as_array()
        .ok_or("tools")?
        .iter()
        .filter_map(|v| v.as_str())
        .collect();
    assert!(plan_tools.contains(&"read_file"));
    assert!(!plan_tools.contains(&"bash"));

    // Stale revision rejection
    let stale = host
        .dispatch("session/mode/commit", commit(0, "agent", false), true)
        .result;
    assert_eq!(stale.err().map(|f| f.status), Some("stale_revision"));

    // Debug mode without debug_ready fails closed and retains Plan mode
    let unready_debug = host
        .dispatch("session/mode/commit", commit(1, "debug", false), true)
        .result;
    assert_eq!(unready_debug.err().map(|f| f.status), Some("debug_refusal"));
    let check = host.dispatch("session/mode", scope.clone(), true).result?;
    assert_eq!(check["revision"], 1);
    assert_eq!(check["mode"], "plan");

    // Debug mode with debug_ready succeeds
    let debug = host
        .dispatch("session/mode/commit", commit(1, "debug", true), true)
        .result?;
    assert_eq!(debug["revision"], 2);
    assert_eq!(debug["mode"], "debug");
    assert_eq!(debug["debug_ready"], true);
    let debug_tools: Vec<&str> = debug["available_tools"]
        .as_array()
        .ok_or("tools")?
        .iter()
        .filter_map(|v| v.as_str())
        .collect();
    assert!(debug_tools.contains(&"debug_stack"));
    assert!(debug_tools.contains(&"debug_start"));
    assert!(!debug_tools.contains(&"bash"));

    // Transition to Agent mode
    let agent = host
        .dispatch("session/mode/commit", commit(2, "agent", false), true)
        .result?;
    assert_eq!(agent["revision"], 3);
    assert_eq!(agent["mode"], "agent");
    let agent_tools: Vec<&str> = agent["available_tools"]
        .as_array()
        .ok_or("tools")?
        .iter()
        .filter_map(|v| v.as_str())
        .collect();
    assert!(agent_tools.contains(&"bash"));
    assert!(agent_tools.contains(&"edit_file"));
    assert!(agent_tools.contains(&"find_files"));

    // Unknown mode fails closed with invalid_params
    let unknown = host
        .dispatch(
            "session/mode/commit",
            json!({
                "application_id": app["application_id"],
                "session_id": session["session_id"],
                "expected_revision": 3,
                "mode": "unauthorized_mode"
            }),
            true,
        )
        .result;
    assert_eq!(unknown.err().map(|f| f.status), Some("invalid_params"));

    // After close, session/mode fails with stale_owner
    host.dispatch("session/close", scope.clone(), true).result?;
    let closed = host.dispatch("session/mode", scope, true).result;
    assert_eq!(closed.err().map(|f| f.status), Some("stale_owner"));
    Ok(())
}

#[test]
fn session_plan_lifecycle_and_single_use_claim_are_owned_natively_and_fail_closed()
-> Result<(), Box<dyn std::error::Error>> {
    let mut host = Host::new();
    host.dispatch(
        "initialize",
        json!({"protocol_major":1,"protocol_minor":0,
        "client_version":"test","capabilities":[],"limits":{"max_frame_bytes":4096}}),
        true,
    )
    .result?;
    host.dispatch("initialized", json!({}), false).result?;
    let app = host
        .dispatch("application/create", json!({}), true)
        .result?;
    let session = host
        .dispatch(
            "session/create",
            json!({"application_id": app["application_id"]}),
            true,
        )
        .result?;
    let scope =
        json!({"application_id": app["application_id"], "session_id": session["session_id"]});

    // 1. Initial plan query returns null
    let empty = host.dispatch("session/plan", scope.clone(), true).result?;
    assert_eq!(empty["plan"], Value::Null);

    // 2. Create plan
    let created = host
        .dispatch(
            "session/plan/create",
            json!({
                "application_id": app["application_id"],
                "session_id": session["session_id"],
                "text": "1. Run cargo check\n2. Run tests"
            }),
            true,
        )
        .result?;
    let plan = &created["plan"];
    assert_eq!(plan["revision"], 1);
    assert_eq!(plan["state"], "pending");
    assert_eq!(plan["text"], "1. Run cargo check\n2. Run tests");
    let plan_id = plan["id"].as_str().ok_or("plan_id")?.to_string();
    let hash_v1 = plan["content_hash"].as_str().ok_or("hash")?.to_string();

    // 3. session/plan returns this record
    let fetched = host.dispatch("session/plan", scope.clone(), true).result?;
    assert_eq!(fetched["plan"]["id"], plan_id);
    assert_eq!(fetched["plan"]["revision"], 1);

    // 4. Revise content generates new revision and updates hash
    let revised = host
        .dispatch(
            "session/plan/revise",
            json!({
                "application_id": app["application_id"],
                "session_id": session["session_id"],
                "plan_id": plan_id,
                "expected_revision": 1,
                "text": "1. Run cargo check\n2. Run tests\n3. Verify clippy"
            }),
            true,
        )
        .result?;
    let rev_plan = &revised["plan"];
    assert_eq!(rev_plan["revision"], 2);
    assert_eq!(rev_plan["state"], "pending");
    let hash_v2 = rev_plan["content_hash"].as_str().ok_or("hash")?.to_string();
    assert_ne!(hash_v1, hash_v2);

    // 5. Stale revision revise fails
    let stale_revise = host
        .dispatch(
            "session/plan/revise",
            json!({
                "application_id": app["application_id"],
                "session_id": session["session_id"],
                "plan_id": plan_id,
                "expected_revision": 1,
                "text": "Stale"
            }),
            true,
        )
        .result;
    assert_eq!(stale_revise.err().map(|f| f.status), Some("stale_revision"));

    // 6. Claim with stale revision or bad hash fails
    let stale_claim = host
        .dispatch(
            "session/plan/claim",
            json!({
                "application_id": app["application_id"],
                "session_id": session["session_id"],
                "plan_id": plan_id,
                "expected_revision": 1,
                "expected_hash": hash_v2
            }),
            true,
        )
        .result;
    assert_eq!(stale_claim.err().map(|f| f.status), Some("stale_revision"));

    let bad_hash_claim = host
        .dispatch(
            "session/plan/claim",
            json!({
                "application_id": app["application_id"],
                "session_id": session["session_id"],
                "plan_id": plan_id,
                "expected_revision": 2,
                "expected_hash": hash_v1
            }),
            true,
        )
        .result;
    assert_eq!(
        bad_hash_claim.err().map(|f| f.status),
        Some("stale_revision")
    );

    // 7. Valid single-use claim succeeds
    let claimed = host
        .dispatch(
            "session/plan/claim",
            json!({
                "application_id": app["application_id"],
                "session_id": session["session_id"],
                "plan_id": plan_id,
                "expected_revision": 2,
                "expected_hash": hash_v2
            }),
            true,
        )
        .result?;
    assert_eq!(claimed["claimed"], true);
    assert_eq!(claimed["plan"]["state"], "dispatching");

    // 8. Replay claim fails with already_decided
    let replay_claim = host
        .dispatch(
            "session/plan/claim",
            json!({
                "application_id": app["application_id"],
                "session_id": session["session_id"],
                "plan_id": plan_id,
                "expected_revision": 2,
                "expected_hash": hash_v2
            }),
            true,
        )
        .result;
    assert_eq!(
        replay_claim.err().map(|f| f.status),
        Some("already_decided")
    );

    // 9. Startup failure in dispatch returns to pending
    let failed_complete = host
        .dispatch(
            "session/plan/complete",
            json!({
                "application_id": app["application_id"],
                "session_id": session["session_id"],
                "plan_id": plan_id,
                "success": false
            }),
            true,
        )
        .result?;
    assert_eq!(failed_complete["state"], "pending");

    // 10. Claim again and succeed to terminal
    host.dispatch(
        "session/plan/claim",
        json!({
            "application_id": app["application_id"],
            "session_id": session["session_id"],
            "plan_id": plan_id,
            "expected_revision": 2,
            "expected_hash": hash_v2
        }),
        true,
    )
    .result?;
    let success_complete = host
        .dispatch(
            "session/plan/complete",
            json!({
                "application_id": app["application_id"],
                "session_id": session["session_id"],
                "plan_id": plan_id,
                "success": true
            }),
            true,
        )
        .result?;
    assert_eq!(success_complete["state"], "terminal");

    // 11. Terminal plan cannot be claimed
    let terminal_claim = host
        .dispatch(
            "session/plan/claim",
            json!({
                "application_id": app["application_id"],
                "session_id": session["session_id"],
                "plan_id": plan_id,
                "expected_revision": 2,
                "expected_hash": hash_v2
            }),
            true,
        )
        .result;
    assert_eq!(
        terminal_claim.err().map(|f| f.status),
        Some("already_decided")
    );

    // 12. Create plan B supersedes previous active plan
    let plan_b_res = host
        .dispatch(
            "session/plan/create",
            json!({
                "application_id": app["application_id"],
                "session_id": session["session_id"],
                "text": "Plan B"
            }),
            true,
        )
        .result?;
    let plan_b_id = plan_b_res["plan"]["id"].as_str().ok_or("id")?;
    assert_ne!(plan_b_id, plan_id);

    // 13. Rejection of plan B
    let rejected = host
        .dispatch(
            "session/plan/reject",
            json!({
                "application_id": app["application_id"],
                "session_id": session["session_id"],
                "plan_id": plan_b_id,
                "expected_revision": 1
            }),
            true,
        )
        .result?;
    assert_eq!(rejected["rejected"], true);
    assert_eq!(rejected["state"], "rejected");

    // Rejected plan cannot be claimed
    let rej_claim = host
        .dispatch(
            "session/plan/claim",
            json!({
                "application_id": app["application_id"],
                "session_id": session["session_id"],
                "plan_id": plan_b_id,
                "expected_revision": 1,
                "expected_hash": plan_b_res["plan"]["content_hash"]
            }),
            true,
        )
        .result;
    assert_eq!(rej_claim.err().map(|f| f.status), Some("already_decided"));

    // 14. Session close rejects subsequent operations
    host.dispatch("session/close", scope.clone(), true).result?;
    let closed = host.dispatch("session/plan", scope, true).result;
    assert_eq!(closed.err().map(|f| f.status), Some("stale_owner"));
    Ok(())
}
