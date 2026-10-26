//! Real Git log/ref consumers, helper denial, literal paths and owned drain.

mod support;
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::{fs::PermissionsExt, process::CommandExt},
    path::{Path, PathBuf},
    process::Command,
};
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn isolated_query(root: &Path, arguments: &[&str]) -> Result<String, Box<dyn std::error::Error>> {
    let layout = git(
        root,
        &[
            "rev-parse",
            "--path-format=absolute",
            "--git-dir",
            "--git-common-dir",
            "--show-object-format",
            "--show-ref-format",
        ],
    )?;
    let mut fields = layout.lines();
    let directory = PathBuf::from(fields.next().ok_or("git directory")?);
    let original_common = PathBuf::from(fields.next().ok_or("common directory")?);
    let object_format = fields.next().ok_or("object format")?;
    let ref_format = fields.next().ok_or("reference format")?;
    if !matches!(object_format, "sha1" | "sha256")
        || !matches!(ref_format, "files" | "reftable")
        || fields.next().is_some()
    {
        return Err("unsupported fixture layout".into());
    }
    let isolated = tempfile::tempdir()?;
    let common = isolated.path().join("common");
    let worktree = isolated.path().join("worktree");
    fs::create_dir(&common)?;
    fs::create_dir(&worktree)?;
    // The ref backend reads physical commondir, not only GIT_COMMON_DIR.
    fs::write(worktree.join("commondir"), "../common\n")?;
    fs::write(
        common.join("config"),
        format!(
            "[core]\nrepositoryformatversion = 1\nbare = false\n[extensions]\nobjectformat = {object_format}\nrefstorage = {ref_format}\n"
        ),
    )?;
    for entry in ["objects", "refs", "packed-refs", "shallow", "reftable"] {
        std::os::unix::fs::symlink(original_common.join(entry), common.join(entry))?;
    }
    std::os::unix::fs::symlink(directory.join("refs"), worktree.join("refs"))?;
    std::os::unix::fs::symlink(directory.join("reftable"), worktree.join("reftable"))?;
    // Absolute HEAD symlinks are not valid Git repository signatures.
    fs::copy(directory.join("HEAD"), worktree.join("HEAD"))?;
    let index = directory.join("index");
    let before = fs::read(&index)?;
    let output = Command::new(executable("git")?)
        .process_group(0)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").ok_or("PATH")?)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_ATTR_NOSYSTEM", "1")
        .env("GIT_COMMON_DIR", &common)
        .env("GIT_INDEX_FILE", &index)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .args(["--no-pager", "--no-lazy-fetch", "--literal-pathspecs"])
        .arg(format!("--git-dir={}", worktree.display()))
        .arg(format!("--work-tree={}", root.display()))
        .args([
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.attributesFile=/dev/null",
            "-c",
            "diff.autoRefreshIndex=false",
        ])
        .args(arguments)
        .current_dir(root)
        .output()?;
    if !output.status.success() {
        return Err(format!(
            "isolated query: {}",
            String::from_utf8_lossy(&output.stderr)
        )
        .into());
    }
    assert_eq!(
        fs::read(&index)?,
        before,
        "queries cannot refresh the original index"
    );
    Ok(String::from_utf8(output.stdout)?)
}

#[test]
fn isolated_git_configuration_disables_clean_helpers_without_reimplementing_diff_or_blame()
-> TestResult {
    for options in [
        vec![],
        vec!["--object-format=sha256"],
        vec!["--ref-format=reftable"],
        vec!["--object-format=sha256", "--ref-format=reftable"],
    ] {
        let root = repository_format(&options)?;
        let linked = tempfile::tempdir()?;
        git(
            root.path(),
            &[
                "worktree",
                "add",
                "-b",
                "linked",
                linked.path().to_str().ok_or("linked path")?,
            ],
        )?;
        let marker = root.path().join("helper-ran");
        let filter = root.path().join("clean-helper");
        fs::write(
            &filter,
            format!("#!/bin/sh\nprintf ran > '{}'\ncat\n", marker.display()),
        )?;
        fs::set_permissions(&filter, fs::Permissions::from_mode(0o700))?;
        git(
            root.path(),
            &[
                "config",
                "filter.fixture.clean",
                filter.to_str().ok_or("filter path")?,
            ],
        )?;
        for workspace in [root.path(), linked.path()] {
            fs::write(workspace.join(".gitattributes"), "*.txt filter=fixture\n")?;
            fs::write(workspace.join("tracked.txt"), "other\n")?;
            git(workspace, &["diff", "--no-ext-diff", "--no-textconv"])?;
            assert!(
                marker.is_file(),
                "positive control must execute the clean helper"
            );
            fs::remove_file(&marker)?;
            git(workspace, &["status", "--porcelain=v1"])?;
            assert!(
                marker.exists(),
                "same-size status refresh also executes clean filters"
            );
            fs::remove_file(&marker)?;
            for arguments in [
                vec![
                    "diff",
                    "--no-ext-diff",
                    "--no-textconv",
                    "--no-color",
                    "--",
                    "tracked.txt",
                ],
                vec![
                    "blame",
                    "--no-textconv",
                    "--date=short",
                    "--",
                    "tracked.txt",
                ],
                vec!["status", "--porcelain=v1", "-b", "-z"],
            ] {
                let result = isolated_query(workspace, &arguments)?;
                assert!(result.contains(if arguments.first() == Some(&"status") {
                    "tracked.txt"
                } else {
                    "other"
                }));
                assert!(!marker.exists());
            }
        }
    }
    Ok(())
}

fn executable(name: &str) -> Result<PathBuf, Box<dyn std::error::Error>> {
    std::env::split_paths(&std::env::var_os("PATH").ok_or("PATH")?)
        .map(|directory| directory.join(name))
        .find(|path| path.is_file())
        .ok_or_else(|| "fixture executable".into())
}
fn git(root: &Path, arguments: &[&str]) -> Result<String, Box<dyn std::error::Error>> {
    let output = Command::new(executable("git")?)
        .process_group(0)
        .current_dir(root)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").ok_or("PATH")?)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .args(["-c", "commit.gpgSign=false", "-c", "core.fsmonitor=false"])
        .args(arguments)
        .output()?;
    if !output.status.success() {
        return Err(format!(
            "fixture Git failed: {}",
            String::from_utf8_lossy(&output.stderr)
        )
        .into());
    }
    Ok(String::from_utf8(output.stdout)?)
}
fn repository() -> Result<tempfile::TempDir, Box<dyn std::error::Error>> {
    repository_format(&[])
}
fn repository_format(options: &[&str]) -> Result<tempfile::TempDir, Box<dyn std::error::Error>> {
    let root = tempfile::tempdir()?;
    let mut init = vec!["init", "--initial-branch=main"];
    init.extend(options);
    git(root.path(), &init)?;
    git(root.path(), &["config", "user.name", "Offline Fixture"])?;
    git(
        root.path(),
        &["config", "user.email", "fixture@example.invalid"],
    )?;
    fs::write(root.path().join("tracked.txt"), "first\n")?;
    git(root.path(), &["add", "--", "tracked.txt"])?;
    git(root.path(), &["commit", "-m", "first fixture"])?;
    Ok(root)
}
fn call(
    peer: &mut Peer,
    scope: &Value,
    root: &Path,
    query: Value,
    output: u64,
) -> Result<Value, Box<dyn std::error::Error>> {
    peer.send(json!({"jsonrpc":"2.0","id":3,"method":"git/read","params":{"scope":scope,"arguments":{"root":root,"query":query,"output_bytes":output,"timeout_ms":null}}}))?;
    peer.read()
}
fn finish(peer: &mut Peer) -> TestResult {
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn real_log_branches_stashes_use_complete_native_results_and_preserve_git_semantics() -> TestResult
{
    let root = repository()?;
    fs::write(root.path().join("tracked.txt"), "second\n")?;
    git(root.path(), &["commit", "-am", "second fixture"])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let log = call(
        &mut peer,
        &scope,
        root.path(),
        json!({"operation":"log","max_count":1}),
        65536,
    )?;
    assert_eq!(log["result"]["outcome"], "ok");
    assert_eq!(log["result"]["cleanup_complete"], true);
    let text = log["result"]["text"].as_str().ok_or("text")?;
    assert!(text.contains("second fixture"));
    assert!(!text.contains("first fixture"));
    assert!(
        call(
            &mut peer,
            &scope,
            root.path(),
            json!({"operation":"branches"}),
            65536
        )?["result"]["text"]
            .as_str()
            .ok_or("text")?
            .contains("main")
    );
    assert_eq!(
        call(
            &mut peer,
            &scope,
            root.path(),
            json!({"operation":"stashes"}),
            65536
        )?["result"]["text"],
        "(no stash entries)"
    );
    fs::write(root.path().join("tracked.txt"), "stashed\n")?;
    git(root.path(), &["stash", "push", "-m", "saved fixture"])?;
    assert!(
        call(
            &mut peer,
            &scope,
            root.path(),
            json!({"operation":"stashes"}),
            65536
        )?["result"]["text"]
            .as_str()
            .ok_or("text")?
            .contains("saved fixture")
    );
    finish(&mut peer)
}

#[test]
fn literal_missing_and_deleted_paths_do_not_expand_to_other_history_or_escape_root() -> TestResult {
    let root = repository()?;
    let outside = tempfile::tempdir()?;
    fs::write(root.path().join("*.txt"), "literal\n")?;
    git(root.path(), &["add", "--", "*.txt"])?;
    git(root.path(), &["commit", "-m", "literal filename"])?;
    fs::remove_file(root.path().join("tracked.txt"))?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let literal = call(
        &mut peer,
        &scope,
        root.path(),
        json!({"operation":"log","path":"*.txt"}),
        65536,
    )?;
    let text = literal["result"]["text"].as_str().ok_or("literal text")?;
    assert!(text.contains("literal filename"));
    assert!(!text.contains("first fixture"));
    assert!(
        call(
            &mut peer,
            &scope,
            root.path(),
            json!({"operation":"log","path":"tracked.txt"}),
            65536
        )?["result"]["text"]
            .as_str()
            .ok_or("deleted text")?
            .contains("first fixture")
    );
    assert_eq!(
        call(
            &mut peer,
            &scope,
            root.path(),
            json!({"operation":"log","path":"absent/child"}),
            65536
        )?["result"]["text"],
        "(no commits found)"
    );
    assert_eq!(
        call(
            &mut peer,
            &scope,
            root.path(),
            json!({"operation":"log","path":root.path()}),
            65536
        )?["result"]["outcome"],
        "ok"
    );
    std::os::unix::fs::symlink(outside.path(), root.path().join("outside"))?;
    for path in [
        json!("../outside"),
        json!(outside.path()),
        json!("outside/missing"),
    ] {
        assert!(
            call(
                &mut peer,
                &scope,
                root.path(),
                json!({"operation":"log","path":path}),
                65536
            )?
            .get("error")
            .is_some()
        );
    }
    finish(&mut peer)
}

#[test]
fn executable_filters_are_not_licensed_by_the_read_query_port() -> TestResult {
    let root = repository()?;
    let marker = root.path().join("filter-ran");
    let helper = root.path().join("filter-helper");
    fs::write(
        &helper,
        format!(
            "#!{}\necho invoked > '{}'\nexec '{}'\n",
            executable("sh")?.display(),
            marker.display(),
            executable("cat")?.display()
        ),
    )?;
    fs::set_permissions(&helper, fs::Permissions::from_mode(0o755))?;
    git(
        root.path(),
        &[
            "config",
            "filter.fixture.clean",
            helper.to_str().ok_or("helper")?,
        ],
    )?;
    git(
        root.path(),
        &[
            "config",
            "diff.fixture.textconv",
            helper.to_str().ok_or("helper")?,
        ],
    )?;
    fs::write(
        root.path().join(".gitattributes"),
        "tracked.txt filter=fixture diff=fixture\n",
    )?;
    fs::write(root.path().join("tracked.txt"), "changed\n")?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    for query in [
        json!({"operation":"log"}),
        json!({"operation":"branches"}),
        json!({"operation":"stashes"}),
    ] {
        assert_eq!(
            call(&mut peer, &scope, root.path(), query, 65536)?["result"]["outcome"],
            "ok"
        );
    }
    for operation in ["diff", "blame"] {
        assert!(
            call(
                &mut peer,
                &scope,
                root.path(),
                json!({"operation":operation}),
                65536
            )?
            .get("error")
            .is_some()
        );
    }
    assert!(!marker.exists());
    // Positive control: disabling diff helpers alone does NOT disable clean filters.
    git(
        root.path(),
        &[
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--",
            "tracked.txt",
        ],
    )?;
    assert!(marker.exists());
    finish(&mut peer)
}

#[test]
fn log_disables_configured_signature_verification_and_pager_programs() -> TestResult {
    let root = repository()?;
    let marker = root.path().join("signature-ran");
    let helper = root.path().join("signature-helper");
    fs::write(
        &helper,
        format!(
            "#!{}\necho invoked > '{}'\nexit 1\n",
            executable("sh")?.display(),
            marker.display()
        ),
    )?;
    fs::set_permissions(&helper, fs::Permissions::from_mode(0o755))?;
    let original = git(root.path(), &["cat-file", "commit", "HEAD"])?;
    let signed = original.replacen("\n\n", "\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n invalid fixture\n -----END PGP SIGNATURE-----\n\n",1);
    let object_file = root.path().join("signed-object");
    fs::write(&object_file, signed)?;
    let oid = git(
        root.path(),
        &[
            "hash-object",
            "-t",
            "commit",
            "-w",
            object_file.to_str().ok_or("path")?,
        ],
    )?;
    git(root.path(), &["update-ref", "refs/heads/main", oid.trim()])?;
    git(
        root.path(),
        &["config", "gpg.program", helper.to_str().ok_or("helper")?],
    )?;
    git(root.path(), &["config", "log.showSignature", "true"])?;
    git(
        root.path(),
        &["config", "core.pager", helper.to_str().ok_or("helper")?],
    )?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    assert_eq!(
        call(
            &mut peer,
            &scope,
            root.path(),
            json!({"operation":"log"}),
            65536
        )?["result"]["outcome"],
        "ok"
    );
    assert!(!marker.exists());
    git(
        root.path(),
        &["--no-pager", "log", "-1", "--show-signature"],
    )?;
    assert!(marker.exists());
    finish(&mut peer)
}

#[test]
fn query_reply_uses_its_captured_capacity_not_the_generic_command_prefix() -> TestResult {
    let root = repository()?;
    let message = "m".repeat(70000);
    git(root.path(), &["commit", "--allow-empty", "-m", &message])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let result = call(
        &mut peer,
        &scope,
        root.path(),
        json!({"operation":"log","max_count":1}),
        131072,
    )?;
    assert_eq!(result["result"]["outcome"], "ok");
    assert!(
        result["result"]["text"]
            .as_str()
            .ok_or("text")?
            .ends_with(&message)
    );
    finish(&mut peer)
}

#[test]
fn malformed_queries_foreign_scope_and_complete_output_limits_fail_without_poisoning_next_read()
-> TestResult {
    let root = repository()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    for query in [
        json!({"operation":"log","max_count":0}),
        json!({"operation":"log","max_count":10001}),
        json!({"operation":"branches","arguments":["--delete","main"]}),
        json!({"operation":"log","program":"/bin/sh"}),
    ] {
        assert!(
            call(&mut peer, &scope, root.path(), query, 65536)?
                .get("error")
                .is_some()
        );
    }
    let mut foreign = scope.clone();
    foreign["application_id"] = peer.scope()?["application_id"].clone();
    assert!(
        call(
            &mut peer,
            &foreign,
            root.path(),
            json!({"operation":"log"}),
            65536
        )?
        .get("error")
        .is_some()
    );
    let limited = call(
        &mut peer,
        &scope,
        root.path(),
        json!({"operation":"log"}),
        8,
    )?;
    assert_eq!(limited["result"]["outcome"], "failed");
    assert_eq!(limited["result"]["capture_stop"], "bytes");
    assert_eq!(limited["result"]["cleanup_complete"], true);
    assert_eq!(
        call(
            &mut peer,
            &scope,
            root.path(),
            json!({"operation":"log"}),
            65536
        )?["result"]["outcome"],
        "ok"
    );
    finish(&mut peer)
}

#[test]
fn missing_git_has_no_fallback_and_unlimited_read_still_drains_on_cancel() -> TestResult {
    let root = repository()?;
    let tools = tempfile::tempdir()?;
    let mut missing = Peer::start_with_path(Some(tools.path()))?;
    missing.initialize()?;
    let scope = missing.scope()?;
    assert!(
        call(
            &mut missing,
            &scope,
            root.path(),
            json!({"operation":"log"}),
            65536
        )?
        .get("error")
        .is_some()
    );
    finish(&mut missing)?;
    let pid_file = root.path().join("child-pid");
    let script = tools.path().join("git");
    fs::write(
        &script,
        format!(
            "#!{}\necho $$ > '{}'\nexec '{}' 30\n",
            executable("sh")?.display(),
            pid_file.display(),
            executable("sleep")?.display()
        ),
    )?;
    fs::set_permissions(&script, fs::Permissions::from_mode(0o755))?;
    let mut peer = Peer::start_with_path(Some(tools.path()))?;
    peer.initialize()?;
    let scope = peer.scope()?;
    peer.send(json!({"jsonrpc":"2.0","id":"held","method":"git/read","params":{"scope":scope,"arguments":{"root":root.path(),"query":{"operation":"log"},"timeout_ms":null}}}))?;
    let deadline = std::time::Instant::now()
        .checked_add(std::time::Duration::from_secs(3))
        .ok_or("clock")?;
    while !pid_file.exists() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    let pid = fs::read_to_string(pid_file)?.trim().to_owned();
    peer.send(json!({"jsonrpc":"2.0","id":"ping","method":"ping"}))?;
    assert_eq!(peer.read()?["id"], "ping");
    peer.send(json!({"jsonrpc":"2.0","method":"rpc/cancel","params":{"request_id":"held","scope":peer.epoch}}))?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "cancelled");
    assert!(!PathBuf::from(format!("/proc/{pid}")).exists());
    finish(&mut peer)
}
