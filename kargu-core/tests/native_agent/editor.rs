//! Native editor reverse RPC tool pipeline acceptance tests; sources only until final gate.
use super::*;

pub(super) fn tool_reply(id: &str, name: &str, arguments: Value) -> Reply {
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
fn native_editor_tools_dispatch_reverse_rpc_and_commit_results_to_history() -> TestResult {
    let root = tempfile::tempdir()?;
    let (url, server, requests) = server(vec![
        tool_reply(
            "call-editor-sym",
            "read_file_symbols",
            json!({"file_path": "src/lib.rs"}),
        ),
        answer("editor tool completed"),
    ])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut input = prompt(root.path(), &url);
    input["tools_enabled"] = json!(true);
    input["editor_available"] = json!(["read_file_symbols"]);
    input["tool_limit"] = json!(2);
    input["turn_limit"] = json!(4);

    begin(&mut peer, "editor-pipeline", &scope, input)?;

    let mut events = Vec::new();
    let capture = reverse(&peer, "editor/prepare_tool", &mut events)?;
    assert_eq!(capture["params"]["tool"], "read_file_symbols");
    assert_eq!(capture["params"]["request_id"], "editor-pipeline");
    assert_eq!(capture["params"]["connection_epoch"], peer.epoch);
    captured(
        &mut peer,
        &capture,
        json!({"kind":"language_document","source":{"kind":"imenu","provider":"fixture-imenu"},"document":{
        "path":"src/lib.rs","document_id":"editor-doc-1","tick":1}}),
    )?;
    let reverse_call = reverse(&peer, "editor/call_tool", &mut events)?;
    assert_eq!(reverse_call["params"]["tool"], "read_file_symbols");
    assert_eq!(
        reverse_call["params"]["arguments"]["file_path"],
        "src/lib.rs"
    );
    assert_eq!(reverse_call["params"]["resource"]["document"]["tick"], 1);
    let resource = &reverse_call["params"]["resource"];
    peer.send(json!({"jsonrpc":"2.0","id":reverse_call["id"],"result":{
        "scope":reverse_call["params"]["scope"],"call_id":reverse_call["params"]["call_id"],
        "quiescent":true,"outcome":"ok","observation":{"kind":"symbols","snapshot":{
            "requested":resource["document"],"observed":resource["document"],"source":resource["source"],"observed_source":resource["source"],
            "symbols":{"symbols":[{"name":"alpha","kind":"function","range":{"start":{"line":1,"column":0},"end":{"line":2,"column":0}},"children":[]}],"truncated":false}}}}}))?;

    let terminal = response(&peer, "editor-pipeline", &mut events)?;
    assert_eq!(terminal["result"]["status"], "completed");
    assert_eq!(
        terminal["result"]["accounting"]["budget"]["requests_spent"],
        2
    );

    let _first = requests.recv_timeout(Duration::from_secs(2))?;
    let after_sym = requests.recv_timeout(Duration::from_secs(2))?;
    let sym_msg = after_sym["messages"]
        .as_array()
        .ok_or("messages")?
        .last()
        .ok_or("sym result")?;
    assert_eq!(sym_msg["tool_call_id"], "call-editor-sym");
    assert!(
        sym_msg["content"]
            .as_str()
            .ok_or("content")?
            .contains("Function alpha")
    );

    server.join().map_err(|_| "server panic")??;
    Ok(())
}

pub(super) fn reverse(
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
            "unexpected terminal before reverse call"
        );
        events.push(message);
    }
}
fn captured(peer: &mut Peer, request: &Value, resource: Value) -> TestResult {
    peer.send(json!({"jsonrpc":"2.0","id":request["id"],"result":{
        "scope":request["params"]["scope"],"call_id":request["params"]["call_id"],"resource":resource}}))
}
fn completed(peer: &mut Peer, request: &Value, outcome: &str, text: &str) -> TestResult {
    peer.send(json!({"jsonrpc":"2.0","id":request["id"],"result":{
        "scope":request["params"]["scope"],"call_id":request["params"]["call_id"],
        "quiescent":true,"outcome":outcome,"text":text}}))
}
fn debugger() -> Value {
    json!({"kind":"debugger","connection_id":"fixture-debugger","stop_generation":3,
        "thread_id":1,"frame_id":0})
}

#[test]
fn native_debugger_evaluation_requires_exact_shared_consent_before_issuance() -> TestResult {
    let root = tempfile::tempdir()?;
    let (url, server, requests) = server(vec![
        tool_reply(
            "evaluate",
            "debug_eval",
            json!({"expression":"counter += 1"}),
        ),
        answer("evaluation rejected"),
    ])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut input = prompt(root.path(), &url);
    input["tools_enabled"] = json!(true);
    input["editor_available"] = json!(["debug_eval"]);
    input["tool_limit"] = json!(1);
    begin(&mut peer, "evaluation", &scope, input)?;
    let mut events = Vec::new();
    let capture = reverse(&peer, "editor/prepare_tool", &mut events)?;
    captured(&mut peer, &capture, debugger())?;
    let approval = reverse(&peer, "editor/approve_tool", &mut events)?;
    assert_eq!(approval["params"]["safety"], "executes_arbitrary_code");
    assert_eq!(approval["params"]["resource"], debugger());
    peer.send(json!({"jsonrpc":"2.0","id":approval["id"],"result":{
        "scope":approval["params"]["scope"],"call_id":approval["params"]["call_id"],"approved":false}}))?;
    assert_eq!(
        response(&peer, "evaluation", &mut events)?["result"]["status"],
        "completed"
    );
    assert!(
        !events
            .iter()
            .any(|message| message["method"] == "editor/call_tool")
    );
    assert!(
        events
            .iter()
            .any(|message| message["method"] == "session/tool_result"
                && message["params"]["event"]["outcome"] == "rejected")
    );
    requests.recv_timeout(Duration::from_secs(2))?;
    let after = requests.recv_timeout(Duration::from_secs(2))?;
    assert_eq!(
        after["messages"]
            .as_array()
            .ok_or("messages")?
            .last()
            .ok_or("result")?["tool_call_id"],
        "evaluate"
    );
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn native_issued_editor_effect_stays_busy_after_abort_and_ignores_foreign_quiescence() -> TestResult
{
    let root = tempfile::tempdir()?;
    let (url, server, requests) = server(vec![tool_reply(
        "evaluate",
        "debug_eval",
        json!({"expression":"side_effect()"}),
    )])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut input = prompt(root.path(), &url);
    input["tools_enabled"] = json!(true);
    input["editor_available"] = json!(["debug_eval"]);
    begin(&mut peer, "held-editor", &scope, input)?;
    let mut events = Vec::new();
    let capture = reverse(&peer, "editor/prepare_tool", &mut events)?;
    captured(&mut peer, &capture, debugger())?;
    let approval = reverse(&peer, "editor/approve_tool", &mut events)?;
    peer.send(json!({"jsonrpc":"2.0","id":approval["id"],"result":{
        "scope":approval["params"]["scope"],"call_id":approval["params"]["call_id"],"approved":true}}))?;
    let issued = reverse(&peer, "editor/call_tool", &mut events)?;
    let mut foreign = issued.clone();
    foreign["params"]["scope"]["generation"] = json!(9999);
    completed(&mut peer, &foreign, "ok", "foreign reply")?;
    send(
        &mut peer,
        "abort-editor",
        "session/abort",
        json!({"scope":issued["params"]["scope"]}),
    )?;
    assert_eq!(
        response(&peer, "abort-editor", &mut events)?["result"]["status"],
        "revoked"
    );
    assert_eq!(
        snapshot(&mut peer, &scope, &mut events)?["state"],
        "draining"
    );
    begin(
        &mut peer,
        "competing-editor",
        &scope,
        prompt(root.path(), &url),
    )?;
    assert_eq!(
        response(&peer, "competing-editor", &mut events)?["error"]["data"]["status"],
        "busy"
    );
    completed(
        &mut peer,
        &issued,
        "outcome_unknown",
        "Effect interrupted; state unknown",
    )?;
    assert_eq!(
        response(&peer, "held-editor", &mut events)?["result"]["status"],
        "cancelled"
    );
    assert_eq!(snapshot(&mut peer, &scope, &mut events)?["state"], "idle");
    assert!(
        events
            .iter()
            .any(|message| message["method"] == "editor/cancel_tool")
    );
    assert!(
        events
            .iter()
            .any(|message| message["method"] == "session/tool_result"
                && message["params"]["event"]["outcome"] == "outcome_unknown")
    );
    requests.recv_timeout(Duration::from_secs(2))?;
    assert!(requests.try_recv().is_err());
    server.join().map_err(|_| "server panic")??;
    Ok(())
}
