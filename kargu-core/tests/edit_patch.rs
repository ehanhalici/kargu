//! Native patch inspection and actual supervised Git, with original files untouched.
mod support;
use serde_json::{Value, json};
use std::{
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;
const ORIGIN: &str = "editor_source_12345678-1234-4234-8234-123456789abc";
fn request(peer: &mut Peer, scope: &Value, id: &str, method: &str, args: Value) -> TestResult {
    peer.send(
        json!({"jsonrpc":"2.0","id":id,"method":method,"params":{"scope":scope,"arguments":args}}),
    )
}
fn call(
    peer: &mut Peer,
    scope: &Value,
    method: &str,
    args: Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    request(peer, scope, "patch", method, args)?;
    let value = peer.read()?;
    assert_eq!(value["id"], "patch");
    Ok(value)
}
fn ticket(id: &Value) -> Value {
    json!({"origin_id":ORIGIN,"preparation_id":id})
}
fn upload(peer: &mut Peer, scope: &Value, id: &Value, part: &str, text: &str) -> TestResult {
    upload_sized(peer, scope, id, part, text, 32768)
}
fn upload_sized(
    peer: &mut Peer,
    scope: &Value,
    id: &Value,
    part: &str,
    text: &str,
    limit: usize,
) -> TestResult {
    let mut offset = 0usize;
    while offset < text.len() {
        let mut end = offset.saturating_add(limit).min(text.len());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        let reply = call(
            peer,
            scope,
            "edit/append",
            json!({"origin_id":ORIGIN,"preparation_id":id,"part":part,"offset":offset,"text":&text[offset..end]}),
        )?;
        assert_eq!(reply["result"]["offset"], end, "{reply}");
        offset = end;
    }
    Ok(())
}
fn inspect(
    peer: &mut Peer,
    scope: &Value,
    root: &Path,
    patch: &str,
) -> Result<Value, Box<dyn std::error::Error>> {
    let reply = call(
        peer,
        scope,
        "edit/begin",
        json!({"origin_id":ORIGIN,"root":root,"mode":"agent","live":null,
        "intent":{"kind":"patch","patch_bytes":patch.len()},"config_revision":0,"policy_revision":0,"review_mode":"auto","save_policy":"save"}),
    )?;
    let id = reply["result"]["preparation_id"].clone();
    assert!(id.is_string(), "{reply}");
    let size = usize::try_from(reply["result"]["page_bytes"].as_u64().ok_or("page size")?)?;
    upload_sized(peer, scope, &id, "patch", patch, size)?;
    let reply = call(peer, scope, "edit/inspect", ticket(&id))?;
    assert_eq!(reply["result"]["inspected"], true, "{reply}");
    Ok(id)
}
fn page(
    peer: &mut Peer,
    scope: &Value,
    id: &Value,
    file: usize,
    part: &str,
) -> Result<String, Box<dyn std::error::Error>> {
    let mut result = String::new();
    loop {
        let reply = call(
            peer,
            scope,
            "edit/read",
            json!({"origin_id":ORIGIN,"preparation_id":id,"file":file,"part":part,"offset":result.len()}),
        )?;
        let value = &reply["result"];
        assert_eq!(value["offset"], result.len(), "{reply}");
        result.push_str(value["text"].as_str().ok_or("page")?);
        assert_eq!(value["next_offset"], result.len());
        if value["complete"] == true {
            return Ok(result);
        }
    }
}
fn files(
    peer: &mut Peer,
    scope: &Value,
    id: &Value,
    method: &str,
) -> Result<Vec<Value>, Box<dyn std::error::Error>> {
    let mut result = Vec::new();
    loop {
        let mut args = ticket(id);
        args["offset"] = json!(result.len());
        let reply = call(peer, scope, method, args)?;
        let value = &reply["result"];
        assert_eq!(value["offset"], result.len(), "{reply}");
        result.extend(value["files"].as_array().ok_or("files")?.iter().cloned());
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
fn wait_file(path: &Path) -> TestResult {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !path.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(path.exists());
    Ok(())
}
fn shell_quote(path: &Path) -> String {
    format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
}
fn git_program() -> Result<PathBuf, Box<dyn std::error::Error>> {
    std::env::split_paths(&std::env::var_os("PATH").ok_or("PATH")?)
        .map(|dir| dir.join("git"))
        .find(|p| p.is_file())
        .ok_or_else(|| "git".into())
}
fn wrapper(dir: &Path, body: &str) -> TestResult {
    std::fs::create_dir_all(dir)?;
    let git = dir.join("git");
    std::fs::write(&git, format!("#!/bin/sh\n{body}\n"))?;
    std::fs::set_permissions(git, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}

#[test]
fn inspected_multifile_patch_uses_real_git_with_exact_counts_and_no_original_writes() -> TestResult
{
    let root = tempfile::tempdir()?;
    std::fs::write(root.path().join("source"), "baş\r\nold\r\nend\r\n")?;
    std::fs::write(root.path().join("delete"), "remove\n")?;
    std::fs::create_dir(root.path().join(".git"))?;
    std::fs::write(root.path().join(".git/index"), "private-index")?;
    let before = disk(&root.path().join("source"))?;
    let fixtures = tempfile::tempdir()?;
    let bin = fixtures.path().join("bin");
    let cwd = fixtures.path().join("cwd");
    wrapper(
        &bin,
        &format!(
            "pwd > {}\nexec {} \"$@\"",
            shell_quote(&cwd),
            shell_quote(&git_program()?)
        ),
    )?;
    let mut peer = Peer::start_with_path(Some(&bin))?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let patch = "--- a/source\n+++ b/source\n@@ -1,3 +1,3 @@\n baş\n-old\n+new\n end\n--- /dev/null\n+++ b/new/nested\n@@ -0,0 +1 @@\n+é🦀\n--- a/delete\n+++ /dev/null\n@@ -1 +0,0 @@\n-remove\n";
    let id = inspect(&mut peer, &scope, root.path(), patch)?;
    let targets = files(&mut peer, &scope, &id, "edit/targets")?;
    assert_eq!(
        targets
            .iter()
            .map(|v| v["path"].as_str())
            .collect::<Vec<_>>(),
        vec![Some("source"), Some("new/nested"), Some("delete")]
    );
    let reply = call(&mut peer, &scope, "edit/prepare", ticket(&id))?;
    assert_eq!(reply["result"]["hunks_total"], 3, "{reply}");
    assert_eq!(reply["result"]["file_count"], 3);
    assert_eq!(reply["result"]["applied"], false);
    let views = files(&mut peer, &scope, &id, "edit/files")?;
    assert_eq!(
        views
            .iter()
            .map(|v| v["operation"].as_str())
            .collect::<Vec<_>>(),
        vec![Some("update"), Some("add"), Some("delete")]
    );
    assert!(views.iter().all(|v| v["hunks_total"] == 1));
    assert_eq!(page(&mut peer, &scope, &id, 0, "base")?, "baş\nold\nend\n");
    assert_eq!(
        page(&mut peer, &scope, &id, 0, "proposed")?,
        "baş\nnew\nend\n"
    );
    assert_eq!(page(&mut peer, &scope, &id, 1, "proposed")?, "é🦀\n");
    assert_eq!(page(&mut peer, &scope, &id, 2, "proposed")?, "");
    assert_eq!(
        std::fs::read_to_string(root.path().join("source"))?,
        "baş\r\nold\r\nend\r\n"
    );
    assert_eq!(disk(&root.path().join("source"))?, before);
    assert_eq!(
        std::fs::read_to_string(root.path().join("delete"))?,
        "remove\n"
    );
    assert!(!root.path().join("new").exists());
    assert_eq!(
        std::fs::read_to_string(root.path().join(".git/index"))?,
        "private-index"
    );
    assert!(!Path::new(std::fs::read_to_string(cwd)?.trim()).exists());
    peer.send(json!({"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}))?;
    assert_eq!(peer.read()?["id"], "shutdown");
    peer.send(json!({"jsonrpc":"2.0","method":"exit"}))?;
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn ambiguity_aliases_missing_or_existing_add_and_git_mismatch_never_publish_a_prefix() -> TestResult
{
    let root = tempfile::tempdir()?;
    std::fs::write(root.path().join("source"), "same\nsame\n")?;
    std::os::unix::fs::symlink(root.path().join("source"), root.path().join("alias"))?;
    let fixtures = tempfile::tempdir()?;
    let bin = fixtures.path().join("bin");
    let cwd = fixtures.path().join("cwd");
    wrapper(
        &bin,
        &format!(
            "pwd > {}\nexec {} \"$@\"",
            shell_quote(&cwd),
            shell_quote(&git_program()?)
        ),
    )?;
    let mut peer = Peer::start_with_path(Some(&bin))?;
    peer.initialize()?;
    let scope = peer.scope()?;
    for (patch, status, runs) in [
        (
            "--- a/source\n+++ b/source\n@@ -1 +1 @@\n-same\n+new\n",
            "ambiguous_match",
            false,
        ),
        (
            "--- a/missing\n+++ b/missing\n@@ -1 +1 @@\n-old\n+new\n",
            "missing_target",
            false,
        ),
        (
            "--- /dev/null\n+++ b/source\n@@ -0,0 +1 @@\n+new\n",
            "conflict",
            false,
        ),
        (
            "--- a/source\n+++ b/source\n@@ -1,2 +1,2 @@\n wrong\n-same\n+new\n",
            "patch_failed",
            true,
        ),
        (
            "--- a/source\n+++ b/source\n@@ -1,2 +1,2 @@\n same\n-same\n+new\n--- a/alias\n+++ b/alias\n@@ -1,2 +1,2 @@\n same\n-same\n+new\n",
            "conflict",
            false,
        ),
    ] {
        if cwd.exists() {
            std::fs::remove_file(&cwd)?;
        }
        let id = inspect(&mut peer, &scope, root.path(), patch)?;
        let reply = call(&mut peer, &scope, "edit/prepare", ticket(&id))?;
        assert_eq!(reply["error"]["data"]["status"], status, "{reply}");
        assert_eq!(cwd.exists(), runs);
        if runs {
            assert!(!Path::new(std::fs::read_to_string(&cwd)?.trim()).exists());
        }
        assert_eq!(
            std::fs::read_to_string(root.path().join("source"))?,
            "same\nsame\n"
        );
    }
    Ok(())
}

#[test]
fn named_live_captures_support_editor_coding_preserve_literal_bom_and_reject_foreign_documents()
-> TestResult {
    let root = tempfile::tempdir()?;
    let source = root.path().join("source");
    std::fs::write(&source, [0xE7, 0x61, 0x0A])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let patch = "--- a/source\n+++ b/source\n@@ -1 +1 @@\n-\u{feff}ça\n+\u{feff}new\n";
    let id = inspect(&mut peer, &scope, root.path(), patch)?;
    let metadata = json!({"id":"editor_document_12345678-1234-4234-8234-123456789abc","tick":3,"bytes":"\u{feff}ça\n".len(),
        "coding":"iso-latin-1-unix","dirty":false,"read_only":false,"disk":disk(&source)?});
    for (path, dirty) in [("foreign", false), ("source", true)] {
        let mut document = metadata.clone();
        document["dirty"] = json!(dirty);
        let mut args = ticket(&id);
        args["path"] = json!(path);
        args["document"] = document;
        assert!(
            call(&mut peer, &scope, "edit/document", args)?
                .get("error")
                .is_some()
        );
    }
    let mut args = ticket(&id);
    args["path"] = json!("source");
    args["document"] = metadata.clone();
    let reply = call(&mut peer, &scope, "edit/document", args.clone())?;
    let part = reply["result"]["part"].as_str().ok_or("part")?;
    assert_eq!(
        call(&mut peer, &scope, "edit/document", args)?["error"]["data"]["status"],
        "invalid_params"
    );
    assert!(
        call(&mut peer, &scope, "edit/prepare", ticket(&id))?
            .get("error")
            .is_some()
    );
    upload(&mut peer, &scope, &id, part, "\u{feff}ça\n")?;
    let reply = call(&mut peer, &scope, "edit/prepare", ticket(&id))?;
    assert_eq!(reply["result"]["batch"], true, "{reply}");
    assert_eq!(page(&mut peer, &scope, &id, 0, "base")?, "\u{feff}ça\n");
    assert_eq!(
        page(&mut peer, &scope, &id, 0, "proposed")?,
        "\u{feff}new\n"
    );
    assert_eq!(
        files(&mut peer, &scope, &id, "edit/files")?[0]["document"],
        metadata
    );
    assert_eq!(std::fs::read(&source)?, [0xE7, 0x61, 0x0A]);
    Ok(())
}

#[test]
fn cancellation_retains_staging_until_supervised_process_tree_and_temp_workspace_drain()
-> TestResult {
    let root = tempfile::tempdir()?;
    std::fs::write(root.path().join("source"), "old\n")?;
    let fixtures = tempfile::tempdir()?;
    let bin = fixtures.path().join("bin");
    let cwd = fixtures.path().join("cwd");
    wrapper(
        &bin,
        &format!(
            "trap '' TERM\npwd > {}\nwhile :; do /bin/sleep 1; done",
            shell_quote(&cwd)
        ),
    )?;
    let mut peer = Peer::start_with_path(Some(&bin))?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let id = inspect(
        &mut peer,
        &scope,
        root.path(),
        "--- a/source\n+++ b/source\n@@ -1 +1 @@\n-old\n+new\n",
    )?;
    request(&mut peer, &scope, "pending", "edit/prepare", ticket(&id))?;
    wait_file(&cwd)?;
    assert!(
        !Path::new(std::fs::read_to_string(&cwd)?.trim())
            .join(".git/index")
            .exists()
    );
    let reply = call(&mut peer, &scope, "edit/abort", ticket(&id))?;
    assert_eq!(reply["result"]["aborted"], true);
    let next = json!({"origin_id":ORIGIN,"root":root.path(),"mode":"agent","live":null,"intent":{"kind":"write","path":"next","new_bytes":0},"config_revision":0,"policy_revision":0,"review_mode":"auto","save_policy":"save"});
    assert_eq!(
        call(&mut peer, &scope, "edit/begin", next.clone())?["error"]["data"]["status"],
        "resource_limit"
    );
    peer.send(json!({"jsonrpc":"2.0","id":"ping","method":"ping"}))?;
    assert_eq!(peer.read()?["id"], "ping");
    let reply = peer.read()?;
    assert_eq!(reply["id"], "pending");
    assert_eq!(reply["error"]["data"]["status"], "cancelled", "{reply}");
    assert!(!Path::new(std::fs::read_to_string(&cwd)?.trim()).exists());
    assert!(call(&mut peer, &scope, "edit/begin", next)?["result"]["preparation_id"].is_string());
    assert_eq!(
        std::fs::read_to_string(root.path().join("source"))?,
        "old\n"
    );
    Ok(())
}

#[test]
fn source_changed_during_git_is_a_conflict_and_private_attributes_neutralize_project_and_global_filters()
-> TestResult {
    let root = tempfile::tempdir()?;
    std::fs::write(root.path().join("source"), "old\n")?;
    std::fs::write(
        root.path().join(".gitattributes"),
        "* filter=attack working-tree-encoding=UTF-16 ident text eol=crlf\n",
    )?;
    let fixtures = tempfile::tempdir()?;
    let bin = fixtures.path().join("bin");
    let cwd = fixtures.path().join("cwd");
    let gate = fixtures.path().join("gate");
    let marker = fixtures.path().join("executed");
    let config = fixtures.path().join("config");
    std::fs::write(
        &config,
        format!(
            "[filter \"attack\"]\nclean = /bin/sh -c 'echo bad > {}; cat'\nsmudge = /bin/sh -c 'echo bad > {}; cat'\nrequired = true\n",
            marker.display(),
            marker.display()
        ),
    )?;
    wrapper(
        &bin,
        &format!(
            "pwd > {}\nwhile [ ! -f {} ]; do /bin/sleep .01; done\nexec {} \"$@\"",
            shell_quote(&cwd),
            shell_quote(&gate),
            shell_quote(&git_program()?)
        ),
    )?;
    let mut peer = Peer::start_with_path_and_environment(
        Some(&bin),
        &[("GIT_CONFIG_GLOBAL", config.as_os_str())],
    )?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let patch = "--- a/source\n+++ b/source\n@@ -1 +1 @@\n-old\n+new\n--- a/.gitattributes\n+++ b/.gitattributes\n@@ -1 +1 @@\n-* filter=attack working-tree-encoding=UTF-16 ident text eol=crlf\n+* filter=attack working-tree-encoding=UTF-16 text eol=crlf\n";
    for changed in [false, true] {
        if gate.exists() {
            std::fs::remove_file(&gate)?;
        }
        if cwd.exists() {
            std::fs::remove_file(&cwd)?;
        }
        let id = inspect(&mut peer, &scope, root.path(), patch)?;
        request(&mut peer, &scope, "pending", "edit/prepare", ticket(&id))?;
        wait_file(&cwd)?;
        if changed {
            std::fs::write(root.path().join("source"), "foreign later\n")?;
        }
        std::fs::write(&gate, "")?;
        let reply = peer.read()?;
        assert_eq!(reply["id"], "pending");
        if changed {
            assert_eq!(reply["error"]["data"]["status"], "conflict", "{reply}");
        } else {
            assert_eq!(reply["result"]["batch"], true, "{reply}");
            assert_eq!(page(&mut peer, &scope, &id, 0, "proposed")?, "new\n");
            call(&mut peer, &scope, "edit/abort", ticket(&id))?;
        }
        assert!(!marker.exists());
        assert!(!Path::new(std::fs::read_to_string(&cwd)?.trim()).exists());
    }
    assert_eq!(
        std::fs::read_to_string(root.path().join("source"))?,
        "foreign later\n"
    );
    Ok(())
}

#[test]
fn all_256_targets_and_batch_descriptors_are_complete_bounded_pages() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.send(json!({"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocol_major":1,"protocol_minor":0,
        "client_version":"test","capabilities":[],"limits":{"max_frame_bytes":2048}}}))?;
    assert_eq!(peer.read()?["result"]["limits"]["max_frame_bytes"], 2048);
    peer.send(json!({"jsonrpc":"2.0","method":"initialized"}))?;
    let scope = peer.scope()?;
    let mut patch = String::new();
    for n in 0..256 {
        patch.push_str(&format!(
            "--- /dev/null\n+++ b/file{n:03}\n@@ -0,0 +1 @@\n+new\n"
        ));
        if n == 255 {
            patch.push_str("\\ No newline at end of file\n");
        }
    }
    let id = inspect(&mut peer, &scope, root.path(), &patch)?;
    let targets = files(&mut peer, &scope, &id, "edit/targets")?;
    assert_eq!(targets.len(), 256);
    let reply = call(&mut peer, &scope, "edit/prepare", ticket(&id))?;
    assert_eq!(reply["result"]["file_count"], 256, "{reply}");
    assert_eq!(reply["result"]["hunks_total"], 256);
    let views = files(&mut peer, &scope, &id, "edit/files")?;
    assert_eq!(views.len(), 256);
    assert_eq!(views[255]["file"], 255);
    assert_eq!(views[255]["requested_path"], "file255");
    assert_eq!(page(&mut peer, &scope, &id, 255, "proposed")?, "new");
    assert_eq!(std::fs::read_dir(root.path())?.count(), 0);
    Ok(())
}

#[test]
fn aggregate_and_expanding_output_bounds_never_publish_partial_batches() -> TestResult {
    let root = tempfile::tempdir()?;
    let fixtures = tempfile::tempdir()?;
    let bin = fixtures.path().join("bin");
    let cwd = fixtures.path().join("cwd");
    wrapper(
        &bin,
        &format!(
            "pwd > {}\nexec {} \"$@\"",
            shell_quote(&cwd),
            shell_quote(&git_program()?)
        ),
    )?;
    let mut peer = Peer::start_with_path(Some(&bin))?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let text = format!("{}\nold\n", "x".repeat(2200000));
    let mut patch = String::new();
    for n in 0..4 {
        std::fs::write(root.path().join(format!("file{n}")), &text)?;
        patch.push_str(&format!(
            "--- a/file{n}\n+++ b/file{n}\n@@ -2 +2 @@\n-old\n+new\n"
        ));
    }
    let id = inspect(&mut peer, &scope, root.path(), &patch)?;
    assert_eq!(
        call(&mut peer, &scope, "edit/prepare", ticket(&id))?["error"]["data"]["status"],
        "resource_limit"
    );
    assert!(!Path::new(std::fs::read_to_string(&cwd)?.trim()).exists());
    for n in 0..4 {
        assert_eq!(
            std::fs::read_to_string(root.path().join(format!("file{n}")))?,
            text
        );
    }
    std::fs::write(
        root.path().join("expand"),
        format!("{}\n", "x".repeat(3000000)),
    )?;
    let patch = format!(
        "--- a/expand\n+++ b/expand\n@@ -1,0 +2 @@\n+{}\n",
        "y".repeat(3000000)
    );
    let id = inspect(&mut peer, &scope, root.path(), &patch)?;
    assert_eq!(
        call(&mut peer, &scope, "edit/prepare", ticket(&id))?["error"]["data"]["status"],
        "resource_limit"
    );
    assert!(!Path::new(std::fs::read_to_string(&cwd)?.trim()).exists());
    assert_eq!(
        std::fs::metadata(root.path().join("expand"))?.len(),
        3000001
    );
    Ok(())
}

#[test]
fn missing_git_is_explicit_and_unstarted_private_workspace_is_cleaned() -> TestResult {
    let root = tempfile::tempdir()?;
    std::fs::write(root.path().join("source"), "old\n")?;
    let bin = tempfile::tempdir()?;
    let temporary = tempfile::tempdir()?;
    let mut peer = Peer::start_with_path_and_environment(
        Some(bin.path()),
        &[("TMPDIR", temporary.path().as_os_str())],
    )?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let id = inspect(
        &mut peer,
        &scope,
        root.path(),
        "--- a/source\n+++ b/source\n@@ -1 +1 @@\n-old\n+new\n",
    )?;
    assert_eq!(
        call(&mut peer, &scope, "edit/prepare", ticket(&id))?["error"]["data"]["status"],
        "unavailable"
    );
    assert_eq!(std::fs::read_dir(temporary.path())?.count(), 0);
    assert_eq!(
        std::fs::read_to_string(root.path().join("source"))?,
        "old\n"
    );
    Ok(())
}

#[test]
fn empty_patch_add_with_live_buffer_is_an_effect_only_when_save_requires_creation() -> TestResult {
    for save in ["save", "buffer_only"] {
        let root = tempfile::tempdir()?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let patch = "--- /dev/null\n+++ b/empty\n";
        let id=call(&mut peer,&scope,"edit/begin",json!({"origin_id":ORIGIN,"root":root.path(),"mode":"agent","intent":{"kind":"patch","patch_bytes":patch.len()},"live":null,"config_revision":0,"policy_revision":0,"review_mode":"auto","save_policy":save}))?["result"]["preparation_id"].clone();
        assert!(id.is_string());
        upload(&mut peer, &scope, &id, "patch", patch)?;
        let inspected = call(&mut peer, &scope, "edit/inspect", ticket(&id))?;
        assert_eq!(inspected["result"]["inspected"], true, "{inspected}");
        let document = json!({"id":"editor_document_12345678-1234-4234-8234-123456789abc","tick":1,"bytes":0,"coding":"utf-8-unix","dirty":false,"read_only":false,"disk":{"kind":"absent"}});
        let attached = call(
            &mut peer,
            &scope,
            "edit/document",
            json!({"origin_id":ORIGIN,"preparation_id":id,"path":"empty","document":document}),
        )?;
        assert!(attached.get("result").is_some(), "{attached}");
        let prepared = call(&mut peer, &scope, "edit/prepare", ticket(&id))?;
        assert_eq!(prepared["result"]["file_count"], 1, "{prepared}");
        let page = call(
            &mut peer,
            &scope,
            "edit/files",
            json!({"origin_id":ORIGIN,"preparation_id":id,"offset":0}),
        )?;
        let file = &page["result"]["files"][0];
        assert_eq!(file["operation"], "add");
        assert_eq!(file["hunks_total"], 0);
        assert_eq!(
            file["unchanged"],
            save == "buffer_only",
            "save={save}: {page}"
        );
        assert!(!root.path().join("empty").exists());
        peer.input.take();
        assert!(peer.wait()?);
    }
    Ok(())
}
