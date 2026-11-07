//! Native ReadTools/provider pipeline cases; sources only until the final gate.
use super::*;

fn tool_reply(id: &str, name: &str, arguments: Value) -> Reply {
    Reply {
        status: 200,
        content_type: "application/json",
        release: None,
        body: json!({"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{
            "id":id,"type":"function","function":{"name":name,"arguments":arguments.to_string()}}]},"finish_reason":"tool_calls"}],
            "usage":{"prompt_tokens":2,"completion_tokens":3}})
        .to_string(),
    }
}

#[test]
fn native_read_tools_execute_find_files_read_file_and_skill_under_parent_run() -> TestResult {
    let root = tempfile::tempdir()?;
    std::fs::create_dir_all(root.path().join("src"))?;
    std::fs::write(
        root.path().join("src/lib.rs"),
        "pub fn alpha() {}\npub fn beta() {}\npub fn gamma() {}\n",
    )?;
    std::fs::create_dir_all(root.path().join("skills/review"))?;
    std::fs::write(
        root.path().join("skills/review/SKILL.md"),
        "---\nname: review\ndescription: Review guidelines\n---\nAlways check invariants.\n",
    )?;
    let (url, server, requests) = server(vec![
        tool_reply("call-find", "find_files", json!({"pattern":"*.rs"})),
        tool_reply(
            "call-read",
            "read_file",
            json!({"file_path":"src/lib.rs","from_line":2,"to_line":2}),
        ),
        tool_reply("call-skill", "skill", json!({"name":"review"})),
        answer("inspection complete"),
    ])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut input = prompt(root.path(), &url);
    input["tools_enabled"] = json!(true);
    input["tool_limit"] = json!(3);
    input["turn_limit"] = json!(5);
    begin(&mut peer, "read-pipeline", &scope, input)?;
    let mut events = Vec::new();
    let terminal = response(&peer, "read-pipeline", &mut events)?;
    assert_eq!(terminal["result"]["status"], "completed");
    assert_eq!(
        terminal["result"]["accounting"]["budget"]["requests_spent"],
        4
    );
    let _first = requests.recv_timeout(Duration::from_secs(2))?;
    let after_find = requests.recv_timeout(Duration::from_secs(2))?;
    let find_msg = after_find["messages"]
        .as_array()
        .ok_or("messages")?
        .last()
        .ok_or("find result")?;
    assert_eq!(find_msg["tool_call_id"], "call-find");
    assert!(
        find_msg["content"]
            .as_str()
            .ok_or("content")?
            .contains("src/lib.rs")
    );
    let after_read = requests.recv_timeout(Duration::from_secs(2))?;
    let read_msg = after_read["messages"]
        .as_array()
        .ok_or("messages")?
        .last()
        .ok_or("read result")?;
    assert_eq!(read_msg["tool_call_id"], "call-read");
    assert!(
        read_msg["content"]
            .as_str()
            .ok_or("content")?
            .contains("2 | pub fn beta() {}")
    );
    let after_skill = requests.recv_timeout(Duration::from_secs(2))?;
    let skill_msg = after_skill["messages"]
        .as_array()
        .ok_or("messages")?
        .last()
        .ok_or("skill result")?;
    assert_eq!(skill_msg["tool_call_id"], "call-skill");
    assert!(
        skill_msg["content"]
            .as_str()
            .ok_or("content")?
            .contains("Always check invariants.")
    );
    let outcomes: Vec<_> = events
        .iter()
        .filter(|event| event["method"] == "session/tool_result")
        .collect();
    assert_eq!(outcomes.len(), 3);
    for outcome in outcomes {
        assert_eq!(outcome["params"]["event"]["outcome"], "ok");
    }
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn read_file_rejects_outside_paths_without_terminating_the_agent_run() -> TestResult {
    let root = tempfile::tempdir()?;
    let (url, server, requests) = server(vec![
        tool_reply(
            "call-escape",
            "read_file",
            json!({"file_path":"../outside.txt"}),
        ),
        answer("escape handled"),
    ])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut input = prompt(root.path(), &url);
    input["tools_enabled"] = json!(true);
    input["tool_limit"] = json!(1);
    begin(&mut peer, "read-escape", &scope, input)?;
    let mut events = Vec::new();
    let terminal = response(&peer, "read-escape", &mut events)?;
    assert_eq!(terminal["result"]["status"], "completed");
    requests.recv_timeout(Duration::from_secs(2))?;
    let second = requests.recv_timeout(Duration::from_secs(2))?;
    let tool_msg = second["messages"]
        .as_array()
        .ok_or("messages")?
        .get(2)
        .ok_or("tool result")?;
    assert_eq!(tool_msg["tool_call_id"], "call-escape");
    assert!(
        tool_msg["content"]
            .as_str()
            .ok_or("content")?
            .starts_with("ERROR:")
    );
    assert!(events.iter().any(|event| {
        event["method"] == "session/tool_result"
            && event["params"]["event"]["outcome"] == "rejected"
    }));
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

fn file_reverse(
    peer: &Peer,
    method: &str,
    events: &mut Vec<Value>,
) -> Result<Value, Box<dyn std::error::Error>> {
    loop {
        let message = peer.read()?;
        if message["method"] == method {
            return Ok(message);
        }
        assert!(
            message.get("method").is_some(),
            "unexpected reply before file observation"
        );
        events.push(message);
    }
}
fn file_captured(peer: &mut Peer, request: &Value, observation: Value) -> TestResult {
    peer.send(json!({"jsonrpc":"2.0","id":request["id"],"result":{
        "scope":request["params"]["scope"],"call_id":request["params"]["call_id"],"observation":observation}}))
}
fn file_checked(peer: &mut Peer, request: &Value, current: bool) -> TestResult {
    peer.send(json!({"jsonrpc":"2.0","id":request["id"],"result":{
        "scope":request["params"]["scope"],"call_id":request["params"]["call_id"],"current":current}}))
}
fn ram_observation(path: &str, text: &str) -> Value {
    json!({"kind":"editor","dirty":true,"document":{"path":path,"document_id":"fixture-ram","tick":11},
        "source":{"text":text,"probe":"","from_available":true,"complete":true}})
}

#[test]
fn native_read_file_uses_unsaved_ram_even_when_the_file_is_absent_on_disk() -> TestResult {
    let root = tempfile::tempdir()?;
    let (url, server, requests) = server(vec![
        tool_reply(
            "ram-read",
            "read_file",
            json!({"file_path":"unsaved.rs","from_line":2,"to_line":2}),
        ),
        answer("RAM inspected"),
    ])?;
    let mut peer = Peer::start()?;
    peer.initialize_with_capabilities(1_048_576, &["editor_file_snapshot"])?;
    let scope = peer.scope()?;
    let mut input = prompt(root.path(), &url);
    input["tools_enabled"] = json!(true);
    input["tool_limit"] = json!(1);
    begin(&mut peer, "ram-file", &scope, input)?;
    let mut events = Vec::new();
    let capture = file_reverse(&peer, "editor/read_file_snapshot", &mut events)?;
    assert_eq!(capture["params"]["capture"]["path"], "unsaved.rs");
    assert_eq!(capture["params"]["capture"]["from"], 2);
    file_captured(
        &mut peer,
        &capture,
        ram_observation("unsaved.rs", "unsaved 🦀\n"),
    )?;
    let validation = file_reverse(&peer, "editor/validate_file_snapshot", &mut events)?;
    assert_eq!(validation["params"]["observation"]["document"]["tick"], 11);
    file_checked(&mut peer, &validation, true)?;
    assert_eq!(
        response(&peer, "ram-file", &mut events)?["result"]["status"],
        "completed"
    );
    assert!(!root.path().join("unsaved.rs").exists());
    requests.recv_timeout(Duration::from_secs(2))?;
    let next = requests.recv_timeout(Duration::from_secs(2))?;
    let output = next["messages"]
        .as_array()
        .ok_or("messages")?
        .last()
        .ok_or("result")?["content"]
        .as_str()
        .ok_or("text")?;
    assert!(output.contains("2 | unsaved 🦀"), "{output}");
    assert!(
        events
            .iter()
            .any(|message| message["method"] == "editor/release_file_snapshot")
    );
    assert!(
        events
            .iter()
            .any(|message| message["method"] == "session/tool_result"
                && message["params"]["event"]["outcome"] == "ok")
    );
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn changed_ram_and_newly_opened_buffers_prevent_read_file_history_publication() -> TestResult {
    for live in [true, false] {
        let root = tempfile::tempdir()?;
        std::fs::write(root.path().join("source.rs"), "DISK_MUST_NOT_REACH_MODEL\n")?;
        let (url, server, requests) = server(vec![
            tool_reply("stale-read", "read_file", json!({"file_path":"source.rs"})),
            answer("stale read handled"),
        ])?;
        let mut peer = Peer::start()?;
        peer.initialize_with_capabilities(1_048_576, &["editor_file_snapshot"])?;
        let scope = peer.scope()?;
        let mut input = prompt(root.path(), &url);
        input["tools_enabled"] = json!(true);
        begin(&mut peer, "stale-file", &scope, input)?;
        let mut events = Vec::new();
        let capture = file_reverse(&peer, "editor/read_file_snapshot", &mut events)?;
        file_captured(
            &mut peer,
            &capture,
            if live {
                ram_observation("source.rs", "RAM_MUST_NOT_REACH_MODEL\n")
            } else {
                json!({"kind":"disk"})
            },
        )?;
        let validation = file_reverse(&peer, "editor/validate_file_snapshot", &mut events)?;
        file_checked(&mut peer, &validation, false)?;
        assert_eq!(
            response(&peer, "stale-file", &mut events)?["result"]["status"],
            "completed"
        );
        requests.recv_timeout(Duration::from_secs(2))?;
        let next = requests.recv_timeout(Duration::from_secs(2))?;
        assert!(!next.to_string().contains("DISK_MUST_NOT_REACH_MODEL"));
        assert!(!next.to_string().contains("RAM_MUST_NOT_REACH_MODEL"));
        assert!(
            events
                .iter()
                .any(|message| message["method"] == "session/tool_result"
                    && message["params"]["event"]["outcome"] == "failed")
        );
        server.join().map_err(|_| "server panic")??;
    }
    Ok(())
}

#[test]
fn editor_snapshot_failure_does_not_fall_back_to_the_existing_disk_file() -> TestResult {
    let root = tempfile::tempdir()?;
    std::fs::write(root.path().join("source.rs"), "STALE_DISK_SECRET\n")?;
    let (url, server, requests) = server(vec![
        tool_reply(
            "unavailable-read",
            "read_file",
            json!({"file_path":"source.rs"}),
        ),
        answer("capture unavailable"),
    ])?;
    let mut peer = Peer::start()?;
    peer.initialize_with_capabilities(1_048_576, &["editor_file_snapshot"])?;
    let scope = peer.scope()?;
    let mut input = prompt(root.path(), &url);
    input["tools_enabled"] = json!(true);
    begin(&mut peer, "unavailable-file", &scope, input)?;
    let mut events = Vec::new();
    let capture = file_reverse(&peer, "editor/read_file_snapshot", &mut events)?;
    peer.send(json!({"jsonrpc":"2.0","id":capture["id"],"error":{"code":-32000,"message":"snapshot unavailable"}}))?;
    assert_eq!(
        response(&peer, "unavailable-file", &mut events)?["result"]["status"],
        "completed"
    );
    requests.recv_timeout(Duration::from_secs(2))?;
    let next = requests.recv_timeout(Duration::from_secs(2))?;
    assert!(!next.to_string().contains("STALE_DISK_SECRET"));
    assert!(
        events
            .iter()
            .any(|message| message["method"] == "session/tool_result"
                && message["params"]["event"]["outcome"] == "failed")
    );
    assert!(
        !events
            .iter()
            .any(|message| message["method"] == "editor/validate_file_snapshot")
    );
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn abort_while_validating_file_discards_output_without_another_provider_request() -> TestResult {
    let root = tempfile::tempdir()?;
    let (url, server, requests) = server(vec![tool_reply(
        "held-read",
        "read_file",
        json!({"file_path":"unsaved.rs"}),
    )])?;
    let mut peer = Peer::start()?;
    peer.initialize_with_capabilities(1_048_576, &["editor_file_snapshot"])?;
    let scope = peer.scope()?;
    let mut input = prompt(root.path(), &url);
    input["tools_enabled"] = json!(true);
    begin(&mut peer, "held-file", &scope, input)?;
    let mut events = Vec::new();
    let capture = file_reverse(&peer, "editor/read_file_snapshot", &mut events)?;
    file_captured(
        &mut peer,
        &capture,
        ram_observation("unsaved.rs", "held RAM\n"),
    )?;
    let validation = file_reverse(&peer, "editor/validate_file_snapshot", &mut events)?;
    send(
        &mut peer,
        "abort-file",
        "session/abort",
        json!({"scope":validation["params"]["scope"]}),
    )?;
    assert_eq!(
        response(&peer, "abort-file", &mut events)?["result"]["status"],
        "revoked"
    );
    assert_eq!(
        response(&peer, "held-file", &mut events)?["result"]["status"],
        "cancelled"
    );
    // A delayed validation ACK cannot revive its already-retired parent run.
    file_checked(&mut peer, &validation, true)?;
    assert_eq!(snapshot(&mut peer, &scope, &mut events)?["state"], "idle");
    requests.recv_timeout(Duration::from_secs(2))?;
    assert!(requests.try_recv().is_err());
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn oversized_file_capture_request_is_a_tool_failure_and_keeps_the_connection_usable() -> TestResult
{
    let root = tempfile::tempdir()?;
    let (url, server, requests) = server(vec![
        tool_reply(
            "large-path",
            "read_file",
            json!({"file_path":"a".repeat(55_000)}),
        ),
        answer("capture limit handled"),
    ])?;
    let mut peer = Peer::start()?;
    // Large enough for native config publication, small enough that the
    // editor capture request for a 55000-byte path cannot fit.
    peer.initialize_with_capabilities(53 * 1024, &["editor_file_snapshot"])?;
    let scope = peer.scope()?;
    let mut input = prompt(root.path(), &url);
    input["tools_enabled"] = json!(true);
    input["prompt"]["content"] = json!("Inspect");
    input["connection"]["headers"] = json!({});
    input["retry"] = Value::Null;
    assert!(
        json!({"jsonrpc":"2.0","id":"limited-file","method":"session/prompt",
        "params":{"scope":scope,"arguments":input}})
        .to_string()
        .len()
            <= 53 * 1024
    );
    begin(&mut peer, "limited-file", &scope, input)?;
    let mut events = Vec::new();
    assert_eq!(
        response(&peer, "limited-file", &mut events)?["result"]["status"],
        "completed"
    );
    assert!(
        !events
            .iter()
            .any(|message| message["method"] == "editor/read_file_snapshot")
    );
    assert!(
        events
            .iter()
            .any(|message| message["method"] == "session/tool_result"
                // The over-frame capture is never sent; the bounded disk read of the
                // overlong name then fails, or the OS refuses it.
                && matches!(
                    message["params"]["event"]["outcome"].as_str(),
                    Some("failed" | "rejected")
                ))
    );
    assert_eq!(snapshot(&mut peer, &scope, &mut events)?["state"], "idle");
    requests.recv_timeout(Duration::from_secs(2))?;
    requests.recv_timeout(Duration::from_secs(2))?;
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn parent_deadline_during_file_validation_preserves_timeout_in_the_tool_result() -> TestResult {
    let root = tempfile::tempdir()?;
    let (url, server, requests) = server(vec![tool_reply(
        "deadline-read",
        "read_file",
        json!({"file_path":"unsaved.rs"}),
    )])?;
    let mut peer = Peer::start()?;
    peer.initialize_with_capabilities(1_048_576, &["editor_file_snapshot"])?;
    let scope = peer.scope()?;
    let mut input = prompt(root.path(), &url);
    input["tools_enabled"] = json!(true);
    input["timeout_ms"] = json!(1500);
    begin(&mut peer, "deadline-file", &scope, input)?;
    let mut events = Vec::new();
    let capture = file_reverse(&peer, "editor/read_file_snapshot", &mut events)?;
    file_captured(
        &mut peer,
        &capture,
        ram_observation("unsaved.rs", "withheld RAM\n"),
    )?;
    file_reverse(&peer, "editor/validate_file_snapshot", &mut events)?;
    let terminal = response(&peer, "deadline-file", &mut events)?;
    assert_eq!(terminal["result"]["status"], "timeout");
    assert!(
        events
            .iter()
            .any(|message| message["method"] == "session/tool_result"
                && message["params"]["event"]["outcome"] == "timeout")
    );
    assert_eq!(snapshot(&mut peer, &scope, &mut events)?["state"], "idle");
    requests.recv_timeout(Duration::from_secs(2))?;
    assert!(requests.try_recv().is_err());
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn ram_capture_does_not_replace_the_parent_runs_pinned_workspace_identity() -> TestResult {
    let parent = tempfile::tempdir()?;
    let root = parent.path().join("workspace");
    let retired = parent.path().join("retired");
    std::fs::create_dir(&root)?;
    let (url, server, requests) = server(vec![
        tool_reply("root-read", "read_file", json!({"file_path":"unsaved.rs"})),
        answer("root replacement rejected"),
    ])?;
    let mut peer = Peer::start()?;
    peer.initialize_with_capabilities(1_048_576, &["editor_file_snapshot"])?;
    let scope = peer.scope()?;
    let mut input = prompt(&root, &url);
    input["tools_enabled"] = json!(true);
    begin(&mut peer, "root-file", &scope, input)?;
    let mut events = Vec::new();
    let capture = file_reverse(&peer, "editor/read_file_snapshot", &mut events)?;
    std::fs::rename(&root, &retired)?;
    std::fs::create_dir(&root)?;
    file_captured(
        &mut peer,
        &capture,
        ram_observation("unsaved.rs", "REPLACED_ROOT_RAM\n"),
    )?;
    assert_eq!(
        response(&peer, "root-file", &mut events)?["result"]["status"],
        "completed"
    );
    requests.recv_timeout(Duration::from_secs(2))?;
    let next = requests.recv_timeout(Duration::from_secs(2))?;
    assert!(!next.to_string().contains("REPLACED_ROOT_RAM"));
    assert!(
        events
            .iter()
            .any(|message| message["method"] == "session/tool_result"
                && message["params"]["event"]["outcome"] == "rejected")
    );
    server.join().map_err(|_| "server panic")??;
    Ok(())
}
