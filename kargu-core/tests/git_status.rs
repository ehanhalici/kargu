//! Read-only Git status composition, worktree scope, exact records and IO bounds.

mod support;
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    process::Command,
};
use support::Peer;

type TestResult = Result<(), Box<dyn std::error::Error>>;

fn executable(name: &str) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let paths = std::env::var_os("PATH").ok_or("missing PATH")?;
    std::env::split_paths(&paths)
        .map(|dir| dir.join(name))
        .find(|path| path.is_file())
        .ok_or_else(|| format!("missing fixture executable: {name}").into())
}
fn git(root: &Path, args: &[&str]) -> TestResult {
    let result = Command::new(executable("git")?)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").ok_or("missing PATH")?)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .current_dir(root)
        .args(["-c", "core.fsmonitor=false", "-c", "commit.gpgSign=false"])
        .args(args)
        .output()?;
    if !result.status.success() {
        return Err(format!(
            "fixture git failed: {}",
            String::from_utf8_lossy(&result.stderr)
        )
        .into());
    }
    Ok(())
}
fn repository() -> Result<tempfile::TempDir, Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    git(directory.path(), &["init", "--initial-branch=main"])?;
    git(
        directory.path(),
        &["config", "user.name", "Offline Fixture"],
    )?;
    git(
        directory.path(),
        &["config", "user.email", "fixture@example.invalid"],
    )?;
    fs::write(directory.path().join("a.txt"), "one\ntwo\n")?;
    git(directory.path(), &["add", "--", "a.txt"])?;
    git(directory.path(), &["commit", "-m", "fixture"])?;
    Ok(directory)
}
fn call(peer: &mut Peer, scope: &Value, args: Value) -> Result<Value, Box<dyn std::error::Error>> {
    peer.send(json!({"jsonrpc":"2.0","id":3,"method":"git/status","params":{"scope":scope,"arguments":args}}))?;
    peer.read()
}

#[test]
fn status_preserves_unicode_newlines_and_renames_without_refreshing_the_index() -> TestResult {
    let root = repository()?;
    for name in [
        "a space.txt",
        "ünicode.txt",
        "line\nbreak.txt",
        " leading.txt ",
    ] {
        fs::write(root.path().join(name), "new")?;
    }
    git(root.path(), &["mv", "--", "a.txt", "renamed ü.txt"])?;
    // Same contents, changed stat data: ordinary status may refresh this index.
    let renamed = fs::File::open(root.path().join("renamed ü.txt"))?;
    let modified = renamed
        .metadata()?
        .modified()?
        .checked_add(std::time::Duration::from_secs(2))
        .ok_or("fixture time overflow")?;
    renamed.set_times(fs::FileTimes::new().set_modified(modified))?;
    let index = fs::read(root.path().join(".git/index"))?;
    let metadata = fs::metadata(root.path().join(".git/index"))?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let reply = call(
        &mut peer,
        &scope,
        json!({"root":root.path(),"timeout_ms":null}),
    )?;
    assert_eq!(reply["result"]["outcome"], "ok");
    assert_eq!(reply["result"]["cleanup_complete"], true);
    let text = reply["result"]["text"].as_str().ok_or("missing text")?;
    for expected in [
        "Head:     main",
        "Untracked files (4)",
        "ünicode.txt",
        "line\\nbreak.txt",
        "a.txt -> renamed ü.txt",
        " leading.txt ",
    ] {
        assert!(text.contains(expected), "missing {expected:?}: {text}");
    }
    assert_eq!(fs::read(root.path().join(".git/index"))?, index);
    let after = fs::metadata(root.path().join(".git/index"))?;
    assert_eq!(
        (metadata.ino(), metadata.mtime(), metadata.mtime_nsec()),
        (after.ino(), after.mtime(), after.mtime_nsec())
    );
    // Positive control: refresh actually changes this fixture without our policy.
    git(root.path(), &["status", "--porcelain=v1", "-b", "-z"])?;
    assert_ne!(fs::read(root.path().join(".git/index"))?, index);
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn repository_fsmonitor_is_not_executed_and_core_worktree_cannot_escape_root() -> TestResult {
    let root = repository()?;
    let outside = tempfile::tempdir()?;
    fs::write(root.path().join("inside.txt"), "fixture")?;
    fs::write(outside.path().join("outside-secret.txt"), "fixture")?;
    let hook = root.path().join("monitor");
    fs::write(
        &hook,
        format!(
            "#!{}\nprintf invoked > fsmonitor-effect\n",
            executable("sh")?.display()
        ),
    )?;
    fs::set_permissions(&hook, fs::Permissions::from_mode(0o755))?;
    git(
        root.path(),
        &[
            "config",
            "core.fsmonitor",
            hook.to_str().ok_or("path encoding")?,
        ],
    )?;
    git(
        root.path(),
        &[
            "config",
            "core.worktree",
            outside.path().to_str().ok_or("path encoding")?,
        ],
    )?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let reply = call(&mut peer, &scope, json!({"root":root.path()}))?;
    assert_eq!(reply["result"]["outcome"], "ok");
    let text = reply["result"]["text"].as_str().ok_or("missing text")?;
    assert!(text.contains("inside.txt"));
    assert!(!text.contains("outside-secret.txt"));
    assert!(!root.path().join("fsmonitor-effect").exists());
    assert!(!outside.path().join("fsmonitor-effect").exists());
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn linked_worktree_gitfile_and_detached_head_are_supported_by_git_itself() -> TestResult {
    let repository = repository()?;
    let worktrees = tempfile::tempdir()?;
    let linked = worktrees.path().join("linked");
    git(
        repository.path(),
        &[
            "worktree",
            "add",
            "--detach",
            linked.to_str().ok_or("path encoding")?,
        ],
    )?;
    assert!(linked.join(".git").is_file());
    fs::write(linked.join("linked.txt"), "fixture")?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let reply = call(&mut peer, &scope, json!({"root":linked}))?;
    assert_eq!(reply["result"]["outcome"], "ok");
    let text = reply["result"]["text"].as_str().ok_or("missing text")?;
    assert!(text.starts_with("Head:     HEAD (detached)"));
    assert!(text.contains("linked.txt"));
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn byte_limited_status_cannot_publish_partial_sections_and_next_request_can_start() -> TestResult {
    let root = repository()?;
    fs::write(root.path().join("untracked.txt"), "fixture")?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let reply = call(
        &mut peer,
        &scope,
        json!({"root":root.path(),"output_bytes":8}),
    )?;
    assert_eq!(reply["result"]["outcome"], "failed");
    assert_eq!(reply["result"]["capture_stop"], "bytes");
    assert_eq!(reply["result"]["cleanup_complete"], true);
    assert!(
        !reply["result"]["text"]
            .as_str()
            .ok_or("missing text")?
            .contains("Untracked files")
    );
    assert_eq!(
        call(&mut peer, &scope, json!({"root":root.path()}))?["result"]["outcome"],
        "ok"
    );
    fs::create_dir(root.path().join("nested"))?;
    assert!(
        call(
            &mut peer,
            &scope,
            json!({"root":root.path().join("nested")})
        )?
        .get("error")
        .is_some()
    );
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn missing_git_foreign_owner_and_argv_injection_are_scoped_failures() -> TestResult {
    let root = repository()?;
    let empty = tempfile::tempdir()?;
    let mut peer = Peer::start_with_path(Some(empty.path()))?;
    peer.initialize()?;
    let scope = peer.scope()?;
    assert_eq!(
        call(&mut peer, &scope, json!({"root":root.path()}))?["error"]["data"]["status"],
        "unavailable"
    );
    let mut foreign = scope.clone();
    foreign["session_id"] = json!(kargu_core::domain::SessionId::new());
    assert_eq!(
        call(&mut peer, &foreign, json!({"root":root.path()}))?["error"]["data"]["status"],
        "stale_owner"
    );
    assert_eq!(
        call(
            &mut peer,
            &scope,
            json!({"root":root.path(),"arguments":["commit"]})
        )?["error"]["code"],
        -32602
    );
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn successful_but_malformed_git_output_is_a_scoped_invalid_output_not_success() -> TestResult {
    let root = repository()?;
    let bin = tempfile::tempdir()?;
    let fake = bin.path().join("git");
    fs::write(
        &fake,
        format!(
            "#!{}\nprintf '## main\\000R  incomplete\\000'\n",
            executable("sh")?.display()
        ),
    )?;
    fs::set_permissions(&fake, fs::Permissions::from_mode(0o755))?;
    let mut peer = Peer::start_with_path(Some(bin.path()))?;
    peer.initialize()?;
    let scope = peer.scope()?;
    assert_eq!(
        call(&mut peer, &scope, json!({"root":root.path()}))?["error"]["data"]["status"],
        "invalid_output"
    );
    fs::write(
        &fake,
        format!(
            "#!{}\nprintf '## main\\000?? bad\\377\\000'\n",
            executable("sh")?.display()
        ),
    )?;
    assert_eq!(
        call(&mut peer, &scope, json!({"root":root.path()}))?["error"]["data"]["status"],
        "invalid_output"
    );
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"ping"}))?;
    assert!(peer.read()?.get("result").is_some());
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn host_global_ignore_configuration_is_preserved_without_enabling_fsmonitor() -> TestResult {
    let root = repository()?;
    fs::write(root.path().join("hidden.fixture"), "fixture")?;
    fs::write(root.path().join("visible.fixture"), "fixture")?;
    let config = tempfile::tempdir()?;
    let ignored = config.path().join("ignore");
    fs::write(&ignored, "hidden.fixture\n")?;
    let global = config.path().join("gitconfig");
    fs::write(
        &global,
        format!("[core]\n excludesFile = {}\n", ignored.display()),
    )?;
    let mut peer =
        Peer::start_with_path_and_environment(None, &[("GIT_CONFIG_GLOBAL", global.as_os_str())])?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let reply = call(&mut peer, &scope, json!({"root":root.path()}))?;
    assert_eq!(reply["result"]["outcome"], "ok");
    let text = reply["result"]["text"].as_str().ok_or("missing text")?;
    assert!(text.contains("visible.fixture"));
    assert!(!text.contains("hidden.fixture"));
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}
