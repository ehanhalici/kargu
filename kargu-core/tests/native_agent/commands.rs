//! Native command/provider pipeline cases; sources only until the final gate.
use super::*;

fn tool_reply(id: &str, name: &str, arguments: Value) -> Reply {
    Reply { status:200, content_type:"application/json", release:None,
        body:json!({"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{
            "id":id,"type":"function","function":{"name":name,"arguments":arguments.to_string()}}]},"finish_reason":"tool_calls"}],
            "usage":{"prompt_tokens":2,"completion_tokens":3}}).to_string() }
}
fn git(root: &std::path::Path, arguments: &[&str]) -> Result<String, Box<dyn std::error::Error>> {
    let result = std::process::Command::new("git")
        .args(arguments)
        .current_dir(root)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()?;
    if !result.status.success() {
        return Err("fixture Git command failed".into());
    }
    Ok(String::from_utf8(result.stdout)?)
}
fn tool_terminal(
    peer: &mut Peer,
    id: &str,
    approved: bool,
    events: &mut Vec<Value>,
    reviews: &mut Vec<Value>,
) -> Result<Value, Box<dyn std::error::Error>> {
    loop {
        let message = peer.read()?;
        if message["id"] == id {
            return Ok(message);
        }
        if message["method"] == "editor/request_approval" {
            peer.send(json!({"jsonrpc":"2.0","id":message["id"],"result":{"approved":approved}}))?;
            reviews.push(message);
        } else {
            events.push(message);
        }
    }
}

#[test]
fn multistep_git_spends_one_tool_call_and_rejection_keeps_the_parent_live() -> TestResult {
    for approved in [true, false] {
        let root = tempfile::tempdir()?;
        git(root.path(), &["init", "-b", "main"])?;
        std::fs::write(root.path().join("new.txt"), "synthetic content\n")?;
        let (url, server, requests) = server(vec![
            tool_reply("provider-stage", "git_stage", json!({"paths":"new.txt"})),
            answer("stage handled"),
        ])?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let mut input = prompt(root.path(), &url);
        input["tools_enabled"] = json!(true);
        input["tool_limit"] = json!(1);
        begin(&mut peer, "stage-root", &scope, input)?;
        let mut events = Vec::new();
        let mut reviews = Vec::new();
        let terminal = tool_terminal(&mut peer, "stage-root", approved, &mut events, &mut reviews)?;
        assert_eq!(terminal["result"]["status"], "completed");
        assert_eq!(
            reviews.len(),
            1,
            "read preparation must not add mutation reviews"
        );
        assert_eq!(
            reviews.first().ok_or("review")?["params"]["scope"],
            terminal["result"]["scope"]
        );
        assert_eq!(
            terminal["result"]["accounting"]["budget"]["requests_spent"],
            2
        );
        let first = requests.recv_timeout(Duration::from_secs(2))?;
        assert!(
            !first["tools"]
                .as_array()
                .ok_or("tools")?
                .iter()
                .any(|tool| tool["function"]["name"] == "git_mutation_prepare")
        );
        let next = requests.recv_timeout(Duration::from_secs(2))?;
        let history = next["messages"].as_array().ok_or("messages")?;
        assert_eq!(
            history.len(),
            3,
            "internal processes must not become model results"
        );
        let result = history.get(2).ok_or("tool result")?;
        assert_eq!(result["role"], "tool");
        assert_eq!(result["tool_call_id"], "provider-stage");
        assert_eq!(result["name"], "git_stage");
        let outcomes: Vec<_> = events
            .iter()
            .filter(|event| event["method"] == "session/tool_result")
            .collect();
        assert_eq!(outcomes.len(), 1);
        assert_eq!(
            outcomes.first().ok_or("outcome")?["params"]["event"]["outcome"],
            if approved { "ok" } else { "rejected" }
        );
        assert_eq!(
            git(root.path(), &["diff", "--cached", "--name-only"])?.contains("new.txt"),
            approved
        );
        server.join().map_err(|_| "server panic")??;
    }
    Ok(())
}

#[test]
fn successful_shell_output_starting_with_error_is_still_a_successful_tool() -> TestResult {
    let root = tempfile::tempdir()?;
    let (url, server, requests) = server(vec![
        tool_reply(
            "provider-shell",
            "bash",
            json!({"command":"printf 'ERROR: printed text, exit status zero'"}),
        ),
        answer("finished"),
    ])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut input = prompt(root.path(), &url);
    input["tools_enabled"] = json!(true);
    input["tool_limit"] = json!(1);
    begin(&mut peer, "shell-root", &scope, input)?;
    let mut events = Vec::new();
    let mut reviews = Vec::new();
    assert_eq!(
        tool_terminal(&mut peer, "shell-root", true, &mut events, &mut reviews)?["result"]["status"],
        "completed"
    );
    assert_eq!(reviews.len(), 1);
    requests.recv_timeout(Duration::from_secs(2))?;
    let next = requests.recv_timeout(Duration::from_secs(2))?;
    assert_eq!(
        next["messages"]
            .as_array()
            .ok_or("messages")?
            .get(2)
            .ok_or("result")?["content"],
        "ERROR: printed text, exit status zero"
    );
    assert!(
        events
            .iter()
            .any(|event| event["method"] == "session/tool_result"
                && event["params"]["event"]["outcome"] == "ok")
    );
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn parent_stays_draining_until_a_term_ignoring_shell_child_actually_finishes() -> TestResult {
    let root = tempfile::tempdir()?;
    let script = "trap '' TERM; printf ready > started; sleep 60 & wait";
    let (url, server, requests) = server(vec![tool_reply(
        "provider-shell",
        "bash",
        json!({"command":script}),
    )])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut input = prompt(root.path(), &url);
    input["tools_enabled"] = json!(true);
    begin(&mut peer, "shell-drain", &scope, input)?;
    let mut events = Vec::new();
    let run = loop {
        let message = peer.read()?;
        if message["method"] == "editor/request_approval" {
            peer.send(json!({"jsonrpc":"2.0","id":message["id"],"result":{"approved":true}}))?;
            break message["params"]["scope"].clone();
        }
        events.push(message);
    };
    let deadline = Instant::now() + Duration::from_secs(3);
    while !root.path().join("started").exists() {
        if Instant::now() >= deadline {
            return Err("native child never started".into());
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    send(
        &mut peer,
        "abort-shell",
        "session/abort",
        json!({"scope":run}),
    )?;
    assert_eq!(
        response(&peer, "abort-shell", &mut events)?["result"]["status"],
        "revoked"
    );
    assert_eq!(
        snapshot(&mut peer, &scope, &mut events)?["state"],
        "draining"
    );
    begin(&mut peer, "too-early", &scope, prompt(root.path(), &url))?;
    assert_eq!(
        response(&peer, "too-early", &mut events)?["error"]["data"]["status"],
        "busy"
    );
    assert_eq!(
        response(&peer, "shell-drain", &mut events)?["result"]["status"],
        "cancelled"
    );
    assert_eq!(snapshot(&mut peer, &scope, &mut events)?["state"], "idle");
    requests.recv_timeout(Duration::from_secs(2))?;
    assert!(
        requests.try_recv().is_err(),
        "cancelled tool must not start another provider turn"
    );
    server.join().map_err(|_| "server panic")??;
    Ok(())
}
