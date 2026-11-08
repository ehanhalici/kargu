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
    server_with_headers(replies, Vec::new())
}
fn server_with_headers(
    replies: Vec<Reply>,
    expected_headers: Vec<(&'static str, String)>,
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
            let wire_headers = String::from_utf8_lossy(&headers);
            for (name, expected) in &expected_headers {
                let actual = wire_headers
                    .lines()
                    .filter_map(|line| line.split_once(':'))
                    .find(|(candidate, _)| candidate.eq_ignore_ascii_case(name))
                    .map(|(_, value)| value.trim());
                if actual != Some(expected.as_str()) {
                    return Err(std::io::Error::other("fixture wire header mismatch"));
                }
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
fn credential_request(
    peer: &Peer,
    events: &mut Vec<Value>,
) -> Result<Value, Box<dyn std::error::Error>> {
    loop {
        let message = peer.read()?;
        if message["method"] == "editor/credential" {
            return Ok(message);
        }
        if message.get("method").is_none() {
            return Err(format!("unexpected terminal before credential request: {message}").into());
        }
        events.push(message);
    }
}
fn complete_credential(
    peer: &mut Peer,
    request: &Value,
    outcome: &str,
    key: Option<&str>,
) -> TestResult {
    peer.send(json!({"jsonrpc":"2.0","id":request["id"],"result":{
        "scope":request["params"]["scope"],"capture_id":request["params"]["capture_id"],
        "quiescent":true,"outcome":outcome,"key":key}}))
}
fn publish_model_metadata(
    peer: &mut Peer,
    scope: &Value,
    revision: u64,
    model: Value,
    metadata: Value,
    events: &mut Vec<Value>,
) -> TestResult {
    send(
        peer,
        "effort-begin",
        "models/begin",
        json!({"scope":scope,
        "arguments":{"provider":"fixture","revision":revision}}),
    )?;
    let upload = response(peer, "effort-begin", events)?["result"]["upload_id"].clone();
    assert!(upload.is_string());
    send(
        peer,
        "effort-append",
        "models/append",
        json!({"scope":scope,
        "arguments":{"upload_id":upload,"offset":0,"chunk":json!({"operation":"put",
            "model":model,"metadata":metadata}).to_string()}}),
    )?;
    assert!(
        response(peer, "effort-append", events)?
            .get("error")
            .is_none()
    );
    send(
        peer,
        "effort-commit",
        "models/commit",
        json!({"scope":scope,
        "arguments":{"upload_id":upload}}),
    )?;
    assert_eq!(
        response(peer, "effort-commit", events)?["result"]["revision"],
        revision + 1
    );
    Ok(())
}
fn publish_provider_registry(
    peer: &mut Peer,
    scope: &Value,
    bound: &mut Value,
    provider: &str,
    registry: Value,
) -> TestResult {
    let generation = FIXTURE_GENERATION.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let staged = peer.call("wire-stage", "configuration/prepare", json!({"scope":scope,
        "arguments":{"generation":generation,"path":"/synthetic/wire","digest":format!("{:064x}",generation),"registry":[],
        "document":{"provider":provider,"model":null,"review-mode":null,"providers":[{"name":provider,
            "data":{"api":bound["connection"]["url"],"model":bound["connection"]["model"],"apikey":""}}]}}}))?;
    let capture = staged["result"]["capture_id"].clone();
    assert!(capture.is_string());
    let committed = peer.call(
        "wire-commit",
        "configuration/commit",
        json!({"scope":scope,
        "arguments":{"capture_id":capture,"context":{"app_url":"https://native-context.invalid/","environment":{},"registry":registry}}}),
    )?;
    assert!(committed["result"]["revision"].is_number());
    bound["config_revision"] = committed["result"]["revision"].clone();
    bound["connection"]["provider"] = json!(provider);
    bound["connection"]["auth"] = json!({"key":null});
    Ok(())
}

fn prompt(root: &std::path::Path, url: &str) -> Value {
    json!({"root":root,"mode":"agent","prompt":{"role":"user","content":"Inspect synthetic workspace"},
        "tools_enabled":false,"editor_available":[],"tool_limit":8,"turn_limit":4,"timeout_ms":15000,
        "config_revision":3,"policy_revision":7,"budget":{"requests":8},
        "connection":{"url":url,"model":"captured-model","headers":{},"auth":{"key":"synthetic-native"},
            "stream":false,"timeouts":{"connect_ms":1000,"first_byte_ms":12000,"idle_ms":null,"deadline_ms":12000}},
        "retry":{"observer":"none","policy":{"retry_max":2,"backoff_base_ms":1,"backoff_cap_ms":1}}})
}
static FIXTURE_GENERATION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1000);
thread_local! {
    /// Revision of this test thread's last fixture publication, for edit scopes.
    static FIXTURE_REVISION: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}
fn fixture_revision() -> u64 {
    FIXTURE_REVISION.with(std::cell::Cell::get)
}
/// Publish a config whose native target is the prompt's fixture server, then
/// bind the prompt to that revision.  Rust rejects any other editor target.
fn publish_target(peer: &mut Peer, scope: &Value, arguments: &mut Value) -> TestResult {
    let key = arguments["connection"]["auth"]["key"]
        .as_str()
        .unwrap_or("")
        .to_owned();
    publish_target_with_key(peer, scope, arguments, Some(&key))
}
fn publish_target_with_key(
    peer: &mut Peer,
    scope: &Value,
    arguments: &mut Value,
    key: Option<&str>,
) -> TestResult {
    publish_target_with_headers(peer, scope, arguments, key, json!({}))
}
fn publish_target_with_headers(
    peer: &mut Peer,
    scope: &Value,
    arguments: &mut Value,
    key: Option<&str>,
    headers: Value,
) -> TestResult {
    publish_target_with_header_policy(peer, scope, arguments, key, headers, json!({}))
}
fn publish_target_with_header_policy(
    peer: &mut Peer,
    scope: &Value,
    arguments: &mut Value,
    key: Option<&str>,
    headers: Value,
    wire_headers: Value,
) -> TestResult {
    use std::hash::{Hash, Hasher};
    let url = arguments["connection"]["url"]
        .as_str()
        .ok_or("fixture url")?
        .to_owned();
    let model = arguments["connection"]["model"]
        .as_str()
        .ok_or("fixture model")?
        .to_owned();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    (&url, &model, key).hash(&mut hasher);
    let generation = FIXTURE_GENERATION.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let mut provider_data = json!({"api":url,"model":model});
    if let Some(key) = key {
        provider_data["apikey"] = json!(key);
    }
    let staged = peer.call(
        &format!("fixture-config-{generation}"),
        "configuration/prepare",
        json!({"scope":scope,"arguments":{"generation":generation,"path":"/synthetic/native-agent",
            "digest":format!("{:064x}", hasher.finish()),"registry":[],
            "document":{"provider":"fixture","model":null,"review-mode":null,
                "providers":[{"name":"fixture","data":provider_data}]}}}),
    )?;
    let capture = staged["result"]["capture_id"].clone();
    if capture.is_null() {
        return Err(format!("fixture config staging failed: {staged}").into());
    }
    let mut committed_wire = arguments["connection"]["wire"]
        .as_object()
        .cloned()
        .unwrap_or_default();
    committed_wire.insert("default-headers".to_owned(), wire_headers.clone());
    let committed_policy = arguments["connection"]["tuning"]["provider_policy"]
        .as_object()
        .cloned()
        .unwrap_or_default();
    let committed = peer.call(
        &format!("fixture-commit-{generation}"),
        "configuration/commit",
        json!({"scope":scope,"arguments":{"capture_id":capture,
            "context":{"app_url":"https://fixture.invalid/","environment":{},"registry":[{"id":"fixture","headers":headers,"wire_headers":wire_headers,"wire":Value::Object(committed_wire).to_string(),"tuning_policy":Value::Object(committed_policy).to_string(),"prompt_caching":arguments["connection"]["cache_markers"].as_bool().unwrap_or(false)}]}}}),
    )?;
    let revision = committed["result"]["revision"].clone();
    if revision.is_null() {
        return Err(format!("fixture config commit failed: {committed}").into());
    }
    FIXTURE_REVISION.with(|cell| cell.set(revision.as_u64().unwrap_or(0)));
    // The committed policy now owns the key; a native prompt never echoes it.
    if let Some(auth) = arguments["connection"]
        .get_mut("auth")
        .and_then(Value::as_object_mut)
    {
        auth.remove("key");
    }
    arguments["config_revision"] = revision;
    arguments["connection"]["provider"] = json!("fixture");
    Ok(())
}
fn begin(peer: &mut Peer, id: &str, scope: &Value, mut arguments: Value) -> TestResult {
    if arguments["connection"]["url"].is_string()
        && arguments["connection"].get("provider").is_none()
    {
        publish_target(peer, scope, &mut arguments)?;
    }
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

#[test]
fn native_model_policy_overrides_editor_tools_and_parameter_claims() -> TestResult {
    for temperature in [false, true] {
        let root = tempfile::tempdir()?;
        let (url, server, requests) = server(vec![answer("native policy")])?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let mut bound = prompt(root.path(), &url);
        publish_target(&mut peer, &scope, &mut bound)?;
        let model = bound["connection"]["model"].clone();
        let mut events = Vec::new();
        send(
            &mut peer,
            "policy-begin",
            "models/begin",
            json!({"scope":scope,
            "arguments":{"provider":"fixture","revision":0}}),
        )?;
        let upload = response(&peer, "policy-begin", &mut events)?["result"]["upload_id"].clone();
        assert!(upload.is_string());
        let parameters = if temperature {
            json!(["temperature", "max_tokens"])
        } else {
            json!(["max_tokens"])
        };
        send(
            &mut peer,
            "policy-append",
            "models/append",
            json!({"scope":scope,
            "arguments":{"upload_id":upload,"offset":0,"chunk":json!({"operation":"put",
                "model":model,"metadata":{"supports_tools":false,"supports_reasoning":temperature,"reasoning-efforts":["high"],"supported_parameters":parameters}}).to_string()}}),
        )?;
        assert!(
            response(&peer, "policy-append", &mut events)?
                .get("error")
                .is_none()
        );
        send(
            &mut peer,
            "policy-commit",
            "models/commit",
            json!({"scope":scope,
            "arguments":{"upload_id":upload}}),
        )?;
        assert_eq!(
            response(&peer, "policy-commit", &mut events)?["result"]["revision"],
            1
        );
        bound["model_revision"] = json!(1);
        bound["tools_enabled"] = json!(true);
        bound["connection"]["tuning"] = json!({"temperature":0.6,"max_tokens":8,"effort":"high",
            "supported_parameters":if temperature {json!(["max_tokens","tools"])} else {json!(["temperature","tools"])}});
        begin(&mut peer, "native-policy", &scope, bound)?;
        assert_eq!(
            response(&peer, "native-policy", &mut events)?["result"]["status"],
            "completed"
        );
        let body = requests.recv_timeout(Duration::from_secs(2))?;
        assert!(body.get("tools").is_none());
        assert!(body.get("tool_choice").is_none());
        assert_eq!(body.get("temperature").is_some(), temperature);
        assert_eq!(body["max_tokens"], 8);
        assert_eq!(body.get("reasoning_effort").is_some(), temperature);
        server.join().map_err(|_| "server panic")??;
    }
    Ok(())
}

#[test]
fn native_wire_auth_stream_and_provider_tuning_ignore_editor_policy() -> TestResult {
    let root = tempfile::tempdir()?;
    let (url, server, requests) = server_with_headers(
        vec![answer("native wire")],
        vec![("x-api-key", "native-wire-key".to_owned())],
    )?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut bound = prompt(root.path(), &url);
    bound["connection"]["wire"] = json!({"auth":"x-api-key","stream":false});
    bound["connection"]["tuning"] =
        json!({"provider_policy":{"max-output-key":"max_completion_tokens"}});
    publish_target_with_key(&mut peer, &scope, &mut bound, Some("native-wire-key"))?;
    // Valid but foreign metadata cannot change the committed codec/auth/policy.
    bound["connection"]["wire"] = json!({"auth":"bearer","stream":true,"chat-path":"/foreign"});
    bound["connection"]["stream"] = json!(true);
    bound["connection"]["tuning"] = json!({"max_tokens":9,"effort":"high","thinking_budget":7,
        "provider_policy":{"max-output-key":"max_tokens"}});
    let mut events = Vec::new();
    begin(&mut peer, "native-wire", &scope, bound)?;
    assert_eq!(
        response(&peer, "native-wire", &mut events)?["result"]["status"],
        "completed"
    );
    let body = requests.recv_timeout(Duration::from_secs(2))?;
    assert_eq!(body["max_completion_tokens"], 9);
    assert!(body.get("max_tokens").is_none());
    assert_ne!(body["stream"], true);
    assert!(body.get("reasoning_effort").is_none());
    assert!(body.get("thinking").is_none());
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn undeclared_native_efforts_and_invalid_thinking_budgets_never_open_http() -> TestResult {
    for (labels, tuning) in [
        (json!(["low"]), json!({"effort":"high"})),
        (Value::Null, json!({"effort":"high"})),
        (json!(["high"]), json!({"effort":"foreign"})),
        (json!(["high"]), json!({"thinking_budget":0})),
    ] {
        let root = tempfile::tempdir()?;
        let listener = TcpListener::bind("127.0.0.1:0")?;
        listener.set_nonblocking(true)?;
        let url = format!("http://{}/v1", listener.local_addr()?);
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let mut bound = prompt(root.path(), &url);
        publish_target(&mut peer, &scope, &mut bound)?;
        let mut events = Vec::new();
        publish_model_metadata(
            &mut peer,
            &scope,
            0,
            bound["connection"]["model"].clone(),
            json!({"supports_reasoning":true,"reasoning-efforts":labels}),
            &mut events,
        )?;
        bound["model_revision"] = json!(1);
        bound["connection"]["tuning"] = tuning;
        begin(&mut peer, "invalid-effort", &scope, bound)?;
        assert_eq!(
            response(&peer, "invalid-effort", &mut events)?["result"]["status"],
            "failed"
        );
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
        );
    }
    Ok(())
}

#[test]
fn native_effort_and_budget_remain_frozen_across_metadata_change_and_retry() -> TestResult {
    let root = tempfile::tempdir()?;
    let (release, wait) = mpsc::channel();
    let held = Reply {
        status: 503,
        content_type: "application/json",
        body: "retry".to_owned(),
        release: Some(wait),
    };
    let (url, server, requests) = server(vec![
        held,
        answer("retried reasoning"),
        answer("reasoning disabled"),
    ])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut bound = prompt(root.path(), &url);
    bound["connection"]["wire"] = json!({"reasoning-shape":"nested","stream":false});
    publish_target(&mut peer, &scope, &mut bound)?;
    let model = bound["connection"]["model"].clone();
    let mut events = Vec::new();
    publish_model_metadata(
        &mut peer,
        &scope,
        0,
        model.clone(),
        json!({"supports_reasoning":true,"reasoning-efforts":["high"]}),
        &mut events,
    )?;
    bound["model_revision"] = json!(1);
    bound["connection"]["tuning"] = json!({"effort":"high","thinking_budget":7});
    begin(&mut peer, "reasoning-retry", &scope, bound.clone())?;
    let first = requests.recv_timeout(Duration::from_secs(3))?;
    assert_eq!(first["reasoning"], json!({"effort":"high","max_tokens":7}));
    publish_model_metadata(
        &mut peer,
        &scope,
        1,
        model,
        json!({"supports_reasoning":true,"reasoning-efforts":["low"]}),
        &mut events,
    )?;
    release.send(())?;
    let reply = response(&peer, "reasoning-retry", &mut events)?;
    assert_eq!(reply["result"]["status"], "completed");
    assert_eq!(reply["result"]["accounting"]["budget"]["requests_spent"], 2);
    assert_eq!(requests.recv_timeout(Duration::from_secs(3))?, first);
    bound["model_revision"] = json!(2);
    begin(&mut peer, "retired-effort", &scope, bound.clone())?;
    assert_eq!(
        response(&peer, "retired-effort", &mut events)?["result"]["status"],
        "failed"
    );
    assert!(matches!(
        requests.try_recv(),
        Err(mpsc::TryRecvError::Empty)
    ));
    bound["connection"]["tuning"] = json!({"effort":"off","thinking_budget":7});
    begin(&mut peer, "reasoning-off", &scope, bound)?;
    assert_eq!(
        response(&peer, "reasoning-off", &mut events)?["result"]["status"],
        "completed"
    );
    let disabled = requests.recv_timeout(Duration::from_secs(3))?;
    assert!(disabled.get("reasoning").is_none());
    assert!(disabled.get("thinking").is_none());
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn native_cache_markers_require_both_committed_provider_and_wire_support() -> TestResult {
    for (provider_cache, wire_cache) in [(false, false), (false, true), (true, false), (true, true)]
    {
        let root = tempfile::tempdir()?;
        let (url, server, requests) = server(vec![answer("cache policy")])?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let mut bound = prompt(root.path(), &url);
        bound["connection"]["wire"] = json!({"cache-marker":wire_cache,"stream":false});
        bound["connection"]["cache_markers"] = json!(provider_cache);
        publish_target(&mut peer, &scope, &mut bound)?;
        // Request metadata cannot enable or disable the native provider annotation.
        bound["connection"]["cache_markers"] = json!(!(provider_cache && wire_cache));
        let system = "stable instructions\n<runtime_environment>\nvolatile context";
        let source = json!([{"role":"system","content":system}]).to_string();
        let mut events = Vec::new();
        send(
            &mut peer,
            "cache-history-begin",
            "history/begin",
            json!({"scope":scope,"arguments":{"revision":0,"bytes":source.len()}}),
        )?;
        let upload =
            response(&peer, "cache-history-begin", &mut events)?["result"]["upload_id"].clone();
        assert!(upload.is_string());
        send(
            &mut peer,
            "cache-history-append",
            "history/append",
            json!({"scope":scope,"arguments":{"upload_id":upload,"offset":0,"text":source}}),
        )?;
        assert!(
            response(&peer, "cache-history-append", &mut events)?
                .get("error")
                .is_none()
        );
        send(
            &mut peer,
            "cache-history-commit",
            "history/commit",
            json!({"scope":scope,"arguments":{"upload_id":upload}}),
        )?;
        assert!(
            response(&peer, "cache-history-commit", &mut events)?
                .get("error")
                .is_none()
        );
        begin(&mut peer, "cache-run", &scope, bound)?;
        assert_eq!(
            response(&peer, "cache-run", &mut events)?["result"]["status"],
            "completed"
        );
        let body = requests.recv_timeout(Duration::from_secs(3))?;
        let content = &body["messages"][0]["content"];
        if provider_cache && wire_cache {
            let blocks = content.as_array().ok_or("native cache blocks")?;
            assert_eq!(
                blocks.first().ok_or("stable block")?["cache_control"]["type"],
                "ephemeral"
            );
            assert!(
                blocks
                    .get(1)
                    .ok_or("runtime block")?
                    .get("cache_control")
                    .is_none()
            );
        } else {
            assert_eq!(content, system);
        }
        send(
            &mut peer,
            "cache-history-rows",
            "history/messages",
            json!({"scope":scope,"arguments":{"offset":0}}),
        )?;
        let rows = response(&peer, "cache-history-rows", &mut events)?;
        let revision = rows["result"]["revision"].clone();
        let id = rows["result"]["messages"][0]["message_id"].clone();
        send(
            &mut peer,
            "cache-history-read",
            "history/read",
            json!({"scope":scope,"arguments":{"revision":revision,"message_id":id,"offset":0}}),
        )?;
        let stored = response(&peer, "cache-history-read", &mut events)?;
        assert_eq!(stored["result"]["complete"], true);
        let message: Value =
            serde_json::from_str(stored["result"]["text"].as_str().ok_or("stored system")?)?;
        assert_eq!(message["content"], system);
        server.join().map_err(|_| "server panic")??;
    }
    Ok(())
}

#[test]
fn missing_or_disabled_custom_wire_never_borrows_request_or_embedded_codec() -> TestResult {
    for (provider, registry) in [
        ("fixture", json!([])),
        ("fixture", json!([{"id":"fixture"}])),
        ("openai", json!([{"id":"openai"}])),
    ] {
        let root = tempfile::tempdir()?;
        let listener = TcpListener::bind("127.0.0.1:0")?;
        listener.set_nonblocking(true)?;
        let url = format!("http://{}/v1", listener.local_addr()?);
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let mut bound = prompt(root.path(), &url);
        publish_provider_registry(&mut peer, &scope, &mut bound, provider, registry)?;
        bound["connection"]["wire"] = json!({"auth":"bearer","stream":false});
        let mut events = Vec::new();
        begin(&mut peer, "unsupported-wire", &scope, bound)?;
        assert_eq!(
            response(&peer, "unsupported-wire", &mut events)?["error"]["data"]["status"],
            "configuration_unavailable"
        );
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
        );
    }
    Ok(())
}

#[test]
fn native_embedded_wire_is_available_without_an_editor_registry_override() -> TestResult {
    for provider in ["openai", "openrouter"] {
        let root = tempfile::tempdir()?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let headers = if provider == "openrouter" {
            vec![
                ("http-referer", "https://native-context.invalid/".to_owned()),
                ("x-title", "kargu".to_owned()),
                (
                    "x-session-id",
                    scope["session_id"]
                        .as_str()
                        .ok_or("native session")?
                        .to_owned(),
                ),
            ]
        } else {
            Vec::new()
        };
        let (url, server, requests) = server_with_headers(vec![answer("embedded codec")], headers)?;
        let mut bound = prompt(root.path(), &url);
        publish_provider_registry(&mut peer, &scope, &mut bound, provider, json!([]))?;
        if provider == "openrouter" {
            bound["connection"]["auth"] = json!({"key":null,"session":"foreign-editor-session","app_url":"https://foreign-editor.invalid/",
                "extra_headers":{"x-session-id":{"binding":"session"}}});
            bound["connection"]["wire"] =
                json!({"default-headers":{"HTTP-Referer":{"binding":"app-url"},"X-Title":"kargu"}});
        }
        let mut events = Vec::new();
        begin(&mut peer, "embedded-wire", &scope, bound)?;
        let reply = response(&peer, "embedded-wire", &mut events)?;
        assert_eq!(
            reply["result"]["status"], "completed",
            "{provider}: {reply}"
        );
        assert_eq!(
            requests.recv_timeout(Duration::from_secs(3))?["model"],
            "captured-model"
        );
        server.join().map_err(|_| "server panic")??;
    }
    Ok(())
}

#[test]
fn committed_custom_header_templates_are_accepted() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let (url, server, requests) = server_with_headers(
        vec![answer("custom headers")],
        vec![
            ("x-tenant", "synthetic-tenant".to_owned()),
            ("x-wire", "native-wire".to_owned()),
            (
                "x-session",
                scope["session_id"].as_str().ok_or("session")?.to_owned(),
            ),
            ("h-referer", "https://fixture.invalid/".to_owned()),
        ],
    )?;

    let mut bound = prompt(root.path(), &url);
    publish_target_with_header_policy(
        &mut peer,
        &scope,
        &mut bound,
        Some(""),
        json!({"X-Tenant":"synthetic-tenant", "X-Session":{"binding":"session"}, "H-Referer":{"binding":"app-url"}}),
        json!({"X-Wire":"native-wire"}),
    )?;
    bound["connection"]["auth"] = json!({"key":"", "session":"synthetic-session", "app_url":"https://foreign.invalid/",
        "extra_headers":{"x-tenant":"synthetic-tenant", "h-referer":{"binding":"app-url"}, "x-session":{"binding":"session"}}});
    bound["connection"]["wire"] = json!({"default-headers":{"x-wire":"native-wire"}});
    let mut events = Vec::new();
    begin(&mut peer, "custom-headers", &scope, bound)?;
    assert_eq!(
        response(&peer, "custom-headers", &mut events)?["result"]["status"],
        "completed"
    );
    requests.recv_timeout(Duration::from_secs(2))?;
    drop(peer);
    server.join().map_err(|_| "server panicked")??;
    Ok(())
}

#[test]
fn native_wire_bindings_are_built_even_without_editor_auth() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let (url, server, requests) = server_with_headers(
        vec![answer("native bindings")],
        vec![
            (
                "x-session",
                scope["session_id"].as_str().ok_or("session")?.to_owned(),
            ),
            ("h-referer", "https://fixture.invalid/".to_owned()),
        ],
    )?;
    let headers = json!({"X-Session":{"binding":"session"},"H-Referer":{"binding":"app-url"}});
    let mut bound = prompt(root.path(), &url);
    publish_target_with_header_policy(
        &mut peer,
        &scope,
        &mut bound,
        Some(""),
        json!({}),
        headers.clone(),
    )?;
    bound["connection"]
        .as_object_mut()
        .ok_or("connection")?
        .remove("auth");
    bound["connection"]["wire"] = json!({"default-headers":headers});
    let mut events = Vec::new();
    begin(&mut peer, "native-bindings", &scope, bound)?;
    assert_eq!(
        response(&peer, "native-bindings", &mut events)?["result"]["status"],
        "completed"
    );
    requests.recv_timeout(Duration::from_secs(2))?;
    drop(peer);
    server.join().map_err(|_| "server panicked")??;
    Ok(())
}

#[test]
fn native_prompt_rejects_uncommitted_header_credentials() -> TestResult {
    for direct in [Some(""), Some("synthetic-native-key"), None] {
        for route in ["headers", "extra", "wire"] {
            let root = tempfile::tempdir()?;
            let (url, server, requests) = server(vec![answer("native headers")])?;
            let mut peer = Peer::start()?;
            peer.initialize_with_capabilities(1_048_576, &["editor_credential_capture"])?;
            let scope = peer.scope()?;
            let mut bound = prompt(root.path(), &url);
            publish_target_with_key(&mut peer, &scope, &mut bound, direct)?;
            bound["connection"]["headers"] = json!({});
            bound["connection"]["auth"] = json!({});
            let mut forged = bound.clone();
            let injected = json!({"X-Foreign-Key":"synthetic-foreign-key"});
            match route {
                "extra" => forged["connection"]["auth"]["extra_headers"] = injected,
                "wire" => forged["connection"]["wire"] = json!({"default-headers":injected}),
                _ => forged["connection"]["headers"] = injected,
            }
            let mut events = Vec::new();
            begin(&mut peer, "foreign-headers", &scope, forged)?;
            assert_eq!(
                response(&peer, "foreign-headers", &mut events)?["error"]["data"]["status"],
                "stale_configuration"
            );
            assert!(requests.try_recv().is_err());
            begin(&mut peer, "bound-headers", &scope, bound)?;
            if direct.is_none() {
                let lookup = credential_request(&peer, &mut events)?;
                complete_credential(
                    &mut peer,
                    &lookup,
                    "resolved",
                    Some("synthetic-interop-key"),
                )?;
            }
            assert_eq!(
                response(&peer, "bound-headers", &mut events)?["result"]["status"],
                "completed"
            );
            requests.recv_timeout(Duration::from_secs(2))?;
            drop(peer);
            server.join().map_err(|_| "server panicked")??;
        }
    }
    Ok(())
}

#[test]
fn interop_cannot_be_enabled_without_negotiated_editor_capability() -> TestResult {
    let root = tempfile::tempdir()?;
    let listener = TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let url = format!("http://{}/v1", listener.local_addr()?);
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut bound = prompt(root.path(), &url);
    publish_target_with_key(&mut peer, &scope, &mut bound, None)?;
    let mut events = Vec::new();
    let mut forged = bound.clone();
    forged["editor_credential_available"] = json!(true);
    begin(&mut peer, "forged-capability", &scope, forged)?;
    assert_eq!(
        response(&peer, "forged-capability", &mut events)?["error"]["code"],
        -32602
    );
    begin(&mut peer, "unavailable", &scope, bound)?;
    assert_eq!(
        response(&peer, "unavailable", &mut events)?["error"]["data"]["status"],
        "configuration_unavailable"
    );
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
    );
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn interop_credential_is_claim_bound_and_editor_key_is_not_authority() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize_with_capabilities(1_048_576, &["editor_credential_capture"])?;
    let scope = peer.scope()?;
    let (url, server, requests) = server_with_headers(
        vec![answer("native credential")],
        vec![("authorization", "Bearer resolved-worker-key".to_owned())],
    )?;
    let mut bound = prompt(root.path(), &url);
    publish_target_with_key(&mut peer, &scope, &mut bound, None)?;
    let mut events = Vec::new();
    begin(&mut peer, "interop", &scope, bound.clone())?;
    let lookup = credential_request(&peer, &mut events)?;
    assert_eq!(lookup["params"]["request_id"], "interop");
    assert_eq!(lookup["params"]["connection_epoch"], peer.epoch);
    assert_eq!(lookup["params"]["scope"]["session_id"], scope["session_id"]);
    assert_eq!(lookup["params"]["provider"], "fixture");
    assert_eq!(lookup["params"]["host"], "127.0.0.1");
    let timeout = lookup["params"]["timeout_ms"].as_u64().ok_or("timeout")?;
    assert!(timeout > 0 && timeout <= 5000);
    let mut forged = lookup.clone();
    forged["params"]["capture_id"] = json!(kargu_core::domain::CredentialCaptureId::new());
    complete_credential(&mut peer, &forged, "resolved", Some("forged-key"))?;
    let mut foreign = lookup.clone();
    foreign["params"]["scope"]["run_id"] = json!(kargu_core::domain::RunId::new());
    complete_credential(&mut peer, &foreign, "resolved", Some("foreign-key"))?;
    begin(&mut peer, "busy", &scope, bound)?;
    assert_eq!(
        response(&peer, "busy", &mut events)?["error"]["data"]["status"],
        "busy"
    );
    assert!(requests.try_recv().is_err());
    complete_credential(&mut peer, &lookup, "resolved", Some("resolved-worker-key"))?;
    complete_credential(&mut peer, &lookup, "resolved", Some("duplicate-key"))?;
    let terminal = response(&peer, "interop", &mut events)?;
    assert_eq!(terminal["result"]["status"], "completed");
    assert_eq!(terminal["result"]["scope"], lookup["params"]["scope"]);
    requests.recv_timeout(Duration::from_secs(2))?;
    drop(peer);
    server.join().map_err(|_| "server panicked")??;
    Ok(())
}

#[test]
fn interop_stop_retains_the_claim_until_actual_quiescence() -> TestResult {
    for abort in [true, false] {
        let root = tempfile::tempdir()?;
        let listener = TcpListener::bind("127.0.0.1:0")?;
        listener.set_nonblocking(true)?;
        let url = format!("http://{}/v1", listener.local_addr()?);
        let mut peer = Peer::start()?;
        peer.initialize_with_capabilities(1_048_576, &["editor_credential_capture"])?;
        let scope = peer.scope()?;
        let mut bound = prompt(root.path(), &url);
        publish_target_with_key(&mut peer, &scope, &mut bound, None)?;

        let mut events = Vec::new();
        begin(&mut peer, "capturing", &scope, bound.clone())?;
        let lookup = credential_request(&peer, &mut events)?;
        if abort {
            let aborted = peer.call(
                "abort",
                "session/abort",
                json!({"scope":lookup["params"]["scope"]}),
            )?;
            assert_eq!(aborted["result"]["status"], "revoked");
        } else {
            peer.send(json!({"jsonrpc":"2.0","method":"rpc/cancel","params":{"scope":peer.epoch,"request_id":"capturing"}}))?;
        }
        begin(&mut peer, "busy", &scope, bound.clone())?;
        assert_eq!(
            response(&peer, "busy", &mut events)?["error"]["data"]["status"],
            "busy"
        );
        assert!(events.iter().any(|event| event["method"] == "rpc/cancel"
            && event["params"]["request_id"] == lookup["id"]));
        complete_credential(&mut peer, &lookup, "resolved", Some("late-key"))?;
        if abort {
            assert_eq!(
                response(&peer, "capturing", &mut events)?["result"]["status"],
                "cancelled"
            );
        } else {
            peer.call("drained", "ping", json!({}))?;
        }
        begin(&mut peer, "next", &scope, bound)?;
        let next = credential_request(&peer, &mut events)?;
        assert_ne!(next["params"]["capture_id"], lookup["params"]["capture_id"]);
        let mut replay = lookup.clone();
        replay["id"] = next["id"].clone();
        complete_credential(&mut peer, &replay, "resolved", Some("old-key"))?;
        complete_credential(&mut peer, &next, "cancelled", None)?;
        assert_eq!(
            response(&peer, "next", &mut events)?["result"]["status"],
            "cancelled"
        );
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
        );
        drop(peer);
    }
    Ok(())
}

#[test]
fn interop_parent_deadline_revokes_but_preserves_actual_drain() -> TestResult {
    let root = tempfile::tempdir()?;
    let listener = TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let url = format!("http://{}/v1", listener.local_addr()?);
    let mut peer = Peer::start()?;
    peer.initialize_with_capabilities(1_048_576, &["editor_credential_capture"])?;
    let scope = peer.scope()?;
    let mut bound = prompt(root.path(), &url);
    publish_target_with_key(&mut peer, &scope, &mut bound, None)?;

    bound["timeout_ms"] = json!(500);
    let mut events = Vec::new();
    begin(&mut peer, "expiring", &scope, bound.clone())?;
    let lookup = credential_request(&peer, &mut events)?;
    assert!(lookup["params"]["timeout_ms"].as_u64().ok_or("timeout")? <= 500);
    loop {
        let message = peer.read()?;
        if message["method"] == "rpc/cancel" && message["params"]["request_id"] == lookup["id"] {
            break;
        }
        assert!(
            message.get("method").is_some(),
            "terminal before actual completion"
        );
        events.push(message);
    }
    begin(&mut peer, "busy", &scope, bound)?;
    assert_eq!(
        response(&peer, "busy", &mut events)?["error"]["data"]["status"],
        "busy"
    );
    complete_credential(&mut peer, &lookup, "resolved", Some("late-key"))?;
    assert_eq!(
        response(&peer, "expiring", &mut events)?["result"]["status"],
        "timeout"
    );
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
    );
    drop(peer);
    Ok(())
}

#[test]
fn closed_session_credential_debt_blocks_replacement_until_quiescence() -> TestResult {
    let root = tempfile::tempdir()?;
    let listener = TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let url = format!("http://{}/v1", listener.local_addr()?);
    let mut peer = Peer::start()?;
    peer.initialize_with_capabilities(1_048_576, &["editor_credential_capture"])?;
    let scope = peer.scope()?;
    let mut bound = prompt(root.path(), &url);
    publish_target_with_key(&mut peer, &scope, &mut bound, None)?;

    let mut events = Vec::new();
    begin(&mut peer, "old", &scope, bound.clone())?;
    let lookup = credential_request(&peer, &mut events)?;
    let closed = peer.call("close", "session/close", scope.clone())?;
    assert_eq!(closed["result"]["status"], "closed");
    let replacement = peer.call(
        "create",
        "session/create",
        json!({"application_id":scope["application_id"]}),
    )?["result"]
        .clone();
    assert_ne!(replacement["session_id"], scope["session_id"]);
    begin(&mut peer, "busy", &replacement, bound.clone())?;
    assert_eq!(
        response(&peer, "busy", &mut events)?["error"]["data"]["status"],
        "busy"
    );
    complete_credential(&mut peer, &lookup, "resolved", Some("old-session-key"))?;
    peer.call("drained", "ping", json!({}))?;
    begin(&mut peer, "replacement", &replacement, bound)?;
    let next = credential_request(&peer, &mut events)?;
    assert_eq!(
        next["params"]["scope"]["session_id"],
        replacement["session_id"]
    );
    let mut replay = lookup.clone();
    replay["id"] = next["id"].clone();
    complete_credential(&mut peer, &replay, "resolved", Some("foreign-session-key"))?;
    complete_credential(&mut peer, &next, "unavailable", None)?;
    assert_eq!(
        response(&peer, "replacement", &mut events)?["result"]["status"],
        "credential_unavailable"
    );
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
    );
    drop(peer);
    Ok(())
}

#[test]
fn interop_eof_releases_the_correlation_without_model_io() -> TestResult {
    let root = tempfile::tempdir()?;
    let listener = TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let url = format!("http://{}/v1", listener.local_addr()?);
    let mut peer = Peer::start()?;
    peer.initialize_with_capabilities(1_048_576, &["editor_credential_capture"])?;
    let scope = peer.scope()?;
    let mut bound = prompt(root.path(), &url);
    publish_target_with_key(&mut peer, &scope, &mut bound, None)?;

    let mut events = Vec::new();
    begin(&mut peer, "disconnect", &scope, bound)?;
    credential_request(&peer, &mut events)?;
    peer.input.take();
    assert!(peer.wait()?);
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
    );
    Ok(())
}

#[test]
fn unavailable_and_malformed_interop_results_are_terminal_without_provider_io() -> TestResult {
    let root = tempfile::tempdir()?;
    let listener = TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let url = format!("http://{}/v1", listener.local_addr()?);
    let mut peer = Peer::start()?;
    peer.initialize_with_capabilities(1_048_576, &["editor_credential_capture"])?;
    let scope = peer.scope()?;
    let mut bound = prompt(root.path(), &url);
    publish_target_with_key(&mut peer, &scope, &mut bound, None)?;

    let mut events = Vec::new();
    for (outcome, key) in [
        ("unavailable", None),
        ("resolved", None),
        ("cancelled", None),
    ] {
        begin(&mut peer, "failed-lookup", &scope, bound.clone())?;
        let lookup = credential_request(&peer, &mut events)?;
        complete_credential(&mut peer, &lookup, outcome, key)?;
        // A quiesced source without a key is a credential refusal; a resolved
        // receipt without its key is malformed.
        let status = match outcome {
            "cancelled" => "cancelled",
            "unavailable" => "credential_unavailable",
            _ => "failed",
        };
        assert_eq!(
            response(&peer, "failed-lookup", &mut events)?["result"]["status"],
            status
        );
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
        );
    }
    drop(peer);
    Ok(())
}

#[test]
fn changed_config_during_interop_rejects_activation_after_real_drain() -> TestResult {
    let root = tempfile::tempdir()?;
    let listener = TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let url = format!("http://{}/v1", listener.local_addr()?);
    let mut peer = Peer::start()?;
    peer.initialize_with_capabilities(1_048_576, &["editor_credential_capture"])?;
    let scope = peer.scope()?;
    let mut bound = prompt(root.path(), &url);
    publish_target_with_key(&mut peer, &scope, &mut bound, None)?;

    let mut events = Vec::new();
    begin(&mut peer, "capturing", &scope, bound.clone())?;
    let lookup = credential_request(&peer, &mut events)?;
    publish_target_with_key(&mut peer, &scope, &mut bound, Some("new-config-key"))?;
    begin(&mut peer, "busy", &scope, bound)?;
    assert_eq!(
        response(&peer, "busy", &mut events)?["error"]["data"]["status"],
        "busy"
    );
    complete_credential(&mut peer, &lookup, "resolved", Some("old-config-key"))?;
    assert_eq!(
        response(&peer, "capturing", &mut events)?["result"]["status"],
        "stale_configuration"
    );
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
    );
    drop(peer);
    Ok(())
}

#[test]
fn changed_model_metadata_during_interop_rejects_activation_after_real_drain() -> TestResult {
    let root = tempfile::tempdir()?;
    let listener = TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let url = format!("http://{}/v1", listener.local_addr()?);
    let mut peer = Peer::start()?;
    peer.initialize_with_capabilities(1_048_576, &["editor_credential_capture"])?;
    let scope = peer.scope()?;
    let mut bound = prompt(root.path(), &url);
    publish_target_with_key(&mut peer, &scope, &mut bound, None)?;

    let mut events = Vec::new();
    begin(&mut peer, "capturing", &scope, bound.clone())?;
    let lookup = credential_request(&peer, &mut events)?;
    send(
        &mut peer,
        "metadata-begin",
        "models/begin",
        json!({"scope":scope,"arguments":{"provider":"fixture","revision":0}}),
    )?;
    let upload = response(&peer, "metadata-begin", &mut events)?["result"]["upload_id"].clone();
    assert!(upload.is_string());
    send(
        &mut peer,
        "metadata-append",
        "models/append",
        json!({"scope":scope,"arguments":{"upload_id":upload,"offset":0,
            "chunk":json!({"operation":"put","model":"fixture-model","metadata":{"context_length":8192}}).to_string()}}),
    )?;
    assert!(
        response(&peer, "metadata-append", &mut events)?
            .get("error")
            .is_none()
    );
    send(
        &mut peer,
        "metadata-commit",
        "models/commit",
        json!({"scope":scope,"arguments":{"upload_id":upload}}),
    )?;
    assert_eq!(
        response(&peer, "metadata-commit", &mut events)?["result"]["revision"],
        1
    );
    let mut current = bound.clone();
    current["model_revision"] = json!(1);
    begin(&mut peer, "busy", &scope, current)?;
    assert_eq!(
        response(&peer, "busy", &mut events)?["error"]["data"]["status"],
        "busy"
    );
    complete_credential(&mut peer, &lookup, "resolved", Some("old-config-key"))?;
    assert_eq!(
        response(&peer, "capturing", &mut events)?["result"]["status"],
        "stale_configuration"
    );
    begin(&mut peer, "old-metadata", &scope, bound.clone())?;
    assert_eq!(
        response(&peer, "old-metadata", &mut events)?["error"]["data"]["status"],
        "stale_configuration"
    );
    bound["model_revision"] = json!(1);
    begin(&mut peer, "fresh-metadata", &scope, bound)?;
    let fresh = credential_request(&peer, &mut events)?;
    complete_credential(&mut peer, &fresh, "unavailable", None)?;
    assert_eq!(
        response(&peer, "fresh-metadata", &mut events)?["result"]["status"],
        "credential_unavailable"
    );
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
    );
    drop(peer);
    Ok(())
}

#[test]
fn native_credentials_never_accept_an_editor_key() -> TestResult {
    for committed in ["synthetic-committed-key", ""] {
        let root = tempfile::tempdir()?;
        let (url, server, requests) = server(vec![answer("bound credential")])?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let mut bound = prompt(root.path(), &url);
        publish_target_with_key(&mut peer, &scope, &mut bound, Some(committed))?;
        bound["connection"]["headers"] = json!({});
        assert!(bound["connection"]["auth"].get("key").is_none());
        let mut events = Vec::new();
        // Neither a foreign key nor an echo of the committed key is accepted.
        for key in ["synthetic-foreign-key", "synthetic-committed-key"] {
            let mut forged = bound.clone();
            forged["connection"]["auth"] = json!({"key":key});
            begin(&mut peer, "editor-key", &scope, forged)?;
            assert_eq!(
                response(&peer, "editor-key", &mut events)?["error"]["data"]["status"],
                "stale_configuration"
            );
            assert!(requests.try_recv().is_err());
        }
        begin(&mut peer, "credential-bound", &scope, bound)?;
        assert_eq!(
            response(&peer, "credential-bound", &mut events)?["result"]["status"],
            "completed"
        );
        requests.recv_timeout(Duration::from_secs(2))?;
        drop(peer);
        server.join().map_err(|_| "server panicked")??;
    }
    Ok(())
}

#[test]
fn prompt_target_is_resolved_natively_and_editor_urls_are_not_authority() -> TestResult {
    let root = tempfile::tempdir()?;
    let (url, server, requests) = server(vec![answer("native target")])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut events = Vec::new();
    let mut bound = prompt(root.path(), &url);
    publish_target(&mut peer, &scope, &mut bound)?;
    for (field, value) in [
        ("url", json!("http://127.0.0.1:9/v1")),
        ("model", json!("other-model")),
        ("provider", json!("openai")),
    ] {
        let mut forged = bound.clone();
        forged["connection"][field] = value;
        begin(&mut peer, "forged", &scope, forged)?;
        let reply = response(&peer, "forged", &mut events)?;
        assert_eq!(
            reply["error"]["data"]["status"], "stale_configuration",
            "{field}: {reply}"
        );
    }
    let mut stale = bound.clone();
    stale["config_revision"] = json!(stale["config_revision"].as_u64().ok_or("revision")? + 1);
    begin(&mut peer, "stale", &scope, stale)?;
    assert_eq!(
        response(&peer, "stale", &mut events)?["error"]["data"]["status"],
        "stale_configuration"
    );
    assert!(
        requests.try_recv().is_err(),
        "no provider request before admission"
    );
    begin(&mut peer, "bound", &scope, bound)?;
    assert_eq!(
        response(&peer, "bound", &mut events)?["result"]["status"],
        "completed"
    );
    assert_eq!(
        requests.recv_timeout(Duration::from_secs(2))?["model"],
        "captured-model"
    );
    drop(peer);
    server.join().map_err(|_| "server panicked")??;
    Ok(())
}

#[test]
fn native_selection_retargets_the_run_and_rejects_the_old_editor_capture() -> TestResult {
    let root = tempfile::tempdir()?;
    let (url, server, requests) = server(vec![answer("selected model")])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut events = Vec::new();
    let mut input = prompt(root.path(), &url);
    publish_target(&mut peer, &scope, &mut input)?;
    let selected = peer.call(
        "select",
        "session/selection/commit",
        json!({"application_id":scope["application_id"],"session_id":scope["session_id"],
            "expected_revision":0,"selection":{"provider":"fixture","model":"chosen-model"}}),
    )?;
    assert_eq!(selected["result"]["revision"], 1, "{selected}");
    begin(&mut peer, "old", &scope, input.clone())?;
    assert_eq!(
        response(&peer, "old", &mut events)?["error"]["data"]["status"],
        "stale_configuration"
    );
    input["connection"]["model"] = json!("chosen-model");
    begin(&mut peer, "chosen", &scope, input)?;
    assert_eq!(
        response(&peer, "chosen", &mut events)?["result"]["status"],
        "completed"
    );
    assert_eq!(
        requests.recv_timeout(Duration::from_secs(2))?["model"],
        "chosen-model"
    );
    drop(peer);
    server.join().map_err(|_| "server panicked")??;
    Ok(())
}

#[test]
fn two_chat_owners_in_same_project_are_independent_and_closed_owner_rejects_late_delivery()
-> TestResult {
    let root = tempfile::tempdir()?;
    let (url, server, requests) = server(vec![answer("reply from chat b")])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope_a = peer.scope()?;

    let scope_b = peer.call(
        "create-b",
        "session/create",
        json!({"application_id": scope_a["application_id"]}),
    )?["result"]
        .clone();
    assert_ne!(scope_a["session_id"], scope_b["session_id"]);

    let mut events = Vec::new();
    let mut input_b = prompt(root.path(), &url);
    publish_target(&mut peer, &scope_b, &mut input_b)?;

    let closed_a = peer.call("close-a", "session/close", scope_a.clone())?;
    assert_eq!(closed_a["result"]["status"], "closed");

    begin(&mut peer, "send-a", &scope_a, input_b.clone())?;
    let reply_a = response(&peer, "send-a", &mut events)?;
    assert!(
        reply_a["error"]["data"]["status"] == "stale_owner"
            || reply_a["error"]["code"] == -32602
            || reply_a["error"]["message"]
                .as_str()
                .is_some_and(|m| m.contains("not found")),
        "closed session A must reject requests: {reply_a}"
    );

    begin(&mut peer, "send-b", &scope_b, input_b)?;
    assert_eq!(
        response(&peer, "send-b", &mut events)?["result"]["status"],
        "completed"
    );
    assert_eq!(
        requests.recv_timeout(Duration::from_secs(2))?["model"],
        "captured-model"
    );

    drop(peer);
    server.join().map_err(|_| "server panicked")??;
    Ok(())
}
