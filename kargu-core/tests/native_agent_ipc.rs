//! Real pipe/provider acceptance sources; deferred until all 3/4/5 implementation finishes.
#[path = "native_agent/commands.rs"]
mod commands;
#[path = "native_agent/editor.rs"]
mod editor;
#[path = "native_agent/edits.rs"]
mod edits;
#[path = "native_agent/reads.rs"]
mod reads;
mod support;
#[path = "native_agent/symbols.rs"]
mod symbols;
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::TcpListener,
    sync::mpsc,
    time::{Duration, Instant},
};
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;
type Server = std::thread::JoinHandle<std::io::Result<()>>;

struct Reply {
    status: u16,
    content_type: &'static str,
    body: String,
    release: Option<mpsc::Receiver<()>>,
}
fn answer(text: &str) -> Reply {
    Reply { status: 200, content_type: "application/json", release: None,
        body: json!({"choices":[{"message":{"role":"assistant","content":text},"finish_reason":"stop"}],
            "usage":{"prompt_tokens":2,"completion_tokens":3}}).to_string() }
}
fn server(
    replies: Vec<Reply>,
) -> Result<(String, Server, mpsc::Receiver<Value>), Box<dyn std::error::Error>> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let url = format!("http://{}/v1", listener.local_addr()?);
    let (observed, receiver) = mpsc::channel();
    let task = std::thread::spawn(move || -> std::io::Result<()> {
        for reply in replies {
            let deadline = Instant::now() + Duration::from_secs(5);
            let mut socket = loop {
                match listener.accept() {
                    Ok((socket, _)) => break socket,
                    Err(error)
                        if error.kind() == std::io::ErrorKind::WouldBlock
                            && Instant::now() < deadline =>
                    {
                        std::thread::sleep(Duration::from_millis(2))
                    }
                    Err(error) => return Err(error),
                }
            };
            socket.set_read_timeout(Some(Duration::from_secs(3)))?;
            socket.set_write_timeout(Some(Duration::from_secs(3)))?;
            let mut headers = Vec::new();
            while !headers.ends_with(b"\r\n\r\n") && headers.len() < 16384 {
                let mut byte = [0];
                socket.read_exact(&mut byte)?;
                headers.extend_from_slice(&byte);
            }
            let length = String::from_utf8_lossy(&headers)
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                })
                .ok_or_else(|| std::io::Error::other("missing fixture body length"))?;
            if length > 65536 {
                return Err(std::io::Error::other("fixture body too large"));
            }
            let mut body = vec![0; length];
            socket.read_exact(&mut body)?;
            let payload: Value = serde_json::from_slice(&body)?;
            observed
                .send(payload)
                .map_err(|_| std::io::Error::other("fixture receiver closed"))?;
            if let Some(release) = reply.release {
                release
                    .recv_timeout(Duration::from_secs(6))
                    .map_err(|_| std::io::Error::other("fixture release missing"))?;
            }
            // A cancellation case deliberately drops its client socket first.
            let _ = write!(
                socket,
                "HTTP/1.1 {} Fixture\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                reply.status,
                reply.content_type,
                reply.body.len(),
                reply.body
            );
            let _ = socket.flush();
        }
        Ok(())
    });
    Ok((url, task, receiver))
}
fn send(peer: &mut Peer, id: &str, method: &str, params: Value) -> TestResult {
    peer.send(json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))
}
fn response(
    peer: &Peer,
    id: &str,
    events: &mut Vec<Value>,
) -> Result<Value, Box<dyn std::error::Error>> {
    loop {
        let message = peer.read()?;
        if message["id"] == id {
            return Ok(message);
        }
        assert!(message.get("method").is_some(), "unexpected reply identity");
        events.push(message);
    }
}
fn prompt(root: &std::path::Path, url: &str) -> Value {
    json!({"root":root,"mode":"agent","prompt":{"role":"user","content":"Inspect synthetic workspace"},
        "tools_enabled":false,"editor_available":[],"tool_limit":8,"turn_limit":4,"timeout_ms":15000,
        "config_revision":3,"policy_revision":7,"budget":{"requests":8},
        "connection":{"url":url,"model":"captured-model","headers":{"Content-Type":"application/json","Authorization":"Bearer synthetic-native"},
            "stream":false,"timeouts":{"connect_ms":1000,"first_byte_ms":12000,"idle_ms":null,"deadline_ms":12000}},
        "retry":{"observer":"none","policy":{"retry_max":2,"backoff_base_ms":1,"backoff_cap_ms":1}}})
}
fn begin(peer: &mut Peer, id: &str, scope: &Value, arguments: Value) -> TestResult {
    send(
        peer,
        id,
        "session/prompt",
        json!({"scope":scope,"arguments":arguments}),
    )
}
fn snapshot(
    peer: &mut Peer,
    scope: &Value,
    events: &mut Vec<Value>,
) -> Result<Value, Box<dyn std::error::Error>> {
    send(peer, "snapshot", "session/snapshot", scope.clone())?;
    Ok(response(peer, "snapshot", events)?["result"].clone())
}

#[test]
fn native_provider_turn_commits_history_and_monotonic_events_without_editor_body_roundtrip()
-> TestResult {
    let root = tempfile::tempdir()?;
    let (url, server, requests) = server(vec![answer("first 🦀"), answer("second")])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut events = Vec::new();
    begin(&mut peer, "first", &scope, prompt(root.path(), &url))?;
    let first = response(&peer, "first", &mut events)?;
    assert_eq!(first["result"]["status"], "completed");
    assert_eq!(first["result"]["accounting"]["budget"]["requests_spent"], 1);
    assert_eq!(first["result"]["accounting"]["budget"]["outstanding"], 0);
    let request = requests.recv_timeout(Duration::from_secs(2))?;
    assert_eq!(request["model"], "captured-model");
    assert_eq!(request["messages"].as_array().ok_or("messages")?.len(), 1);
    assert!(request.get("tools").is_none());
    assert!(request.get("tool_choice").is_none());
    assert!(
        !events
            .iter()
            .any(|event| matches!(event["method"].as_str(), Some("api/body" | "api/delta")))
    );
    let head = snapshot(&mut peer, &scope, &mut events)?;
    assert_eq!(head["state"], "idle");
    assert!(head["history_revision"].as_u64().ok_or("revision")? >= 2);
    let old_sequence = head["sequence"].as_u64().ok_or("sequence")?;
    begin(&mut peer, "second", &scope, prompt(root.path(), &url))?;
    assert_eq!(
        response(&peer, "second", &mut events)?["result"]["status"],
        "completed"
    );
    let request = requests.recv_timeout(Duration::from_secs(2))?;
    let history = request["messages"].as_array().ok_or("history")?;
    assert_eq!(history.len(), 3);
    assert_eq!(
        history.get(1).ok_or("assistant history")?["content"],
        "first 🦀"
    );
    let next = snapshot(&mut peer, &scope, &mut events)?;
    assert!(next["sequence"].as_u64().ok_or("sequence")? > old_sequence);
    let mut previous = 0;
    for event in events {
        assert_eq!(event["params"]["connection_epoch"], peer.epoch);
        let sequence = event["params"]["sequence"]
            .as_u64()
            .ok_or("event sequence")?;
        assert!(sequence > previous);
        previous = sequence;
    }
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn native_parent_stays_claimed_while_provider_waits_and_abort_drains_before_release() -> TestResult
{
    let root = tempfile::tempdir()?;
    let (release, wait) = mpsc::channel();
    let mut held = answer("late reply");
    held.release = Some(wait);
    let (url, server, requests) = server(vec![held])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut events = Vec::new();
    begin(&mut peer, "held", &scope, prompt(root.path(), &url))?;
    requests.recv_timeout(Duration::from_secs(3))?;
    let active = snapshot(&mut peer, &scope, &mut events)?;
    assert_eq!(active["state"], "running");
    let run = active["active_run"].clone();
    begin(&mut peer, "competing", &scope, prompt(root.path(), &url))?;
    assert_eq!(
        response(&peer, "competing", &mut events)?["error"]["data"]["status"],
        "busy"
    );
    send(&mut peer, "abort", "session/abort", json!({"scope":run}))?;
    assert_eq!(
        response(&peer, "abort", &mut events)?["result"]["status"],
        "revoked"
    );
    let terminal = response(&peer, "held", &mut events)?;
    assert_eq!(terminal["result"]["status"], "cancelled");
    assert_eq!(terminal["result"]["accounting"]["budget"]["outstanding"], 0);
    let idle = snapshot(&mut peer, &scope, &mut events)?;
    assert_eq!(idle["state"], "idle");
    assert_eq!(
        idle["history_revision"], 1,
        "late assistant must not enter history"
    );
    release.send(())?;
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn native_retries_keep_one_run_and_charge_every_actual_socket() -> TestResult {
    let root = tempfile::tempdir()?;
    let failed = || Reply {
        status: 503,
        content_type: "application/json",
        body: "synthetic-private-body".to_owned(),
        release: None,
    };
    let (url, server, requests) = server(vec![failed(), failed(), answer("retried")])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut events = Vec::new();
    begin(&mut peer, "retry", &scope, prompt(root.path(), &url))?;
    let reply = response(&peer, "retry", &mut events)?;
    assert_eq!(reply["result"]["status"], "completed");
    assert_eq!(reply["result"]["accounting"]["budget"]["requests_spent"], 3);
    assert_eq!(reply["result"]["accounting"]["budget"]["tokens_spent"], 5);
    let first = requests.recv_timeout(Duration::from_secs(2))?;
    assert_eq!(requests.recv_timeout(Duration::from_secs(2))?, first);
    assert_eq!(requests.recv_timeout(Duration::from_secs(2))?, first);
    assert!(!reply.to_string().contains("synthetic-private-body"));
    assert!(
        !events
            .iter()
            .any(|event| event["method"] == "editor/api_retry")
    );
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn eof_cancels_an_owned_native_exchange_and_waits_for_actual_worker_teardown() -> TestResult {
    let root = tempfile::tempdir()?;
    let (release, wait) = mpsc::channel();
    let mut held = answer("late");
    held.release = Some(wait);
    let (url, server, requests) = server(vec![held])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    begin(&mut peer, "eof", &scope, prompt(root.path(), &url))?;
    requests.recv_timeout(Duration::from_secs(3))?;
    peer.input.take();
    assert!(peer.wait()?);
    release.send(())?;
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn continuation_keeps_the_same_native_run_and_external_api_cannot_borrow_its_budget() -> TestResult
{
    let root = tempfile::tempdir()?;
    let mut length = answer("partial answer");
    length.body = json!({"choices":[{"message":{"role":"assistant","content":"partial answer"},"finish_reason":"length"}],
        "usage":{"prompt_tokens":2,"completion_tokens":3}}).to_string();
    let (url, server, requests) = server(vec![length, answer("finished")])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    begin(
        &mut peer,
        "continue-root",
        &scope,
        prompt(root.path(), &url),
    )?;
    let mut events = Vec::new();
    let mut budget = Value::Null;
    let run = loop {
        let message = peer.read()?;
        assert!(
            message.get("id").is_none(),
            "root must wait for an explicit continuation"
        );
        if message["method"] == "session/accounting" {
            budget = message["params"]["event"]["budget"]["budget_id"].clone();
        }
        let waiting = message["method"] == "session/state"
            && message["params"]["event"]["phase"]["reason"] == "length";
        let run = message["params"]["scope"].clone();
        events.push(message);
        if waiting {
            break run;
        }
    };
    assert!(budget.is_string());
    send(
        &mut peer,
        "borrow",
        "api/request",
        json!({"scope":scope,
        "budget":{"budget_id":budget,"kind":"normal_request"},
        "arguments":{"url":url,"method":"post","body":"{}","headers":{},"stream":false,
            "timeouts":{"connect_ms":500,"first_byte_ms":1000,"idle_ms":null,"deadline_ms":1000}}}),
    )?;
    assert_eq!(
        response(&peer, "borrow", &mut events)?["error"]["data"]["status"],
        "stale_owner"
    );
    send(
        &mut peer,
        "close-budget",
        "api/budget/close",
        json!({"scope":scope,"budget_id":budget}),
    )?;
    assert_eq!(
        response(&peer, "close-budget", &mut events)?["error"]["data"]["status"],
        "budget_busy"
    );
    send(
        &mut peer,
        "continue",
        "session/continue",
        json!({"scope":run,"reason":"length","turn_limit":null}),
    )?;
    assert_eq!(
        response(&peer, "continue", &mut events)?["result"]["status"],
        "continued"
    );
    let terminal = response(&peer, "continue-root", &mut events)?;
    assert_eq!(terminal["result"]["status"], "completed");
    assert_eq!(terminal["result"]["scope"], run);
    assert_eq!(
        terminal["result"]["accounting"]["budget"]["requests_spent"],
        2
    );
    let first = requests.recv_timeout(Duration::from_secs(2))?;
    let second = requests.recv_timeout(Duration::from_secs(2))?;
    assert_eq!(
        first["messages"].as_array().ok_or("first messages")?.len(),
        1
    );
    let messages = second["messages"].as_array().ok_or("second messages")?;
    assert_eq!(messages.len(), 3);
    assert_eq!(
        messages.get(1).ok_or("partial assistant")?["content"],
        "partial answer"
    );
    assert_eq!(messages.get(2).ok_or("continue notice")?["role"], "user");
    server.join().map_err(|_| "server panic")??;
    Ok(())
}
