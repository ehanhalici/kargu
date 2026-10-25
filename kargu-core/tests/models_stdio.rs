//! Real framed metadata staging, atomic publication and application/session ownership.

mod support;
use serde_json::{Value, json};
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn call(
    peer: &mut Peer,
    scope: &Value,
    method: &str,
    arguments: Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    peer.send(json!({"jsonrpc":"2.0","id":"metadata","method":method,"params":{"scope":scope,"arguments":arguments}}))?;
    let reply = peer.read()?;
    assert_eq!(reply.get("id"), Some(&json!("metadata")));
    Ok(reply)
}
fn success(reply: &Value) -> Result<&Value, Box<dyn std::error::Error>> {
    reply
        .get("result")
        .ok_or_else(|| format!("unexpected fault {reply}").into())
}
fn begin(
    peer: &mut Peer,
    scope: &Value,
    revision: u64,
) -> Result<Value, Box<dyn std::error::Error>> {
    let reply = call(
        peer,
        scope,
        "models/begin",
        json!({"provider":"A","revision":revision}),
    )?;
    Ok(success(&reply)?.clone())
}
fn append(peer: &mut Peer, scope: &Value, upload: &Value, source: &str) -> TestResult {
    let max = usize::try_from(
        upload
            .get("max_chunk_bytes")
            .and_then(Value::as_u64)
            .ok_or("chunk bound missing")?,
    )?;
    let id = upload.get("upload_id").ok_or("upload identity missing")?;
    let mut offset = 0_usize;
    while offset < source.len() {
        let mut end = offset.saturating_add(max).min(source.len());
        while !source.is_char_boundary(end) {
            end = end.saturating_sub(1);
        }
        let reply = call(
            peer,
            scope,
            "models/append",
            json!({"upload_id":id,"offset":offset,"chunk":source.get(offset..end).ok_or("invalid source range")?}),
        )?;
        assert_eq!(success(&reply)?.get("offset"), Some(&json!(end)));
        offset = end;
    }
    Ok(())
}
fn publish(
    peer: &mut Peer,
    scope: &Value,
    revision: u64,
    source: &str,
) -> Result<Value, Box<dyn std::error::Error>> {
    let upload = begin(peer, scope, revision)?;
    append(peer, scope, &upload, source)?;
    let reply = call(
        peer,
        scope,
        "models/commit",
        json!({"upload_id":upload.get("upload_id")}),
    )?;
    Ok(success(&reply)?.clone())
}
fn snapshot(
    peer: &mut Peer,
    scope: &Value,
    descriptor: &Value,
    frame: usize,
) -> Result<Value, Box<dyn std::error::Error>> {
    let mut offset = 0_usize;
    let mut source = String::new();
    loop {
        let reply = call(
            peer,
            scope,
            "models/read",
            json!({"revision":descriptor.get("revision"),"offset":offset}),
        )?;
        assert!(serde_json::to_vec(&reply)?.len() < frame);
        let page = success(&reply)?;
        assert_eq!(page.get("offset"), Some(&json!(offset)));
        source.push_str(
            page.get("chunk")
                .and_then(Value::as_str)
                .ok_or("missing page")?,
        );
        offset = source.len();
        assert_eq!(page.get("next_offset"), Some(&json!(offset)));
        if page.get("done") == Some(&json!(true)) {
            break;
        }
    }
    assert_eq!(descriptor.get("total_bytes"), Some(&json!(source.len())));
    Ok(serde_json::from_str(&source)?)
}

#[test]
fn staging_is_not_publication_mailbox_stays_live_and_commit_cannot_replay() -> TestResult {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let upload = begin(&mut peer, &scope, 0)?;
    append(
        &mut peer,
        &scope,
        &upload,
        r#"{"operation":"put","model":"Model","metadata":{"context_length":9007199254740992.5,"pricing":{"prompt":1e-38}}}"#,
    )?;
    let before = call(&mut peer, &scope, "models/snapshot", json!({}))?;
    assert_eq!(success(&before)?.get("revision"), Some(&json!(0)));
    peer.send(json!({"jsonrpc":"2.0","id":"ping","method":"ping"}))?;
    assert_eq!(peer.read()?.get("id"), Some(&json!("ping")));
    let committed = call(
        &mut peer,
        &scope,
        "models/commit",
        json!({"upload_id":upload.get("upload_id")}),
    )?;
    assert_eq!(success(&committed)?.get("revision"), Some(&json!(1)));
    let view = snapshot(&mut peer, &scope, success(&committed)?, 1_048_576)?;
    assert_eq!(
        view.pointer("/records/0/fields/context_window/state"),
        Some(&json!("invalid"))
    );
    assert_eq!(
        view.pointer("/records/0/fields/input_cost/value"),
        Some(&json!("0.00000000000000000000000000000000000001"))
    );
    let replay = call(
        &mut peer,
        &scope,
        "models/commit",
        json!({"upload_id":upload.get("upload_id")}),
    )?;
    assert_eq!(
        replay.pointer("/error/data/status"),
        Some(&json!("stale_metadata"))
    );
    Ok(())
}

#[test]
fn upload_ids_cannot_borrow_a_sibling_session_or_application() -> TestResult {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let foreign = peer.scope()?;
    peer.send(json!({"jsonrpc":"2.0","id":"session","method":"session/create","params":{"application_id":scope.get("application_id")}}))?;
    let sibling = peer.read()?.get("result").ok_or("session missing")?.clone();
    let upload = begin(&mut peer, &scope, 0)?;
    for attacker in [&sibling, &foreign] {
        let reply = call(
            &mut peer,
            attacker,
            "models/append",
            json!({"upload_id":upload.get("upload_id"),"offset":0,"chunk":"forbidden"}),
        )?;
        assert!(reply.get("error").is_some());
        let reply = call(
            &mut peer,
            attacker,
            "models/abort",
            json!({"upload_id":upload.get("upload_id")}),
        )?;
        assert!(reply.get("error").is_some());
    }
    append(
        &mut peer,
        &scope,
        &upload,
        r#"{"operation":"put","model":"owned","metadata":{}}"#,
    )?;
    let reply = call(
        &mut peer,
        &scope,
        "models/commit",
        json!({"upload_id":upload.get("upload_id")}),
    )?;
    assert_eq!(success(&reply)?.get("revision"), Some(&json!(1)));
    let foreign_view = call(&mut peer, &foreign, "models/snapshot", json!({}))?;
    assert_eq!(success(&foreign_view)?.get("revision"), Some(&json!(0)));
    Ok(())
}

#[test]
fn malformed_offset_abort_and_invalid_commit_never_publish_partial_data() -> TestResult {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let baseline = publish(
        &mut peer,
        &scope,
        0,
        r#"{"operation":"put","model":"good","metadata":{"context_length":10}}"#,
    )?;
    let upload = begin(&mut peer, &scope, 1)?;
    let bad_offset = call(
        &mut peer,
        &scope,
        "models/append",
        json!({"upload_id":upload.get("upload_id"),"offset":1,"chunk":"{}"}),
    )?;
    assert!(bad_offset.get("error").is_some());
    append(&mut peer, &scope, &upload, "{broken")?;
    let failed = call(
        &mut peer,
        &scope,
        "models/commit",
        json!({"upload_id":upload.get("upload_id")}),
    )?;
    assert_eq!(
        failed.pointer("/error/data/status"),
        Some(&json!("invalid_metadata"))
    );
    let after = call(&mut peer, &scope, "models/snapshot", json!({}))?;
    assert_eq!(success(&after)?, &baseline);
    let upload = begin(&mut peer, &scope, 1)?;
    append(
        &mut peer,
        &scope,
        &upload,
        r#"{"operation":"replace_catalog","catalog":[]}"#,
    )?;
    let aborted = call(
        &mut peer,
        &scope,
        "models/abort",
        json!({"upload_id":upload.get("upload_id")}),
    )?;
    assert_eq!(success(&aborted)?.get("status"), Some(&json!("aborted")));
    let after = call(&mut peer, &scope, "models/snapshot", json!({}))?;
    assert_eq!(success(&after)?, &baseline);
    let stale = call(
        &mut peer,
        &scope,
        "models/begin",
        json!({"provider":"a","revision":0}),
    )?;
    assert_eq!(
        stale.pointer("/error/data/status"),
        Some(&json!("stale_metadata"))
    );
    Ok(())
}

#[test]
fn large_unicode_snapshot_uses_pages_and_old_revision_cannot_be_mixed_in() -> TestResult {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let source = json!({"operation":"put","model":"large","metadata":{"description":"🦀\"\\\n".repeat(120_000),"input-cost":"invalid9"}}).to_string();
    assert!(source.len() > 1_048_576);
    let descriptor = publish(&mut peer, &scope, 0, &source)?;
    let view = snapshot(&mut peer, &scope, &descriptor, 1_048_576)?;
    assert_eq!(
        view.pointer("/records/0/fields/input_cost/state"),
        Some(&json!("invalid"))
    );
    assert_eq!(
        view.pointer("/records/0/metadata/description"),
        Some(&json!("🦀\"\\\n".repeat(120_000)))
    );
    publish(
        &mut peer,
        &scope,
        1,
        r#"{"operation":"replace_catalog","catalog":[]}"#,
    )?;
    let stale = call(
        &mut peer,
        &scope,
        "models/read",
        json!({"revision":1,"offset":0}),
    )?;
    assert_eq!(
        stale.pointer("/error/data/status"),
        Some(&json!("stale_metadata"))
    );
    Ok(())
}

#[test]
fn minimum_negotiated_frame_keeps_unicode_and_worst_case_escaping_bounded() -> TestResult {
    let mut peer = Peer::start()?;
    peer.send(json!({"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocol_major":1,"protocol_minor":0,"client_version":"metadata-test","capabilities":[],"limits":{"max_frame_bytes":1024}}}))?;
    let initialized = peer.read()?;
    assert!(
        initialized
            .pointer("/result/capabilities")
            .and_then(Value::as_array)
            .ok_or("capabilities missing")?
            .contains(&json!("model_metadata"))
    );
    peer.send(json!({"jsonrpc":"2.0","method":"initialized"}))?;
    let scope = peer.scope()?;
    let source = json!({"operation":"put","model":"small-frame","metadata":{"description":"🦀\"\\\n".repeat(150)}}).to_string();
    let descriptor = publish(&mut peer, &scope, 0, &source)?;
    let view = snapshot(&mut peer, &scope, &descriptor, 1024)?;
    assert_eq!(view.pointer("/records/0/id"), Some(&json!("small-frame")));
    Ok(())
}

#[test]
fn session_close_discards_staging_without_closing_sibling_metadata_service() -> TestResult {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    peer.send(json!({"jsonrpc":"2.0","id":"session","method":"session/create","params":{"application_id":scope.get("application_id")}}))?;
    let sibling = peer.read()?.get("result").ok_or("session missing")?.clone();
    let upload = begin(&mut peer, &scope, 0)?;
    append(
        &mut peer,
        &scope,
        &upload,
        r#"{"operation":"put","model":"discarded","metadata":{}}"#,
    )?;
    peer.send(json!({"jsonrpc":"2.0","id":"close","method":"session/close","params":scope}))?;
    assert_eq!(
        peer.read()?.pointer("/result/status"),
        Some(&json!("closed"))
    );
    let stale = call(
        &mut peer,
        &scope,
        "models/commit",
        json!({"upload_id":upload.get("upload_id")}),
    )?;
    assert_eq!(
        stale.pointer("/error/data/status"),
        Some(&json!("stale_owner"))
    );
    let committed = publish(
        &mut peer,
        &sibling,
        0,
        r#"{"operation":"put","model":"live","metadata":{}}"#,
    )?;
    assert_eq!(committed.get("revision"), Some(&json!(1)));
    let pending = begin(&mut peer, &sibling, 1)?;
    peer.send(json!({"jsonrpc":"2.0","id":"close-app","method":"application/close","params":{"application_id":sibling.get("application_id")}}))?;
    assert_eq!(
        peer.read()?.pointer("/result/status"),
        Some(&json!("closed"))
    );
    let stale = call(
        &mut peer,
        &sibling,
        "models/commit",
        json!({"upload_id":pending.get("upload_id")}),
    )?;
    assert_eq!(
        stale.pointer("/error/data/status"),
        Some(&json!("stale_owner"))
    );
    peer.send(json!({"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}))?;
    assert_eq!(peer.read()?.get("id"), Some(&json!("shutdown")));
    peer.send(json!({"jsonrpc":"2.0","method":"exit"}))?;
    assert!(peer.wait()?);
    Ok(())
}
