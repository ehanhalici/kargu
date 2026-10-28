//! Real stdio proposal preparation: immutable text is data, never a write grant.
mod support;
use serde_json::{Value, json};
use std::{os::unix::fs::MetadataExt, path::Path};
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;
const ORIGIN: &str = "editor_source_12345678-1234-4234-8234-123456789abc";
const OTHER: &str = "editor_source_22345678-1234-4234-8234-123456789abc";

fn call(
    peer: &mut Peer,
    scope: &Value,
    method: &str,
    args: Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    peer.send(json!({"jsonrpc":"2.0","id":"edit","method":method,"params":{"scope":scope,"arguments":args}}))?;
    let reply = peer.read()?;
    assert_eq!(reply["id"], "edit");
    Ok(reply)
}
fn begin(root: &Path, intent: Value) -> Value {
    json!({"origin_id":ORIGIN,"root":root,"mode":"agent","intent":intent,"live":null,
        "config_revision":0,"policy_revision":0,"review_mode":"auto","save_policy":"save"})
}
fn ticket(id: &Value) -> Value {
    json!({"origin_id":ORIGIN,"preparation_id":id})
}
fn upload(peer: &mut Peer, scope: &Value, id: &Value, part: &str, text: &str) -> TestResult {
    let mut offset = 0;
    while offset < text.len() {
        let mut end = offset.saturating_add(32768).min(text.len());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        let reply = call(
            peer,
            scope,
            "edit/append",
            json!({"origin_id":ORIGIN,"preparation_id":id,
            "part":part,"offset":offset,"text":&text[offset..end]}),
        )?;
        assert_eq!(reply["result"]["offset"], end, "{reply}");
        offset = end;
    }
    Ok(())
}
fn download(
    peer: &mut Peer,
    scope: &Value,
    id: &Value,
    part: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    let mut result = String::new();
    loop {
        let reply = call(
            peer,
            scope,
            "edit/read",
            json!({"origin_id":ORIGIN,"preparation_id":id,"part":part,"offset":result.len()}),
        )?;
        let value = &reply["result"];
        assert_eq!(value["offset"], result.len(), "{reply}");
        result.push_str(value["text"].as_str().ok_or("page text")?);
        assert_eq!(value["next_offset"], result.len());
        if value["complete"] == true {
            return Ok(result);
        }
    }
}
fn disk(path: &Path) -> Result<Value, Box<dyn std::error::Error>> {
    let m = path.metadata()?;
    Ok(
        json!({"kind":"file","version":{"device":m.dev(),"inode":m.ino(),"bytes":m.len(),
        "mtime_ns":(i128::from(m.mtime())*1_000_000_000+i128::from(m.mtime_nsec())).to_string(),
        "ctime_ns":(i128::from(m.ctime())*1_000_000_000+i128::from(m.ctime_nsec())).to_string()}}),
    )
}

#[test]
fn literal_replace_captures_full_decoded_source_and_never_writes_original() -> TestResult {
    let root = tempfile::tempdir()?;
    let path = root.path().join("source");
    std::fs::write(&path, "baş\r\nold.*\r\nson\r\n")?;
    let before = disk(&path)?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let id = call(
        &mut peer,
        &scope,
        "edit/begin",
        begin(
            root.path(),
            json!({"kind":"replace","path":"source","old_bytes":5,"new_bytes":4}),
        ),
    )?["result"]["preparation_id"]
        .clone();
    assert!(id.is_string());
    upload(&mut peer, &scope, &id, "old", "old.*")?;
    upload(&mut peer, &scope, &id, "new", "yeni")?;
    let reply = call(&mut peer, &scope, "edit/prepare", ticket(&id))?;
    assert_eq!(reply["result"]["applied"], false, "{reply}");
    assert_eq!(reply["result"]["disk"], before);
    assert_eq!(
        reply["result"]["base_hash"].as_str().map(str::len),
        Some(64)
    );
    assert_ne!(
        reply["result"]["base_hash"],
        reply["result"]["proposed_hash"]
    );
    assert_eq!(
        download(&mut peer, &scope, &id, "base")?,
        "baş\nold.*\nson\n"
    );
    assert_eq!(
        download(&mut peer, &scope, &id, "proposed")?,
        "baş\nyeni\nson\n"
    );
    assert_eq!(std::fs::read_to_string(&path)?, "baş\r\nold.*\r\nson\r\n");
    assert_eq!(disk(&path)?, before);
    assert_eq!(
        call(&mut peer, &scope, "edit/prepare", ticket(&id))?["error"]["data"]["status"],
        "invalid_params"
    );
    call(&mut peer, &scope, "edit/abort", ticket(&id))?;
    assert!(
        call(
            &mut peer,
            &scope,
            "edit/read",
            json!({"origin_id":ORIGIN,"preparation_id":id,"part":"base","offset":0})
        )?
        .get("error")
        .is_some()
    );
    peer.send(json!({"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}))?;
    assert_eq!(peer.read()?["id"], "shutdown");
    peer.send(json!({"jsonrpc":"2.0","method":"exit"}))?;
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn paged_unicode_upload_is_immutable_and_isolated_by_source_and_session() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let text = "\0\"\\é🦀\n".repeat(10000);
    let id = call(
        &mut peer,
        &scope,
        "edit/begin",
        begin(
            root.path(),
            json!({"kind":"write","path":"new/nested","new_bytes":text.len()}),
        ),
    )?["result"]["preparation_id"]
        .clone();
    assert!(
        call(&mut peer, &scope, "edit/prepare", ticket(&id))?
            .get("error")
            .is_some()
    );
    let mut foreign = ticket(&id);
    foreign["origin_id"] = json!(OTHER);
    assert_eq!(
        call(&mut peer, &scope, "edit/abort", foreign)?["error"]["data"]["status"],
        "stale_owner"
    );
    let foreign_scope = peer.scope()?;
    assert_eq!(
        call(&mut peer, &foreign_scope, "edit/abort", ticket(&id))?["error"]["data"]["status"],
        "stale_owner"
    );
    assert!(
        call(
            &mut peer,
            &scope,
            "edit/append",
            json!({"origin_id":ORIGIN,"preparation_id":id,"part":"new","offset":1,"text":"x"})
        )?
        .get("error")
        .is_some()
    );
    upload(&mut peer, &scope, &id, "new", &text)?;
    let prepared = call(&mut peer, &scope, "edit/prepare", ticket(&id))?;
    assert_eq!(prepared["result"]["existed"], false, "{prepared}");
    assert_eq!(prepared["result"]["unchanged"], false);
    assert_eq!(download(&mut peer, &scope, &id, "proposed")?, text);
    assert!(!root.path().join("new").exists());
    call(&mut peer, &scope, "edit/close", json!({"origin_id":OTHER}))?;
    assert_eq!(download(&mut peer, &scope, &id, "proposed")?, text);
    call(&mut peer, &scope, "edit/close", json!({"origin_id":ORIGIN}))?;
    assert!(
        call(
            &mut peer,
            &scope,
            "edit/read",
            json!({"origin_id":ORIGIN,"preparation_id":id,"part":"base","offset":0})
        )?
        .get("error")
        .is_some()
    );
    Ok(())
}

#[test]
fn live_capture_checks_native_disk_revision_and_preserves_exact_editor_evidence() -> TestResult {
    let root = tempfile::tempdir()?;
    let path = root.path().join("source");
    std::fs::write(&path, [0xE7, 0x61])?; // Editor may decode a coding not supported by native UTF8 reader.
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut input = begin(
        root.path(),
        json!({"kind":"write","path":"source","new_bytes":4}),
    );
    input["live"] = json!({"id":"editor_document_12345678-1234-4234-8234-123456789abc","tick":3,"bytes":3,
        "coding":"iso-latin-1-unix","dirty":false,"read_only":false,"disk":disk(&path)?});
    for field in ["dirty", "read_only"] {
        let mut invalid = input.clone();
        invalid["live"][field] = json!(true);
        assert_eq!(
            call(&mut peer, &scope, "edit/begin", invalid)?["error"]["data"]["status"],
            "conflict"
        );
    }
    for changed in [false, true] {
        let id = call(&mut peer, &scope, "edit/begin", input.clone())?["result"]["preparation_id"]
            .clone();
        upload(&mut peer, &scope, &id, "new", "next")?;
        upload(&mut peer, &scope, &id, "document", "ça")?;
        if changed {
            std::fs::write(&path, "foreign later")?;
        }
        let reply = call(&mut peer, &scope, "edit/prepare", ticket(&id))?;
        if changed {
            assert_eq!(reply["error"]["data"]["status"], "conflict", "{reply}");
        } else {
            assert_eq!(reply["result"]["document"], input["live"], "{reply}");
            assert_eq!(download(&mut peer, &scope, &id, "base")?, "ça");
            call(&mut peer, &scope, "edit/abort", ticket(&id))?;
        }
    }
    assert_eq!(std::fs::read_to_string(&path)?, "foreign later");
    Ok(())
}

#[test]
fn unsupported_paths_modes_bounds_and_ambiguous_context_fail_closed() -> TestResult {
    let root = tempfile::tempdir()?;
    let foreign = tempfile::tempdir()?;
    std::fs::write(root.path().join("source"), "duplicate duplicate")?;
    std::fs::write(foreign.path().join("source"), "private")?;
    std::os::unix::fs::symlink(foreign.path(), root.path().join("outside"))?;
    std::os::unix::fs::symlink(root.path().join("missing"), root.path().join("broken"))?;
    nix::unistd::mkfifo(&root.path().join("fifo"), nix::sys::stat::Mode::S_IRUSR)?;
    std::fs::create_dir(root.path().join(".git"))?;
    std::fs::write(root.path().join(".git/config"), "private")?;
    std::os::unix::fs::symlink(root.path().join(".git"), root.path().join("metadata"))?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    for mode in ["ask", "plan", "debug"] {
        let mut input = begin(
            root.path(),
            json!({"kind":"write","path":"source","new_bytes":0}),
        );
        input["mode"] = json!(mode);
        assert_eq!(
            call(&mut peer, &scope, "edit/begin", input)?["error"]["data"]["status"],
            "rejected"
        );
    }
    for path in ["../escape", "/absolute", ".git/config", ".kargu.patch/x"] {
        assert!(
            call(
                &mut peer,
                &scope,
                "edit/begin",
                begin(
                    root.path(),
                    json!({"kind":"write","path":path,"new_bytes":0})
                )
            )?
            .get("error")
            .is_some()
        );
    }
    assert!(
        call(
            &mut peer,
            &scope,
            "edit/begin",
            begin(
                root.path(),
                json!({"kind":"write","path":"x","new_bytes":4194305})
            )
        )?
        .get("error")
        .is_some()
    );
    for path in [
        "outside/source",
        "outside/missing",
        "broken",
        "fifo",
        "metadata/config",
        "metadata/new",
    ] {
        let id = call(
            &mut peer,
            &scope,
            "edit/begin",
            begin(
                root.path(),
                json!({"kind":"write","path":path,"new_bytes":0}),
            ),
        )?["result"]["preparation_id"]
            .clone();
        assert!(id.is_string());
        let reply = call(&mut peer, &scope, "edit/prepare", ticket(&id))?;
        assert!(reply.get("error").is_some(), "{reply}");
        assert!(!reply.to_string().contains("private"));
    }
    let id = call(
        &mut peer,
        &scope,
        "edit/begin",
        begin(
            root.path(),
            json!({"kind":"replace","path":"source","old_bytes":9,"new_bytes":1}),
        ),
    )?["result"]["preparation_id"]
        .clone();
    upload(&mut peer, &scope, &id, "old", "duplicate")?;
    upload(&mut peer, &scope, &id, "new", "x")?;
    assert_eq!(
        call(&mut peer, &scope, "edit/prepare", ticket(&id))?["error"]["data"]["status"],
        "ambiguous_match"
    );
    assert_eq!(
        std::fs::read_to_string(root.path().join("source"))?,
        "duplicate duplicate"
    );
    Ok(())
}

#[test]
fn minimum_negotiated_frame_bounds_upload_advice_and_read_pages() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.send(
        json!({"jsonrpc":"2.0","id":"init","method":"initialize","params":{
        "protocol_major":1,"protocol_minor":0,"client_version":"test","capabilities":[],
        "limits":{"max_frame_bytes":1024}}}),
    )?;
    assert_eq!(peer.read()?["result"]["limits"]["max_frame_bytes"], 1024);
    peer.send(json!({"jsonrpc":"2.0","method":"initialized"}))?;
    let scope = peer.scope()?;
    let text = "\0é🦀".repeat(200);
    let allocated = call(
        &mut peer,
        &scope,
        "edit/begin",
        begin(
            root.path(),
            json!({"kind":"write","path":"target","new_bytes":text.len()}),
        ),
    )?;
    let id = &allocated["result"]["preparation_id"];
    let size = usize::try_from(
        allocated["result"]["page_bytes"]
            .as_u64()
            .ok_or("page size")?,
    )?;
    assert!((4..=85).contains(&size));
    let mut offset = 0usize;
    while offset < text.len() {
        let mut end = offset.saturating_add(size).min(text.len());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        assert_eq!(
            call(
                &mut peer,
                &scope,
                "edit/append",
                json!({"origin_id":ORIGIN,"preparation_id":id,"part":"new","offset":offset,"text":&text[offset..end]})
            )?["result"]["offset"],
            end
        );
        offset = end;
    }
    let prepared = call(&mut peer, &scope, "edit/prepare", ticket(id))?;
    assert_eq!(prepared["result"]["applied"], false, "{prepared}");
    assert_eq!(download(&mut peer, &scope, id, "proposed")?, text);
    Ok(())
}

#[test]
fn two_source_services_can_retain_small_replacements_without_reserving_worst_case_forever()
-> TestResult {
    let root = tempfile::tempdir()?;
    std::fs::write(root.path().join("source"), "old\n")?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut ids = Vec::new();
    for origin in [ORIGIN, OTHER] {
        let mut args = begin(
            root.path(),
            json!({"kind":"replace","path":"source","old_bytes":3,"new_bytes":3}),
        );
        args["origin_id"] = json!(origin);
        let reply = call(&mut peer, &scope, "edit/begin", args)?;
        let id = reply["result"]["preparation_id"].clone();
        assert!(id.is_string(), "{reply}");
        for (part, text) in [("old", "old"), ("new", "new")] {
            let reply = call(
                &mut peer,
                &scope,
                "edit/append",
                json!({"origin_id":origin,"preparation_id":id,"part":part,"offset":0,"text":text}),
            )?;
            assert_eq!(reply["result"]["offset"], 3, "{reply}");
        }
        let reply = call(
            &mut peer,
            &scope,
            "edit/prepare",
            json!({"origin_id":origin,"preparation_id":id}),
        )?;
        assert_eq!(reply["result"]["applied"], false, "{reply}");
        ids.push(id);
    }
    assert_eq!(
        call(
            &mut peer,
            &scope,
            "edit/abort",
            json!({"origin_id":OTHER,"preparation_id":ids[0]})
        )?["error"]["data"]["status"],
        "stale_owner"
    );
    assert_eq!(download(&mut peer, &scope, &ids[0], "proposed")?, "new\n");
    assert_eq!(
        std::fs::read_to_string(root.path().join("source"))?,
        "old\n"
    );
    Ok(())
}
