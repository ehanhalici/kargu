//! Actual pipe/config IO: exact editor paths, strict fail-closed selection, no source.
mod support;
use kargu_core::configuration::read::ReadInput;
use serde_json::{Value, json};
use std::path::Path;
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn read(peer: &mut Peer, paths: &[&Path]) -> Result<Value, Box<dyn std::error::Error>> {
    peer.send(json!({"jsonrpc":"2.0","id":"config","method":"configuration/read",
        "params":{"connection_epoch":peer.epoch,"arguments":{"paths":paths,"generation":u64::MAX,"timeout_ms":5000}}}))?;
    let reply = peer.read()?;
    assert_eq!(reply["id"], "config");
    assert!(!reply.to_string().contains("\"source\""));
    Ok(reply)
}

#[test]
fn native_selects_first_existing_parses_and_preserves_original_symlink_path() -> TestResult {
    let root = tempfile::tempdir()?;
    let missing = root.path().join("missing");
    let actual = root.path().join("actual");
    let linked = root.path().join("linked");
    std::fs::write(
        &actual,
        "provider='private'\n[provider.private]\napikey='synthetic-private-key'",
    )?;
    std::os::unix::fs::symlink(&actual, &linked)?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let reply = read(&mut peer, &[&missing, &linked])?;
    assert_eq!(reply["result"]["path"], json!(linked));
    assert_eq!(reply["result"]["status"], "ok");
    assert_eq!(reply["result"]["generation"], u64::MAX);
    assert_eq!(
        reply["result"]["config"]["providers"][0]["data"]["apikey"],
        "synthetic-private-key"
    );
    assert_eq!(reply["result"]["digest"].as_str().map(str::len), Some(64));
    let absent = read(&mut peer, &[&missing])?;
    assert_eq!(
        absent["result"],
        json!({"status":"absent","generation":u64::MAX,"path":missing})
    );
    Ok(())
}

#[test]
fn invalid_oversized_non_utf8_directory_fifo_and_device_never_fall_back() -> TestResult {
    let root = tempfile::tempdir()?;
    let bad = root.path().join("bad");
    let fallback = root.path().join("fallback");
    std::fs::write(&fallback, "provider='must-not-read'")?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    std::fs::write(&bad, "apikey='synthetic-hidden-key'\nprovider=42")?;
    let reply = read(&mut peer, &[&bad, &fallback])?;
    assert_eq!(reply["result"]["status"], "invalid");
    assert!(!reply.to_string().contains("synthetic-hidden-key"));
    for content in [vec![b' '; 65537], vec![255]] {
        std::fs::write(&bad, content)?;
        assert!(read(&mut peer, &[&bad, &fallback])?.get("error").is_some());
    }
    std::fs::remove_file(&bad)?;
    std::fs::create_dir(&bad)?;
    assert_eq!(
        read(&mut peer, &[&bad, &fallback])?["error"]["data"]["status"],
        "rejected"
    );
    let fifo = root.path().join("fifo");
    nix::unistd::mkfifo(&fifo, nix::sys::stat::Mode::S_IRUSR)?;
    for path in [&fifo, Path::new("/dev/zero")] {
        assert_eq!(
            read(&mut peer, &[path, &fallback])?["error"]["data"]["status"],
            "rejected"
        );
    }
    Ok(())
}

#[test]
fn strict_input_bounds_and_epoch_are_checked_before_io_and_notifications_do_not_read() -> TestResult
{
    let base = json!({"paths":["/synthetic/config"],"generation":0,"timeout_ms":5000});
    for (field, invalid) in [
        ("paths", json!([])),
        ("paths", json!(["relative"])),
        ("paths", json!(["/a/../b"])),
        ("paths", json!(["/a\u{0000}b"])),
        ("paths", json!(vec!["/x"; 9])),
        ("timeout_ms", json!(0)),
        ("timeout_ms", json!(5001)),
        ("timeout_ms", json!(-1)),
        ("generation", json!(-1)),
        ("extra", json!(true)),
    ] {
        let mut input = base.clone();
        input[field] = invalid;
        assert!(serde_json::from_value::<ReadInput>(input).is_err());
    }
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let _standalone_scope = peer.scope()?;
    peer.send(json!({"jsonrpc":"2.0","id":1,"method":"configuration/read","params":{"connection_epoch":"foreign","arguments":base}}))?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "stale_owner");
    peer.send(json!({"jsonrpc":"2.0","method":"configuration/read","params":{}}))?;
    peer.send(json!({"jsonrpc":"2.0","id":2,"method":"ping"}))?;
    assert_eq!(peer.read()?["id"], 2);
    peer.send(json!({"jsonrpc":"2.0","id":3,"method":"shutdown"}))?;
    assert_eq!(peer.read()?["id"], 3);
    peer.send(json!({"jsonrpc":"2.0","method":"exit"}))?;
    assert!(peer.wait()?);
    Ok(())
}
