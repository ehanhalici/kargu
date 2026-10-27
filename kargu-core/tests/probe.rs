//! Declarative project probes and executable presence never execute a binary.
mod support;
use serde_json::{Value, json};
use std::{fs, os::unix::fs::PermissionsExt, path::Path};
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;
fn input(root: &Path) -> Value {
    json!({"root":root,"profiles":[
    {"id":"typescript","name":"TypeScript","priority":86,"detectors":[{"kind":"path","path":"tsconfig.json"}],"toolchain":{"kind":"javascript","typescript":true}},
    {"id":"javascript","name":"JavaScript","priority":85,"detectors":[{"kind":"path","path":"package.json"}],"toolchain":{"kind":"javascript","typescript":false}},
    {"id":"java","name":"Java","priority":75,"detectors":[{"kind":"path","path":"pom.xml"},{"kind":"path","path":"build.gradle"}],"toolchain":{"kind":"java"}},
    {"id":"golang","name":"Go","priority":90,"detectors":[{"kind":"extension","extensions":["go"],"recursive":true}],"toolchain":{"kind":"static","commands":{"build_cmd":"go build ./...","test_cmd":"go test ./...","lint_cmd":null,"notes":null}}},
    {"id":"emacs-lisp","name":"Emacs Lisp","priority":10,"detectors":[{"kind":"extension","extensions":["el"],"recursive":false}],"toolchain":{"kind":"elisp"}}
    ],"executables":["present","missing"],"search_path":[root],"skip_directories":["vendor",".git"],"max_files":2000,"max_directories":2000})
}
fn call(peer: &mut Peer, scope: &Value, args: Value) -> Result<Value, Box<dyn std::error::Error>> {
    peer.send(json!({"jsonrpc":"2.0","id":3,"method":"workspace/probe","params":{"scope":scope,"arguments":args}}))?;
    peer.read()
}
#[test]
fn profiles_priority_scripts_and_lockfile_selection_are_native_and_do_not_run_scripts() -> TestResult
{
    let root = tempfile::tempdir()?;
    fs::write(
        root.path().join("package.json"),
        r#"{"scripts":{"build":"echo synthetic-secret","test":"x","lint":" "}}"#,
    )?;
    fs::write(root.path().join("yarn.lock"), "")?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let reply = call(&mut peer, &scope, input(root.path()))?;
    assert_eq!(reply["result"]["language"], "javascript");
    assert_eq!(
        reply["result"]["toolchains"]["javascript"]["build_cmd"],
        "yarn run build"
    );
    assert_eq!(
        reply["result"]["toolchains"]["javascript"]["test_cmd"],
        "yarn test"
    );
    assert!(reply["result"]["toolchains"]["javascript"]["lint_cmd"].is_null());
    assert!(!reply.to_string().contains("synthetic-secret"));
    fs::write(root.path().join("tsconfig.json"), "{}")?;
    fs::write(root.path().join("pnpm-lock.yaml"), "")?;
    let reply = call(&mut peer, &scope, input(root.path()))?;
    assert_eq!(reply["result"]["language"], "typescript");
    assert_eq!(
        reply["result"]["toolchains"]["typescript"]["build_cmd"],
        "pnpm run build"
    );
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}
#[test]
fn executable_discovery_and_special_metadata_never_start_programs_or_open_fifos() -> TestResult {
    let root = tempfile::tempdir()?;
    let marker = root.path().join("marker");
    let program = root.path().join("present");
    fs::write(
        &program,
        format!("#!/bin/sh\ntouch '{}'\n", marker.display()),
    )?;
    fs::set_permissions(&program, fs::Permissions::from_mode(0o700))?;
    nix::unistd::mkfifo(
        &root.path().join("package.json"),
        nix::sys::stat::Mode::S_IRUSR,
    )?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let reply = call(&mut peer, &scope, input(root.path()))?;
    assert_eq!(reply["result"]["executables"]["present"], true);
    assert_eq!(reply["result"]["executables"]["missing"], false);
    assert!(!marker.exists());
    fs::set_permissions(&program, fs::Permissions::from_mode(0o600))?;
    let reply = call(&mut peer, &scope, input(root.path()))?;
    assert_eq!(reply["result"]["executables"]["present"], false);
    assert!(!marker.exists());
    Ok(())
}
#[test]
fn nested_extensions_ignore_exclusions_and_elisp_runner_is_not_invented() -> TestResult {
    let root = tempfile::tempdir()?;
    fs::create_dir_all(root.path().join("vendor"))?;
    fs::write(root.path().join("vendor/a.go"), "")?;
    fs::write(root.path().join("a.el"), "(message \"test\")")?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let reply = call(&mut peer, &scope, input(root.path()))?;
    assert_eq!(reply["result"]["language"], "emacs-lisp");
    assert!(reply["result"]["toolchains"]["emacs-lisp"]["test_cmd"].is_null());
    fs::create_dir_all(root.path().join("src/deep"))?;
    fs::write(root.path().join("src/deep/a.go"), "")?;
    fs::create_dir_all(root.path().join("tests"))?;
    fs::write(root.path().join("tests/run-tests.el"), "native runner")?;
    let reply = call(&mut peer, &scope, input(root.path()))?;
    assert_eq!(reply["result"]["language"], "golang");
    assert!(
        reply["result"]["toolchains"]["emacs-lisp"]["test_cmd"]
            .as_str()
            .ok_or("runner")?
            .contains("tests/run-tests.el")
    );
    Ok(())
}
#[test]
fn invalid_limits_paths_and_foreign_owner_fail_without_any_probe_effect() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    for (key, value) in [
        ("max_files", json!(20001)),
        ("search_path", json!(["relative"])),
        ("skip_directories", json!(["../outside"])),
    ] {
        let mut args = input(root.path());
        args[key] = value;
        assert!(call(&mut peer, &scope, args)?.get("error").is_some());
    }
    let mut args = input(root.path());
    args["profiles"][0]["detectors"] = json!([{"kind":"path","path":"../outside"}]);
    assert!(call(&mut peer, &scope, args)?.get("error").is_some());
    let mut foreign = scope.clone();
    foreign["session_id"] = json!("foreign");
    assert!(
        call(&mut peer, &foreign, input(root.path()))?
            .get("error")
            .is_some()
    );
    Ok(())
}

#[test]
fn truncated_or_malformed_discovery_is_explicit_and_profiles_have_unique_identities() -> TestResult
{
    let root = tempfile::tempdir()?;
    fs::write(root.path().join("package.json"), "{ malformed")?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let reply = call(&mut peer, &scope, input(root.path()))?;
    assert_eq!(reply["result"]["complete"], false);
    fs::write(root.path().join("package.json"), vec![b' '; 262145])?;
    assert_eq!(
        call(&mut peer, &scope, input(root.path()))?["result"]["complete"],
        false
    );
    fs::remove_file(root.path().join("package.json"))?;
    fs::create_dir_all(root.path().join("src/deep"))?;
    fs::write(root.path().join("src/deep/a.go"), "")?;
    let mut arguments = input(root.path());
    arguments["max_directories"] = json!(0);
    assert_eq!(
        call(&mut peer, &scope, arguments)?["result"]["complete"],
        false
    );
    let mut arguments = input(root.path());
    arguments["profiles"][1]["id"] = json!("typescript");
    assert!(call(&mut peer, &scope, arguments)?.get("error").is_some());
    Ok(())
}
