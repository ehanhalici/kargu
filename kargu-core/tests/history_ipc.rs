//! Native conversation imports/read pages, deferred until the final 3/4/5 gate.
mod support;
use serde_json::{Value, json};
use std::collections::HashMap;
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;

struct Client {
    peer: Peer,
    scope: Value,
    sequence: u64,
    deferred: HashMap<String, Value>,
}
impl Client {
    fn new() -> Result<Self, Box<dyn std::error::Error>> {
        let mut peer = Peer::start()?;
        peer.initialize_with_limit(1024)?;
        let scope = peer.scope()?;
        Ok(Self {
            peer,
            scope,
            sequence: 0,
            deferred: HashMap::new(),
        })
    }
    fn start(
        &mut self,
        method: &str,
        arguments: Value,
    ) -> Result<String, Box<dyn std::error::Error>> {
        self.sequence = self.sequence.checked_add(1).ok_or("sequence")?;
        let id = format!("history:{}", self.sequence);
        self.peer
            .send(json!({"jsonrpc":"2.0", "id":id, "method":method,
                             "params":{"scope":self.scope,"arguments":arguments}}))?;
        Ok(id)
    }
    fn response(&mut self, id: &str) -> Result<Value, Box<dyn std::error::Error>> {
        if let Some(reply) = self.deferred.remove(id) {
            return Ok(reply);
        }
        loop {
            let reply = self.peer.read()?;
            if reply["id"] == id {
                return Ok(reply);
            }
            let other = reply["id"].as_str().ok_or("reply identity")?.to_owned();
            self.deferred.insert(other, reply);
        }
    }
    fn call(
        &mut self,
        method: &str,
        arguments: Value,
    ) -> Result<Value, Box<dyn std::error::Error>> {
        let id = self.start(method, arguments)?;
        self.response(&id)
    }
    fn stage(
        &mut self,
        source: &str,
        revision: Value,
    ) -> Result<Value, Box<dyn std::error::Error>> {
        let begin = self.call(
            "history/begin",
            json!({"revision":revision,"bytes":source.len()}),
        )?;
        let ticket = begin["result"]["upload_id"].clone();
        let page = usize::try_from(begin["result"]["page_bytes"].as_u64().ok_or("page bytes")?)?;
        let mut offset = 0usize;
        while offset < source.len() {
            let end = source.floor_char_boundary(offset.saturating_add(page).min(source.len()));
            let chunk = source.get(offset..end).ok_or("source boundary")?;
            let reply = self.call(
                "history/append",
                json!({"upload_id":ticket,"offset":offset,"text":chunk}),
            )?;
            assert_eq!(reply["result"]["offset"], end);
            offset = end;
        }
        Ok(ticket)
    }
    fn read_message(
        &mut self,
        id: Value,
        revision: Value,
    ) -> Result<Value, Box<dyn std::error::Error>> {
        let mut source = String::new();
        loop {
            let reply = self.call(
                "history/read",
                json!({"message_id":id,"revision":revision,"offset":source.len()}),
            )?;
            source.push_str(reply["result"]["text"].as_str().ok_or("message text")?);
            assert_eq!(reply["result"]["next_offset"], source.len());
            if reply["result"]["complete"] == true {
                return Ok(serde_json::from_str(&source)?);
            }
        }
    }
}

#[test]
fn small_frames_import_preserves_multimodal_content_and_repairs_interrupted_calls() -> TestResult {
    let mut client = Client::new()?;
    let user = json!({"role":"user","content":[{"type":"text","text":"🦀 literal </context>\n".repeat(300)},
        {"type":"image_url","image_url":{"url":"data:image/png;base64,synthetic"}}],
        "provider_metadata":{"signature":"retained", "number":9007199254740993_u64}});
    let source = serde_json::to_string(&json!([
        user,
        {"role":"assistant", "content":null, "tool_calls":[
            {"id":"provider-a","type":"function","function":{"name":"read_file","arguments":"{}"}},
            {"id":"provider-b","type":"function","function":{"name":"bash","arguments":"{}"}}
        ]},
        {"role":"tool","tool_call_id":"provider-a","name":"read_file","content":"actual completed output"}
    ]))?;
    let ticket = client.stage(&source, json!(0))?;
    let commit = client.start("history/commit", json!({"upload_id":ticket}))?;
    client
        .peer
        .send(json!({"jsonrpc":"2.0","id":"ping-during-import","method":"ping","params":{}}))?;
    assert_eq!(
        client.response("ping-during-import")?["result"]["status"],
        "ok"
    );
    let committed = client.response(&commit)?;
    assert_eq!(committed["result"]["messages_total"], 4);
    let revision = committed["result"]["revision"].clone();
    let metadata = client.call("history/messages", json!({"revision":revision,"offset":0}))?;
    let rows = metadata["result"]["messages"]
        .as_array()
        .ok_or("metadata rows")?;
    let first = rows.first().ok_or("first metadata row")?["message_id"].clone();
    assert_eq!(client.read_message(first, revision.clone())?, user);
    let mut offset = 0usize;
    let mut messages = Vec::new();
    loop {
        let page = client.call(
            "history/messages",
            json!({"revision":revision,"offset":offset}),
        )?;
        for row in page["result"]["messages"].as_array().ok_or("page rows")? {
            messages.push(client.read_message(row["message_id"].clone(), revision.clone())?);
        }
        offset = usize::try_from(
            page["result"]["next_offset"]
                .as_u64()
                .ok_or("next offset")?,
        )?;
        if page["result"]["complete"] == true {
            break;
        }
    }
    assert_eq!(messages.len(), 4);
    assert_eq!(
        messages.get(2).ok_or("real result")?["content"],
        "actual completed output"
    );
    let interrupted = messages.get(3).ok_or("interrupted result")?;
    assert_eq!(interrupted["tool_call_id"], "provider-b");
    assert!(
        interrupted["content"]
            .as_str()
            .ok_or("interrupted text")?
            .contains("effects are unknown")
    );
    let stale = client.call("history/begin", json!({"revision":0,"bytes":2}))?;
    assert!(stale.get("error").is_some());
    let invalid = r#"[{"role":"tool","tool_call_id":"orphan","content":"invalid"}]"#;
    let bad_ticket = client.stage(invalid, revision.clone())?;
    let rejected = client.call("history/commit", json!({"upload_id":bad_ticket}))?;
    assert!(rejected.get("error").is_some());
    let after = client.call("history/messages", json!({"revision":revision,"offset":0}))?;
    assert!(after.get("result").is_some());
    Ok(())
}

#[test]
fn foreign_session_and_offset_replays_cannot_change_a_staged_history() -> TestResult {
    let mut client = Client::new()?;
    let begun = client.call("history/begin", json!({"revision":0,"bytes":2}))?;
    let ticket = begun["result"]["upload_id"].clone();
    let owner = client.scope.clone();
    client.peer.send(
        json!({"jsonrpc":"2.0","id":"sibling","method":"session/create",
                           "params":{"application_id":owner["application_id"]}}),
    )?;
    client.scope = client.response("sibling")?["result"].clone();
    let foreign = client.call(
        "history/append",
        json!({"upload_id":ticket,"offset":0,"text":"[]"}),
    )?;
    assert!(foreign.get("error").is_some());
    client.scope = owner;
    let appended = client.call(
        "history/append",
        json!({"upload_id":ticket,"offset":0,"text":"[]"}),
    )?;
    assert_eq!(appended["result"]["offset"], 2);
    let replay = client.call(
        "history/append",
        json!({"upload_id":ticket,"offset":0,"text":"[]"}),
    )?;
    assert!(replay.get("error").is_some());
    let committed = client.call("history/commit", json!({"upload_id":ticket}))?;
    assert_eq!(committed["result"]["messages_total"], 0);
    let repeated = client.call("history/commit", json!({"upload_id":ticket}))?;
    assert!(repeated.get("error").is_some());
    Ok(())
}

#[test]
fn display_pages_are_native_revision_bound_and_do_not_expose_opaque_blocks() -> TestResult {
    let mut client = Client::new()?;
    let first = "first 🦀\r\n".repeat(400);
    let last = "last visible\n";
    let assistant = json!({"role":"assistant","content":[
        {"type":"text","text":first},
        {"type":"reasoning","text":{"opaque":"private reasoning"}},
        {"type":"image_url","image_url":{"url":"private-image"}},
        {"type":"output_text","text":last}],
        "reasoning_content":"private-top-level-reasoning","provider_metadata":{"signature":"private-signature"}});
    let source = json!([{"role":"user","content":"private-user"}, assistant]).to_string();
    let ticket = client.stage(&source, json!(0))?;
    let commit = client.call("history/commit", json!({"upload_id":ticket}))?;
    let revision = commit["result"]["revision"].clone();
    let rows = client.call("history/messages", json!({"revision":revision,"offset":0}))?;
    let rows = rows["result"]["messages"].as_array().ok_or("rows")?;
    let user_id = rows.first().ok_or("user row")?["message_id"].clone();
    let id = rows.get(1).ok_or("assistant row")?["message_id"].clone();
    let first_page = client.call(
        "history/read",
        json!({"revision":revision,
        "message_id":id,"offset":0,"projection":"display"}),
    )?;
    assert_eq!(first_page["result"]["projection"], "display");
    assert_eq!(first_page["result"]["complete"], false);
    let mut display = String::new();
    let mut offset = 0usize;
    loop {
        let page = client.call(
            "history/read",
            json!({"revision":revision,
            "message_id":id,"offset":offset,"projection":"display"}),
        )?;
        assert!(page.get("error").is_none(), "{page}");
        let page = &page["result"];
        assert_eq!(page["message_id"], id);
        assert_eq!(page["revision"], revision);
        assert_eq!(page["offset"], offset);
        display.push_str(page["text"].as_str().ok_or("display text")?);
        let next = usize::try_from(page["next_offset"].as_u64().ok_or("display offset")?)?;
        assert_eq!(next, display.len());
        if page["complete"] == true {
            break;
        }
        assert!(next > offset);
        offset = next;
    }
    assert_eq!(display, format!("{first}{last}"));
    assert_eq!(
        client.read_message(id.clone(), revision.clone())?,
        assistant
    );
    let denied = client.call(
        "history/read",
        json!({"revision":revision,
        "message_id":user_id,"offset":0,"projection":"display"}),
    )?;
    assert!(denied.get("error").is_some());
    // Offset seven is inside the first crab's UTF-8 encoding.
    let denied = client.call(
        "history/read",
        json!({"revision":revision,
        "message_id":id,"offset":7,"projection":"display"}),
    )?;
    assert!(denied.get("error").is_some());
    let ticket = client.stage(
        r#"[{"role":"assistant","content":"replacement"}]"#,
        revision.clone(),
    )?;
    let commit = client.call("history/commit", json!({"upload_id":ticket}))?;
    assert!(commit.get("error").is_none(), "{commit}");
    let stale = client.call(
        "history/read",
        json!({"revision":revision,
        "message_id":id,"offset":first_page["result"]["next_offset"],"projection":"display"}),
    )?;
    assert!(stale.get("error").is_some());
    Ok(())
}
