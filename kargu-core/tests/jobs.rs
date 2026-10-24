//! Real-pipe persistent jobs: startup, ownership, stdin, output and drain.

mod support;
use serde_json::{Value, json};
use std::{
    path::Path,
    time::{Duration, Instant},
};
use support::Peer;

type TestResult = Result<(), Box<dyn std::error::Error>>;

fn owner(scope: &Value, root: &Path) -> Value {
    json!({"scope":scope,"root":root})
}
fn arguments(root: &Path, script: &str) -> Result<Value, Box<dyn std::error::Error>> {
    let paths = std::env::var_os("PATH").ok_or("PATH missing")?;
    let shell = std::env::split_paths(&paths)
        .map(|p| p.join("sh"))
        .find(|p| p.is_file())
        .ok_or("sh missing")?;
    Ok(
        json!({"root":root,"mode":"agent","program":shell,"arguments":["-c",script],
        "cwd":null,"timeout_ms":null,"environment":{},"config_revision":1,"policy_revision":1}),
    )
}
fn start(
    peer: &mut Peer,
    scope: &Value,
    root: &Path,
    script: &str,
) -> Result<Value, Box<dyn std::error::Error>> {
    start_arguments(peer, scope, arguments(root, script)?)
}
fn start_arguments(
    peer: &mut Peer,
    scope: &Value,
    arguments: Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    peer.send(json!({"jsonrpc":"2.0","id":3,"method":"job/start","params":{"scope":scope,"arguments":arguments}}))?;
    let review = peer.read()?;
    assert_eq!(review["method"], "editor/request_approval");
    assert_eq!(review["params"]["scope"]["purpose"], "process_job");
    peer.send(json!({"jsonrpc":"2.0","id":review["id"],"result":{"approved":true}}))?;
    let reply = peer.read()?;
    assert_eq!(reply["id"], 3);
    assert!(reply.get("error").is_none(), "{reply}");
    let job = reply["result"].clone();
    let bound = owner(
        scope,
        arguments
            .get("root")
            .and_then(Value::as_str)
            .map(Path::new)
            .ok_or("root missing")?,
    );
    assert_eq!(
        call(peer, "job/claim", query(&bound, &job))?["result"]["claimed"],
        true
    );
    Ok(job)
}
fn call(peer: &mut Peer, method: &str, params: Value) -> Result<Value, Box<dyn std::error::Error>> {
    peer.send(json!({"jsonrpc":"2.0","id":20,"method":method,"params":params}))?;
    response(peer, 20)
}
fn response(peer: &Peer, expected: i64) -> Result<Value, Box<dyn std::error::Error>> {
    loop {
        let reply = peer.read()?;
        if reply["id"] == expected {
            return Ok(reply);
        }
        let id = reply["id"].as_i64().ok_or("unexpected response")?;
        assert!(
            (100..104).contains(&id),
            "unexpected unrelated reply {reply}"
        );
        if reply.get("error").is_some() {
            assert_eq!(reply["error"]["data"]["status"], "outcome_unknown");
        }
    }
}
fn query(bound: &Value, job: &Value) -> Value {
    json!({"owner":bound,"job_id":job["job_id"]})
}
fn exited(
    peer: &mut Peer,
    bound: &Value,
    job: &Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    let until = Instant::now() + Duration::from_secs(8);
    loop {
        let reply = call(peer, "job/status", query(bound, job))?;
        assert!(reply.get("error").is_none(), "{reply}");
        if reply["result"]["state"] == "exited" {
            return Ok(reply["result"].clone());
        }
        if Instant::now() >= until {
            return Err("job did not drain".into());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
fn output(
    peer: &mut Peer,
    bound: &Value,
    job: &Value,
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let mut cursor = 0_u64;
    let mut output = Vec::new();
    loop {
        let reply = call(
            peer,
            "job/read",
            json!({"owner":bound,"job_id":job["job_id"],"stream":"stdout","cursor":cursor}),
        )?;
        assert!(reply.get("error").is_none(), "{reply}");
        output.extend(serde_json::from_value::<Vec<u8>>(
            reply["result"]["data"].clone(),
        )?);
        let next = reply["result"]["next_cursor"]
            .as_u64()
            .ok_or("cursor missing")?;
        if next == cursor {
            return Ok(output);
        }
        cursor = next;
    }
}

#[test]
fn unlimited_interactive_start_write_eof_and_lossless_output() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let bound = owner(&scope, root.path());
    let job = start(
        &mut peer,
        &scope,
        root.path(),
        "printf ready; while IFS= read -r line; do printf '%s\\n' \"$line\"; done; printf closed",
    )?;
    assert_eq!(job["state"], "awaiting_claim");
    assert_eq!(
        call(
            &mut peer,
            "job/write",
            json!({"owner":bound,"job_id":job["job_id"],"text":"hello😀\n"})
        )?["result"]["accepted"],
        true
    );
    assert_eq!(
        call(&mut peer, "job/eof", query(&bound, &job))?["result"]["accepted"],
        true
    );
    assert_eq!(exited(&mut peer, &bound, &job)?["result"]["outcome"], "ok");
    assert_eq!(
        output(&mut peer, &bound, &job)?,
        "readyhello😀\nclosed".as_bytes()
    );
    assert_eq!(
        call(&mut peer, "job/forget", query(&bound, &job))?["result"]["forgotten"],
        true
    );
    assert_eq!(
        call(&mut peer, "job/status", query(&bound, &job))?["error"]["data"]["status"],
        "stale_owner"
    );
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn sibling_jobs_and_foreground_command_keep_independent_claims() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let bound = owner(&scope, root.path());
    let first = start(&mut peer, &scope, root.path(), "read value")?;
    let second = start(&mut peer, &scope, root.path(), "read value")?;
    let mut command = arguments(root.path(), "printf foreground")?;
    command["timeout_ms"] = json!(1000);
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"tool/execute","params":{"scope":scope,"arguments":command}}))?;
    let approval = peer.read()?;
    assert_eq!(approval["method"], "editor/request_approval");
    assert_eq!(approval["params"]["scope"]["purpose"], "agent_turn");
    peer.send(json!({"jsonrpc":"2.0","id":approval["id"],"result":{"approved":true}}))?;
    assert_eq!(peer.read()?["result"]["stdout"], "foreground");
    assert_eq!(
        call(&mut peer, "job/list", json!({"owner":bound}))?["result"]["jobs"]
            .as_array()
            .ok_or("jobs missing")?
            .len(),
        2
    );
    call(&mut peer, "job/eof", query(&bound, &first))?;
    exited(&mut peer, &bound, &first)?;
    assert_eq!(
        call(&mut peer, "job/status", query(&bound, &second))?["result"]["state"],
        "running"
    );
    call(&mut peer, "job/eof", query(&bound, &second))?;
    exited(&mut peer, &bound, &second)?;
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn project_and_session_job_authority_cannot_be_borrowed() -> TestResult {
    let root = tempfile::tempdir()?;
    let foreign = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let bound = owner(&scope, root.path());
    let job = start(&mut peer, &scope, root.path(), "read value")?;
    peer.send(json!({"jsonrpc":"2.0","id":5,"method":"session/create","params":{"application_id":scope["application_id"]}}))?;
    let other = peer.read()?["result"].clone();
    for wrong in [owner(&scope, foreign.path()), owner(&other, root.path())] {
        for method in ["job/status", "job/cancel", "job/forget", "job/eof"] {
            assert_eq!(
                call(&mut peer, method, query(&wrong, &job))?["error"]["data"]["status"],
                "stale_owner"
            );
        }
        assert_eq!(
            call(&mut peer, "job/list", json!({"owner":wrong}))?["result"]["jobs"],
            json!([])
        );
        assert_eq!(
            call(
                &mut peer,
                "job/write",
                json!({"owner":wrong,"job_id":job["job_id"],"text":"injected"})
            )?["error"]["data"]["status"],
            "stale_owner"
        );
    }
    assert_eq!(
        call(&mut peer, "job/forget", query(&bound, &job))?["error"]["data"]["status"],
        "busy"
    );
    call(&mut peer, "job/eof", query(&bound, &job))?;
    exited(&mut peer, &bound, &job)?;
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn application_job_capacity_is_reusable_only_after_real_completion() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let bound = owner(&scope, root.path());
    let mut jobs = Vec::new();
    for _ in 0..4 {
        jobs.push(start(&mut peer, &scope, root.path(), "read value")?);
    }
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"job/start","params":{"scope":scope,"arguments":arguments(root.path(),"read value")?}}))?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "resource_limit");
    let first = jobs.first().ok_or("job missing")?;
    call(&mut peer, "job/eof", query(&bound, first))?;
    exited(&mut peer, &bound, first)?;
    let replacement = start(&mut peer, &scope, root.path(), "printf replacement")?;
    assert_eq!(
        exited(&mut peer, &bound, &replacement)?["result"]["outcome"],
        "ok"
    );
    for job in jobs.iter().skip(1) {
        call(&mut peer, "job/eof", query(&bound, job))?;
        exited(&mut peer, &bound, job)?;
    }
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn owner_close_and_shutdown_reap_all_jobs_before_the_shutdown_reply() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let first = start(&mut peer, &scope, root.path(), "read value")?;
    let second = start(&mut peer, &scope, root.path(), "read value")?;
    call(&mut peer, "session/close", scope.clone())?;
    peer.send(json!({"jsonrpc":"2.0","id":30,"method":"shutdown"}))?;
    assert_eq!(peer.read()?["id"], 30);
    for job in [first, second] {
        let pid = job["process_id"].as_u64().ok_or("process id missing")?;
        assert!(!Path::new(&format!("/proc/{pid}")).exists());
    }
    peer.send(json!({"jsonrpc":"2.0","method":"exit"}))?;
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn configured_and_zero_tail_capacity_are_bound_before_approval() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let bound = owner(&scope, root.path());
    for limit in [0, 256, 4_000_000] {
        let script = format!("printf '%s' '{}final-marker'", "x".repeat(700));
        let mut args = arguments(root.path(), &script)?;
        args["output_bytes"] = json!(limit);
        let job = start_arguments(&mut peer, &scope, args)?;
        assert_eq!(exited(&mut peer, &bound, &job)?["result"]["outcome"], "ok");
        let retained = output(&mut peer, &bound, &job)?;
        assert!(retained.len() <= limit);
        if limit > 0 {
            assert!(retained.ends_with(b"final-marker"));
        }
        call(&mut peer, "job/forget", query(&bound, &job))?;
    }
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn explicit_merged_stderr_is_one_ordered_os_pipe() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let bound = owner(&scope, root.path());
    let mut args = arguments(root.path(), "printf out; printf err >&2; printf done")?;
    args["stderr"] = json!("merge");
    let job = start_arguments(&mut peer, &scope, args)?;
    assert_eq!(exited(&mut peer, &bound, &job)?["result"]["outcome"], "ok");
    assert_eq!(output(&mut peer, &bound, &job)?, b"outerrdone");
    let stderr = call(
        &mut peer,
        "job/read",
        json!({"owner":bound,"job_id":job["job_id"],"stream":"stderr","cursor":0}),
    )?;
    assert_eq!(stderr["result"]["data"], json!([]));
    assert_eq!(stderr["result"]["eof"], true);
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn unclaimed_job_is_revoked_and_reaped_without_losing_connection() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let bound = owner(&scope, root.path());
    peer.send(json!({"jsonrpc":"2.0","id":3,"method":"job/start","params":{"scope":scope,"arguments":arguments(root.path(),"read value")?}}))?;
    let review = peer.read()?;
    peer.send(json!({"jsonrpc":"2.0","id":review["id"],"result":{"approved":true}}))?;
    let job = peer.read()?["result"].clone();
    let until = Instant::now() + Duration::from_secs(12);
    loop {
        let reply = call(&mut peer, "job/status", query(&bound, &job))?;
        if reply.get("error").is_some() {
            assert_eq!(reply["error"]["data"]["status"], "stale_owner");
            break;
        }
        if Instant::now() >= until {
            return Err("unclaimed job was not reaped".into());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let pid = job["process_id"].as_u64().ok_or("pid missing")?;
    assert!(!Path::new(&format!("/proc/{pid}")).exists());
    assert_eq!(
        call(&mut peer, "ping", json!({}))?["result"]["status"],
        "ok"
    );
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn blocked_stdin_does_not_block_the_mailbox_or_cancel_its_job() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let bound = owner(&scope, root.path());
    let mut args = arguments(root.path(), "sleep 30")?;
    args["environment"] = json!({"PATH":std::env::var("PATH")?});
    let job = start_arguments(&mut peer, &scope, args)?;
    let text = "x".repeat(32768);
    for id in 100..104 {
        peer.send(json!({"jsonrpc":"2.0","id":id,"method":"job/write","params":{"owner":bound,"job_id":job["job_id"],"text":text}}))?;
    }
    peer.send(json!({"jsonrpc":"2.0","id":200,"method":"ping"}))?;
    let at = Instant::now();
    assert_eq!(response(&peer, 200)?["result"]["status"], "ok");
    assert!(at.elapsed() < Duration::from_secs(2));
    for id in 100..104 {
        peer.send(json!({"jsonrpc":"2.0","method":"rpc/cancel","params":{"request_id":id,"scope":peer.epoch}}))?;
    }
    assert_eq!(
        call(&mut peer, "job/status", query(&bound, &job))?["result"]["state"],
        "running"
    );
    call(&mut peer, "job/cancel", query(&bound, &job))?;
    assert_eq!(
        exited(&mut peer, &bound, &job)?["result"]["outcome"],
        "cancelled"
    );
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}
