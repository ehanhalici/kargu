//! Actual budget ownership, pre-IO admission and cancellation/drain barriers.

mod support;
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::TcpListener,
    sync::mpsc,
    time::{Duration, SystemTime},
};
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn open(
    peer: &mut Peer,
    scope: &Value,
    limits: Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    peer.send(json!({"jsonrpc":"2.0","id":"open","method":"api/budget/open","params":{"scope":scope,"limits":limits}}))?;
    let result = peer.read()?;
    assert!(result.get("error").is_none(), "{result}");
    Ok(result["result"]["budget_id"].clone())
}
fn params(scope: &Value, budget: &Value, url: &str, kind: &str) -> Value {
    json!({"scope":scope,"budget":{"budget_id":budget,"kind":kind},"arguments":{
        "method":"post","url":url,"body":"{}","headers":{},"stream":false,
        "timeouts":{"connect_ms":1000,"first_byte_ms":30000,"idle_ms":null,"deadline_ms":30000}}})
}
fn send(peer: &mut Peer, id: &str, params: Value) -> TestResult {
    peer.send(json!({"jsonrpc":"2.0","id":id,"method":"api/request","params":params}))
}
fn final_reply(peer: &Peer, id: &str) -> Result<Value, Box<dyn std::error::Error>> {
    loop {
        let reply = peer.read()?;
        if reply["id"] == id {
            return Ok(reply);
        }
    }
}
fn snapshot(
    peer: &mut Peer,
    scope: &Value,
    budget: &Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    peer.send(json!({"jsonrpc":"2.0","id":"snapshot","method":"api/budget/snapshot","params":{"scope":scope,"budget_id":budget}}))?;
    Ok(peer.read()?["result"].clone())
}

#[test]
fn exact_usage_and_request_gate_are_authoritative_before_a_second_socket() -> TestResult {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let address = listener.local_addr()?;
    let (served_tx, served_rx) = mpsc::channel();
    let server = std::thread::spawn(move || -> std::io::Result<TcpListener> {
        let (mut socket, _) = listener.accept()?;
        socket.set_read_timeout(Some(Duration::from_secs(3)))?;
        let mut request = Vec::new();
        while !request.ends_with(b"\r\n\r\n") {
            let mut byte = [0];
            socket.read_exact(&mut byte)?;
            request.push(byte[0]);
        }
        let mut body = [0; 2];
        socket.read_exact(&mut body)?;
        let response = r#"{"choices":[{"message":{"role":"assistant","content":"ok"}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#;
        write!(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            response.len(),
            response
        )?;
        socket.flush()?;
        let _ = served_tx.send(());
        Ok(listener)
    });
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let budget = open(&mut peer, &scope, json!({"requests":1}))?;
    let url = format!("http://{address}/chat");
    send(
        &mut peer,
        "first",
        params(&scope, &budget, &url, "normal_request"),
    )?;
    let reply = final_reply(&peer, "first")?;
    assert_eq!(reply["result"]["budget"]["requests_spent"], 1);
    assert_eq!(reply["result"]["budget"]["tokens_spent"], 5);
    assert_eq!(reply["result"]["budget"]["tokens_unknown"], false);
    assert_eq!(reply["result"]["budget"]["outstanding"], 0);
    served_rx.recv_timeout(Duration::from_secs(3))?;
    let listener = server.join().map_err(|_| "server fixture failed")??;
    send(
        &mut peer,
        "retry",
        params(&scope, &budget, &url, "retry_attempt"),
    )?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "budget_exhausted");
    assert_eq!(snapshot(&mut peer, &scope, &budget)?["requests_spent"], 1);
    listener.set_nonblocking(true)?;
    assert!(matches!(listener.accept(),Err(error) if error.kind()==std::io::ErrorKind::WouldBlock));
    Ok(())
}

#[test]
fn foreign_budget_omission_and_get_relabeling_cannot_bypass_accounting() -> TestResult {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let owner = peer.scope()?;
    let foreign = peer.scope()?;
    let budget = open(&mut peer, &owner, json!({}))?;
    send(
        &mut peer,
        "foreign",
        params(&foreign, &budget, "http://127.0.0.1:9/", "normal_request"),
    )?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "stale_owner");
    let mut omitted = params(&owner, &budget, "http://127.0.0.1:9/", "normal_request");
    omitted
        .as_object_mut()
        .ok_or("params object")?
        .remove("budget");
    send(&mut peer, "omitted", omitted)?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "budget_required");
    let mut get = params(&owner, &budget, "http://127.0.0.1:9/", "normal_request");
    get["arguments"]["method"] = json!("get");
    get["arguments"]["body"] = Value::Null;
    send(&mut peer, "get", get)?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "invalid_params");
    assert_eq!(snapshot(&mut peer, &owner, &budget)?["requests_spent"], 0);
    Ok(())
}

#[test]
fn failed_connection_is_not_free_and_unknown_usage_prevents_a_capped_retry() -> TestResult {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let url = format!("http://{}/chat", listener.local_addr()?);
    drop(listener);
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let budget = open(&mut peer, &scope, json!({"tokens":100}))?;
    send(
        &mut peer,
        "failed",
        params(&scope, &budget, &url, "normal_request"),
    )?;
    let failed = peer.read()?;
    assert_eq!(failed["result"]["failure"]["code"], "connection_failed");
    assert_eq!(failed["result"]["budget"]["requests_spent"], 1);
    assert_eq!(failed["result"]["budget"]["tokens_spent"], 0);
    assert_eq!(failed["result"]["budget"]["tokens_unknown"], true);
    send(
        &mut peer,
        "retry",
        params(&scope, &budget, &url, "retry_attempt"),
    )?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "budget_exhausted");
    let state = snapshot(&mut peer, &scope, &budget)?;
    assert_eq!(state["refusal"], "unknown_usage");
    assert_eq!(state["requests_spent"], 1);
    Ok(())
}

#[test]
fn budget_close_revokes_then_drains_socket_before_ack_and_prevents_resurrection() -> TestResult {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let url = format!("http://{}/chat", listener.local_addr()?);
    let (connected_tx, connected_rx) = mpsc::channel();
    let (closed_tx, closed_rx) = mpsc::channel();
    let server = std::thread::spawn(move || -> std::io::Result<()> {
        let (mut socket, _) = listener.accept()?;
        socket.set_read_timeout(Some(Duration::from_secs(5)))?;
        let _ = connected_tx.send(());
        socket.read_to_end(&mut Vec::new())?;
        let _ = closed_tx.send(());
        Ok(())
    });
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let budget = open(&mut peer, &scope, json!({}))?;
    send(
        &mut peer,
        "active",
        params(&scope, &budget, &url, "normal_request"),
    )?;
    connected_rx.recv_timeout(Duration::from_secs(3))?;
    send(
        &mut peer,
        "overlap",
        params(&scope, &budget, &url, "normal_request"),
    )?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "budget_busy");
    peer.send(json!({"jsonrpc":"2.0","id":"close","method":"api/budget/close","params":{"scope":scope,"budget_id":budget}}))?;
    let active = peer.read()?;
    assert_eq!(active["id"], "active");
    assert_eq!(active["result"]["failure"]["code"], "cancelled");
    let closed = peer.read()?;
    assert_eq!(closed["id"], "close");
    assert_eq!(closed["result"]["status"], "closed");
    assert_eq!(closed["result"]["budget"]["outstanding"], 0);
    assert_eq!(closed["result"]["budget"]["requests_spent"], 1);
    assert_eq!(closed["result"]["budget"]["tokens_unknown"], true);
    closed_rx.recv_timeout(Duration::from_secs(1))?;
    send(
        &mut peer,
        "stale",
        params(&scope, &budget, &url, "normal_request"),
    )?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "stale_owner");
    let next = open(&mut peer, &scope, json!({}))?;
    assert_ne!(next, budget);
    server.join().map_err(|_| "server fixture failed")??;
    Ok(())
}

#[test]
fn expired_absolute_deadline_rejects_before_any_network_or_counter_increment() -> TestResult {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    peer.send(json!({"jsonrpc":"2.0","id":"open","method":"api/budget/open","params":{"scope":scope,"deadline_epoch_ms":1}}))?;
    let budget = peer.read()?["result"]["budget_id"].clone();
    send(
        &mut peer,
        "expired",
        params(&scope, &budget, "http://127.0.0.1:9/", "normal_request"),
    )?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "budget_exhausted");
    let state = snapshot(&mut peer, &scope, &budget)?;
    assert_eq!(state["refusal"], "deadline");
    assert_eq!(state["requests_spent"], 0);
    Ok(())
}

#[test]
fn run_deadline_interrupts_an_active_socket_independently_of_attempt_timeout() -> TestResult {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let url = format!("http://{}/chat", listener.local_addr()?);
    let (closed_tx, closed_rx) = mpsc::channel();
    let server = std::thread::spawn(move || -> std::io::Result<()> {
        let (mut socket, _) = listener.accept()?;
        socket.set_read_timeout(Some(Duration::from_secs(3)))?;
        socket.read_to_end(&mut Vec::new())?;
        let _ = closed_tx.send(());
        Ok(())
    });
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let deadline = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)?
        .as_millis()
        .checked_add(500)
        .ok_or("deadline overflow")?;
    peer.send(json!({"jsonrpc":"2.0","id":"open","method":"api/budget/open","params":{"scope":scope,"deadline_epoch_ms":deadline}}))?;
    let budget = peer.read()?["result"]["budget_id"].clone();
    send(
        &mut peer,
        "active",
        params(&scope, &budget, &url, "normal_request"),
    )?;
    let reply = peer.read()?;
    assert_eq!(reply["result"]["failure"]["code"], "deadline");
    assert_eq!(reply["result"]["budget"]["requests_spent"], 1);
    assert_eq!(reply["result"]["budget"]["tokens_unknown"], true);
    closed_rx.recv_timeout(Duration::from_secs(1))?;
    server.join().map_err(|_| "server fixture failed")??;
    Ok(())
}

#[test]
fn closing_an_application_reclaims_idle_budgets_and_allows_sibling_progress() -> TestResult {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    for _ in 0..80 {
        let scope = peer.scope()?;
        let _ = open(&mut peer, &scope, json!({}))?;
        peer.send(json!({"jsonrpc":"2.0","id":"close-app","method":"application/close","params":{"application_id":scope["application_id"]}}))?;
        assert_eq!(peer.read()?["result"]["status"], "closed");
    }
    peer.send(json!({"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}))?;
    assert_eq!(peer.read()?["id"], "shutdown");
    peer.send(json!({"jsonrpc":"2.0","method":"exit"}))?;
    assert!(peer.wait()?);
    Ok(())
}
