//! Discovery reads native config and cannot publish after owner/revision loss.
mod support;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io::{Read, Write},
    net::TcpListener,
    sync::mpsc,
    time::Duration,
};
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
        peer.initialize()?;
        let scope = peer.scope()?;
        Ok(Self {
            peer,
            scope,
            sequence: 0,
            deferred: HashMap::new(),
        })
    }
    fn send(&mut self, method: &str, params: Value) -> Result<String, Box<dyn std::error::Error>> {
        self.sequence += 1;
        let id = format!("catalog:{}", self.sequence);
        self.peer
            .send(json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))?;
        Ok(id)
    }
    fn response(&mut self, id: &str) -> Result<Value, Box<dyn std::error::Error>> {
        if let Some(value) = self.deferred.remove(id) {
            return Ok(value);
        }
        loop {
            let value = self.peer.read()?;
            if value["id"] == id {
                return Ok(value);
            }
            let other = value["id"].as_str().ok_or("response id")?.to_owned();
            self.deferred.insert(other, value);
        }
    }
    fn call(&mut self, method: &str, params: Value) -> Result<Value, Box<dyn std::error::Error>> {
        let id = self.send(method, params)?;
        self.response(&id)
    }
    fn configure(
        &mut self,
        url: &str,
        generation: u64,
    ) -> Result<Value, Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let file = dir.path().join("config.toml");
        std::fs::write(
            &file,
            format!(
                "provider='custom'\n[providers.custom]\napi='{url}'\napikey='synthetic-owned-key'\n"
            ),
        )?;
        let read = self.call(
            "configuration/read",
            json!({"connection_epoch":self.peer.epoch,
            "arguments":{"paths":[file],"generation":generation,"timeout_ms":2000}}),
        )?;
        assert!(read.get("error").is_none(), "{read}");
        assert_eq!(read["result"]["status"], "ok");
        let stage = self.call(
            "configuration/prepare",
            json!({"scope":self.scope,"arguments":{
            "generation":generation,"path":file,"digest":read["result"]["digest"],
            "document":read["result"]["config"],"registry":[]}}),
        )?;
        assert!(stage.get("error").is_none(), "{stage}");
        let commit = self.call(
            "configuration/commit",
            json!({"scope":self.scope,"arguments":{
            "capture_id":stage["result"]["capture_id"],
            "context":{"api_base":"https://fallback.invalid/v1","environment":{},"registry":[]}}}),
        )?;
        assert!(commit.get("error").is_none(), "{commit}");
        Ok(commit["result"]["revision"].clone())
    }
    fn refresh(&mut self, revision: Value) -> Result<String, Box<dyn std::error::Error>> {
        self.send(
            "model/refresh",
            json!({"connection_epoch":self.peer.epoch,"scope":self.scope,
            "configuration_revision":revision,"provider":"custom"}),
        )
    }
    fn models(&mut self) -> Result<Value, Box<dyn std::error::Error>> {
        let result = self.call(
            "model/list",
            json!({"application_id":self.scope["application_id"],
            "connection_epoch":self.peer.epoch,"provider":"custom"}),
        )?;
        Ok(result["result"]["models"].clone())
    }
}
struct Server {
    url: String,
    request: mpsc::Receiver<String>,
    release: mpsc::Sender<()>,
    thread: Option<std::thread::JoinHandle<std::io::Result<()>>>,
}
impl Server {
    fn start() -> Result<Self, Box<dyn std::error::Error>> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let url = format!("http://{}/v1", listener.local_addr()?);
        let (seen, request) = mpsc::channel();
        let (release, gate) = mpsc::channel();
        let thread = std::thread::spawn(move || -> std::io::Result<()> {
            let (mut socket, _) = listener.accept()?;
            socket.set_read_timeout(Some(Duration::from_secs(3)))?;
            let mut bytes = Vec::new();
            while !bytes.ends_with(b"\r\n\r\n") {
                let mut chunk = [0; 1];
                if socket.read(&mut chunk)? == 0 {
                    break;
                }
                bytes.extend_from_slice(&chunk);
            }
            let _ = seen.send(String::from_utf8_lossy(&bytes).to_lowercase());
            let _ = gate.recv_timeout(Duration::from_secs(5));
            let body = r#"{"data":[{"id":"owned-model"}]}"#;
            let _ = write!(
                socket,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            Ok(())
        });
        Ok(Self {
            url,
            request,
            release,
            thread: Some(thread),
        })
    }
    fn seen(&self) -> TestResult {
        let request = self.request.recv_timeout(Duration::from_secs(4))?;
        assert!(request.starts_with("get /v1/models http/1.1\r\n"));
        assert!(request.contains("authorization: bearer synthetic-owned-key\r\n"));
        Ok(())
    }
    fn finish(mut self) -> TestResult {
        let _ = self.release.send(());
        self.thread
            .take()
            .ok_or("server thread")?
            .join()
            .map_err(|_| "server panic")??;
        Ok(())
    }
}

#[test]
fn native_read_config_to_http_to_owned_model_publication() -> TestResult {
    let mut client = Client::new()?;
    let server = Server::start()?;
    let revision = client.configure(&server.url, 1)?;
    let id = client.refresh(revision)?;
    server.seen()?;
    server.finish()?;
    let result = client.response(&id)?;
    assert!(result.get("error").is_none(), "{result}");
    assert_eq!(result["result"]["models"][0]["id"], "owned-model");
    assert_eq!(client.models()?[0]["id"], "owned-model");
    Ok(())
}

#[test]
fn changed_config_and_closed_session_revoke_pending_publication() -> TestResult {
    for ending in ["config", "session", "cancel"] {
        let mut client = Client::new()?;
        let server = Server::start()?;
        let revision = client.configure(&server.url, 1)?;
        let id = client.refresh(revision)?;
        server.seen()?;
        match ending {
            "config" => {
                client.configure("http://127.0.0.1:1/new", 2)?;
            }
            "session" => {
                let reply = client.call(
                    "session/close",
                    json!({"application_id":client.scope["application_id"],
                    "session_id":client.scope["session_id"]}),
                )?;
                assert!(reply.get("error").is_none(), "{reply}");
            }
            _ => {
                client
                    .peer
                    .send(json!({"jsonrpc":"2.0","method":"rpc/cancel","params":{"request_id":id,"scope":client.peer.epoch}}))?;
            }
        }
        if ending == "cancel" {
            let _ = client.models()?;
        }
        server.finish()?;
        let result = client.response(&id)?;
        assert!(result.get("error").is_some(), "{ending}: {result}");
        assert_eq!(client.models()?, json!([]), "{ending}");
    }
    Ok(())
}

#[test]
fn absent_config_stale_revision_foreign_scope_and_url_override_fail_before_io() -> TestResult {
    let mut client = Client::new()?;
    let id = client.refresh(json!(0))?;
    assert!(client.response(&id)?.get("error").is_some());
    let revision = client.configure("http://127.0.0.1:1/v1", 1)?;
    let id = client.refresh(json!(0))?;
    assert!(client.response(&id)?.get("error").is_some());
    for field in ["url", "auth", "application_id"] {
        let mut params = json!({"connection_epoch":client.peer.epoch,"scope":client.scope,
            "configuration_revision":revision,"provider":"custom"});
        params[field] = json!("untrusted-override");
        let reply = client.call("model/refresh", params)?;
        assert!(reply.get("error").is_some(), "{reply}");
    }
    let foreign = client.peer.scope()?;
    let reply = client.call("model/refresh", json!({"connection_epoch":client.peer.epoch,
        "scope":{"application_id":client.scope["application_id"],"session_id":foreign["session_id"]},
        "configuration_revision":revision,"provider":"custom"}))?;
    assert!(reply.get("error").is_some());
    Ok(())
}
