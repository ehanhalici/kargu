//! Native summary transaction, multimodal/tool-block preservation, cancellation,
//! and context-overflow pipe acceptance tests (6.3c).
use super::*;

fn stage_history(
    peer: &mut Peer,
    scope: &Value,
    tag: &str,
    revision: u64,
    messages: &Value,
    events: &mut Vec<Value>,
) -> Result<u64, Box<dyn std::error::Error>> {
    let source = messages.to_string();
    send(
        peer,
        &format!("{tag}-begin"),
        "history/begin",
        json!({"scope":scope,"arguments":{"revision":revision,"bytes":source.len()}}),
    )?;
    let upload = response(peer, &format!("{tag}-begin"), events)?["result"]["upload_id"].clone();
    assert!(upload.is_string());
    send(
        peer,
        &format!("{tag}-append"),
        "history/append",
        json!({"scope":scope,"arguments":{"upload_id":upload,"offset":0,"text":source}}),
    )?;
    assert!(
        response(peer, &format!("{tag}-append"), events)?
            .get("error")
            .is_none()
    );
    send(
        peer,
        &format!("{tag}-commit"),
        "history/commit",
        json!({"scope":scope,"arguments":{"upload_id":upload}}),
    )?;
    let committed = response(peer, &format!("{tag}-commit"), events)?;
    assert!(committed.get("error").is_none());
    Ok(committed["result"]["revision"]
        .as_u64()
        .ok_or("committed revision")?)
}

fn read_all_history_messages(
    peer: &mut Peer,
    scope: &Value,
    tag: &str,
    events: &mut Vec<Value>,
) -> Result<(u64, Vec<Value>), Box<dyn std::error::Error>> {
    send(
        peer,
        &format!("{tag}-rows"),
        "history/messages",
        json!({"scope":scope,"arguments":{"offset":0}}),
    )?;
    let rows = response(peer, &format!("{tag}-rows"), events)?;
    let revision = rows["result"]["revision"]
        .as_u64()
        .ok_or("history revision")?;
    let items = rows["result"]["messages"]
        .as_array()
        .ok_or("history rows")?
        .clone();
    let mut out = Vec::with_capacity(items.len());
    for (idx, item) in items.iter().enumerate() {
        let id = item["message_id"].clone();
        let req_id = format!("{tag}-read-{idx}");
        send(
            peer,
            &req_id,
            "history/read",
            json!({"scope":scope,"arguments":{"revision":revision,"message_id":id,"offset":0}}),
        )?;
        let stored = response(peer, &req_id, events)?;
        assert_eq!(stored["result"]["complete"], true);
        let msg: Value = serde_json::from_str(
            stored["result"]["text"]
                .as_str()
                .ok_or("stored message text")?,
        )?;
        out.push(msg);
    }
    Ok((revision, out))
}

#[test]
fn native_summary_compacts_multimodal_and_tool_blocks_and_restores_tools_policy() -> TestResult {
    let root = tempfile::tempdir()?;
    let summary_body = "Goal: inspect diagram\nDone: ran grep\nFiles and symbols touched: src/lib.rs\nOpen issues: none\nNext step: answer user";
    let (url, server, requests) = server(vec![
        answer(summary_body),
        answer("Final answer after native compaction"),
    ])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut events = Vec::new();

    let mut bound = prompt(root.path(), &url);
    bound["tools_enabled"] = json!(true);
    bound["turn_limit"] = json!(6);
    publish_target(&mut peer, &scope, &mut bound)?;
    publish_model_metadata(
        &mut peer,
        &scope,
        0,
        json!("captured-model"),
        json!({"context_window": 64}),
        &mut events,
    )?;
    bound["model_revision"] = json!(1);

    let multimodal_user = json!({
        "role": "user",
        "content": [
            {"type": "text", "text": "Inspect this architecture diagram"},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="}}
        ]
    });
    let initial_messages = json!([
        {"role": "system", "content": "You are kargu."},
        {"role": "user", "content": "question 1 with enough text to exceed the small window"},
        {"role": "assistant", "content": "answer 1 with details about the module layout"},
        {"role": "user", "content": "question 2"},
        {
            "role": "assistant",
            "content": null,
            "tool_calls": [{
                "id": "call_hist_1",
                "type": "function",
                "function": {"name": "find_files", "arguments": "{\"pattern\":\"*.rs\"}"}
            }]
        },
        {"role": "tool", "tool_call_id": "call_hist_1", "name": "find_files", "content": "src/lib.rs"},
        {"role": "assistant", "content": "Found src/lib.rs"},
        multimodal_user,
        {"role": "assistant", "content": "Diagram noted."}
    ]);
    let staged_rev = stage_history(
        &mut peer,
        &scope,
        "mm-stage",
        0,
        &initial_messages,
        &mut events,
    )?;

    begin(&mut peer, "compact-mm", &scope, bound)?;
    let terminal = response(&peer, "compact-mm", &mut events)?;
    assert_eq!(terminal["result"]["status"], "completed");
    assert_eq!(
        terminal["result"]["accounting"]["budget"]["compactions_spent"],
        1
    );
    assert_eq!(
        terminal["result"]["accounting"]["budget"]["requests_spent"],
        2
    );

    // 1st outbound request is the tools-off summary turn.
    let summary_req = requests.recv_timeout(Duration::from_secs(2))?;
    assert!(
        summary_req.get("tools").is_none(),
        "Summary turn must strictly omit tools"
    );
    assert!(
        summary_req.get("tool_choice").is_none(),
        "Summary turn must strictly omit tool_choice"
    );
    let summary_msgs = summary_req["messages"]
        .as_array()
        .ok_or("summary messages")?;
    let last_summary_msg = summary_msgs.last().ok_or("last summary msg")?;
    assert_eq!(last_summary_msg["role"], "user");
    assert!(
        last_summary_msg["content"]
            .as_str()
            .is_some_and(|c| c.starts_with("COMPACTION_REQUEST:"))
    );

    // 2nd outbound request is the post-compaction normal turn with tools re-enabled.
    let model_req = requests.recv_timeout(Duration::from_secs(2))?;
    assert!(
        model_req["tools"]
            .as_array()
            .is_some_and(|tools| !tools.is_empty()),
        "Normal conversation tools policy must be restored after summary commit"
    );
    let post_msgs = model_req["messages"].as_array().ok_or("post messages")?;
    assert!(post_msgs.iter().any(|m| {
        m["role"] == "user"
            && m["content"].as_str().is_some_and(|c| {
                c.starts_with("COMPACTION_ACK: Prior work summary:\n") && c.contains(summary_body)
            })
    }));
    assert!(
        !post_msgs.iter().any(|m| {
            m["content"]
                .as_str()
                .is_some_and(|c| c.starts_with("COMPACTION_REQUEST:"))
        }),
        "Ephemeral COMPACTION_REQUEST must never enter committed history"
    );
    // Multimodal block and tool-call atomic pair in preserved tail must survive intact.
    assert!(post_msgs.iter().any(|m| m["content"].is_array()));
    assert!(
        post_msgs
            .iter()
            .any(|m| m["role"] == "tool" && m["tool_call_id"] == "call_hist_1")
    );
    assert!(post_msgs.iter().any(|m| {
        m["role"] == "assistant"
            && m["tool_calls"]
                .as_array()
                .is_some_and(|calls| calls.iter().any(|c| c["id"] == "call_hist_1"))
    }));

    // Verify committed history revision and contents over the pipe.
    let (final_rev, stored_msgs) =
        read_all_history_messages(&mut peer, &scope, "mm-final", &mut events)?;
    assert!(
        final_rev > staged_rev,
        "History revision must advance monotonically across prompt, compaction, and answer"
    );
    assert_eq!(
        terminal["result"]["accounting"]["history_revision"],
        json!(final_rev)
    );
    assert!(stored_msgs.iter().any(|m| {
        m["role"] == "user"
            && m["content"]
                .as_str()
                .is_some_and(|c| c.starts_with("COMPACTION_ACK:"))
    }));
    assert!(stored_msgs.iter().any(|m| m["content"].is_array()));

    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn cancelled_summary_and_late_reply_preserves_original_history_and_revision() -> TestResult {
    let root = tempfile::tempdir()?;
    let (release, wait) = mpsc::channel();
    let mut held_summary = answer("Goal: late summary that must be discarded");
    held_summary.release = Some(wait);
    let (url, server, requests) = server(vec![held_summary])?;

    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut events = Vec::new();

    let mut bound = prompt(root.path(), &url);
    bound["tools_enabled"] = json!(true);
    bound["turn_limit"] = json!(6);
    publish_target(&mut peer, &scope, &mut bound)?;
    publish_model_metadata(
        &mut peer,
        &scope,
        0,
        json!("captured-model"),
        json!({"context_window": 64}),
        &mut events,
    )?;
    bound["model_revision"] = json!(1);

    let initial_messages = json!([
        {"role": "system", "content": "You are kargu."},
        {"role": "user", "content": "u1 long message body for threshold"},
        {"role": "assistant", "content": "a1 long message body for threshold"},
        {"role": "user", "content": "u2 long message body for threshold"},
        {"role": "assistant", "content": "a2 long message body for threshold"},
        {"role": "user", "content": "u3 long message body for threshold"},
        {"role": "assistant", "content": "a3 long message body for threshold"}
    ]);
    let staged_rev = stage_history(
        &mut peer,
        &scope,
        "cancel-stage",
        0,
        &initial_messages,
        &mut events,
    )?;

    begin(&mut peer, "cancel-summary", &scope, bound)?;
    // Wait until the summary request has reached the fixture HTTP server.
    let summary_req = requests.recv_timeout(Duration::from_secs(3))?;
    assert!(summary_req.get("tools").is_none());

    let active = snapshot(&mut peer, &scope, &mut events)?;
    assert_eq!(active["state"], "running");
    // Only the user prompt of `begin` was appended (staged_rev + 1); summary has not mutated history.
    let pre_summary_rev = staged_rev + 1;
    assert_eq!(active["history_revision"], json!(pre_summary_rev));

    let run = active["active_run"].clone();
    send(
        &mut peer,
        "abort-summary",
        "session/abort",
        json!({"scope":run}),
    )?;
    assert_eq!(
        response(&peer, "abort-summary", &mut events)?["result"]["status"],
        "revoked"
    );
    // Let the fixture server send the late summary reply after abort.
    let _ = release.send(());

    let terminal = response(&peer, "cancel-summary", &mut events)?;
    assert_eq!(terminal["result"]["status"], "cancelled");
    assert_eq!(
        terminal["result"]["accounting"]["history_revision"],
        json!(pre_summary_rev)
    );

    let (after_rev, stored_msgs) =
        read_all_history_messages(&mut peer, &scope, "cancel-after", &mut events)?;
    assert_eq!(after_rev, pre_summary_rev);
    assert_eq!(stored_msgs.len(), 8);
    assert!(
        !stored_msgs.iter().any(|m| {
            m["content"].as_str().is_some_and(|c| {
                c.starts_with("COMPACTION_ACK:") || c.starts_with("COMPACTION_REQUEST:")
            })
        }),
        "Cancelled summary + late reply must leave original history completely untouched"
    );

    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn context_overflow_compacts_once_after_orphan_repair_and_second_overflow_fails_closed()
-> TestResult {
    let root = tempfile::tempdir()?;
    std::fs::write(root.path().join("sample.txt"), "hello world\n")?;

    let overflow_reply = || Reply {
        status: 400,
        content_type: "application/json",
        release: None,
        body: json!({
            "error": {
                "code": "context_length_exceeded",
                "message": "This model's maximum context length is exceeded."
            }
        })
        .to_string(),
    };

    let (url, server, requests) = server(vec![
        // Run 1: Model Turn 1 overflows -> Summary Turn succeeds -> Model Turn 2 answers.
        overflow_reply(),
        answer("Summary after reactive context overflow"),
        answer("Completed after reactive overflow recovery"),
        // Run 2: Model Turn 1 overflows -> Summary Turn succeeds -> Model Turn 2 overflows again (second overflow!).
        overflow_reply(),
        answer("Summary in second run"),
        overflow_reply(),
    ])?;

    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut events = Vec::new();

    // Stage history containing a tool call + result pair to verify atomic repair/tail integrity.
    let initial_messages = json!([
        {"role": "system", "content": "You are kargu."},
        {"role": "user", "content": "Read sample.txt"},
        {
            "role": "assistant",
            "content": null,
            "tool_calls": [{
                "id": "call_read_1",
                "type": "function",
                "function": {"name": "read_file", "arguments": "{\"path\":\"sample.txt\"}"}
            }]
        },
        {"role": "tool", "tool_call_id": "call_read_1", "name": "read_file", "content": "[execution cancelled before completion]"}
    ]);
    stage_history(
        &mut peer,
        &scope,
        "ovf-stage",
        0,
        &initial_messages,
        &mut events,
    )?;

    let mut bound = prompt(root.path(), &url);
    bound["tools_enabled"] = json!(true);
    bound["turn_limit"] = json!(6);
    publish_target(&mut peer, &scope, &mut bound)?;

    begin(&mut peer, "ovf-run-1", &scope, bound.clone())?;
    let term1 = response(&peer, "ovf-run-1", &mut events)?;
    assert_eq!(term1["result"]["status"], "completed");
    assert_eq!(
        term1["result"]["accounting"]["budget"]["compactions_spent"],
        1
    );
    assert_eq!(term1["result"]["accounting"]["budget"]["requests_spent"], 3);

    let req1 = requests.recv_timeout(Duration::from_secs(2))?;
    assert!(req1["tools"].as_array().is_some_and(|t| !t.is_empty()));
    let req2_summary = requests.recv_timeout(Duration::from_secs(2))?;
    assert!(req2_summary.get("tools").is_none());
    let req3_resumed = requests.recv_timeout(Duration::from_secs(2))?;
    assert!(
        req3_resumed["tools"]
            .as_array()
            .is_some_and(|t| !t.is_empty())
    );

    // Run 2: second overflow in the same run must fail closed without a second compaction!
    begin(&mut peer, "ovf-run-2", &scope, bound)?;
    let term2 = response(&peer, "ovf-run-2", &mut events)?;
    assert_eq!(term2["result"]["status"], "failed");
    assert_eq!(
        term2["result"]["accounting"]["budget"]["compactions_spent"], 1,
        "Second overflow must not admit a second compaction turn"
    );
    assert_eq!(
        term2["result"]["accounting"]["failure"]["code"],
        "context_overflow"
    );

    let (rev_after_fail, msgs_after_fail) =
        read_all_history_messages(&mut peer, &scope, "ovf-after-fail", &mut events)?;
    assert_eq!(
        term2["result"]["accounting"]["history_revision"],
        json!(rev_after_fail)
    );
    assert!(msgs_after_fail.iter().any(|m| {
        m["content"]
            .as_str()
            .is_some_and(|c| c.contains("Summary in second run"))
    }));

    server.join().map_err(|_| "server panic")??;
    Ok(())
}
