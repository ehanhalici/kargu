//! Real pipe: the owned prepared artifact reaches the shared native editor gate.
mod support;
use serde_json::{Value, json};
use std::{
    path::Path,
    time::{Duration, Instant},
};
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;
const SOURCE: &str = "editor_source_12345678-1234-4234-8234-123456789abc";
const FOREIGN: &str = "editor_source_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
fn call(
    peer: &mut Peer,
    scope: &Value,
    method: &str,
    args: Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    peer.send(json!({"jsonrpc":"2.0","id":"edit-call","method":method,"params":{"scope":scope,"arguments":args}}))?;
    let reply = peer.read()?;
    assert_eq!(reply["id"], "edit-call", "{reply}");
    Ok(reply)
}
fn begin(root: &Path, source: &str, review: &str) -> Value {
    json!({"origin_id":source,"root":root,"mode":"agent","intent":{"kind":"write","path":"file.txt","new_bytes":4},"live":null,"config_revision":3,"policy_revision":7,"review_mode":review,"save_policy":"save"})
}
fn prepared(
    peer: &mut Peer,
    scope: &Value,
    root: &Path,
    source: &str,
    review: &str,
) -> Result<Value, Box<dyn std::error::Error>> {
    let id =
        call(peer, scope, "edit/begin", begin(root, source, review))?["result"]["preparation_id"]
            .clone();
    assert!(id.is_string());
    let reply = call(
        peer,
        scope,
        "edit/append",
        json!({"origin_id":source,"preparation_id":id,"part":"new","offset":0,"text":"new\n"}),
    )?;
    assert_eq!(reply["result"]["offset"], 4, "{reply}");
    let reply = call(peer, scope, "edit/prepare", ticket(source, &id))?;
    assert_eq!(reply["result"]["preparation_id"], id, "{reply}");
    Ok(id)
}
fn ticket(source: &str, id: &Value) -> Value {
    json!({"origin_id":source,"preparation_id":id})
}
fn authorize(
    peer: &mut Peer,
    scope: &Value,
    source: &str,
    preparation: &Value,
    presenter: &str,
) -> Result<Value, Box<dyn std::error::Error>> {
    call(
        peer,
        scope,
        "edit/authorize",
        json!({"origin_id":source,"preparation_id":preparation,"presenter":presenter}),
    )
}
fn decide(
    peer: &mut Peer,
    scope: &Value,
    source: &str,
    edit: &Value,
    revision: u64,
    decision: &str,
) -> Result<Value, Box<dyn std::error::Error>> {
    call(
        peer,
        scope,
        "edit/decision",
        json!({"origin_id":source,"edit_id":edit,"revision":revision,"decision":decision}),
    )
}
fn released(peer: &mut Peer, scope: &Value, preparation: &Value) -> TestResult {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let reply = call(
            peer,
            scope,
            "edit/read",
            json!({"origin_id":SOURCE,"preparation_id":preparation,"part":"base","offset":0}),
        )?;
        if reply["error"]["data"]["status"] == "stale_owner" {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!("Claim not released: {reply}").into());
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}
#[test]
fn auto_claim_preserves_paged_source_and_reservation_until_explicit_abort() -> TestResult {
    let root = tempfile::tempdir()?;
    std::fs::write(root.path().join("file.txt"), "old\n")?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let prep = prepared(&mut peer, &scope, root.path(), SOURCE, "auto")?;
    let result = authorize(&mut peer, &scope, SOURCE, &prep, "missing")?["result"].clone();
    assert_eq!(result["state"], "authorized", "{result}");
    assert_eq!(result["scope"]["purpose"], "editor_edit");
    assert_eq!(result["scope"]["config_revision"], 3);
    assert_eq!(result["scope"]["policy_revision"], 7);
    assert_eq!(result["revision"], 1);
    assert_eq!(result["applied"], false);
    assert!(
        authorize(&mut peer, &scope, SOURCE, &prep, "missing")?
            .get("error")
            .is_some()
    );
    let reply = call(
        &mut peer,
        &scope,
        "edit/read",
        json!({"origin_id":SOURCE,"preparation_id":prep,"part":"proposed","offset":0}),
    )?;
    assert_eq!(reply["result"]["text"], "new\n");
    assert!(
        call(
            &mut peer,
            &scope,
            "edit/begin",
            begin(root.path(), FOREIGN, "auto")
        )?["result"]["preparation_id"]
            .is_string()
    );
    assert_eq!(
        call(
            &mut peer,
            &scope,
            "edit/begin",
            begin(root.path(), FOREIGN, "auto")
        )?["error"]["data"]["status"],
        "resource_limit"
    );
    call(&mut peer, &scope, "edit/abort", ticket(SOURCE, &prep))?;
    released(&mut peer, &scope, &prep)?;
    assert!(
        call(
            &mut peer,
            &scope,
            "edit/begin",
            begin(root.path(), SOURCE, "auto")
        )?["result"]["preparation_id"]
            .is_string()
    );
    assert_eq!(
        std::fs::read_to_string(root.path().join("file.txt"))?,
        "old\n"
    );
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}
#[test]
fn foreign_source_session_stale_revision_and_replay_cannot_steal_a_review() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let foreign = peer.scope()?;
    let prep = prepared(&mut peer, &scope, root.path(), SOURCE, "async")?;
    assert!(
        authorize(&mut peer, &scope, FOREIGN, &prep, "available")?
            .get("error")
            .is_some()
    );
    let review = authorize(&mut peer, &scope, SOURCE, &prep, "available")?["result"].clone();
    assert_eq!(review["state"], "review", "{review}");
    let edit = &review["edit_id"];
    for (owner, source, revision) in [
        (&scope, FOREIGN, 1),
        (&foreign, SOURCE, 1),
        (&scope, SOURCE, 2),
    ] {
        assert_eq!(
            decide(&mut peer, owner, source, edit, revision, "accept")?["error"]["data"]["status"],
            "stale_owner"
        );
    }
    let grant = decide(&mut peer, &scope, SOURCE, edit, 1, "accept")?;
    assert_eq!(grant["result"]["state"], "authorized", "{grant}");
    assert!(
        decide(&mut peer, &scope, SOURCE, edit, 1, "accept")?
            .get("error")
            .is_some()
    );
    call(&mut peer, &scope, "edit/close", json!({"origin_id":SOURCE}))?;
    released(&mut peer, &scope, &prep)?;
    assert!(!root.path().join("file.txt").exists());
    Ok(())
}
#[test]
fn missing_presenter_and_refusal_release_claim_without_applying_or_replaying() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    for review in ["async", "blocking"] {
        let prep = prepared(&mut peer, &scope, root.path(), SOURCE, review)?;
        assert_eq!(
            authorize(&mut peer, &scope, SOURCE, &prep, "missing")?["error"]["data"]["status"],
            "unavailable"
        );
        released(&mut peer, &scope, &prep)?;
        for decision in ["reject", "interrupt"] {
            let prep = prepared(&mut peer, &scope, root.path(), SOURCE, review)?;
            let edit =
                authorize(&mut peer, &scope, SOURCE, &prep, "available")?["result"]["edit_id"]
                    .clone();
            let reply = decide(&mut peer, &scope, SOURCE, &edit, 1, decision)?;
            assert_eq!(
                reply["error"]["data"]["status"],
                if decision == "reject" {
                    "rejected"
                } else {
                    "cancelled"
                },
                "{reply}"
            );
            released(&mut peer, &scope, &prep)?;
        }
    }
    assert!(!root.path().join("file.txt").exists());
    Ok(())
}
#[test]
fn pending_editor_review_coexists_with_foreground_shared_gate_command() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let prep = prepared(&mut peer, &scope, root.path(), SOURCE, "async")?;
    let edit =
        authorize(&mut peer, &scope, SOURCE, &prep, "available")?["result"]["edit_id"].clone();
    let shell = std::env::var_os("PATH")
        .into_iter()
        .flat_map(|p| std::env::split_paths(&p).collect::<Vec<_>>())
        .map(|p| p.join("sh"))
        .find(|p| p.is_file())
        .ok_or("sh unavailable")?;
    peer.send(json!({"jsonrpc":"2.0","id":"command","method":"tool/execute","params":{"scope":scope,"arguments":{"root":root.path(),"mode":"agent","program":shell,"arguments":["-c","exit 0"],"cwd":null,"timeout_ms":1000,"environment":{},"config_revision":3,"policy_revision":7}}}))?;
    let approval = peer.read()?;
    assert_eq!(approval["method"], "editor/request_approval", "{approval}");
    let reply = decide(&mut peer, &scope, SOURCE, &edit, 1, "reject")?;
    assert_eq!(reply["error"]["data"]["status"], "rejected");
    peer.send(json!({"jsonrpc":"2.0","id":approval["id"],"result":{"approved":false}}))?;
    let command = peer.read()?;
    assert_eq!(command["id"], "command");
    assert_eq!(command["error"]["data"]["status"], "rejected");
    assert!(!root.path().join("file.txt").exists());
    Ok(())
}
#[test]
fn source_disk_changes_and_close_during_claim_fail_closed_and_drain_on_eof() -> TestResult {
    for review in ["auto", "blocking"] {
        let root = tempfile::tempdir()?;
        let path = root.path().join("file.txt");
        std::fs::write(&path, "old\n")?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let prep = prepared(&mut peer, &scope, root.path(), SOURCE, review)?;
        std::fs::write(&path, "foreign\n")?;
        assert!(
            authorize(&mut peer, &scope, SOURCE, &prep, "available")?
                .get("error")
                .is_some()
        );
        released(&mut peer, &scope, &prep)?;
        let prep = prepared(&mut peer, &scope, root.path(), SOURCE, review)?;
        peer.send(json!({"jsonrpc":"2.0","id":"claim","method":"edit/authorize","params":{"scope":scope,"arguments":{"origin_id":SOURCE,"preparation_id":prep,"presenter":"available"}}}))?;
        peer.input.take();
        assert!(peer.wait()?);
        assert_eq!(std::fs::read_to_string(&path)?, "foreign\n");
    }
    Ok(())
}

#[test]
fn live_review_and_auto_grant_are_revoked_by_session_application_shutdown_and_eof() -> TestResult {
    for mode in ["auto", "async"] {
        for teardown in ["session/close", "application/close", "shutdown", "eof"] {
            let root = tempfile::tempdir()?;
            let mut peer = Peer::start()?;
            peer.initialize()?;
            let scope = peer.scope()?;
            let prep = prepared(&mut peer, &scope, root.path(), SOURCE, mode)?;
            let admission = authorize(&mut peer, &scope, SOURCE, &prep, "available")?;
            assert!(admission["result"]["edit_id"].is_string(), "{admission}");
            if teardown != "eof" {
                let params = match teardown {
                    "session/close" => scope.clone(),
                    "application/close" => json!({"application_id":scope["application_id"]}),
                    _ => json!({}),
                };
                peer.send(json!({"jsonrpc":"2.0","id":"close","method":teardown,"params":params}))?;
                let reply = peer.read()?;
                assert_eq!(reply["id"], "close", "{reply}");
                assert!(reply.get("result").is_some(), "{reply}");
            }
            peer.input.take();
            assert!(peer.wait()?);
            assert!(!root.path().join("file.txt").exists());
        }
    }
    Ok(())
}
#[test]
fn minimum_frame_can_authorize_and_decide_without_embedding_all_source_metadata() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.send(json!({"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocol_major":1,"protocol_minor":0,"client_version":"tiny-editor-frame","capabilities":[],"limits":{"max_frame_bytes":1024}}}))?;
    let init = peer.read()?;
    peer.epoch = init["result"]["connection_epoch"]
        .as_str()
        .ok_or("epoch")?
        .to_owned();
    peer.send(json!({"jsonrpc":"2.0","method":"initialized"}))?;
    let scope = peer.scope()?;
    let prep = prepared(&mut peer, &scope, root.path(), SOURCE, "blocking")?;
    let review = authorize(&mut peer, &scope, SOURCE, &prep, "available")?;
    assert!(review.to_string().len() < 1024);
    assert_eq!(review["result"]["state"], "review", "{review}");
    let reply = decide(
        &mut peer,
        &scope,
        SOURCE,
        &review["result"]["edit_id"],
        1,
        "accept",
    )?;
    assert_eq!(reply["result"]["state"], "authorized", "{reply}");
    assert!(reply.to_string().len() < 1024);
    Ok(())
}
