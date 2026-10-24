//! Real-pipe framing, shutdown and adversarial consumer checks.

mod support;
use serde_json::{Value, json};
use std::time::{Duration, Instant};
use support::Peer;

type TestResult = Result<(), Box<dyn std::error::Error>>;

fn command_arguments(root: &std::path::Path, script: &str) -> Value {
    let shell = std::env::var_os("PATH")
        .and_then(|paths| {
            std::env::split_paths(&paths)
                .map(|p| p.join("sh"))
                .find(|p| p.is_file())
        })
        .unwrap_or_else(|| "/bin/sh".into());
    json!({"root":root,"mode":"agent","program":shell,"arguments":["-c",script],
        "cwd":null,"timeout_ms":1000,"environment":{},"config_revision":1,"policy_revision":1})
}

#[test]
fn approved_program_argv_keeps_mailbox_live_and_delivers_once() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    peer.send(json!({"jsonrpc":"2.0","id":3,"method":"tool/execute",
        "params":{"scope":scope,"arguments":command_arguments(root.path(), "printf ready; printf warning >&2; exit 7")}}))?;
    let review = peer.read()?;
    assert_eq!(review["method"], "editor/request_approval");
    assert_eq!(review["params"]["request_id"], 3);
    assert!(!root.path().join("effect").exists());
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"ping"}))?;
    assert_eq!(peer.read()?["result"]["status"], "ok");
    peer.send(json!({"jsonrpc":"2.0","id":review["id"],"result":{"approved":true}}))?;
    let result = peer.read()?;
    assert_eq!(result["id"], 3);
    assert_eq!(result["result"]["stdout"], "ready");
    assert_eq!(result["result"]["stderr"], "warning");
    assert_eq!(result["result"]["exit_code"], 7);
    assert_eq!(result["result"]["outcome"], "failed");
    assert_eq!(result["result"]["cleanup_complete"], true);
    peer.send(json!({"jsonrpc":"2.0","id":review["id"],"result":{"approved":true}}))?;
    peer.send(json!({"jsonrpc":"2.0","id":5,"method":"session/close","params":scope}))?;
    assert_eq!(peer.read()?["id"], 5);
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn rejected_or_missing_approval_never_runs_and_next_call_can_start() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    for (index, response) in [
        json!({"approved":false}),
        json!({"approved":"true"}),
        json!({"approved":true,"extra":true}),
    ]
    .into_iter()
    .enumerate()
    {
        let id = i64::try_from(index)?.checked_add(3).ok_or("overflow")?;
        peer.send(
            json!({"jsonrpc":"2.0","id":id,"method":"tool/execute","params":{
            "scope":scope,"arguments":command_arguments(root.path(), "printf bad > effect")}}),
        )?;
        let review = peer.read()?;
        assert_eq!(review["method"], "editor/request_approval");
        peer.send(json!({"jsonrpc":"2.0","id":review["id"],"result":response}))?;
        assert_eq!(peer.read()?["error"]["data"]["status"], "rejected");
        assert!(!root.path().join("effect").exists());
    }
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn closing_owner_cancels_review_and_late_approval_is_inert() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    peer.send(
        json!({"jsonrpc":"2.0","id":3,"method":"tool/execute","params":{
        "scope":scope,"arguments":command_arguments(root.path(), "printf bad > effect")}}),
    )?;
    let review = peer.read()?;
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"session/close","params":scope}))?;
    assert_eq!(peer.read()?["result"]["status"], "closed");
    let cancel = peer.read()?;
    assert_eq!(cancel["method"], "rpc/cancel");
    assert_eq!(peer.read()?["error"]["data"]["status"], "stale_owner");
    peer.send(json!({"jsonrpc":"2.0","id":review["id"],"result":{"approved":true}}))?;
    peer.send(json!({"jsonrpc":"2.0","id":5,"method":"ping"}))?;
    assert_eq!(peer.read()?["id"], 5);
    assert!(!root.path().join("effect").exists());
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn arbitrary_command_mode_path_and_owner_are_rejected_without_review() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    for mode in ["ask", "plan", "debug"] {
        let mut arguments = command_arguments(root.path(), "true");
        arguments["mode"] = json!(mode);
        peer.send(json!({"jsonrpc":"2.0","id":3,"method":"tool/execute","params":{"scope":scope,"arguments":arguments}}))?;
        assert_eq!(peer.read()?["error"]["data"]["status"], "rejected");
    }
    let mut arguments = command_arguments(root.path(), "true");
    arguments["cwd"] = json!("../escape");
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"tool/execute","params":{"scope":scope,"arguments":arguments}}))?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "rejected");
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn approved_command_output_is_bounded_and_timeout_is_typed() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    for (id, script, timeout) in [
        (3, "printf '%070000d' 0", 1000),
        (4, "while :; do :; done", 80),
    ] {
        let mut arguments = command_arguments(root.path(), script);
        arguments["timeout_ms"] = json!(timeout);
        peer.send(json!({"jsonrpc":"2.0","id":id,"method":"tool/execute","params":{"scope":scope,"arguments":arguments}}))?;
        let review = peer.read()?;
        peer.send(json!({"jsonrpc":"2.0","id":review["id"],"result":{"approved":true}}))?;
        let result = peer.read()?;
        if id == 3 {
            assert_eq!(result["result"]["truncated"], true);
            assert_eq!(
                result["result"]["stdout"]
                    .as_str()
                    .ok_or("stdout missing")?
                    .len(),
                65536
            );
        } else {
            assert_eq!(result["result"]["outcome"], "timeout");
        }
    }
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn cancelled_request_and_eof_reap_the_approved_process_before_release() -> TestResult {
    for eof in [false, true] {
        let root = tempfile::tempdir()?;
        let mut peer = Peer::start()?;
        peer.initialize()?;
        let scope = peer.scope()?;
        let arguments = command_arguments(
            root.path(),
            "printf '%s' $$ > leader.pid; while :; do :; done",
        );
        peer.send(json!({"jsonrpc":"2.0","id":3,"method":"tool/execute","params":{"scope":scope,"arguments":arguments}}))?;
        let review = peer.read()?;
        peer.send(json!({"jsonrpc":"2.0","id":review["id"],"result":{"approved":true}}))?;
        let deadline = Instant::now() + Duration::from_secs(2);
        let pid = loop {
            if let Ok(text) = std::fs::read_to_string(root.path().join("leader.pid"))
                && let Ok(pid) = text.parse::<u32>()
            {
                break pid;
            }
            if Instant::now() >= deadline {
                return Err("process did not start".into());
            }
            std::thread::sleep(Duration::from_millis(5));
        };
        if eof {
            peer.input.take();
        } else {
            peer.send(json!({"jsonrpc":"2.0","method":"rpc/cancel","params":{"request_id":3,"scope":peer.epoch}}))?;
            assert_eq!(peer.read()?["error"]["data"]["status"], "cancelled");
            assert!(!std::path::Path::new(&format!("/proc/{pid}")).exists());
            peer.input.take();
        }
        assert!(peer.wait()?);
        assert!(!std::path::Path::new(&format!("/proc/{pid}")).exists());
    }
    Ok(())
}

#[test]
fn native_listing_uses_the_same_owner_and_nonblocking_mailbox() -> TestResult {
    let root = tempfile::tempdir()?;
    std::fs::create_dir(root.path().join("sub"))?;
    std::fs::write(root.path().join("top.el"), "fixture")?;
    std::fs::write(root.path().join("sub/inner.el"), "fixture")?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let arguments = json!({"root":root.path(),"path":null,"skip_directories":[]});
    peer.send(
        json!({"jsonrpc":"2.0","id":3,"method":"workspace/listFiles",
        "params":{"scope":scope,"arguments":arguments}}),
    )?;
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"ping"}))?;
    let replies = [peer.read()?, peer.read()?];
    let listing = replies
        .iter()
        .find(|reply| reply["id"] == 3)
        .ok_or("listing missing")?;
    let text = listing["result"]["text"]
        .as_str()
        .ok_or("ls text missing")?;
    assert!(text.contains("sub"));
    assert!(text.contains("top.el"));
    assert!(listing["result"].get("entries").is_none());
    assert!(
        replies
            .iter()
            .any(|reply| reply["id"] == 4 && reply["result"]["status"] == "ok")
    );
    peer.send(json!({"jsonrpc":"2.0","id":5,"method":"session/close","params":scope}))?;
    assert_eq!(peer.read()?["result"]["status"], "closed");
    peer.send(
        json!({"jsonrpc":"2.0","id":6,"method":"workspace/listFiles",
        "params":{"scope":scope,"arguments":arguments}}),
    )?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "stale_owner");
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn listing_invalid_dto_and_foreign_owner_are_rejected_before_io() -> TestResult {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut arguments = json!({"root":"/kargu-nonexistent-fixture-root","path":null,
        "skip_directories":[]});
    arguments["unexpected"] = json!(true);
    peer.send(
        json!({"jsonrpc":"2.0","id":3,"method":"workspace/listFiles",
        "params":{"scope":scope,"arguments":arguments}}),
    )?;
    assert_eq!(peer.read()?["error"]["code"], -32602);
    arguments
        .as_object_mut()
        .ok_or("not an object")?
        .remove("unexpected");
    let mut foreign = scope;
    foreign["application_id"] = json!(kargu_core::domain::ApplicationId::new());
    peer.send(
        json!({"jsonrpc":"2.0","id":4,"method":"workspace/listFiles",
        "params":{"scope":foreign,"arguments":arguments}}),
    )?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "stale_owner");
    peer.send(json!({"jsonrpc":"2.0","id":5,"method":"ping"}))?;
    assert_eq!(peer.read()?["result"]["status"], "ok");
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn oversized_listing_is_a_scoped_error_and_ping_survives() -> TestResult {
    let root = tempfile::tempdir()?;
    for n in 0..100 {
        std::fs::write(root.path().join(format!("file-{n:04}.el")), "fixture")?;
    }
    let mut peer = Peer::start()?;
    peer.send(
        json!({"jsonrpc":"2.0","id":0,"method":"initialize","params":{
        "protocol_major":1,"protocol_minor":0,"client_version":"test","capabilities":[],
        "limits":{"max_frame_bytes":1024}}}),
    )?;
    assert!(peer.read()?.get("result").is_some());
    peer.send(json!({"jsonrpc":"2.0","method":"initialized"}))?;
    let scope = peer.scope()?;
    peer.send(
        json!({"jsonrpc":"2.0","id":3,"method":"workspace/listFiles","params":{
        "scope":scope,"arguments":{"root":root.path(),"path":null,"skip_directories":[]}}}),
    )?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "resource_limit");
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"ping"}))?;
    assert_eq!(peer.read()?["result"]["status"], "ok");
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn native_file_discovery_uses_owned_session_and_keeps_reader_responsive() -> TestResult {
    let root = tempfile::tempdir()?;
    std::fs::create_dir(root.path().join("src"))?;
    std::fs::write(root.path().join("src/main.el"), "fixture")?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    peer.send(json!({"jsonrpc":"2.0","id":1,"method":"application/create"}))?;
    let app = peer.read()?["result"]["application_id"].clone();
    peer.send(
        json!({"jsonrpc":"2.0","id":2,"method":"session/create","params":{"application_id":app}}),
    )?;
    let scope = peer.read()?["result"].clone();
    let arguments = json!({"root":root.path(),"path":null,"pattern":"*.el",
        "skip_directories":[".git"],"max_files":2000,"max_directories":2000});
    peer.send(
        json!({"jsonrpc":"2.0","id":3,"method":"workspace/findFiles",
        "params":{"scope":scope,"arguments":arguments}}),
    )?;
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"ping"}))?;
    let replies = [peer.read()?, peer.read()?];
    let search = replies
        .iter()
        .find(|reply| reply["id"] == 3)
        .ok_or("search reply missing")?;
    let ping = replies
        .iter()
        .find(|reply| reply["id"] == 4)
        .ok_or("ping reply missing")?;
    assert_eq!(search["result"]["text"], "src/main.el\n");
    assert_eq!(search["result"]["truncated"], false);
    assert_eq!(ping["result"]["status"], "ok");
    peer.send(json!({"jsonrpc":"2.0","id":5,"method":"application/create"}))?;
    let other = peer.read()?["result"]["application_id"].clone();
    peer.send(json!({"jsonrpc":"2.0","id":6,"method":"workspace/findFiles",
        "params":{"scope":{"application_id":other,"session_id":scope["session_id"]},"arguments":arguments}}))?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "stale_owner");
    peer.send(
        json!({"jsonrpc":"2.0","id":7,"method":"workspace/findFiles",
        "params":{"scope":scope,"arguments":arguments}}),
    )?;
    peer.send(json!({"jsonrpc":"2.0","id":8,"method":"shutdown"}))?;
    let replies = [peer.read()?, peer.read()?];
    assert!(replies.iter().any(|reply| reply["id"] == 7));
    assert_eq!(replies.last().ok_or("shutdown reply missing")?["id"], 8);
    peer.send(json!({"jsonrpc":"2.0","method":"exit"}))?;
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn oversized_search_response_is_a_scoped_error_not_transport_failure() -> TestResult {
    let root = tempfile::tempdir()?;
    for n in 0..100 {
        std::fs::write(
            root.path().join(format!("source-file-{n:04}.el")),
            "fixture",
        )?;
    }
    let mut peer = Peer::start()?;
    peer.send(
        json!({"jsonrpc":"2.0","id":0,"method":"initialize","params":{
        "protocol_major":1,"protocol_minor":0,"client_version":"test","capabilities":[],
        "limits":{"max_frame_bytes":1024}}}),
    )?;
    assert!(peer.read()?.get("result").is_some());
    peer.send(json!({"jsonrpc":"2.0","method":"initialized"}))?;
    peer.send(json!({"jsonrpc":"2.0","id":1,"method":"application/create"}))?;
    let app = peer.read()?["result"].clone();
    peer.send(json!({"jsonrpc":"2.0","id":2,"method":"session/create","params":app}))?;
    let scope = peer.read()?["result"].clone();
    peer.send(
        json!({"jsonrpc":"2.0","id":3,"method":"workspace/findFiles","params":{
        "scope":scope,"arguments":{"root":root.path(),"path":null,"pattern":"*.el",
        "skip_directories":[],"max_files":2000,"max_directories":2000}}}),
    )?;
    assert_eq!(peer.read()?["error"]["data"]["status"], "resource_limit");
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"ping"}))?;
    assert_eq!(peer.read()?["result"]["status"], "ok");
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn real_pipe_lifecycle_and_clean_shutdown() -> TestResult {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    peer.send(json!({"jsonrpc":"2.0","id":1,"method":"application/create"}))?;
    let app = peer.read()?["result"]["application_id"].clone();
    peer.send(
        json!({"jsonrpc":"2.0","id":2,"method":"session/create","params":{"application_id":app}}),
    )?;
    let session = peer.read()?["result"]["session_id"].clone();
    peer.send(json!({"jsonrpc":"2.0","id":3,"method":"session/snapshot",
        "params":{"application_id":app,"session_id":session}}))?;
    assert_eq!(peer.read()?["result"]["state"], "idle");
    peer.send(json!({"jsonrpc":"2.0","id":4,"method":"session/close",
        "params":{"application_id":app,"session_id":session}}))?;
    assert_eq!(peer.read()?["result"]["status"], "closed");
    peer.send(json!({"jsonrpc":"2.0","id":5,"method":"shutdown"}))?;
    assert_eq!(peer.read()?["result"], Value::Null);
    peer.send(json!({"jsonrpc":"2.0","method":"exit"}))?;
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn every_byte_fragment_and_combined_frames() -> TestResult {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let frame = "{\"jsonrpc\":\"2.0\",\"id\":\"e:Türkçe🦀\",\"method\":\"ping\"}\r\n";
    for byte in frame.as_bytes() {
        peer.raw(&[*byte])?;
    }
    assert_eq!(peer.read()?["id"], "e:Türkçe🦀");
    peer.raw(b"{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":null}\n{\"jsonrpc\":\"2.0\",\"method\":\"unknown\"}\n{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}\n")?;
    // Unknown response and notification do not create phantom replies.
    assert_eq!(peer.read()?["id"], 9);
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn malformed_input_is_sanitized_and_connection_can_continue() -> TestResult {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    for frame in [
        "{secret-input\n",
        "[]\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"method\":\"secret\"}\n",
    ] {
        peer.raw(frame.as_bytes())?;
        let reply = peer.read()?;
        assert!(reply["error"]["code"].as_i64().is_some());
        assert!(!reply.to_string().contains("secret"));
    }
    peer.send(json!({"jsonrpc":"2.0","id":"still-live","method":"ping"}))?;
    assert_eq!(peer.read()?["result"]["status"], "ok");
    peer.input.take();
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn partial_eof_and_oversize_are_fatal() -> TestResult {
    let mut partial = Peer::start()?;
    partial.raw(b"{\"jsonrpc\":\"2.0\"")?;
    partial.input.take();
    assert!(!partial.wait()?);
    let mut oversize = Peer::start()?;
    // More than the bound without any newline: decoder must not wait for LF.
    let input = vec![b'x'; 1048577];
    let _ = oversize.raw(&input);
    assert!(!oversize.wait()?);
    Ok(())
}

#[tokio::test]
async fn stalled_output_is_bounded_and_disconnects() -> TestResult {
    use tokio::io::AsyncWriteExt;
    let (mut writer, reader) = tokio::io::duplex(4096);
    let (output, _slow_reader) = tokio::io::duplex(64);
    let server = tokio::spawn(kargu_core::ipc::serve(reader, output));
    // Each malformed frame produces a bounded parse error; reader stays idle.
    let producer = tokio::spawn(async move {
        for _ in 0..1000 {
            if writer.write_all(b"{\n").await.is_err() {
                break;
            }
        }
    });
    let result = tokio::time::timeout(Duration::from_secs(7), server).await??;
    assert!(result.is_err());
    producer.await?;
    Ok(())
}

#[tokio::test]
async fn cancelling_server_releases_its_writer_task() -> TestResult {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let (mut input, reader) = tokio::io::duplex(64);
    let (output, mut consumer) = tokio::io::duplex(1);
    let server = tokio::spawn(kargu_core::ipc::serve(reader, output));
    input.write_all(b"{\n").await?;
    // Wait until the writer owns a blocked send, then retire its parent.
    let mut first = [0_u8; 1];
    tokio::time::timeout(Duration::from_secs(1), consumer.read_exact(&mut first)).await??;
    server.abort();
    assert!(server.await.is_err());
    let mut rest = Vec::new();
    tokio::time::timeout(Duration::from_secs(1), consumer.read_to_end(&mut rest)).await??;
    Ok(())
}
