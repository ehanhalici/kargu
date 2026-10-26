//! Real owned file excerpts, encoding, scope and special-file denial.

mod support;
use serde_json::{Value, json};
use std::{fs, path::Path};
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn arguments(root: &Path, path: &str, from: u64, to: Option<u64>) -> Value {
    json!({"display_path":path,"window":{"from":from,"to":to},"max_bytes":16777216,
        "scan_chars":16777216,"output_chars":15000,"source":{"kind":"disk","root":root,"path":path}})
}
fn call(
    peer: &mut Peer,
    scope: &Value,
    arguments: Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    peer.send(json!({"jsonrpc":"2.0","id":3,"method":"workspace/readFile","params":{"scope":scope,"arguments":arguments}}))?;
    peer.read()
}
fn finish(peer: &mut Peer) -> TestResult {
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn unicode_crlf_bom_utf16_empty_and_final_newline_share_exact_numbering() -> TestResult {
    let root = tempfile::tempdir()?;
    fs::write(
        root.path().join("unicode ' 😀"),
        "α😀\r\nsecond\r\nthird\r\n",
    )?;
    fs::write(root.path().join("empty"), "")?;
    fs::write(root.path().join("two"), "one\n\n")?;
    for (name, little) in [("le", true), ("be", false)] {
        let mut bytes = if little {
            vec![0xff, 0xfe]
        } else {
            vec![0xfe, 0xff]
        };
        for unit in "α😀\r\nsecond\n".encode_utf16() {
            bytes.extend(if little {
                unit.to_le_bytes()
            } else {
                unit.to_be_bytes()
            });
        }
        fs::write(root.path().join(name), bytes)?;
    }
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let excerpt = call(
        &mut peer,
        &scope,
        arguments(root.path(), "unicode ' 😀", 1, Some(2)),
    )?;
    assert_eq!(
        excerpt["result"]["text"],
        "(file unicode ' 😀, lines 1-2 of unknown)\n1 | α😀\n2 | second"
    );
    for name in ["le", "be"] {
        let reply = call(&mut peer, &scope, arguments(root.path(), name, 1, None))?;
        assert_eq!(
            reply["result"]["text"],
            format!("(file {name}, lines 1-2 of 2)\n1 | α😀\n2 | second")
        );
    }
    assert_eq!(
        call(&mut peer, &scope, arguments(root.path(), "empty", 1, None))?["result"]["text"],
        "(file empty, lines 1-1 of 1)\n1 | "
    );
    assert_eq!(
        call(&mut peer, &scope, arguments(root.path(), "two", 1, None))?["result"]["text"],
        "(file two, lines 1-2 of 2)\n1 | one\n2 | "
    );
    assert!(
        call(&mut peer, &scope, arguments(root.path(), "two", 3, None))?
            .get("error")
            .is_some()
    );
    finish(&mut peer)
}

#[test]
fn byte_scan_and_character_limits_bound_actual_disk_work_without_fabricating_eof() -> TestResult {
    let root = tempfile::tempdir()?;
    fs::write(
        root.path().join("large"),
        "longer source line\n".repeat(100000),
    )?;
    fs::write(
        root.path().join("long"),
        format!("{}\nnext", "x".repeat(100000)),
    )?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let small = call(
        &mut peer,
        &scope,
        arguments(root.path(), "large", 1, Some(3)),
    )?;
    assert!(small["result"]["bytes_read"].as_u64().ok_or("bytes")? <= 4096);
    assert!(
        small["result"]["text"]
            .as_str()
            .ok_or("text")?
            .contains("lines 1-3 of unknown")
    );
    let mut large = arguments(root.path(), "large", 6000, Some(6001));
    large["max_bytes"] = json!(200000);
    let large = call(&mut peer, &scope, large)?;
    assert!(
        large["result"]["text"]
            .as_str()
            .ok_or("text")?
            .contains("6001 | longer source line")
    );
    assert!(large["result"]["bytes_read"].as_u64().ok_or("bytes")? <= 200000);
    let mut long = arguments(root.path(), "long", 1, Some(1));
    long["output_chars"] = json!(32);
    long["max_bytes"] = json!(1024);
    let long = call(&mut peer, &scope, long)?;
    assert_eq!(long["result"]["truncated"], true);
    assert!(long["result"]["text"].as_str().ok_or("text")?.len() < 250);
    let mut missing = arguments(root.path(), "long", 2, None);
    missing["max_bytes"] = json!(1024);
    assert!(call(&mut peer, &scope, missing)?.get("error").is_some());
    let mut scan = arguments(root.path(), "large", 1, None);
    scan["scan_chars"] = json!(12);
    let scan = call(&mut peer, &scope, scan)?;
    assert!(
        scan["result"]["text"]
            .as_str()
            .ok_or("text")?
            .contains("of unknown, truncated")
    );
    finish(&mut peer)
}

#[test]
fn untrusted_paths_fifos_devices_binary_and_invalid_encoding_never_become_text() -> TestResult {
    let root = tempfile::tempdir()?;
    let outside = tempfile::tempdir()?;
    fs::write(outside.path().join("private"), "private")?;
    std::os::unix::fs::symlink(outside.path(), root.path().join("escape"))?;
    nix::unistd::mkfifo(&root.path().join("fifo"), nix::sys::stat::Mode::S_IRUSR)?;
    std::os::unix::fs::symlink("/dev/null", root.path().join("device"))?;
    fs::write(root.path().join("binary"), [b'a', 0, b'b'])?;
    fs::write(
        root.path().join("later-binary"),
        format!("visible\n{}\0tail", "x".repeat(500)),
    )?;
    fs::write(root.path().join("invalid"), [0xff, 0x20])?;
    fs::write(root.path().join("surrogate"), [0xff, 0xfe, 0x00, 0xd8])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    for path in [
        "../private",
        "escape/private",
        "fifo",
        "device",
        "binary",
        "invalid",
        "surrogate",
        "absent",
    ] {
        assert!(
            call(&mut peer, &scope, arguments(root.path(), path, 1, None))?
                .get("error")
                .is_some(),
            "{path}"
        );
    }
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"ping","params":{}}))?;
    assert_eq!(peer.read()?["id"], 4);
    assert!(
        call(
            &mut peer,
            &scope,
            arguments(root.path(), "later-binary", 1, Some(1))
        )?
        .get("error")
        .is_some()
    );
    finish(&mut peer)
}

#[test]
fn closed_editor_snapshots_share_renderer_and_reject_foreign_owners_and_oversized_frames()
-> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut input = arguments(root.path(), "unsaved", 7, Some(8));
    input["source"] = json!({"kind":"editor","text":"α😀\nsecond\nthird\n","probe":"α😀","from_available":true,"complete":true});
    let reply = call(&mut peer, &scope, input.clone())?;
    assert_eq!(
        reply["result"]["text"],
        "(file unsaved, lines 7-8 of unknown)\n7 | α😀\n8 | second"
    );
    assert_eq!(reply["result"]["bytes_read"], 0);
    let mut foreign = scope.clone();
    foreign["session_id"] = json!("foreign");
    assert!(
        call(&mut peer, &foreign, input.clone())?
            .get("error")
            .is_some()
    );
    for change in ["range", "unknown", "output", "source", "probe"] {
        let mut malformed = input.clone();
        match change {
            "range" => malformed["window"]["from"] = json!(0),
            "unknown" => malformed["arguments"] = json!(["--execute"]),
            "output" => malformed["output_chars"] = json!(131073),
            "source" => malformed["source"]["text"] = json!("x".repeat(15002)),
            _ => malformed["source"]["probe"] = json!("a\u{0}b"),
        }
        assert!(call(&mut peer, &scope, malformed)?.get("error").is_some());
    }
    finish(&mut peer)
}
