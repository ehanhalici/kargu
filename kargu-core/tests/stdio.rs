//! Real-pipe framing, shutdown and adversarial consumer checks.

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};

type TestResult = Result<(), Box<dyn std::error::Error>>;

struct Peer {
    child: Child,
    input: Option<ChildStdin>,
    output: Receiver<String>,
}

impl Peer {
    fn start() -> Result<Self, Box<dyn std::error::Error>> {
        let mut child = Command::new(env!("CARGO_BIN_EXE_kargu-core"))
            .arg("--stdio")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let input = child.stdin.take().ok_or("missing stdin")?;
        let stdout = child.stdout.take().ok_or("missing stdout")?;
        let (tx, output) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                match line {
                    Ok(line) => {
                        if tx.send(line).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
        });
        Ok(Self {
            child,
            input: Some(input),
            output,
        })
    }
    fn raw(&mut self, bytes: &[u8]) -> TestResult {
        let input = self.input.as_mut().ok_or("closed stdin")?;
        input.write_all(bytes)?;
        input.flush()?;
        Ok(())
    }
    fn send(&mut self, value: Value) -> TestResult {
        self.raw(format!("{value}\n").as_bytes())
    }
    fn read(&self) -> Result<Value, Box<dyn std::error::Error>> {
        let line = self.output.recv_timeout(Duration::from_secs(5))?;
        Ok(serde_json::from_str(&line)?)
    }
    fn initialize(&mut self) -> TestResult {
        self.send(json!({"jsonrpc":"2.0","id":"e:init","method":"initialize",
            "params":{"protocol_major":1,"protocol_minor":0,"client_version":"pipe-test",
            "capabilities":[],"limits":{"max_frame_bytes":1048576}}}))?;
        assert!(self.read()?.get("result").is_some());
        self.send(json!({"jsonrpc":"2.0","method":"initialized"}))
    }
    fn scope(&mut self) -> Result<Value, Box<dyn std::error::Error>> {
        self.send(json!({"jsonrpc":"2.0","id":1,"method":"application/create"}))?;
        let app = self.read()?["result"].clone();
        self.send(json!({"jsonrpc":"2.0","id":2,"method":"session/create","params":app}))?;
        Ok(self.read()?["result"].clone())
    }
    fn wait(&mut self) -> Result<bool, Box<dyn std::error::Error>> {
        let deadline = Instant::now() + Duration::from_secs(8);
        loop {
            if let Some(status) = self.child.try_wait()? {
                return Ok(status.success());
            }
            if Instant::now() >= deadline {
                return Err("child failed to exit".into());
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
impl Drop for Peer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
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
    let arguments =
        json!({"root":root.path(),"path":null,"skip_directories":[],"max_entries":2000});
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
    assert_eq!(listing["result"]["text"], "[DIR]  sub\n[FILE] top.el");
    assert_eq!(
        listing["result"]["entries"]
            .as_array()
            .ok_or("entries missing")?
            .len(),
        2
    );
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
        "skip_directories":[],"max_entries":2000});
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
    peer.send(json!({"jsonrpc":"2.0","id":3,"method":"workspace/listFiles","params":{
        "scope":scope,"arguments":{"root":root.path(),"path":null,"skip_directories":[],"max_entries":2000}}}))?;
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
