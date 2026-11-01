//! Real provider/pipe/edit acceptance sources; run only at the final 3/4/5 gate.
use super::editor::{reverse, tool_reply};
use super::*;
use sha2::{Digest, Sha256};
use std::{
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::Path,
};

const TEXT: &str = "new 🦀\n";
const PATCH: &str = "--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new 🦀\n";
const DOC: &str = "editor_document_12345678-1234-4234-8234-123456789abc";

fn edit_rpc(
    peer: &mut Peer,
    scope: &Value,
    method: &str,
    args: Value,
    events: &mut Vec<Value>,
) -> Result<Value, Box<dyn std::error::Error>> {
    send(
        peer,
        "edit-fixture",
        method,
        json!({"scope":scope,"arguments":args}),
    )?;
    response(peer, "edit-fixture", events)
}
fn ticket(request: &Value, preparation: &Value) -> Value {
    json!({"origin_id":request["params"]["origin_id"],"preparation_id":preparation})
}
fn begin_args(root: &Path, request: &Value, intent: Value, review: &str) -> Value {
    json!({"origin_id":request["params"]["origin_id"],"root":root,"mode":"agent","intent":intent,"live":null,
        "config_revision":3,"policy_revision":7,"review_mode":review,"save_policy":"save"})
}
fn prepared(
    peer: &mut Peer,
    scope: &Value,
    request: &Value,
    root: &Path,
    tool: &str,
    review: &str,
    events: &mut Vec<Value>,
) -> Result<(Value, Value), Box<dyn std::error::Error>> {
    let intent = match tool {
        "edit_file" => {
            json!({"kind":"replace","path":"file.txt","old_bytes":4,"new_bytes":TEXT.len()})
        }
        "apply_patch" => json!({"kind":"patch","patch_bytes":PATCH.len()}),
        _ => json!({"kind":"write","path":"file.txt","new_bytes":TEXT.len()}),
    };
    let reply = edit_rpc(
        peer,
        scope,
        "edit/begin",
        begin_args(root, request, intent, review),
        events,
    )?;
    let id = reply["result"]["preparation_id"].clone();
    assert!(id.is_string(), "{reply}");
    let parts = match tool {
        "edit_file" => vec![("old", "old\n"), ("new", TEXT)],
        "apply_patch" => vec![("patch", PATCH)],
        _ => vec![("new", TEXT)],
    };
    for (part, text) in parts {
        let mut args = ticket(request, &id);
        args["part"] = json!(part);
        args["offset"] = json!(0);
        args["text"] = json!(text);
        let ack = edit_rpc(peer, scope, "edit/append", args, events)?;
        assert!(ack.get("result").is_some(), "{ack}");
    }
    if tool == "apply_patch" {
        let inspected = edit_rpc(peer, scope, "edit/inspect", ticket(request, &id), events)?;
        assert_eq!(inspected["result"]["inspected"], true, "{inspected}");
    }
    let reply = edit_rpc(peer, scope, "edit/prepare", ticket(request, &id), events)?;
    assert!(reply.get("result").is_some(), "{reply}");
    let descriptor = if tool == "apply_patch" {
        let mut args = ticket(request, &id);
        args["offset"] = json!(0);
        edit_rpc(peer, scope, "edit/files", args, events)?["result"]["files"][0].clone()
    } else {
        reply["result"].clone()
    };
    Ok((id, descriptor))
}
fn authorized(
    peer: &mut Peer,
    scope: &Value,
    request: &Value,
    id: &Value,
    events: &mut Vec<Value>,
) -> Result<Value, Box<dyn std::error::Error>> {
    let mut args = ticket(request, id);
    args["presenter"] = json!("available");
    let reply = edit_rpc(peer, scope, "edit/authorize", args, events)?;
    assert!(reply.get("result").is_some(), "{reply}");
    Ok(reply["result"].clone())
}
fn issue(
    peer: &mut Peer,
    scope: &Value,
    request: &Value,
    grant: &Value,
    descriptor: &Value,
    journal: &Path,
    events: &mut Vec<Value>,
) -> Result<Value, Box<dyn std::error::Error>> {
    let args = json!({"origin_id":request["params"]["origin_id"],"edit_id":grant["edit_id"],"revision":1,
        "witness":{"file":0,"base_hash":descriptor["base_hash"],"document":{"id":DOC,"tick":1,
            "bytes":descriptor["base_bytes"],"coding":"utf-8-unix","dirty":false,"read_only":false,"disk":descriptor["disk"]}}});
    let reply = edit_rpc(peer, scope, "edit/preflight", args, events)?;
    assert_eq!(reply["result"]["state"], "preflighted", "{reply}");
    let reply = edit_rpc(
        peer,
        scope,
        "edit/issue",
        json!({"origin_id":request["params"]["origin_id"],
        "edit_id":grant["edit_id"],"revision":1,"journal_directory":journal}),
        events,
    )?;
    assert_eq!(reply["result"]["state"], "issued", "{reply}");
    Ok(reply["result"]["issued_token"].clone())
}
pub(super) fn disk(path: &Path) -> Result<Value, Box<dyn std::error::Error>> {
    let m = fs::metadata(path)?;
    Ok(
        json!({"kind":"file","version":{"device":m.dev(),"inode":m.ino(),"bytes":m.len(),
        "mtime_ns":(i128::from(m.mtime())*1_000_000_000+i128::from(m.mtime_nsec())).to_string(),
        "ctime_ns":(i128::from(m.ctime())*1_000_000_000+i128::from(m.ctime_nsec())).to_string()}}),
    )
}
fn receipt(
    peer: &mut Peer,
    scope: &Value,
    request: &Value,
    grant: &Value,
    token: &Value,
    path: &Path,
    events: &mut Vec<Value>,
) -> Result<Value, Box<dyn std::error::Error>> {
    let observation = json!({"file":0,"progress":"save_returned","write_tick":2,"written_bytes":TEXT.len(),
        "after":{"kind":"document","document":{"id":DOC,"tick":3,"bytes":TEXT.len(),"coding":"utf-8-unix",
            "dirty":false,"read_only":false,"disk":disk(path)?},"encoded_hash":format!("{:x}",Sha256::digest(TEXT.as_bytes()))}});
    let inputs = [
        json!({"action":"file","observation":observation}),
        json!({"action":"append","file":0,"part":"written","offset":0,"text":TEXT}),
        json!({"action":"append","file":0,"part":"after","offset":0,"text":TEXT}),
        json!({"action":"commit"}),
    ];
    let mut last = Value::Null;
    for input in inputs {
        last = edit_rpc(
            peer,
            scope,
            "edit/receipt",
            json!({"origin_id":request["params"]["origin_id"],"edit_id":grant["edit_id"],
            "revision":1,"issued_token":token,"input":input}),
            events,
        )?;
        assert!(last.get("result").is_some(), "{last}");
    }
    Ok(last)
}
fn complete(peer: &mut Peer, request: &Value) -> TestResult {
    peer.send(json!({"jsonrpc":"2.0","id":request["id"],"result":{"scope":request["params"]["scope"],
        "call_id":request["params"]["call_id"],"origin_id":request["params"]["origin_id"],"finished":true,"failure":null}}))
}
fn model_args(tool: &str) -> Value {
    match tool {
        "edit_file" => json!({"file_path":"file.txt","old_string":"old\n","new_string":TEXT}),
        "apply_patch" => json!({"patch":PATCH}),
        _ => json!({"file_path":"file.txt","contents":TEXT}),
    }
}

#[test]
fn native_edits_share_one_model_budget_and_commit_verified_receipts_before_the_next_turn()
-> TestResult {
    for tool in ["write_file", "edit_file", "apply_patch"] {
        let root = tempfile::tempdir()?;
        let journal = tempfile::tempdir()?;
        fs::set_permissions(journal.path(), fs::Permissions::from_mode(0o700))?;
        let path = root.path().join("file.txt");
        fs::write(&path, "old\n")?;
        let (url, server, requests) = server(vec![
            tool_reply("call-edit", tool, model_args(tool)),
            answer("edited"),
        ])?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let mut events = vec![];
        let mut input = prompt(root.path(), &url);
        input["tools_enabled"] = json!(true);
        input["editor_available"] = json!([tool]);
        input["tool_limit"] = json!(1);
        input["edit_policy"] = json!({"review_mode":"auto","save_policy":"save"});
        begin(&mut peer, "native-edit", &scope, input)?;
        let request = reverse(&peer, "editor/run_edit", &mut events)?;
        assert_eq!(request["params"]["tool"], tool);
        let (prep, descriptor) = prepared(
            &mut peer,
            &scope,
            &request,
            root.path(),
            tool,
            "auto",
            &mut events,
        )?;
        let grant = authorized(&mut peer, &scope, &request, &prep, &mut events)?;
        assert_eq!(grant["state"], "authorized");
        let token = issue(
            &mut peer,
            &scope,
            &request,
            &grant,
            &descriptor,
            journal.path(),
            &mut events,
        )?;
        fs::write(&path, TEXT)?;
        let result = receipt(
            &mut peer,
            &scope,
            &request,
            &grant,
            &token,
            &path,
            &mut events,
        )?;
        assert_eq!(result["result"]["receipt"]["outcome"], "applied_full");
        complete(&mut peer, &request)?;
        let terminal = response(&peer, "native-edit", &mut events)?;
        assert_eq!(terminal["result"]["status"], "completed", "{terminal}");
        assert_eq!(
            terminal["result"]["accounting"]["budget"]["requests_spent"],
            2
        );
        let _first = requests.recv_timeout(Duration::from_secs(2))?;
        let next = requests.recv_timeout(Duration::from_secs(2))?;
        let results: Vec<_> = next["messages"]
            .as_array()
            .ok_or("messages")?
            .iter()
            .filter(|m| m["role"] == "tool")
            .collect();
        assert_eq!(results.len(), 1);
        let message = results.first().ok_or("tool result")?;
        assert_eq!(message["tool_call_id"], "call-edit");
        let facts: Value =
            serde_json::from_str(message["content"].as_str().ok_or("tool content")?)?;
        assert_eq!(facts["outcome"], "applied_full");
        assert_eq!(facts["files_saved"], 1);
        assert_eq!(facts["files"][0]["path"], "file.txt");
        assert_eq!(fs::read_to_string(&path)?, TEXT);
        server.join().map_err(|_| "server panic")??;
    }
    Ok(())
}

#[test]
fn rejected_native_review_settles_only_the_edit_and_the_agent_continues() -> TestResult {
    let root = tempfile::tempdir()?;
    fs::write(root.path().join("file.txt"), "old\n")?;
    let (url, server, requests) = server(vec![
        tool_reply("call-edit", "write_file", model_args("write_file")),
        answer("review was rejected"),
    ])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut events = vec![];
    let mut input = prompt(root.path(), &url);
    input["tools_enabled"] = json!(true);
    input["editor_available"] = json!(["write_file"]);
    input["tool_limit"] = json!(1);
    input["edit_policy"] = json!({"review_mode":"blocking","save_policy":"save"});
    begin(&mut peer, "native-edit", &scope, input)?;
    let request = reverse(&peer, "editor/run_edit", &mut events)?;
    let (prep, _) = prepared(
        &mut peer,
        &scope,
        &request,
        root.path(),
        "write_file",
        "blocking",
        &mut events,
    )?;
    let grant = authorized(&mut peer, &scope, &request, &prep, &mut events)?;
    assert_eq!(grant["state"], "review");
    let rejected = edit_rpc(
        &mut peer,
        &scope,
        "edit/decision",
        json!({"origin_id":request["params"]["origin_id"],
        "edit_id":grant["edit_id"],"revision":1,"decision":"reject"}),
        &mut events,
    )?;
    assert_eq!(rejected["error"]["data"]["status"], "rejected");
    complete(&mut peer, &request)?;
    let terminal = response(&peer, "native-edit", &mut events)?;
    assert_eq!(terminal["result"]["status"], "completed", "{terminal}");
    let _first = requests.recv_timeout(Duration::from_secs(2))?;
    let next = requests.recv_timeout(Duration::from_secs(2))?;
    assert!(
        next["messages"]
            .as_array()
            .ok_or("messages")?
            .last()
            .ok_or("tool result")?["content"]
            .as_str()
            .ok_or("text")?
            .contains("rejected")
    );
    assert_eq!(fs::read_to_string(root.path().join("file.txt"))?, "old\n");
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn native_edit_rejects_foreign_policy_and_uploaded_arguments_before_io() -> TestResult {
    let root = tempfile::tempdir()?;
    fs::write(root.path().join("file.txt"), "old\n")?;
    let (url, server, requests) = server(vec![
        tool_reply("call-edit", "write_file", model_args("write_file")),
        answer("edit failed"),
    ])?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut events = vec![];
    let mut input = prompt(root.path(), &url);
    input["tools_enabled"] = json!(true);
    input["editor_available"] = json!(["write_file"]);
    input["edit_policy"] = json!({"review_mode":"blocking","save_policy":"save"});
    begin(&mut peer, "native-edit", &scope, input)?;
    let request = reverse(&peer, "editor/run_edit", &mut events)?;
    let intent = json!({"kind":"write","path":"file.txt","new_bytes":TEXT.len()});
    let unapproved = edit_rpc(
        &mut peer,
        &scope,
        "edit/begin",
        begin_args(root.path(), &request, intent.clone(), "auto"),
        &mut events,
    )?;
    assert!(unapproved.get("error").is_some(), "{unapproved}");
    let foreign_path = json!({"kind":"write","path":"missing/foreign.txt","new_bytes":TEXT.len()});
    let started = edit_rpc(
        &mut peer,
        &scope,
        "edit/begin",
        begin_args(root.path(), &request, foreign_path, "blocking"),
        &mut events,
    )?;
    let prep = started["result"]["preparation_id"].clone();
    assert!(prep.is_string(), "{started}");
    let mut args = ticket(&request, &prep);
    args["part"] = json!("new");
    args["offset"] = json!(0);
    args["text"] = json!(TEXT);
    assert!(
        edit_rpc(&mut peer, &scope, "edit/append", args, &mut events)?
            .get("result")
            .is_some()
    );
    let refused = edit_rpc(
        &mut peer,
        &scope,
        "edit/prepare",
        ticket(&request, &prep),
        &mut events,
    )?;
    assert!(refused.get("error").is_some(), "{refused}");
    // A refused source cannot reallocate a second intent under the same call.
    let replay = edit_rpc(
        &mut peer,
        &scope,
        "edit/begin",
        begin_args(root.path(), &request, intent, "blocking"),
        &mut events,
    )?;
    assert!(replay.get("error").is_some(), "{replay}");
    complete(&mut peer, &request)?;
    let terminal = response(&peer, "native-edit", &mut events)?;
    assert_eq!(terminal["result"]["status"], "completed", "{terminal}");
    assert_eq!(fs::read_to_string(root.path().join("file.txt"))?, "old\n");
    assert!(!root.path().join("missing").exists());
    let _ = requests.recv_timeout(Duration::from_secs(2))?;
    let _ = requests.recv_timeout(Duration::from_secs(2))?;
    server.join().map_err(|_| "server panic")??;
    Ok(())
}

#[test]
fn abort_retains_native_edit_claim_until_issued_editor_activity_really_quiesces() -> TestResult {
    for applied in [false, true] {
        let root = tempfile::tempdir()?;
        let journal = tempfile::tempdir()?;
        fs::set_permissions(journal.path(), fs::Permissions::from_mode(0o700))?;
        fs::write(root.path().join("file.txt"), "old\n")?;
        let (url, server, _requests) = server(vec![tool_reply(
            "call-edit",
            "write_file",
            model_args("write_file"),
        )])?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let mut events = vec![];
        let mut input = prompt(root.path(), &url);
        input["tools_enabled"] = json!(true);
        input["editor_available"] = json!(["write_file"]);
        input["edit_policy"] = json!({"review_mode":"auto","save_policy":"save"});
        begin(&mut peer, "native-edit", &scope, input)?;
        let request = reverse(&peer, "editor/run_edit", &mut events)?;
        let (prep, descriptor) = prepared(
            &mut peer,
            &scope,
            &request,
            root.path(),
            "write_file",
            "auto",
            &mut events,
        )?;
        let grant = authorized(&mut peer, &scope, &request, &prep, &mut events)?;
        let token = issue(
            &mut peer,
            &scope,
            &request,
            &grant,
            &descriptor,
            journal.path(),
            &mut events,
        )?;
        send(
            &mut peer,
            "abort",
            "session/abort",
            json!({"scope":request["params"]["scope"]}),
        )?;
        assert_eq!(
            response(&peer, "abort", &mut events)?["result"]["status"],
            "revoked"
        );
        begin(&mut peer, "competing", &scope, prompt(root.path(), &url))?;
        assert_eq!(
            response(&peer, "competing", &mut events)?["error"]["data"]["status"],
            "busy"
        );
        // An orchestration callback is not a receipt or proof of actual drain.
        complete(&mut peer, &request)?;
        begin(
            &mut peer,
            "still-competing",
            &scope,
            prompt(root.path(), &url),
        )?;
        assert_eq!(
            response(&peer, "still-competing", &mut events)?["error"]["data"]["status"],
            "busy"
        );
        let settled = if applied {
            // The handler entered before Stop and returned a real completed save.
            // Revocation cannot erase these facts or synthesize a failed write.
            let path = root.path().join("file.txt");
            fs::write(&path, TEXT)?;
            receipt(
                &mut peer,
                &scope,
                &request,
                &grant,
                &token,
                &path,
                &mut events,
            )?
        } else {
            let args = json!({"origin_id":request["params"]["origin_id"],"edit_id":grant["edit_id"],"revision":1,
            "issued_token":token,"effect":"not_dispatched"});
            edit_rpc(&mut peer, &scope, "edit/quiescent", args, &mut events)?
        };
        assert!(settled.get("result").is_some(), "{settled}");
        assert_eq!(
            response(&peer, "native-edit", &mut events)?["result"]["status"],
            "cancelled"
        );
        assert_eq!(
            fs::read_to_string(root.path().join("file.txt"))?,
            if applied { TEXT } else { "old\n" }
        );
        let tool_results: Vec<_> = events
            .iter()
            .filter(|event| event["method"] == "session/tool_result")
            .collect();
        assert_eq!(tool_results.len(), 1);
        assert_eq!(
            tool_results.first().ok_or("tool outcome")?["params"]["event"]["outcome"],
            if applied { "ok" } else { "cancelled" }
        );
        let replay = edit_rpc(
            &mut peer,
            &scope,
            "edit/begin",
            begin_args(
                root.path(),
                &request,
                json!({"kind":"write","path":"file.txt","new_bytes":TEXT.len()}),
                "auto",
            ),
            &mut events,
        )?;
        assert!(replay.get("error").is_some(), "{replay}");
        server.join().map_err(|_| "server panic")??;
    }
    Ok(())
}
