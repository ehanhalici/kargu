//! Real stdio live witnesses and a complete native all-file preflight barrier.
mod support;
use kargu_core::edit::types::EditText;
use serde_json::{Value, json};
use std::{os::unix::fs::MetadataExt, path::Path};
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;
const SOURCE: &str = "editor_source_12345678-1234-4234-8234-123456789abc";
fn call(
    peer: &mut Peer,
    scope: &Value,
    method: &str,
    args: Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    peer.send(json!({"jsonrpc":"2.0","id":"preflight","method":method,"params":{"scope":scope,"arguments":args}}))?;
    let reply = peer.read()?;
    assert_eq!(reply["id"], "preflight", "{reply}");
    Ok(reply)
}
fn ticket(id: &Value) -> Value {
    json!({"origin_id":SOURCE,"preparation_id":id})
}
fn disk(path: &Path) -> Result<Value, Box<dyn std::error::Error>> {
    let m = path.metadata()?;
    Ok(
        json!({"kind":"file","version":{"device":m.dev(),"inode":m.ino(),"bytes":m.len(),"mtime_ns":(i128::from(m.mtime())*1_000_000_000+i128::from(m.mtime_nsec())).to_string(),"ctime_ns":(i128::from(m.ctime())*1_000_000_000+i128::from(m.ctime_nsec())).to_string()}}),
    )
}
fn witness(index: usize, descriptor: &Value, document_id: &str, tick: u64) -> Value {
    json!({"file":index,"base_hash":descriptor["base_hash"],"document":{"id":document_id,"tick":tick,"bytes":descriptor["base_bytes"],"coding":"utf-8-unix","dirty":false,"read_only":false,"disk":descriptor["disk"]}})
}
fn prepare_write(
    peer: &mut Peer,
    scope: &Value,
    root: &Path,
    live: Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    let id=call(peer,scope,"edit/begin",json!({"origin_id":SOURCE,"root":root,"mode":"agent","intent":{"kind":"write","path":"file.txt","new_bytes":4},"live":live,"config_revision":3,"policy_revision":7,"review_mode":"auto","save_policy":"save"}))?["result"]["preparation_id"].clone();
    assert!(id.is_string());
    call(
        peer,
        scope,
        "edit/append",
        json!({"origin_id":SOURCE,"preparation_id":id,"part":"new","offset":0,"text":"new\n"}),
    )?;
    if !live.is_null() {
        call(
            peer,
            scope,
            "edit/append",
            json!({"origin_id":SOURCE,"preparation_id":id,"part":"document","offset":0,"text":"old\n"}),
        )?;
    }
    let reply = call(peer, scope, "edit/prepare", ticket(&id))?;
    assert_eq!(reply["result"]["preparation_id"], id, "{reply}");
    Ok(reply["result"].clone())
}
fn authorize(
    peer: &mut Peer,
    scope: &Value,
    preparation: &Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    let reply = call(
        peer,
        scope,
        "edit/authorize",
        json!({"origin_id":SOURCE,"preparation_id":preparation,"presenter":"missing"}),
    )?;
    assert_eq!(reply["result"]["state"], "authorized", "{reply}");
    Ok(reply["result"]["edit_id"].clone())
}
fn preflight(
    peer: &mut Peer,
    scope: &Value,
    edit: &Value,
    witness: Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    call(
        peer,
        scope,
        "edit/preflight",
        json!({"origin_id":SOURCE,"edit_id":edit,"revision":1,"witness":witness}),
    )
}
fn prepare_batch(
    peer: &mut Peer,
    scope: &Value,
    root: &Path,
) -> Result<(Value, Vec<Value>), Box<dyn std::error::Error>> {
    let patch = "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-old\n+new\n";
    let id=call(peer,scope,"edit/begin",json!({"origin_id":SOURCE,"root":root,"mode":"agent","intent":{"kind":"patch","patch_bytes":patch.len()},"live":null,"config_revision":3,"policy_revision":7,"review_mode":"auto","save_policy":"save"}))?["result"]["preparation_id"].clone();
    assert!(id.is_string());
    call(
        peer,
        scope,
        "edit/append",
        json!({"origin_id":SOURCE,"preparation_id":id,"part":"patch","offset":0,"text":patch}),
    )?;
    let inspected = call(peer, scope, "edit/inspect", ticket(&id))?;
    assert_eq!(inspected["result"]["inspected"], true, "{inspected}");
    let prepared = call(peer, scope, "edit/prepare", ticket(&id))?;
    assert_eq!(prepared["result"]["file_count"], 2, "{prepared}");
    let page = call(
        peer,
        scope,
        "edit/files",
        json!({"origin_id":SOURCE,"preparation_id":id,"offset":0}),
    )?;
    let files = page["result"]["files"].as_array().ok_or("files")?.clone();
    assert_eq!(files.len(), 2);
    Ok((id, files))
}
#[test]
fn native_single_file_preflight_keeps_original_and_rejects_foreign_stale_and_duplicate_input()
-> TestResult {
    let root = tempfile::tempdir()?;
    let path = root.path().join("file.txt");
    std::fs::write(&path, "old\n")?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let foreign = peer.scope()?;
    let prepared = prepare_write(&mut peer, &scope, root.path(), Value::Null)?;
    let edit = authorize(&mut peer, &scope, &prepared["preparation_id"])?;
    let fact = witness(
        0,
        &prepared,
        "editor_document_12345678-1234-4234-8234-123456789abc",
        1,
    );
    assert_eq!(
        preflight(&mut peer, &foreign, &edit, fact.clone())?["error"]["data"]["status"],
        "stale_owner"
    );
    let bad = call(
        &mut peer,
        &scope,
        "edit/preflight",
        json!({"origin_id":SOURCE,"edit_id":edit,"revision":2,"witness":fact}),
    )?;
    assert_eq!(bad["error"]["data"]["status"], "stale_owner");
    let reply = preflight(&mut peer, &scope, &edit, fact.clone())?;
    assert_eq!(reply["result"]["state"], "preflighted", "{reply}");
    assert_eq!(reply["result"]["applied"], false);
    assert_eq!(reply["result"]["preflight"]["files_total"], 1);
    assert_eq!(reply["result"]["preflight"]["files_checked"], 1);
    assert_eq!(
        reply["result"]["preflight"]["preflight_digest"]
            .as_str()
            .map(str::len),
        Some(64)
    );
    assert!(
        preflight(&mut peer, &scope, &edit, fact)?
            .get("error")
            .is_some()
    );
    assert_eq!(std::fs::read_to_string(path)?, "old\n");
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}
#[test]
fn live_identity_tick_coding_dirty_read_only_hash_and_disk_must_match_before_progress() -> TestResult
{
    let root = tempfile::tempdir()?;
    let path = root.path().join("file.txt");
    std::fs::write(&path, "old\n")?;
    let document = json!({"id":"editor_document_12345678-1234-4234-8234-123456789abc","tick":9,"bytes":4,"coding":"utf-8-unix","dirty":false,"read_only":false,"disk":disk(&path)?});
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let prepared = prepare_write(&mut peer, &scope, root.path(), document.clone())?;
    let edit = authorize(&mut peer, &scope, &prepared["preparation_id"])?;
    let valid = json!({"file":0,"base_hash":serde_json::to_value(EditText::try_from("old\n".to_owned())?.hash())?,"document":document});
    for field in [
        "id",
        "tick",
        "bytes",
        "coding",
        "dirty",
        "read_only",
        "disk",
        "hash",
    ] {
        let mut changed = valid.clone();
        match field {
            "id" => {
                changed["document"][field] =
                    json!("editor_document_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
            }
            "tick" => changed["document"][field] = json!(10),
            "bytes" => changed["document"][field] = json!(5),
            "coding" => changed["document"][field] = json!("utf-8-dos"),
            "dirty" | "read_only" => changed["document"][field] = json!(true),
            "disk" => changed["document"][field] = json!({"kind":"absent"}),
            _ => changed["base_hash"] = json!("a".repeat(64)),
        }
        let reply = preflight(&mut peer, &scope, &edit, changed)?;
        assert_eq!(
            reply["error"]["data"]["status"], "conflict",
            "{field}: {reply}"
        );
    }
    assert_eq!(
        preflight(&mut peer, &scope, &edit, valid)?["result"]["state"],
        "preflighted"
    );
    assert_eq!(std::fs::read_to_string(path)?, "old\n");
    Ok(())
}
#[test]
fn complete_multifile_set_is_required_and_out_of_order_witnesses_cannot_count_twice() -> TestResult
{
    let root = tempfile::tempdir()?;
    for name in ["a.txt", "b.txt"] {
        std::fs::write(root.path().join(name), "old\n")?;
    }
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let (prep, files) = prepare_batch(&mut peer, &scope, root.path())?;
    let edit = authorize(&mut peer, &scope, &prep)?;
    let second = witness(
        1,
        files.get(1).ok_or("second")?,
        "editor_document_bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        7,
    );
    let first = witness(
        0,
        files.first().ok_or("first")?,
        "editor_document_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        5,
    );
    let reply = preflight(&mut peer, &scope, &edit, second.clone())?;
    assert_eq!(reply["result"]["files_checked"], 1);
    assert_eq!(reply["result"]["files_total"], 2);
    assert_eq!(reply["result"]["ready"], false);
    assert!(
        preflight(&mut peer, &scope, &edit, second)?
            .get("error")
            .is_some()
    );
    let mut invalid = first.clone();
    invalid["file"] = json!(2);
    assert!(
        preflight(&mut peer, &scope, &edit, invalid)?
            .get("error")
            .is_some()
    );
    let mut same_document = first.clone();
    same_document["document"]["id"] = json!("editor_document_bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    assert_eq!(
        preflight(&mut peer, &scope, &edit, same_document)?["error"]["data"]["status"],
        "conflict"
    );
    let reply = preflight(&mut peer, &scope, &edit, first)?;
    assert_eq!(reply["result"]["state"], "preflighted", "{reply}");
    assert_eq!(reply["result"]["preflight"]["files_checked"], 2);
    for name in ["a.txt", "b.txt"] {
        assert_eq!(std::fs::read_to_string(root.path().join(name))?, "old\n");
    }
    Ok(())
}
#[test]
fn native_worker_rechecks_all_disk_pins_and_cannot_publish_a_preflighted_prefix() -> TestResult {
    let root = tempfile::tempdir()?;
    for name in ["a.txt", "b.txt"] {
        std::fs::write(root.path().join(name), "old\n")?;
    }
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let (prep, files) = prepare_batch(&mut peer, &scope, root.path())?;
    let edit = authorize(&mut peer, &scope, &prep)?;
    let first = witness(
        0,
        files.first().ok_or("first")?,
        "editor_document_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        5,
    );
    let second = witness(
        1,
        files.get(1).ok_or("second")?,
        "editor_document_bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        7,
    );
    assert_eq!(
        preflight(&mut peer, &scope, &edit, first)?["result"]["ready"],
        false
    );
    std::fs::write(root.path().join("a.txt"), "foreign\n")?;
    let reply = preflight(&mut peer, &scope, &edit, second)?;
    assert_eq!(reply["error"]["data"]["status"], "conflict", "{reply}");
    assert_eq!(
        std::fs::read_to_string(root.path().join("a.txt"))?,
        "foreign\n"
    );
    assert_eq!(std::fs::read_to_string(root.path().join("b.txt"))?, "old\n");
    peer.send(json!({"jsonrpc":"2.0","id":"ping","method":"ping"}))?;
    assert_eq!(peer.read()?["id"], "ping");
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}
#[test]
fn minimum_frame_and_source_close_after_native_preflight_do_not_issue_editor_writes() -> TestResult
{
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.send(json!({"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocol_major":1,"protocol_minor":0,"client_version":"tiny-preflight","capabilities":[],"limits":{"max_frame_bytes":1024}}}))?;
    peer.epoch = peer.read()?["result"]["connection_epoch"]
        .as_str()
        .ok_or("epoch")?
        .to_owned();
    peer.send(json!({"jsonrpc":"2.0","method":"initialized"}))?;
    let scope = peer.scope()?;
    let prepared = prepare_write(&mut peer, &scope, root.path(), Value::Null)?;
    let edit = authorize(&mut peer, &scope, &prepared["preparation_id"])?;
    let fact = witness(
        0,
        &prepared,
        "editor_document_12345678-1234-4234-8234-123456789abc",
        1,
    );
    let reply = preflight(&mut peer, &scope, &edit, fact.clone())?;
    assert_eq!(reply["result"]["state"], "preflighted", "{reply}");
    assert!(reply.to_string().len() < 1024);
    call(&mut peer, &scope, "edit/close", json!({"origin_id":SOURCE}))?;
    assert!(
        preflight(&mut peer, &scope, &edit, fact)?
            .get("error")
            .is_some()
    );
    peer.input.take();
    assert!(peer.wait()?);
    assert!(!root.path().join("file.txt").exists());
    Ok(())
}
