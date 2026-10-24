//! GNU ls composition, path policy and bounded-output regression checks.

mod support;
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::{fs::symlink, net::UnixListener},
    path::Path,
};
use support::Peer;

type TestResult = Result<(), Box<dyn std::error::Error>>;

#[test]
fn missing_ls_is_unavailable_without_a_native_or_elisp_fallback() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start_with_path(Some(root.path()))?;
    peer.initialize()?;
    let scope = peer.scope()?;
    peer.send(
        json!({"jsonrpc":"2.0","id":3,"method":"workspace/listFiles","params":{
        "scope":scope,"arguments":{"root":root.path(),"path":null,"skip_directories":[]}}}),
    )?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "unavailable");
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

fn listing(
    root: &Path,
    path: Option<&str>,
    exclusions: &[&str],
) -> Result<Value, Box<dyn std::error::Error>> {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    peer.send(
        json!({"jsonrpc":"2.0","id":3,"method":"workspace/listFiles","params":{
        "scope":scope,"arguments":{"root":root,"path":path,"skip_directories":exclusions}}}),
    )?;
    let reply = peer.read()?;
    peer.input.take();
    assert!(peer.wait()?);
    Ok(reply)
}

#[test]
fn listing_returns_ls_text_with_hidden_files_links_and_literal_exclusions() -> TestResult {
    let root = tempfile::tempdir()?;
    for file in [
        "top.el",
        ".hidden",
        "compiled.elc",
        "back~",
        "a*b",
        "ab",
        "line\nbreak",
    ] {
        fs::write(root.path().join(file), "fixture")?;
    }
    fs::create_dir(root.path().join("sub"))?;
    fs::create_dir(root.path().join("node_modules"))?;
    symlink("/outside-target", root.path().join("broken"))?;
    let _socket = UnixListener::bind(root.path().join("socket"))?;
    let reply = listing(root.path(), None, &["node_modules", "a*b"])?;
    let text = reply["result"]["text"].as_str().ok_or("text missing")?;
    for expected in [
        "total ",
        "top.el",
        ".hidden",
        "compiled.elc",
        "back~",
        "broken -> /outside-target",
        "socket",
        "sub",
        " ab\n",
        "\\n",
    ] {
        assert!(text.contains(expected), "missing ls output: {expected:?}");
    }
    assert!(!text.contains("node_modules"));
    assert!(!text.contains("a*b"));
    assert!(!text.contains("[FILE]"));
    assert!(!text.contains("[DIR]"));
    assert!(reply["result"].get("entries").is_none());
    assert_eq!(reply["result"]["outcome"], "ok");
    Ok(())
}

#[test]
fn empty_and_subdirectory_outputs_remain_ls_output() -> TestResult {
    let root = tempfile::tempdir()?;
    fs::create_dir(root.path().join("empty"))?;
    assert_eq!(
        listing(root.path(), Some("empty"), &[])?["result"]["text"],
        "total 0\n"
    );
    fs::write(root.path().join("empty/child.el"), "fixture")?;
    let reply = listing(root.path(), Some("empty"), &[])?;
    let text = reply["result"]["text"].as_str().ok_or("text missing")?;
    assert!(text.contains("child.el"));
    assert!(!text.contains("empty/child.el"));
    Ok(())
}

#[test]
fn traversal_outside_symlink_and_non_directory_targets_are_rejected() -> TestResult {
    let root = tempfile::tempdir()?;
    let outside = tempfile::tempdir()?;
    symlink(outside.path(), root.path().join("escape"))?;
    fs::write(root.path().join("file"), "fixture")?;
    nix::unistd::mkfifo(&root.path().join("fifo"), nix::sys::stat::Mode::S_IRUSR)?;
    for path in ["../escape", "escape", "file", "fifo"] {
        let reply = listing(root.path(), Some(path), &[])?;
        assert!(reply.get("error").is_some(), "accepted {path}");
    }
    let reply = listing(Path::new("/nonexistent-kargu-root"), Some("../escape"), &[])?;
    assert_eq!(reply["error"]["data"]["status"], "rejected");
    Ok(())
}

#[test]
fn invalid_exclusions_cannot_inject_flags_or_shell_operations() -> TestResult {
    let root = tempfile::tempdir()?;
    for invalid in ["../escape", ".", "", "bad\0name"] {
        assert!(
            listing(root.path(), None, &[invalid])?
                .get("error")
                .is_some()
        );
    }
    let reply = listing(
        root.path(),
        None,
        &["--help", "$(touch injected)", "x;touch injected"],
    )?;
    assert_eq!(reply["result"]["outcome"], "ok");
    assert!(!root.path().join("injected").exists());
    Ok(())
}

#[test]
fn large_listing_uses_shared_process_output_bound_and_explicit_truncation() -> TestResult {
    let root = tempfile::tempdir()?;
    for n in 0..1200 {
        fs::write(
            root.path().join(format!("entry-{n:04}-{}", "x".repeat(80))),
            "fixture",
        )?;
    }
    let reply = listing(root.path(), None, &[])?;
    assert_eq!(reply["result"]["truncated"], true);
    assert_eq!(
        reply["result"]["stdout"]
            .as_str()
            .ok_or("stdout missing")?
            .len(),
        65536
    );
    assert!(
        reply["result"]["text"]
            .as_str()
            .ok_or("text missing")?
            .contains("output truncated")
    );
    assert_eq!(reply["result"]["cleanup_complete"], true);
    Ok(())
}
