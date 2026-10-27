//! Real Git writes, immutable reviews, refusal and no replay after issuance.
mod support;
use serde_json::{Value, json};
use std::{fs, path::Path, process::Command};
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;
fn git(root: &Path, args: &[&str]) -> Result<String, Box<dyn std::error::Error>> {
    let out = Command::new("git")
        .args(args)
        .current_dir(root)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()?;
    if !out.status.success() {
        return Err(format!("Git failed: {}", String::from_utf8_lossy(&out.stderr)).into());
    }
    Ok(String::from_utf8(out.stdout)?)
}
fn init(root: &Path) -> TestResult {
    git(root, &["init", "-b", "main"])?;
    git(root, &["config", "user.name", "Fixture"])?;
    git(root, &["config", "user.email", "fixture@example.invalid"])?;
    fs::write(root.join("a"), "one\n")?;
    Ok(())
}
fn args(root: &Path, query: Value) -> Value {
    json!({"root":root,"mode":"agent","query":query,"timeout_ms":null,"output_bytes":1048576,"environment":{"PATH":std::env::var("PATH").unwrap_or_default(),"HOME":root,"GIT_CONFIG_GLOBAL":"/dev/null"},"config_revision":0,"policy_revision":0})
}
fn start(peer: &mut Peer, scope: &Value, input: Value) -> TestResult {
    peer.send(json!({"jsonrpc":"2.0","id":3,"method":"git/mutate","params":{"scope":scope,"arguments":input}}))
}
fn decide(peer: &mut Peer, review: &Value, approved: bool) -> TestResult {
    peer.send(json!({"jsonrpc":"2.0","id":review["id"],"result":{"approved":approved}}))
}
fn mutate(
    peer: &mut Peer,
    scope: &Value,
    root: &Path,
    query: Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    start(peer, scope, args(root, query))?;
    let review = peer.read()?;
    assert_eq!(review["method"], "editor/request_approval", "{review}");
    decide(peer, &review, true)?;
    let result = peer.read()?;
    assert_eq!(result["result"]["outcome"], "ok", "{result}");
    Ok(result)
}
#[test]
fn stage_unborn_unstage_commit_branch_and_stash_use_one_reviewed_write() -> TestResult {
    let root = tempfile::tempdir()?;
    init(root.path())?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    mutate(
        &mut peer,
        &scope,
        root.path(),
        json!({"operation":"stage","paths":["a"]}),
    )?;
    mutate(
        &mut peer,
        &scope,
        root.path(),
        json!({"operation":"unstage","paths":["."]}),
    )?;
    assert_eq!(git(root.path(), &["ls-files"])?, "");
    assert!(root.path().join("a").is_file());
    mutate(
        &mut peer,
        &scope,
        root.path(),
        json!({"operation":"stage","paths":["."]}),
    )?;
    mutate(
        &mut peer,
        &scope,
        root.path(),
        json!({"operation":"commit","message":"first","all":false}),
    )?;
    mutate(
        &mut peer,
        &scope,
        root.path(),
        json!({"operation":"branch_create","name":"feature"}),
    )?;
    assert_eq!(
        git(root.path(), &["branch", "--show-current"])?.trim(),
        "feature"
    );
    mutate(
        &mut peer,
        &scope,
        root.path(),
        json!({"operation":"branch_switch","name":"main"}),
    )?;
    mutate(
        &mut peer,
        &scope,
        root.path(),
        json!({"operation":"branch_delete","name":"feature"}),
    )?;
    fs::write(root.path().join("a"), "changed\n")?;
    mutate(
        &mut peer,
        &scope,
        root.path(),
        json!({"operation":"stash_push","message":"saved"}),
    )?;
    mutate(
        &mut peer,
        &scope,
        root.path(),
        json!({"operation":"stash_apply","stash":"stash@{0}"}),
    )?;
    assert_eq!(fs::read_to_string(root.path().join("a"))?, "changed\n");
    assert!(!git(root.path(), &["stash", "list"])?.is_empty());
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}
#[test]
fn changed_index_and_target_revision_refuse_delayed_approval_without_side_effects() -> TestResult {
    for change in ["index", "target", "head", "config"] {
        let root = tempfile::tempdir()?;
        init(root.path())?;
        git(root.path(), &["add", "a"])?;
        git(root.path(), &["commit", "-m", "initial"])?;
        fs::write(root.path().join("a"), "new\n")?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        start(
            &mut peer,
            &scope,
            args(root.path(), json!({"operation":"stage","paths":["a"]})),
        )?;
        let review = peer.read()?;
        assert_eq!(review["method"], "editor/request_approval", "{review}");
        match change {
            "index" => {
                git(root.path(), &["add", "a"])?;
            }
            "target" => fs::write(root.path().join("a"), "racing\n")?,
            "head" => {
                git(root.path(), &["checkout", "-b", "race"])?;
            }
            _ => {
                git(root.path(), &["config", "user.name", "Changed"])?;
            }
        }
        let before = fs::read(root.path().join(".git/index"))?;
        decide(&mut peer, &review, true)?;
        let result = peer.read()?;
        assert_eq!(
            result["error"]["data"]["status"], "workspace_changed",
            "{result}"
        );
        assert_eq!(fs::read(root.path().join(".git/index"))?, before);
    }
    Ok(())
}
#[test]
fn modes_paths_unknown_fields_reject_before_approval_and_rejection_leaves_index_absent()
-> TestResult {
    let root = tempfile::tempdir()?;
    init(root.path())?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    for mode in ["ask", "plan", "debug"] {
        let mut input = args(root.path(), json!({"operation":"stage","paths":["a"]}));
        input["mode"] = json!(mode);
        start(&mut peer, &scope, input)?;
        assert!(peer.read()?.get("error").is_some());
    }
    for query in [
        json!({"operation":"stage","paths":["../outside"]}),
        json!({"operation":"stage","paths":[]}),
        json!({"operation":"branch_create","name":"--force"}),
        json!({"operation":"stash_apply","stash":"HEAD"}),
        json!({"operation":"stash_drop","stash":"stash@{0}"}),
        json!({"operation":"commit","message":"x","argv":["--amend"]}),
    ] {
        start(&mut peer, &scope, args(root.path(), query))?;
        assert!(peer.read()?.get("error").is_some());
    }
    start(
        &mut peer,
        &scope,
        args(root.path(), json!({"operation":"stage","paths":["a"]})),
    )?;
    let review = peer.read()?;
    decide(&mut peer, &review, false)?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "rejected");
    assert!(!root.path().join(".git/index").exists());
    Ok(())
}
#[test]
fn stash_review_uses_immutable_object_even_if_reflog_reorders() -> TestResult {
    let root = tempfile::tempdir()?;
    init(root.path())?;
    git(root.path(), &["add", "a"])?;
    git(root.path(), &["commit", "-m", "initial"])?;
    fs::write(root.path().join("a"), "stash body\n")?;
    git(root.path(), &["stash", "push", "-m", "old"])?;
    let object = git(root.path(), &["rev-parse", "refs/stash"])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    start(
        &mut peer,
        &scope,
        args(
            root.path(),
            json!({"operation":"stash_apply","stash":"stash@{0}"}),
        ),
    )?;
    let review = peer.read()?;
    assert!(
        review["params"]["arguments"]
            .as_array()
            .ok_or("argv")?
            .contains(&json!(object.trim()))
    );
    git(
        root.path(),
        &["stash", "store", "-m", "reordered", object.trim()],
    )?;
    decide(&mut peer, &review, true)?;
    let result = peer.read()?;
    assert_eq!(result["result"]["outcome"], "ok", "{result}");
    assert_eq!(fs::read_to_string(root.path().join("a"))?, "stash body\n");
    Ok(())
}

#[test]
fn corrupt_head_never_selects_unborn_unstage_or_changes_index() -> TestResult {
    for corrupt in ["broken head\n", "ref: refs/heads/main\n"] {
        let root = tempfile::tempdir()?;
        init(root.path())?;
        git(root.path(), &["add", "a"])?;
        fs::write(root.path().join(".git/HEAD"), corrupt)?;
        if corrupt.starts_with("ref:") {
            fs::write(root.path().join(".git/refs/heads/main"), "broken ref\n")?;
        }
        let index = fs::read(root.path().join(".git/index"))?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        start(
            &mut peer,
            &scope,
            args(root.path(), json!({"operation":"unstage","paths":["."]})),
        )?;
        let result = peer.read()?;
        assert!(result.get("error").is_some(), "{result}");
        assert_eq!(fs::read(root.path().join(".git/index"))?, index);
    }
    Ok(())
}

#[test]
fn hooks_are_reviewed_arbitrary_code_and_output_failure_never_replays_a_commit() -> TestResult {
    use std::os::unix::fs::PermissionsExt;
    for noisy in [false, true] {
        let root = tempfile::tempdir()?;
        init(root.path())?;
        git(root.path(), &["add", "a"])?;
        let hook = root.path().join(".git/hooks/pre-commit");
        fs::write(
            &hook,
            if noisy {
                "#!/bin/sh\nprintf x >> hook.calls\ni=0; while [ $i -lt 4000 ]; do printf 'hook output\n'; i=$((i+1)); done\nexit 1\n"
            } else {
                "#!/bin/sh\nprintf x >> hook.calls\n"
            },
        )?;
        fs::set_permissions(hook, fs::Permissions::from_mode(0o700))?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let mut input = args(
            root.path(),
            json!({"operation":"commit","message":"hooked"}),
        );
        if noisy {
            input["output_bytes"] = json!(256);
        }
        start(&mut peer, &scope, input)?;
        let review = peer.read()?;
        assert_eq!(review["method"], "editor/request_approval", "{review}");
        assert!(!root.path().join("hook.calls").exists());
        decide(&mut peer, &review, true)?;
        let result = peer.read()?;
        if noisy {
            assert_ne!(result["result"]["outcome"], "ok", "{result}");
            assert!(result.to_string().contains("unknown"), "{result}");
        } else {
            assert_eq!(result["result"]["outcome"], "ok", "{result}");
            assert_eq!(git(root.path(), &["log", "--format=%s"])?.trim(), "hooked");
        }
        assert_eq!(fs::read_to_string(root.path().join("hook.calls"))?, "x");
    }
    Ok(())
}

#[test]
fn cancel_during_hook_or_signer_reaps_descendant_before_reply_and_readmission() -> TestResult {
    for signing in [false, true] {
        cancelled_commit(signing)?;
    }
    Ok(())
}
fn cancelled_commit(signing: bool) -> TestResult {
    use std::{
        os::unix::fs::PermissionsExt,
        time::{Duration, Instant},
    };
    let root = tempfile::tempdir()?;
    init(root.path())?;
    git(root.path(), &["add", "a"])?;
    let hook = root.path().join(if signing {
        ".git/fixture-signer"
    } else {
        ".git/hooks/pre-commit"
    });
    if signing {
        git(root.path(), &["config", "commit.gpgsign", "true"])?;
        git(
            root.path(),
            &["config", "gpg.program", hook.to_str().ok_or("signer path")?],
        )?;
    }
    fs::write(
        &hook,
        "#!/bin/sh\n(trap '' TERM; printf '%s' \"$BASHPID\" > hook.pid; while :; do sleep 1; done) &\nwait\n",
    )?;
    // POSIX sh does not expose its subshell PID; invoke Bash explicitly as fixture data.
    let bash = Command::new("sh")
        .args(["-c", "command -v bash"])
        .output()?;
    let bash = String::from_utf8(bash.stdout)?;
    let script = fs::read_to_string(&hook)?.replacen("#!/bin/sh", &format!("#!{}", bash.trim()), 1);
    fs::write(&hook, script)?;
    fs::set_permissions(&hook, fs::Permissions::from_mode(0o700))?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    start(
        &mut peer,
        &scope,
        args(
            root.path(),
            json!({"operation":"commit","message":"cancelled"}),
        ),
    )?;
    let review = peer.read()?;
    decide(&mut peer, &review, true)?;
    let stop = Instant::now() + Duration::from_secs(3);
    let pid = loop {
        if let Ok(text) = fs::read_to_string(root.path().join("hook.pid"))
            && let Ok(pid) = text.trim().parse::<u32>()
        {
            break pid;
        }
        if Instant::now() >= stop {
            return Err("hook did not start".into());
        }
        std::thread::sleep(Duration::from_millis(5));
    };
    peer.send(
        json!({"jsonrpc":"2.0","method":"rpc/cancel","params":{"request_id":3,"scope":peer.epoch}}),
    )?;
    let result = peer.read()?;
    assert_eq!(
        result["error"]["data"]["status"], "outcome_unknown",
        "{result}"
    );
    assert!(!Path::new(&format!("/proc/{pid}")).exists());
    fs::remove_file(hook)?;
    if signing {
        git(root.path(), &["config", "commit.gpgsign", "false"])?;
    }
    mutate(
        &mut peer,
        &scope,
        root.path(),
        json!({"operation":"commit","message":"after drain"}),
    )?;
    assert_eq!(
        git(root.path(), &["log", "--format=%s"])?.trim(),
        "after drain"
    );
    Ok(())
}

#[test]
fn mutations_support_sha1_sha256_files_reftable_and_linked_worktrees() -> TestResult {
    for format in ["sha1", "sha256"] {
        for refs in ["files", "reftable"] {
            let root = tempfile::tempdir()?;
            git(
                root.path(),
                &[
                    "init",
                    "-b",
                    "main",
                    &format!("--object-format={format}"),
                    &format!("--ref-format={refs}"),
                ],
            )?;
            git(root.path(), &["config", "user.name", "Fixture"])?;
            git(
                root.path(),
                &["config", "user.email", "fixture@example.invalid"],
            )?;
            fs::write(root.path().join("a"), "first")?;
            git(root.path(), &["add", "a"])?;
            git(root.path(), &["commit", "-m", "initial"])?;
            let worktree = root.path().join("linked");
            git(
                root.path(),
                &[
                    "worktree",
                    "add",
                    "-b",
                    "linked",
                    worktree.to_str().ok_or("path")?,
                ],
            )?;
            let mut peer = Peer::start()?;
            peer.initialize()?;
            let scope = peer.scope()?;
            for target in [root.path(), worktree.as_path()] {
                fs::write(target.join("a"), "changed")?;
                mutate(
                    &mut peer,
                    &scope,
                    target,
                    json!({"operation":"stage","paths":["a"]}),
                )?;
                mutate(
                    &mut peer,
                    &scope,
                    target,
                    json!({"operation":"unstage","paths":["a"]}),
                )?;
                assert_eq!(git(target, &["diff", "--cached", "--name-only"])?, "");
            }
        }
    }
    Ok(())
}

#[test]
fn literal_wildcards_and_internal_symlink_changes_are_bound_to_review() -> TestResult {
    let root = tempfile::tempdir()?;
    init(root.path())?;
    fs::write(root.path().join("literal*"), "wildcard is a filename")?;
    std::os::unix::fs::symlink("a", root.path().join("link"))?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    mutate(
        &mut peer,
        &scope,
        root.path(),
        json!({"operation":"stage","paths":["literal*","link"]}),
    )?;
    assert_eq!(git(root.path(), &["ls-files"])?, "link\nliteral*\n");
    start(
        &mut peer,
        &scope,
        args(root.path(), json!({"operation":"stage","paths":["link"]})),
    )?;
    let review = peer.read()?;
    fs::remove_file(root.path().join("link"))?;
    std::os::unix::fs::symlink("literal*", root.path().join("link"))?;
    decide(&mut peer, &review, true)?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "workspace_changed");
    Ok(())
}
