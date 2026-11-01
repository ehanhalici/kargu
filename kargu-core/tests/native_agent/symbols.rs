//! Real native provider/pipe sources for the final 3/4/5 acceptance gate.
use super::editor::{reverse, tool_reply};
use super::*;

fn resource() -> Value {
    json!({"kind":"language_document","document":{"path":"file.rs","document_id":"live-doc","tick":7},
    "source":{"kind":"eglot","server":"eglot-process-1","version":3,"encoding":"utf-16"}})
}
fn range() -> Value {
    json!({"start":{"line":2,"column":2},"end":{"line":2,"column":4}})
}
fn node(name: &str) -> Value {
    json!({"name":name,"kind":"function","range":range(),"children":[]})
}
fn symbols(request: &Value, nodes: Vec<Value>, truncated: bool) -> Value {
    let resource = &request["params"]["resource"];
    json!({"kind":"symbols","snapshot":{"requested":resource["document"],"observed":resource["document"],
        "source":resource["source"],"observed_source":resource["source"],"symbols":{"symbols":nodes,"truncated":truncated}}})
}
fn complete(
    peer: &mut Peer,
    request: &Value,
    outcome: &str,
    observation: Option<Value>,
) -> TestResult {
    peer.send(json!({"jsonrpc":"2.0","id":request["id"],"result":{"scope":request["params"]["scope"],
        "call_id":request["params"]["call_id"],"quiescent":true,"outcome":outcome,"observation":observation,
        "text":"UNTRUSTED formatted text must never replace a typed symbol observation"}}))
}
fn issued(peer: &mut Peer, events: &mut Vec<Value>) -> Result<Value, Box<dyn std::error::Error>> {
    let capture = reverse(peer, "editor/prepare_tool", events)?;
    peer.send(
        json!({"jsonrpc":"2.0","id":capture["id"],"result":{"scope":capture["params"]["scope"],
        "call_id":capture["params"]["call_id"],"resource":resource()}}),
    )?;
    reverse(peer, "editor/call_tool", events)
}
fn input(root: &std::path::Path, url: &str, tool: &str) -> Value {
    let mut input = prompt(root, url);
    input["tools_enabled"] = json!(true);
    input["editor_available"] = json!([tool]);
    input["tool_limit"] = json!(1);
    input
}
fn result_text(requests: &mpsc::Receiver<Value>) -> Result<String, Box<dyn std::error::Error>> {
    let _first = requests.recv_timeout(Duration::from_secs(2))?;
    let next = requests.recv_timeout(Duration::from_secs(2))?;
    let results: Vec<_> = next["messages"]
        .as_array()
        .ok_or("messages")?
        .iter()
        .filter(|m| m["role"] == "tool")
        .collect();
    assert_eq!(results.len(), 1);
    let text = results.first().ok_or("tool result")?["content"]
        .as_str()
        .ok_or("tool text")?
        .to_owned();
    assert!(!text.contains("UNTRUSTED"));
    Ok(text)
}

#[test]
fn native_read_symbol_selects_in_rust_then_reads_one_exact_live_range_under_one_call() -> TestResult
{
    let root = tempfile::tempdir()?;
    let (url, server, requests) = server(vec![
        tool_reply(
            "symbol",
            "read_symbol",
            json!({"file_path":"file.rs","symbol":"alpha","kind":"Function"}),
        ),
        answer("read live symbol"),
    ])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut events = vec![];
    begin(
        &mut peer,
        "symbols",
        &scope,
        input(root.path(), &url, "read_symbol"),
    )?;
    let call = issued(&mut peer, &mut events)?;
    assert!(
        call["params"]["timeout_ms"]
            .as_u64()
            .is_some_and(|ms| (1..=30000).contains(&ms))
    );
    complete(
        &mut peer,
        &call,
        "ok",
        Some(symbols(&call, vec![node("alpha")], false)),
    )?;
    let body = reverse(&peer, "editor/read_symbol_range", &mut events)?;
    assert_eq!(body["params"]["resource"], resource());
    assert_eq!(body["params"]["range"], range());
    assert_eq!(body["params"]["call_id"], call["params"]["call_id"]);
    complete(
        &mut peer,
        &body,
        "ok",
        Some(
            json!({"kind":"body","snapshot":{"document":resource()["document"],
        "source":resource()["source"],"range":range(),"text":"🦀β","truncated":false}}),
        ),
    )?;
    let terminal = response(&peer, "symbols", &mut events)?;
    assert_eq!(terminal["result"]["status"], "completed");
    assert_eq!(
        terminal["result"]["accounting"]["budget"]["requests_spent"],
        2
    );
    assert_eq!(
        events
            .iter()
            .filter(|m| m["method"] == "session/tool_result")
            .count(),
        1
    );
    let text = result_text(&requests)?;
    assert!(text.contains("🦀β"));
    assert!(text.contains("L2:C2-L2:C4"));
    assert!(!root.path().join("file.rs").exists());
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn ambiguous_truncated_and_missing_symbols_do_not_enter_a_body_reader() -> TestResult {
    for case in ["ambiguous", "truncated", "not_found"] {
        let root = tempfile::tempdir()?;
        let (url, server, requests) = server(vec![
            tool_reply(
                "symbol",
                "read_symbol",
                json!({"file_path":"file.rs","symbol":"alpha","kind":"function"}),
            ),
            answer("symbol unavailable"),
        ])?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let mut events = vec![];
        begin(
            &mut peer,
            "symbols",
            &scope,
            input(root.path(), &url, "read_symbol"),
        )?;
        let call = issued(&mut peer, &mut events)?;
        let nodes = if case == "ambiguous" {
            vec![node("alpha"), node("ALPHA")]
        } else if case == "not_found" {
            vec![node("other")]
        } else {
            vec![node("alpha")]
        };
        complete(
            &mut peer,
            &call,
            "ok",
            Some(symbols(&call, nodes, case == "truncated")),
        )?;
        assert_eq!(
            response(&peer, "symbols", &mut events)?["result"]["status"],
            "completed"
        );
        assert!(
            !events
                .iter()
                .any(|m| m["method"] == "editor/read_symbol_range")
        );
        assert!(
            events
                .iter()
                .any(|m| m["method"] == "editor/release_symbol_snapshot")
        );
        let text = result_text(&requests)?;
        assert!(
            text.contains(if case == "not_found" {
                "not found"
            } else {
                case
            }),
            "{text}"
        );
        server.join().map_err(|_| "server panic")??;
    }
    Ok(())
}

#[test]
fn typed_symbol_success_requires_the_exact_document_provider_and_complete_valid_ranges()
-> TestResult {
    for case in [
        "text_only",
        "stale_tick",
        "replacement_server",
        "unflushed_version",
        "encoding",
        "invalid_tree",
    ] {
        let root = tempfile::tempdir()?;
        let (url, server, requests) = server(vec![
            tool_reply(
                "symbol",
                "read_file_symbols",
                json!({"file_path":"file.rs"}),
            ),
            answer("symbol unavailable"),
        ])?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let mut events = vec![];
        begin(
            &mut peer,
            "symbols",
            &scope,
            input(root.path(), &url, "read_file_symbols"),
        )?;
        let call = issued(&mut peer, &mut events)?;
        let mut observation = symbols(&call, vec![node("alpha")], false);
        match case {
            "stale_tick" => observation["snapshot"]["observed"]["tick"] = json!(8),
            "replacement_server" => {
                observation["snapshot"]["observed_source"]["server"] = json!("eglot-process-2")
            }
            "unflushed_version" => observation["snapshot"]["observed_source"]["version"] = json!(4),
            "encoding" => observation["snapshot"]["observed_source"]["encoding"] = json!("utf-8"),
            "invalid_tree" => {
                observation["snapshot"]["symbols"]["symbols"][0]["selection_range"] =
                    json!({"start":{"line":9,"column":0},"end":{"line":10,"column":0}})
            }
            _ => {}
        }
        complete(
            &mut peer,
            &call,
            "ok",
            if case == "text_only" {
                None
            } else {
                Some(observation)
            },
        )?;
        assert_eq!(
            response(&peer, "symbols", &mut events)?["result"]["status"],
            "completed"
        );
        let text = result_text(&requests)?;
        assert!(text.starts_with("ERROR:"), "{case}: {text}");
        assert!(
            events.iter().any(|m| m["method"] == "session/tool_result"
                && m["params"]["event"]["outcome"] == "failed")
        );
        server.join().map_err(|_| "server panic")??;
    }
    Ok(())
}

#[test]
fn native_symbol_capture_rejects_replacement_of_the_original_workspace() -> TestResult {
    let outer = tempfile::tempdir()?;
    let root = outer.path().join("project");
    std::fs::create_dir(&root)?;
    let (url, server, requests) = server(vec![
        tool_reply(
            "symbol",
            "read_file_symbols",
            json!({"file_path":"file.rs"}),
        ),
        answer("workspace changed"),
    ])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut events = vec![];
    begin(
        &mut peer,
        "symbols",
        &scope,
        input(&root, &url, "read_file_symbols"),
    )?;
    let call = issued(&mut peer, &mut events)?;
    std::fs::rename(&root, outer.path().join("old-project"))?;
    std::fs::create_dir(&root)?;
    complete(
        &mut peer,
        &call,
        "ok",
        Some(symbols(&call, vec![node("foreign_secret_symbol")], false)),
    )?;
    assert_eq!(
        response(&peer, "symbols", &mut events)?["result"]["status"],
        "completed"
    );
    let text = result_text(&requests)?;
    assert!(text.starts_with("ERROR:"));
    assert!(!text.contains("foreign_secret_symbol"));
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn native_symbol_failure_reasons_are_closed_statuses_and_not_editor_prose() -> TestResult {
    for (reason, outcome, expected) in [
        ("unavailable", "failed", "provider unavailable"),
        ("stale", "failed", "provider changed"),
        ("invalid_range", "failed", "invalid source range"),
        ("timeout", "timeout", "deadline exceeded"),
        ("cancelled", "cancelled", "cancelled"),
        ("resource_limit", "failed", "resource limit exceeded"),
    ] {
        let root = tempfile::tempdir()?;
        let (url, server, requests) = server(vec![
            tool_reply(
                "symbol",
                "read_file_symbols",
                json!({"file_path":"file.rs"}),
            ),
            answer("provider result observed"),
        ])?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let mut events = vec![];
        begin(
            &mut peer,
            "symbols",
            &scope,
            input(root.path(), &url, "read_file_symbols"),
        )?;
        let call = issued(&mut peer, &mut events)?;
        complete(
            &mut peer,
            &call,
            "ok",
            Some(json!({"kind":"unavailable","reason":reason})),
        )?;
        assert_eq!(
            response(&peer, "symbols", &mut events)?["result"]["status"],
            "completed"
        );
        assert!(result_text(&requests)?.contains(expected));
        assert!(
            events.iter().any(|m| m["method"] == "session/tool_result"
                && m["params"]["event"]["outcome"] == outcome)
        );
        server.join().map_err(|_| "server panic")??;
    }
    Ok(())
}

#[test]
fn a_symbol_body_cannot_substitute_a_foreign_revision_or_claim_a_false_full_span() -> TestResult {
    for case in ["tick", "server", "range", "short_text"] {
        let root = tempfile::tempdir()?;
        let (url, server, requests) = server(vec![
            tool_reply(
                "symbol",
                "read_symbol",
                json!({"file_path":"file.rs","symbol":"alpha"}),
            ),
            answer("body rejected"),
        ])?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let mut events = vec![];
        begin(
            &mut peer,
            "symbols",
            &scope,
            input(root.path(), &url, "read_symbol"),
        )?;
        let call = issued(&mut peer, &mut events)?;
        complete(
            &mut peer,
            &call,
            "ok",
            Some(symbols(&call, vec![node("alpha")], false)),
        )?;
        let body = reverse(&peer, "editor/read_symbol_range", &mut events)?;
        let mut value = json!({"kind":"body","snapshot":{"document":resource()["document"],"source":resource()["source"],
            "range":range(),"text":"🦀β","truncated":false}});
        match case {
            "tick" => value["snapshot"]["document"]["tick"] = json!(8),
            "server" => value["snapshot"]["source"]["server"] = json!("replacement-server"),
            "range" => value["snapshot"]["range"]["end"]["column"] = json!(5),
            _ => value["snapshot"]["text"] = json!("🦀"),
        }
        complete(&mut peer, &body, "ok", Some(value))?;
        assert_eq!(
            response(&peer, "symbols", &mut events)?["result"]["status"],
            "completed"
        );
        assert!(result_text(&requests)?.starts_with("ERROR:"));
        assert!(
            events.iter().any(|m| m["method"] == "session/tool_result"
                && m["params"]["event"]["outcome"] == "failed")
        );
        server.join().map_err(|_| "server panic")??;
    }
    Ok(())
}

#[test]
fn cancel_during_the_second_symbol_read_keeps_the_actual_callback_claimed() -> TestResult {
    let root = tempfile::tempdir()?;
    let (url, server, _requests) = server(vec![tool_reply(
        "symbol",
        "read_symbol",
        json!({"file_path":"file.rs","symbol":"alpha"}),
    )])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut events = vec![];
    begin(
        &mut peer,
        "symbols",
        &scope,
        input(root.path(), &url, "read_symbol"),
    )?;
    let call = issued(&mut peer, &mut events)?;
    complete(
        &mut peer,
        &call,
        "ok",
        Some(symbols(&call, vec![node("alpha")], false)),
    )?;
    let body = reverse(&peer, "editor/read_symbol_range", &mut events)?;
    send(
        &mut peer,
        "abort-symbol",
        "session/abort",
        json!({"scope":body["params"]["scope"]}),
    )?;
    assert_eq!(
        response(&peer, "abort-symbol", &mut events)?["result"]["status"],
        "revoked"
    );
    let mut foreign = body.clone();
    foreign["params"]["scope"]["generation"] = json!(999);
    complete(&mut peer, &foreign, "cancelled", None)?;
    assert_eq!(
        snapshot(&mut peer, &scope, &mut events)?["state"],
        "draining"
    );
    begin(&mut peer, "competing", &scope, prompt(root.path(), &url))?;
    assert_eq!(
        response(&peer, "competing", &mut events)?["error"]["data"]["status"],
        "busy"
    );
    complete(&mut peer, &body, "cancelled", None)?;
    assert_eq!(
        response(&peer, "symbols", &mut events)?["result"]["status"],
        "cancelled"
    );
    assert_eq!(snapshot(&mut peer, &scope, &mut events)?["state"], "idle");
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn symbol_edit_ambiguity_truncation_and_stale_source_never_enter_edit_orchestration() -> TestResult
{
    for case in ["ambiguous", "truncated", "stale", "not_found"] {
        let root = tempfile::tempdir()?;
        let (url, server, requests) = server(vec![
            tool_reply(
                "edit-symbol",
                "edit_by_lsp",
                json!({"file_path":"file.rs","symbol":"alpha","new_content":"replacement"}),
            ),
            answer("symbol edit refused"),
        ])?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let mut events = vec![];
        begin(
            &mut peer,
            "symbol-edit",
            &scope,
            input(root.path(), &url, "edit_by_lsp"),
        )?;
        let call = issued(&mut peer, &mut events)?;
        assert_eq!(call["params"]["parent_tool"], "edit_by_lsp");
        assert_eq!(call["params"]["tool"], "read_file_symbols");
        let nodes = match case {
            "ambiguous" => vec![node("alpha"), node("ALPHA")],
            "not_found" => vec![node("other")],
            _ => vec![node("alpha")],
        };
        let mut observation = symbols(&call, nodes, case == "truncated");
        if case == "stale" {
            observation["snapshot"]["observed_source"]["server"] = json!("replaced-server");
        }
        complete(&mut peer, &call, "ok", Some(observation))?;
        let terminal = response(&peer, "symbol-edit", &mut events)?;
        assert_eq!(terminal["result"]["status"], "completed", "{terminal}");
        assert!(
            !events
                .iter()
                .any(|event| event["method"] == "editor/run_edit")
        );
        assert!(result_text(&requests)?.starts_with("ERROR:"));
        assert!(!root.path().join("file.rs").exists());
        server.join().map_err(|_| "server panic")??;
    }
    Ok(())
}

#[test]
fn symbol_edit_prepare_rejects_foreign_tick_provider_text_and_wire_range() -> TestResult {
    const DOC: &str = "editor_document_12345678-1234-4234-8234-123456789abc";
    const BASE: &str = "head\n  🦀β trailing\n";
    for case in ["tick", "provider", "text", "range"] {
        let root = tempfile::tempdir()?;
        let path = root.path().join("file.rs");
        std::fs::write(&path, BASE)?;
        let (url, server, _requests) = server(vec![
            tool_reply(
                "edit-symbol",
                "edit_by_lsp",
                json!({"file_path":"file.rs","symbol":"alpha","new_content":"REPLACED"}),
            ),
            answer("edit was refused"),
        ])?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let mut events = vec![];
        begin(
            &mut peer,
            "symbol-edit",
            &scope,
            input(root.path(), &url, "edit_by_lsp"),
        )?;
        let capture = reverse(&peer, "editor/prepare_tool", &mut events)?;
        let mut resource = resource();
        resource["document"]["document_id"] = json!(DOC);
        peer.send(json!({"jsonrpc":"2.0","id":capture["id"],"result":{
            "scope":capture["params"]["scope"],"call_id":capture["params"]["call_id"],"resource":resource}}))?;
        let call = reverse(&peer, "editor/call_tool", &mut events)?;
        complete(
            &mut peer,
            &call,
            "ok",
            Some(symbols(&call, vec![node("alpha")], false)),
        )?;
        let edit = reverse(&peer, "editor/run_edit", &mut events)?;
        assert_eq!(edit["params"]["symbol_selection"]["range"], range());
        let mut args = json!({"origin_id":edit["params"]["origin_id"],"root":root.path(),"mode":"agent",
            "intent":{"kind":"symbol","path":"file.rs","new_bytes":8},
            "live":{"id":DOC,"tick":7,"bytes":BASE.len(),"coding":"utf-8-unix","dirty":false,"read_only":false,"disk":super::edits::disk(&path)?},
            "language_source":resource["source"],"config_revision":3,"policy_revision":7,"review_mode":"blocking","save_policy":"buffer_only"});
        match case {
            "tick" => args["live"]["tick"] = json!(8),
            "provider" => args["language_source"]["server"] = json!("foreign-server"),
            "range" => args["range"] = range(),
            _ => {}
        }
        send(
            &mut peer,
            "prepare-symbol",
            "edit/begin",
            json!({"scope":scope,"arguments":args}),
        )?;
        let reply = response(&peer, "prepare-symbol", &mut events)?;
        if case == "text" {
            let id = reply["result"]["preparation_id"].clone();
            assert!(id.is_string(), "{reply}");
            for (part, text) in [("document", BASE), ("new", "FORGED!!")] {
                send(
                    &mut peer,
                    "part",
                    "edit/append",
                    json!({"scope":scope,"arguments":{
                    "origin_id":edit["params"]["origin_id"],"preparation_id":id,"part":part,"offset":0,"text":text}}),
                )?;
                assert!(
                    response(&peer, "part", &mut events)?
                        .get("result")
                        .is_some()
                );
            }
            send(
                &mut peer,
                "prepared",
                "edit/prepare",
                json!({"scope":scope,"arguments":{
                "origin_id":edit["params"]["origin_id"],"preparation_id":id}}),
            )?;
            assert!(
                response(&peer, "prepared", &mut events)?
                    .get("error")
                    .is_some()
            );
        } else {
            assert!(reply.get("error").is_some(), "{reply}");
        }
        assert_eq!(std::fs::read_to_string(&path)?, BASE);
        peer.send(json!({"jsonrpc":"2.0","id":edit["id"],"result":{
            "scope":edit["params"]["scope"],"call_id":edit["params"]["call_id"],"origin_id":edit["params"]["origin_id"],"finished":true,"failure":"rejected"}}))?;
        assert_eq!(
            response(&peer, "symbol-edit", &mut events)?["result"]["status"],
            "completed"
        );
        server.join().map_err(|_| "server panic")??;
    }
    Ok(())
}
