//! Real rg/GNU grep composition, exact global record caps and scoped failures.

mod support;
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    path::{Path, PathBuf},
};
use support::Peer;

type TestResult = Result<(), Box<dyn std::error::Error>>;

fn executable(name: &str) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let paths = std::env::var_os("PATH").ok_or("missing test PATH")?;
    std::env::split_paths(&paths)
        .map(|dir| dir.join(name))
        .find(|path| path.is_file())
        .ok_or_else(|| format!("required test tool missing: {name}").into())
}
fn arguments(root: &Path, pattern: &str, cap: u64) -> Value {
    json!({"root":root,"path":null,"pattern":pattern,"glob":null,"max_matches":cap,"skip_directories":[".git","node_modules"]})
}
fn call(peer: &mut Peer, scope: &Value, args: Value) -> Result<Value, Box<dyn std::error::Error>> {
    peer.send(json!({"jsonrpc":"2.0","id":3,"method":"workspace/grep","params":{"scope":scope,"arguments":args}}))?;
    peer.read()
}
fn engines(test: impl Fn(&mut Peer, &Value, &Path) -> TestResult) -> TestResult {
    for engine in ["rg", "grep"] {
        let directory = tempfile::tempdir()?;
        let bin = directory.path().join("bin");
        let root = directory.path().join("workspace");
        fs::create_dir(&bin)?;
        fs::create_dir(&root)?;
        symlink(executable(engine)?, bin.join(engine))?;
        let mut peer = Peer::start_with_path(Some(&bin))?;
        peer.initialize()?;
        let scope = peer.scope()?;
        test(&mut peer, &scope, &root)?;
        peer.input.take();
        assert!(peer.wait()?);
    }
    Ok(())
}

#[test]
fn no_match_and_invalid_regex_are_distinct_and_release_the_claim() -> TestResult {
    engines(|peer, scope, root| {
        fs::write(root.join("a.txt"), "needle\n")?;
        let none = call(peer, scope, arguments(root, "absent", 3))?;
        assert_eq!(none["result"]["outcome"], "ok");
        assert_eq!(none["result"]["exit_code"], 1);
        assert_eq!(none["result"]["text"], "No matches for \"absent\"");
        let invalid = call(peer, scope, arguments(root, "[", 3))?;
        assert_eq!(invalid["result"]["outcome"], "failed");
        assert_eq!(invalid["result"]["exit_code"], 2);
        assert!(
            !invalid["result"]["stderr"]
                .as_str()
                .ok_or("missing stderr")?
                .is_empty()
        );
        assert_eq!(
            call(peer, scope, arguments(root, "needle", 3))?["result"]["outcome"],
            "ok"
        );
        Ok(())
    })
}

#[test]
fn global_cap_keeps_one_lookahead_across_files_and_exact_cap_is_not_omitted() -> TestResult {
    engines(|peer, scope, root| {
        for n in 0..20 {
            fs::write(root.join(format!("{n:02}.txt")), "needle\n")?;
        }
        let reply = call(peer, scope, arguments(root, "needle", 3))?;
        let result = &reply["result"];
        assert_eq!(result["outcome"], "ok");
        assert_eq!(result["cleanup_complete"], true);
        assert_eq!(result["capture_stop"], "records");
        let raw: Vec<_> = result["stdout"]
            .as_str()
            .ok_or("missing stdout")?
            .lines()
            .collect();
        assert_eq!(raw.len(), 4);
        let files: std::collections::HashSet<_> = raw.iter().collect();
        assert_eq!(files.len(), 4);
        let text = result["text"].as_str().ok_or("missing text")?;
        assert_eq!(text.lines().count(), 4);
        assert!(
            text.ends_with("... (additional hits omitted; raise max_matches or narrow the search)")
        );
        fs::write(root.join("exact.txt"), "needle\nneedle\nneedle\n")?;
        let mut args = arguments(root, "needle", 3);
        args["path"] = json!("exact.txt");
        let exact = call(peer, scope, args)?;
        assert_eq!(exact["result"]["outcome"], "ok");
        assert_eq!(exact["result"]["capture_stop"], Value::Null);
        let text = exact["result"]["text"].as_str().ok_or("missing text")?;
        assert_eq!(text.lines().count(), 3);
        assert!(!text.contains("omitted"));
        Ok(())
    })
}

#[test]
fn includes_literal_exclusions_and_recursive_symlinks_remain_tool_owned() -> TestResult {
    engines(|peer, scope, root| {
        for name in [
            "src/a.el",
            "src/b.txt",
            "node_modules/c.el",
            "a*b/c.el",
            "ab/visible.el",
        ] {
            let path = root.join(name);
            fs::create_dir_all(path.parent().ok_or("missing parent")?)?;
            fs::write(path, "needle\n")?;
        }
        let outside = tempfile::tempdir()?;
        fs::write(outside.path().join("secret.el"), "needle outside-secret\n")?;
        symlink(outside.path(), root.join("escape"))?;
        symlink(outside.path().join("secret.el"), root.join("file-link.el"))?;
        let mut args = arguments(root, "needle", 20);
        args["glob"] = json!("**/*.el");
        args["skip_directories"] = json!(["node_modules", "a*b"]);
        let reply = call(peer, scope, args)?;
        assert_eq!(reply["result"]["outcome"], "ok");
        let text = reply["result"]["text"].as_str().ok_or("missing text")?;
        assert!(text.contains("src/a.el:1:needle"));
        assert!(text.contains("ab/visible.el:1:needle"));
        for hidden in ["b.txt", "node_modules", "a*b", "outside-secret"] {
            assert!(!text.contains(hidden), "unexpected {hidden}");
        }
        Ok(())
    })
}

#[test]
fn byte_limit_is_a_failed_incomplete_search_not_a_hit_limit_success() -> TestResult {
    engines(|peer, scope, root| {
        fs::write(root.join("a.txt"), format!("needle{}\n", "x".repeat(4096)))?;
        let mut args = arguments(root, "needle", 3);
        args["output_bytes"] = json!(16);
        let reply = call(peer, scope, args)?;
        assert_eq!(reply["result"]["outcome"], "failed");
        assert_eq!(reply["result"]["capture_stop"], "bytes");
        assert_eq!(reply["result"]["cleanup_complete"], true);
        assert_eq!(
            reply["result"]["stdout"]
                .as_str()
                .ok_or("missing stdout")?
                .len(),
            16
        );
        Ok(())
    })
}

#[test]
fn traversal_external_target_special_file_and_invalid_dto_fail_closed() -> TestResult {
    engines(|peer, scope, root| {
        let outside = tempfile::tempdir()?;
        symlink(outside.path(), root.join("escape"))?;
        nix::unistd::mkfifo(&root.join("fifo"), nix::sys::stat::Mode::S_IRUSR)?;
        for path in ["../escape", "escape", "fifo"] {
            let mut args = arguments(root, "needle", 3);
            args["path"] = json!(path);
            assert_eq!(
                call(peer, scope, args)?["error"]["data"]["status"],
                "rejected"
            );
        }
        for (key, value) in [
            ("max_matches", json!(0)),
            ("pattern", json!("")),
            ("program", json!("sh")),
            ("timeout_ms", json!(0)),
            ("skip_directories", json!(["../escape"])),
        ] {
            let mut args = arguments(root, "needle", 3);
            args[key] = value;
            assert!(call(peer, scope, args)?.get("error").is_some());
        }
        Ok(())
    })
}

#[test]
fn missing_search_tools_is_scoped_unavailable_and_foreign_scope_is_rejected() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start_with_path(Some(root.path()))?;
    peer.initialize()?;
    let scope = peer.scope()?;
    assert_eq!(
        call(&mut peer, &scope, arguments(root.path(), "x", 3))?["error"]["data"]["status"],
        "unavailable"
    );
    let mut foreign = scope.clone();
    foreign["session_id"] = json!(kargu_core::domain::SessionId::new());
    assert_eq!(
        call(&mut peer, &foreign, arguments(root.path(), "x", 3))?["error"]["data"]["status"],
        "stale_owner"
    );
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"ping"}))?;
    assert!(peer.read()?.get("result").is_some());
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn oversized_search_reply_is_a_scoped_error_and_does_not_break_transport() -> TestResult {
    let root = tempfile::tempdir()?;
    fs::write(
        root.path().join("large.txt"),
        format!("needle{}\n", "x".repeat(600_000)),
    )?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    assert!(
        call(&mut peer, &scope, arguments(root.path(), "needle", 3))?
            .get("error")
            .is_some()
    );
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"ping"}))?;
    assert!(peer.read()?.get("result").is_some());
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn unlimited_search_keeps_mailbox_live_and_cancel_waits_for_actual_reaping() -> TestResult {
    let directory = tempfile::tempdir()?;
    let root = directory.path().join("workspace");
    let bin = directory.path().join("bin");
    fs::create_dir(&root)?;
    fs::create_dir(&bin)?;
    let tool = bin.join("rg");
    fs::write(
        &tool,
        format!(
            "#!{}\nprintf '%s' $$ > leader.pid\ntrap '' TERM\nexec '{}' 30\n",
            executable("sh")?.display(),
            executable("sleep")?.display()
        ),
    )?;
    fs::set_permissions(&tool, fs::Permissions::from_mode(0o755))?;
    let mut peer = Peer::start_with_path(Some(&bin))?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut args = arguments(&root, "needle", 3);
    args["timeout_ms"] = Value::Null;
    peer.send(json!({"jsonrpc":"2.0","id":3,"method":"workspace/grep","params":{"scope":scope,"arguments":args}}))?;
    let until = std::time::Instant::now() + std::time::Duration::from_secs(2);
    let pid = loop {
        if let Ok(text) = fs::read_to_string(root.join("leader.pid"))
            && let Ok(pid) = text.parse::<u32>()
        {
            break pid;
        }
        if std::time::Instant::now() >= until {
            return Err("fixture was not started".into());
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    };
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"ping"}))?;
    assert_eq!(peer.read()?["id"], 4);
    peer.send(
        json!({"jsonrpc":"2.0","method":"rpc/cancel","params":{"request_id":3,"scope":peer.epoch}}),
    )?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "cancelled");
    assert!(!Path::new(&format!("/proc/{pid}")).exists());
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}
