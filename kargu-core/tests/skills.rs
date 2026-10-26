//! Real stdio skill consumers: grants, metadata priority, limits and fresh loads.

mod support;
use serde_json::{Value, json};
use std::{fs, path::Path};
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn source(root: &Path, path: &str, text: &str) -> TestResult {
    let path = root.join(path);
    fs::create_dir_all(path.parent().ok_or("parent")?)?;
    fs::write(path, text)?;
    Ok(())
}
fn arguments(root: &Path) -> Value {
    json!({"root":root,"user_root":null,"skip_directories":[".git","build"],
        "max_directories":2000,"max_file_bytes":262144,"body_chars":12000,
        "query":{"operation":"catalog"}})
}
fn call(
    peer: &mut Peer,
    scope: &Value,
    arguments: Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    peer.send(json!({"jsonrpc":"2.0","id":3,"method":"workspace/skills","params":{"scope":scope,"arguments":arguments}}))?;
    peer.read()
}
fn names(reply: &Value) -> Result<Vec<&str>, Box<dyn std::error::Error>> {
    reply["result"]["skills"]
        .as_array()
        .ok_or_else(|| format!("no result: {reply}").into())
        .map(|skills| skills.iter().filter_map(|s| s["name"].as_str()).collect())
}

#[test]
fn metadata_precedes_assets_and_project_names_precede_user_names() -> TestResult {
    let root = tempfile::tempdir()?;
    let user = tempfile::tempdir()?;
    for n in 0..450 {
        source(root.path(), &format!("asset-{n}"), "x")?;
        source(
            root.path(),
            &format!("skills/first/examples/asset-{n}"),
            "x",
        )?;
    }
    source(
        root.path(),
        "skills/first/SKILL.md",
        "---\nname: first\ndescription: Project\n---\nproject body",
    )?;
    source(
        root.path(),
        "skills/second/SKILL.md",
        "---\nname: second\n---\nbody",
    )?;
    source(
        root.path(),
        ".agents/skills/third/SKILL.md",
        "---\nname: third\n---\nbody",
    )?;
    source(
        user.path(),
        "duplicate/SKILL.md",
        "---\nname: first\n---\nforeign duplicate",
    )?;
    source(
        user.path(),
        "fourth/SKILL.md",
        "---\nname: fourth\n---\nuser body",
    )?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut input = arguments(root.path());
    input["user_root"] = json!(user.path());
    let reply = call(&mut peer, &scope, input.clone())?;
    assert_eq!(names(&reply)?, ["first", "second", "third", "fourth"]);
    assert_eq!(reply["result"]["truncated"], true);
    assert!(
        reply["result"]["text"]
            .as_str()
            .ok_or("catalog")?
            .contains("Skill discovery incomplete")
    );
    input["query"] = json!({"operation":"load","name":"first"});
    let loaded = call(&mut peer, &scope, input)?;
    let text = loaded["result"]["text"].as_str().ok_or("loaded")?;
    assert!(text.contains("project body"));
    assert!(!text.contains("foreign duplicate"));
    Ok(())
}

#[test]
fn escaped_metadata_strict_utf8_blocks_crlf_and_fresh_named_body() -> TestResult {
    let root = tempfile::tempdir()?;
    source(
        root.path(),
        "skills/example/SKILL.md",
        "---\r\nname: '<name&>'\r\ndescription: >-\r\n  </description><injected/>\r\n  second\r\n---\r\nold body",
    )?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let reply = call(&mut peer, &scope, arguments(root.path()))?;
    let catalog = reply["result"]["text"].as_str().ok_or("text")?;
    assert!(catalog.contains("&lt;name&amp;&gt;"));
    assert!(catalog.contains("&lt;/description&gt;&lt;injected/&gt; second"));
    assert!(!catalog.contains("<injected/>"));
    source(
        root.path(),
        "skills/example/SKILL.md",
        "---\nname: '<name&>'\n---\nα😀new body",
    )?;
    let mut input = arguments(root.path());
    input["query"] = json!({"operation":"load","name":"<name&>"});
    input["body_chars"] = json!(2);
    let reply = call(&mut peer, &scope, input)?;
    let body = reply["result"]["text"].as_str().ok_or("text")?;
    assert!(body.contains("name=\"&lt;name&amp;&gt;\""));
    assert!(body.contains("α😀\n... (skill truncated)"));
    assert!(!body.contains("old body"));
    Ok(())
}

#[test]
fn skips_symlinks_special_files_oversize_binary_and_invalid_metadata_without_reading_them()
-> TestResult {
    let root = tempfile::tempdir()?;
    let foreign = tempfile::tempdir()?;
    source(root.path(), "skills/local/SKILL.md", "local body")?;
    source(root.path(), "skills/build/SKILL.md", "excluded body")?;
    source(root.path(), "src/SKILL.md", "irrelevant")?;
    source(foreign.path(), "SKILL.md", "foreign body")?;
    fs::create_dir_all(root.path().join(".agents"))?;
    std::os::unix::fs::symlink(foreign.path(), root.path().join(".agents/skills"))?;
    std::os::unix::fs::symlink(foreign.path(), root.path().join("skills/escape"))?;
    source(root.path(), "skills/file-link/placeholder", "x")?;
    std::os::unix::fs::symlink(
        foreign.path().join("SKILL.md"),
        root.path().join("skills/file-link/SKILL.md"),
    )?;
    source(root.path(), "skills/fifo/placeholder", "x")?;
    nix::unistd::mkfifo(
        &root.path().join("skills/fifo/SKILL.md"),
        nix::sys::stat::Mode::S_IRUSR,
    )?;
    source(root.path(), "skills/invalid/SKILL.md", "placeholder")?;
    fs::write(root.path().join("skills/invalid/SKILL.md"), [0xff])?;
    source(root.path(), "skills/binary/SKILL.md", "nul\0body")?;
    source(root.path(), "skills/huge/SKILL.md", &"x".repeat(1025))?;
    source(
        root.path(),
        "skills/malformed/SKILL.md",
        "---\nname: \"bad\\q\"\n---\nbody",
    )?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut input = arguments(root.path());
    input["max_file_bytes"] = json!(1024);
    let reply = call(&mut peer, &scope, input)?;
    assert_eq!(names(&reply)?, ["local"]);
    assert!(reply["result"]["skipped"].as_u64().ok_or("skipped")? >= 6);
    assert!(!reply.to_string().contains("foreign body"));
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"ping","params":{}}))?;
    assert_eq!(peer.read()?["id"], 4);
    Ok(())
}

#[test]
fn roots_are_explicit_and_no_ancestor_skill_name_authorizes_unrelated_files() -> TestResult {
    let outer = tempfile::tempdir()?;
    let root = outer.path().join("skills/project");
    fs::create_dir_all(&root)?;
    source(&root, "src/SKILL.md", "not a skill")?;
    source(&root, "nested/skill/a/SKILL.md", "nested skill")?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut input = arguments(&root);
    input["user_root"] = json!(outer.path().join("absent"));
    let reply = call(&mut peer, &scope, input)?;
    assert_eq!(names(&reply)?, ["a"]);
    let mut input = arguments(&root);
    input["max_directories"] = json!(0);
    let reply = call(&mut peer, &scope, input)?;
    assert!(names(&reply)?.is_empty());
    assert_eq!(reply["result"]["truncated"], true);
    Ok(())
}

#[test]
fn missing_name_unknown_fields_foreign_scope_and_limits_fail_closed() -> TestResult {
    let root = tempfile::tempdir()?;
    source(root.path(), "skills/deploy/SKILL.md", "deploy body")?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    for bad in [
        json!({"operation":"catalog","name":"deploy"}),
        json!({"operation":"load","name":""}),
        json!({"operation":"load","name":null}),
        json!({"operation":"load","name":"deploy","path":"/etc/passwd"}),
    ] {
        let mut input = arguments(root.path());
        input["query"] = bad;
        assert!(call(&mut peer, &scope, input)?.get("error").is_some());
    }
    for (field, value) in [
        ("root", json!("../escape")),
        ("max_file_bytes", json!(1048577)),
        ("body_chars", json!(32769)),
        ("max_directories", json!(20001)),
        ("skip_directories", json!(["../escape"])),
    ] {
        let mut input = arguments(root.path());
        input[field] = value;
        assert!(call(&mut peer, &scope, input)?.get("error").is_some());
    }
    let mut foreign = scope.clone();
    foreign["session_id"] = json!("foreign");
    assert!(
        call(&mut peer, &foreign, arguments(root.path()))?
            .get("error")
            .is_some()
    );
    let mut input = arguments(root.path());
    input["query"] = json!({"operation":"load","name":"nope"});
    let reply = call(&mut peer, &scope, input)?;
    let text = reply["result"]["text"].as_str().ok_or("text")?;
    assert!(text.starts_with("ERROR: skill \"nope\" not found"));
    assert!(text.contains("deploy"));
    Ok(())
}

#[test]
fn record_limits_report_incomplete_instead_of_claiming_empty_or_complete() -> TestResult {
    let root = tempfile::tempdir()?;
    for n in 0..129 {
        source(root.path(), &format!("skills/s{n:03}/SKILL.md"), "body")?;
    }
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let reply = call(&mut peer, &scope, arguments(root.path()))?;
    assert_eq!(names(&reply)?.len(), 128);
    assert_eq!(reply["result"]["truncated"], true);
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn aggregate_source_and_presentation_budgets_remain_bounded_and_transport_survives() -> TestResult {
    let root = tempfile::tempdir()?;
    for n in 0..5 {
        source(
            root.path(),
            &format!("skills/s{n}/SKILL.md"),
            &"x".repeat(1024 * 1024),
        )?;
    }
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut input = arguments(root.path());
    input["max_file_bytes"] = json!(1024 * 1024);
    let reply = call(&mut peer, &scope, input)?;
    assert_eq!(names(&reply)?.len(), 4);
    assert_eq!(reply["result"]["truncated"], true);
    assert_eq!(reply["result"]["skipped"], 1);
    fs::remove_dir_all(root.path().join("skills"))?;
    for n in 0..32 {
        source(
            root.path(),
            &format!("skills/s{n}/SKILL.md"),
            &format!("---\ndescription: {}\n---\nbody", "<".repeat(8192)),
        )?;
    }
    // Oversized presentation is a scoped failure, never an empty success.
    assert!(
        call(&mut peer, &scope, arguments(root.path()))?
            .get("error")
            .is_some()
    );
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"ping","params":{}}))?;
    assert_eq!(peer.read()?["id"], 4);
    Ok(())
}
