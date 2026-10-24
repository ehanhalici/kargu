//! Actual application close drains sockets without borrowing a sibling owner.

mod support;
use serde_json::{Value, json};
use std::{io::Read, net::TcpListener, sync::mpsc, time::Duration};
use support::Peer;
type TestResult = Result<(), Box<dyn std::error::Error>>;

#[test]
fn application_close_drains_http_rejects_stale_owner_and_keeps_sibling_live() -> TestResult {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let first = peer.scope()?;
    let sibling = peer.scope()?;
    let mut sockets = Vec::new();
    let mut closed = Vec::new();
    for (id, scope) in [("first", &first), ("sibling", &sibling)] {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let url = format!("http://{}/chat", listener.local_addr()?);
        let (connected_tx, connected_rx) = mpsc::channel();
        let (closed_tx, closed_rx) = mpsc::channel();
        sockets.push(std::thread::spawn(move || -> std::io::Result<()> {
            let (mut socket, _) = listener.accept()?;
            socket.set_read_timeout(Some(Duration::from_secs(5)))?;
            let _ = connected_tx.send(());
            let mut body = Vec::new();
            socket.read_to_end(&mut body)?;
            let _ = closed_tx.send(());
            Ok(())
        }));
        peer.send(json!({"jsonrpc":"2.0","id":id,"method":"api/request","params":{"scope":scope,"arguments":{
            "url":url,"method":"post","headers":{},"body":"{}","stream":false,
            "timeouts":{"connect_ms":1000,"first_byte_ms":30000,"idle_ms":null,"deadline_ms":30000}}}}))?;
        connected_rx.recv_timeout(Duration::from_secs(3))?;
        closed.push(closed_rx);
    }
    peer.send(json!({"jsonrpc":"2.0","id":"close","method":"application/close","params":{"application_id":first["application_id"]}}))?;
    peer.send(json!({"jsonrpc":"2.0","id":"stale","method":"session/create","params":{"application_id":first["application_id"]}}))?;
    peer.send(json!({"jsonrpc":"2.0","id":"ping","method":"ping"}))?;
    let replies: Vec<Value> = (0..4).map(|_| peer.read()).collect::<Result<_, _>>()?;
    let index = |id: &str| {
        replies
            .iter()
            .position(|reply| reply["id"] == id)
            .ok_or("missing reply")
    };
    assert!(index("first")? < index("close")?);
    assert_eq!(
        replies.get(index("first")?).ok_or("missing failure")?["result"]["failure"]["code"],
        "cancelled"
    );
    assert_eq!(
        replies.get(index("close")?).ok_or("missing close")?["result"]["status"],
        "closed"
    );
    assert!(
        replies
            .get(index("stale")?)
            .ok_or("missing stale")?
            .get("error")
            .is_some()
    );
    closed
        .first()
        .ok_or("missing first socket")?
        .recv_timeout(Duration::from_secs(1))?;
    assert!(matches!(
        closed.get(1).ok_or("missing sibling socket")?.try_recv(),
        Err(mpsc::TryRecvError::Empty)
    ));
    peer.send(json!({"jsonrpc":"2.0","id":"sibling-snapshot","method":"session/snapshot","params":sibling}))?;
    assert_eq!(peer.read()?["id"], "sibling-snapshot");
    peer.send(json!({"jsonrpc":"2.0","method":"rpc/cancel","params":{"request_id":"sibling","scope":peer.epoch}}))?;
    assert_eq!(peer.read()?["id"], "sibling");
    for socket in sockets {
        socket.join().map_err(|_| "socket fixture failed")??;
    }
    peer.send(json!({"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}))?;
    assert_eq!(peer.read()?["id"], "shutdown");
    peer.send(json!({"jsonrpc":"2.0","method":"exit"}))?;
    assert!(peer.wait()?);
    Ok(())
}

#[test]
fn closed_application_capacity_is_reusable_beyond_the_host_limit() -> TestResult {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    for _ in 0..80 {
        let scope = peer.scope()?;
        peer.send(json!({"jsonrpc":"2.0","id":"close","method":"application/close","params":{"application_id":scope["application_id"]}}))?;
        assert_eq!(peer.read()?["result"]["status"], "closed");
    }
    Ok(())
}

fn command(root: &std::path::Path, script: &str) -> Result<Value, Box<dyn std::error::Error>> {
    let paths = std::env::var_os("PATH").ok_or("PATH missing")?;
    let shell = std::env::split_paths(&paths)
        .map(|path| path.join("sh"))
        .find(|path| path.is_file())
        .ok_or("sh missing")?;
    Ok(
        json!({"root":root,"mode":"agent","program":shell,"arguments":["-c",script],"cwd":null,
        "timeout_ms":1000,"environment":{},"config_revision":1,"policy_revision":1}),
    )
}

#[test]
fn application_close_revokes_pending_approval_before_release() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    peer.send(json!({"jsonrpc":"2.0","id":"command","method":"tool/execute","params":{"scope":scope,"arguments":command(root.path(),"printf forbidden > effect")?}}))?;
    let review = peer.read()?;
    assert_eq!(review["method"], "editor/request_approval");
    peer.send(json!({"jsonrpc":"2.0","id":"close","method":"application/close","params":{"application_id":scope["application_id"]}}))?;
    let cancelled = peer.read()?;
    assert_eq!(cancelled["method"], "rpc/cancel");
    let command = peer.read()?;
    assert_eq!(command["id"], "command");
    assert!(command.get("error").is_some());
    assert_eq!(peer.read()?["id"], "close");
    peer.send(json!({"jsonrpc":"2.0","id":review["id"],"result":{"approved":true}}))?;
    peer.send(json!({"jsonrpc":"2.0","id":"ping","method":"ping"}))?;
    assert_eq!(peer.read()?["id"], "ping");
    assert!(!root.path().join("effect").exists());
    Ok(())
}

#[test]
fn application_close_drains_claimed_process_job_before_ack_and_shutdown() -> TestResult {
    let root = tempfile::tempdir()?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let mut arguments = command(root.path(), "cat")?;
    arguments["timeout_ms"] = Value::Null;
    peer.send(json!({"jsonrpc":"2.0","id":"start","method":"job/start","params":{"scope":scope,"arguments":arguments}}))?;
    let review = peer.read()?;
    peer.send(json!({"jsonrpc":"2.0","id":review["id"],"result":{"approved":true}}))?;
    let started = peer.read()?;
    let pid = started["result"]["process_id"].as_u64().ok_or("pid")?;
    peer.send(json!({"jsonrpc":"2.0","id":"claim","method":"job/claim","params":{"owner":{"scope":scope,"root":root.path()},"job_id":started["result"]["job_id"]}}))?;
    assert_eq!(peer.read()?["id"], "claim");
    peer.send(json!({"jsonrpc":"2.0","id":"close","method":"application/close","params":{"application_id":scope["application_id"]}}))?;
    peer.send(json!({"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}))?;
    assert_eq!(peer.read()?["id"], "close");
    assert!(!std::path::Path::new(&format!("/proc/{pid}")).exists());
    assert_eq!(peer.read()?["id"], "shutdown");
    peer.send(json!({"jsonrpc":"2.0","method":"exit"}))?;
    assert!(peer.wait()?);
    Ok(())
}
