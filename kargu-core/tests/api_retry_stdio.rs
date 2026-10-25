//! Real native logical retries: each socket is charged and observers precede IO.

#[path = "api_retry/circuit.rs"]
mod circuit;
mod support;
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::TcpListener,
    sync::mpsc,
    time::{Duration, Instant, SystemTime},
};
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;
type Server = std::thread::JoinHandle<std::io::Result<TcpListener>>;
type ServerFixture = (String, Server, mpsc::Receiver<Vec<u8>>);

fn server(
    replies: Vec<(u16, String, String)>,
) -> Result<ServerFixture, Box<dyn std::error::Error>> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let url = format!("http://{}/captured", listener.local_addr()?);
    let (tx, rx) = mpsc::channel();
    let task = std::thread::spawn(move || -> std::io::Result<TcpListener> {
        for (status, headers, body) in replies {
            let deadline = Instant::now() + Duration::from_secs(4);
            let mut socket = loop {
                match listener.accept() {
                    Ok((socket, _)) => break socket,
                    Err(error)
                        if error.kind() == std::io::ErrorKind::WouldBlock
                            && Instant::now() < deadline =>
                    {
                        std::thread::sleep(Duration::from_millis(2));
                    }
                    Err(error) => return Err(error),
                }
            };
            socket.set_read_timeout(Some(Duration::from_secs(2)))?;
            socket.set_write_timeout(Some(Duration::from_secs(2)))?;
            let mut request = Vec::new();
            while request.len() < 16_384 && !request.ends_with(b"\r\n\r\n") {
                let mut byte = [0];
                socket.read_exact(&mut byte)?;
                request.extend_from_slice(&byte);
            }
            let length = String::from_utf8_lossy(&request)
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                })
                .ok_or_else(|| std::io::Error::other("missing fixture content length"))?;
            if length > 16384 {
                return Err(std::io::Error::other("fixture body too large"));
            }
            let mut payload = vec![0; length];
            socket.read_exact(&mut payload)?;
            request.extend_from_slice(&payload);
            tx.send(request)
                .map_err(|_| std::io::Error::other("test receiver dropped"))?;
            write!(
                socket,
                "HTTP/1.1 {status} Fixture\r\nContent-Length: {}\r\nConnection: close\r\n{headers}\r\n{body}",
                body.len()
            )?;
            socket.flush()?;
        }
        Ok(listener)
    });
    Ok((url, task, rx))
}
fn success() -> (u16, String, String) {
    (200, String::new(), json!({"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":2,"completion_tokens":3}}).to_string())
}
fn transient(headers: &str) -> (u16, String, String) {
    (503, headers.into(), "synthetic-private-error-body".into())
}
fn open(
    peer: &mut Peer,
    scope: &Value,
    limits: Value,
    deadline: Option<u64>,
) -> Result<Value, Box<dyn std::error::Error>> {
    peer.send(
        json!({"jsonrpc":"2.0","id":"open","method":"api/budget/open",
        "params":{"scope":scope,"limits":limits,"deadline_epoch_ms":deadline}}),
    )?;
    let reply = peer.read()?;
    assert!(reply.get("error").is_none(), "{reply}");
    Ok(reply["result"]["budget_id"].clone())
}
fn send(
    peer: &mut Peer,
    scope: &Value,
    budget: &Value,
    url: &str,
    observer: &str,
    policy: Value,
) -> TestResult {
    peer.send(json!({"jsonrpc":"2.0","id":"api","method":"api/request","params":{
        "scope":scope,"budget":{"budget_id":budget,"kind":"normal_request"},
        "retry":{"policy":policy,"observer":observer},
        "arguments":{"method":"post","url":url,"body":"{}","headers":{"Authorization":"Bearer synthetic-captured"},
            "stream":false,"timeouts":{"connect_ms":500,"first_byte_ms":3000,"idle_ms":null,"deadline_ms":3000}}}}))
}
fn final_reply(peer: &Peer) -> Result<Value, Box<dyn std::error::Error>> {
    loop {
        let reply = peer.read()?;
        assert_ne!(
            reply["method"], "editor/api_retry",
            "unexpected observer: {reply}"
        );
        if reply["id"] == "api" {
            return Ok(reply);
        }
    }
}
fn observer(peer: &Peer) -> Result<Value, Box<dyn std::error::Error>> {
    let reply = peer.read()?;
    assert_eq!(reply["method"], "editor/api_retry", "{reply}");
    Ok(reply)
}
fn no_extra_socket(server: Server) -> TestResult {
    let listener = server.join().map_err(|_| "server fixture panicked")??;
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
    );
    Ok(())
}
fn policy() -> Value {
    json!({"retry_max":2,"backoff_base_ms":1,"backoff_cap_ms":1})
}

#[test]
fn invalid_retry_intent_is_refused_before_budget_debit_or_io() -> TestResult {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let url = format!("http://{}/captured", listener.local_addr()?);
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let budget = open(&mut peer, &scope, json!({}), None)?;
    let base = json!({"scope":scope,"budget":{"budget_id":budget,"kind":"normal_request"},
        "retry":{"policy":policy(),"observer":"editor"},
        "arguments":{"method":"post","url":url,"body":"{}","headers":{},"stream":false,
            "timeouts":{"connect_ms":500,"first_byte_ms":3000,"idle_ms":null,"deadline_ms":3000}}});
    for kind in [
        "missing_budget",
        "get",
        "observer",
        "missing_observer",
        "retry_limit",
    ] {
        let mut params = base.clone();
        match kind {
            "missing_budget" => {
                params.as_object_mut().ok_or("params")?.remove("budget");
            }
            "get" => {
                params["arguments"]["method"] = json!("get");
                params["arguments"]["body"] = Value::Null;
            }
            "observer" => params["retry"]["observer"] = json!("unknown"),
            "missing_observer" => {
                params["retry"]
                    .as_object_mut()
                    .ok_or("retry")?
                    .remove("observer");
            }
            _ => params["retry"]["policy"]["retry_max"] = json!(11),
        }
        peer.send(json!({"jsonrpc":"2.0","id":"bad","method":"api/request","params":params}))?;
        assert_eq!(peer.read()?["error"]["data"]["status"], "invalid_params");
    }
    peer.send(json!({"jsonrpc":"2.0","id":"snapshot","method":"api/budget/snapshot","params":{"scope":scope,"budget_id":budget}}))?;
    assert_eq!(peer.read()?["result"]["requests_spent"], 0);
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
    );
    Ok(())
}

#[test]
fn headless_retry_uses_identical_capture_and_counts_every_physical_attempt() -> TestResult {
    let (url, server, requests) = server(vec![transient("Retry-After: 0\r\n"), success()])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let budget = open(&mut peer, &scope, json!({}), None)?;
    send(&mut peer, &scope, &budget, &url, "none", policy())?;
    let reply = final_reply(&peer)?;
    assert_eq!(reply["result"]["body_ready"], true);
    assert_eq!(reply["result"]["budget"]["requests_spent"], 2);
    assert_eq!(reply["result"]["budget"]["tokens_spent"], 5);
    assert_eq!(reply["result"]["budget"]["tokens_unknown"], true);
    assert_eq!(reply["result"]["budget"]["outstanding"], 0);
    assert!(!reply.to_string().contains("synthetic-private"));
    assert_eq!(
        requests.recv_timeout(Duration::from_secs(2))?,
        requests.recv_timeout(Duration::from_secs(2))?
    );
    no_extra_socket(server)
}

#[test]
fn editor_acknowledgement_precedes_socket_and_preserves_budget_projection() -> TestResult {
    let (url, server, requests) = server(vec![transient(""), success()])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let budget = open(&mut peer, &scope, json!({}), None)?;
    send(&mut peer, &scope, &budget, &url, "editor", policy())?;
    let observe = observer(&peer)?;
    assert_eq!(observe["params"]["request_id"], "api");
    assert_eq!(observe["params"]["scope"], scope);
    assert_eq!(observe["params"]["connection_epoch"], peer.epoch);
    assert_eq!(observe["params"]["attempt"], 1);
    assert_eq!(observe["params"]["budget"]["requests_spent"], 1);
    assert_eq!(observe["params"]["budget"]["outstanding"], 0);
    requests.recv_timeout(Duration::from_secs(2))?;
    assert!(requests.try_recv().is_err());
    peer.send(json!({"jsonrpc":"2.0","id":observe["id"],"result":{"accepted":true}}))?;
    assert_eq!(final_reply(&peer)?["result"]["budget"]["requests_spent"], 2);
    requests.recv_timeout(Duration::from_secs(2))?;
    no_extra_socket(server)
}

#[test]
fn observer_rejection_malformed_ack_and_forward_cancel_never_open_retry_socket() -> TestResult {
    for action in ["reject", "malformed", "cancel", "close"] {
        let (url, server, requests) = server(vec![transient("")])?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let budget = open(&mut peer, &scope, json!({}), None)?;
        send(&mut peer, &scope, &budget, &url, "editor", policy())?;
        let observe = observer(&peer)?;
        requests.recv_timeout(Duration::from_secs(2))?;
        // An unrelated/late correlation is not authorization for this waiter.
        peer.send(json!({"jsonrpc":"2.0","id":"unknown-observer","result":{"accepted":true}}))?;
        if action == "cancel" {
            peer.send(json!({"jsonrpc":"2.0","method":"rpc/cancel","params":{"request_id":"api","scope":peer.epoch}}))?;
        } else if action == "close" {
            peer.send(json!({"jsonrpc":"2.0","id":"close","method":"api/budget/close","params":{"scope":scope,"budget_id":budget}}))?;
        } else {
            let ack = if action == "reject" {
                json!({"accepted":false})
            } else {
                json!({"accepted":"true"})
            };
            peer.send(json!({"jsonrpc":"2.0","id":observe["id"],"result":ack}))?;
        }
        let reply = final_reply(&peer)?;
        assert_eq!(
            reply["result"]["failure"]["code"],
            if action == "malformed" {
                "retry_unavailable"
            } else {
                "cancelled"
            }
        );
        assert_eq!(reply["result"]["budget"]["requests_spent"], 1);
        if action == "close" {
            assert_eq!(peer.read()?["result"]["status"], "closed");
        }
        // Even a valid late response cannot resurrect the retired operation.
        peer.send(json!({"jsonrpc":"2.0","id":observe["id"],"result":{"accepted":true}}))?;
        peer.send(json!({"jsonrpc":"2.0","id":"ping","method":"ping"}))?;
        assert_eq!(peer.read()?["id"], "ping");
        no_extra_socket(server)?;
    }
    Ok(())
}

#[test]
fn exhausted_or_unknown_budget_stops_before_backoff_observer_and_socket() -> TestResult {
    for (limits, reason) in [
        (json!({"requests":1}), "requests"),
        (json!({"tokens":100}), "unknown_usage"),
    ] {
        let (url, server, requests) = server(vec![transient("")])?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let budget = open(&mut peer, &scope, limits, None)?;
        send(&mut peer, &scope, &budget, &url, "editor", policy())?;
        let reply = final_reply(&peer)?;
        assert_eq!(reply["result"]["failure"]["code"], "budget_exhausted");
        assert_eq!(reply["result"]["failure"]["reason"], reason);
        assert_eq!(reply["result"]["budget"]["refusal"], reason);
        assert_eq!(reply["result"]["budget"]["requests_spent"], 1);
        requests.recv_timeout(Duration::from_secs(2))?;
        no_extra_socket(server)?;
    }
    Ok(())
}

#[test]
fn original_deadline_expires_during_server_wait_without_a_second_charge() -> TestResult {
    let (url, server, requests) = server(vec![transient("Retry-After: 1\r\n")])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let deadline = u64::try_from(
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)?
            .as_millis(),
    )?
    .checked_add(200)
    .ok_or("deadline")?;
    let budget = open(&mut peer, &scope, json!({}), Some(deadline))?;
    send(&mut peer, &scope, &budget, &url, "editor", policy())?;
    let reply = final_reply(&peer)?;
    assert_eq!(reply["result"]["failure"]["code"], "run_deadline");
    assert_eq!(reply["result"]["budget"]["refusal"], "deadline");
    assert_eq!(reply["result"]["budget"]["requests_spent"], 1);
    requests.recv_timeout(Duration::from_secs(2))?;
    no_extra_socket(server)
}

#[test]
fn oversized_server_wait_and_captured_retry_limit_never_replay_early() -> TestResult {
    for (headers, retries) in [
        ("Retry-After: 999999\r\n", 2),
        ("Retry-After: 18446744073709551616\r\n", 2),
        ("", 0),
    ] {
        let (url, server, requests) = server(vec![transient(headers)])?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let budget = open(&mut peer, &scope, json!({}), None)?;
        let mut captured = policy();
        captured["retry_max"] = json!(retries);
        send(&mut peer, &scope, &budget, &url, "editor", captured)?;
        let reply = final_reply(&peer)?;
        assert_eq!(reply["result"]["failure"]["code"], "http");
        assert_eq!(reply["result"]["budget"]["requests_spent"], 1);
        requests.recv_timeout(Duration::from_secs(2))?;
        no_extra_socket(server)?;
    }
    Ok(())
}

#[test]
fn backoff_and_observer_are_revoked_and_joined_before_owner_close_shutdown_or_eof() -> TestResult {
    for stage in ["backoff", "observer"] {
        for action in ["budget_close", "application_close", "shutdown", "eof"] {
            let (url, server, requests) = server(vec![transient(if stage == "backoff" {
                "Retry-After: 3\r\n"
            } else {
                ""
            })])?;
            let mut peer = Peer::start()?;
            peer.initialize()?;
            let scope = peer.scope()?;
            let budget = open(&mut peer, &scope, json!({}), None)?;
            send(&mut peer, &scope, &budget, &url, "editor", policy())?;
            if stage == "observer" {
                observer(&peer)?;
            } else {
                let deadline = Instant::now() + Duration::from_secs(2);
                loop {
                    peer.send(json!({"jsonrpc":"2.0","id":"snapshot","method":"api/budget/snapshot","params":{"scope":scope,"budget_id":budget}}))?;
                    let reply = peer.read()?;
                    assert_eq!(reply["id"], "snapshot");
                    if reply["result"]["outstanding"] == 0 {
                        break;
                    }
                    assert!(Instant::now() < deadline, "attempt never retired");
                    std::thread::sleep(Duration::from_millis(5));
                }
            }
            requests.recv_timeout(Duration::from_secs(2))?;
            if action == "eof" {
                drop(peer.input.take());
                assert!(peer.wait()?);
            } else {
                let (method, params) = match action {
                    "budget_close" => (
                        "api/budget/close",
                        json!({"scope":scope,"budget_id":budget}),
                    ),
                    "application_close" => (
                        "application/close",
                        json!({"application_id":scope["application_id"]}),
                    ),
                    _ => ("shutdown", json!({})),
                };
                peer.send(json!({"jsonrpc":"2.0","id":"close","method":method,"params":params}))?;
                let reply = final_reply(&peer)?;
                assert_eq!(reply["result"]["failure"]["code"], "cancelled");
                assert_eq!(reply["result"]["budget"]["requests_spent"], 1);
                let close = peer.read()?;
                assert_eq!(close["id"], "close", "close overtook logical drain");
                assert!(close.get("error").is_none(), "{close}");
                if action == "shutdown" {
                    peer.send(json!({"jsonrpc":"2.0","method":"exit"}))?;
                    assert!(peer.wait()?);
                }
            }
            no_extra_socket(server)?;
        }
    }
    Ok(())
}

#[test]
fn visible_stream_prefix_is_delivered_before_failure_and_never_replayed() -> TestResult {
    let body = "data: {\"choices\":[{\"delta\":{\"content\":\"visible\"}}]}\n\n";
    let (url, server, requests) = server(vec![(
        200,
        "Content-Type: text/event-stream\r\n".into(),
        body.into(),
    )])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let budget = open(&mut peer, &scope, json!({}), None)?;
    peer.send(json!({"jsonrpc":"2.0","id":"api","method":"api/request","params":{
        "scope":scope,"budget":{"budget_id":budget,"kind":"normal_request"},
        "retry":{"policy":policy(),"observer":"editor"},
        "arguments":{"method":"post","url":url,"body":"{\"stream\":true}","headers":{},"stream":true,
            "timeouts":{"connect_ms":500,"first_byte_ms":3000,"idle_ms":1000,"deadline_ms":3000}}}}))?;
    let delta = peer.read()?;
    assert_eq!(delta["method"], "api/delta");
    let reply = final_reply(&peer)?;
    assert_eq!(reply["result"]["failure"]["code"], "incomplete_stream");
    assert_eq!(reply["result"]["partial"], true);
    assert_eq!(reply["result"]["budget"]["requests_spent"], 1);
    requests.recv_timeout(Duration::from_secs(2))?;
    no_extra_socket(server)
}
