//! Pure mention parsing: no file access, local byte spans and bounded pages.
mod support;
use serde_json::{Value, json};
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn epoch(peer: &mut Peer, frame: usize) -> Result<Value, Box<dyn std::error::Error>> {
    let reply = peer.call(
        "init",
        "initialize",
        json!({"protocol_major":1,"protocol_minor":0,
        "client_version":"mentions","capabilities":[],"limits":{"max_frame_bytes":frame}}),
    )?;
    let epoch = reply["result"]["connection_epoch"].clone();
    assert!(epoch.is_string());
    peer.send(json!({"jsonrpc":"2.0","method":"initialized"}))?;
    Ok(epoch)
}
#[test]
fn minimum_frames_page_complete_mentions_and_preserve_source_identity() -> TestResult {
    let mut peer = Peer::start()?;
    let epoch = epoch(&mut peer, 1024)?;
    let source = (0..60).map(|i| format!("@f{i}.rs ")).collect::<String>();
    let mut offset = 0;
    let mut hash = Value::Null;
    let mut spans = Vec::new();
    let mut pages = 0;
    loop {
        let reply = peer.call(
            "page",
            "mentions/parse",
            json!({"connection_epoch":epoch,"source":source,"offset":offset}),
        )?;
        assert!(reply.to_string().len() <= 1024);
        let page = &reply["result"];
        if hash.is_null() {
            hash = page["source_hash"].clone();
        }
        assert_eq!(page["source_hash"], hash);
        assert_eq!(page["source_bytes"], source.len());
        assert_eq!(page["coordinates"], "utf8_bytes");
        assert_eq!(page["offset"], offset);
        spans.extend(page["spans"].as_array().ok_or("spans")?.iter().cloned());
        let next = page["next_offset"].as_u64().ok_or("next")?;
        pages += 1;
        if page["done"] == true {
            break;
        }
        assert!(next > offset);
        offset = next;
    }
    assert!(pages > 1);
    assert_eq!(spans.len(), 60);
    for span in spans {
        let start = usize::try_from(span["start"].as_u64().ok_or("start")?)?;
        let end = usize::try_from(span["end"].as_u64().ok_or("end")?)?;
        assert_eq!(source.get(start..end), span["raw"].as_str());
    }
    Ok(())
}
#[test]
fn unicode_quotes_literals_and_exact_git_tokens_use_native_spans() -> TestResult {
    let mut peer = Peer::start()?;
    let epoch = epoch(&mut peer, 4096)?;
    let source = "🦀 @file:\"é space.rs\" user@example.com ``` @file:hidden.rs ``` @git:diffusion @git:staged.txt @git:diff.";
    let reply = peer.call(
        "parse",
        "mentions/parse",
        json!({"connection_epoch":epoch,"source":source}),
    )?;
    let spans = reply["result"]["spans"].as_array().ok_or("spans")?;
    assert_eq!(spans.len(), 2);
    assert_eq!(spans.first().ok_or("file")?["start"], 5);
    assert_eq!(spans.first().ok_or("file")?["target"]["path"], "é space.rs");
    assert_eq!(spans.get(1).ok_or("git")?["raw"], "@git:diff");
    assert_eq!(spans.get(1).ok_or("git")?["target"]["type"], "git_diff");
    Ok(())
}
#[test]
fn wrong_epoch_limits_and_unknown_fields_never_publish_a_partial_parse() -> TestResult {
    let mut peer = Peer::start()?;
    let epoch = epoch(&mut peer, 262144)?;
    for params in [
        json!({"connection_epoch":"foreign","source":"@file:a.rs"}),
        json!({"connection_epoch":epoch,"source":"@file:a.rs","offset":2}),
        json!({"connection_epoch":epoch,"source":"x".repeat(65537)}),
        json!({"connection_epoch":epoch,"source":"@f.rs ".repeat(257)}),
        json!({"connection_epoch":epoch,"source":"","grant":true}),
    ] {
        let reply = peer.call("invalid", "mentions/parse", params)?;
        assert!(reply.get("error").is_some());
        assert!(reply.get("result").is_none());
        assert!(!reply.to_string().contains("@file:a.rs"));
    }
    let reply = peer.call(
        "empty",
        "mentions/parse",
        json!({"connection_epoch":epoch,"source":""}),
    )?;
    assert_eq!(reply["result"]["spans"], json!([]));
    assert_eq!(reply["result"]["done"], true);
    let scope = peer.scope()?;
    assert!(scope["session_id"].is_string());
    Ok(())
}
