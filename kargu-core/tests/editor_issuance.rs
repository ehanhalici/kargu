//! Actual stdio issuance: durable journal before nonce, explicit quiescence before release.
mod support;
use kargu_core::{
    edit::{
        journal::{self, JournalDirectory, JournalResolution, RecoveredJournal},
        types::EditorEditId,
    },
    error::CoreError,
};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    fs,
    os::unix::fs::PermissionsExt,
    path::Path,
    time::{Duration, Instant},
};
use support::Peer;
use tokio_util::sync::CancellationToken;
type TestResult = Result<(), Box<dyn std::error::Error>>;
const SOURCE: &str = "editor_source_12345678-1234-4234-8234-123456789abc";
const OTHER: &str = "editor_source_aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
struct Client {
    peer: Peer,
    scope: Value,
    sequence: u64,
    notices: Vec<Value>,
    deferred: HashMap<String, Value>,
}
impl Client {
    fn new() -> Result<Self, Box<dyn std::error::Error>> {
        let mut peer = Peer::start()?;
        peer.initialize()?;
        Self::from_peer(peer)
    }
    fn with_frame(frame: usize) -> Result<Self, Box<dyn std::error::Error>> {
        let mut peer = Peer::start()?;
        peer.send(json!({"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocol_major":1,"protocol_minor":0,"client_version":"issuance-test","capabilities":[],"limits":{"max_frame_bytes":frame}}}))?;
        peer.epoch = peer.read()?["result"]["connection_epoch"]
            .as_str()
            .ok_or("epoch")?
            .to_owned();
        peer.send(json!({"jsonrpc":"2.0","method":"initialized"}))?;
        Self::from_peer(peer)
    }
    fn from_peer(mut peer: Peer) -> Result<Self, Box<dyn std::error::Error>> {
        let scope = peer.scope()?;
        Ok(Self {
            peer,
            scope,
            sequence: 0,
            notices: vec![],
            deferred: HashMap::new(),
        })
    }
    fn response(&mut self, id: &str) -> Result<Value, Box<dyn std::error::Error>> {
        if let Some(reply) = self.deferred.remove(id) {
            return Ok(reply);
        }
        loop {
            let reply = self.peer.read()?;
            if reply.get("method").is_some() {
                self.notices.push(reply);
                continue;
            }
            if reply["id"] == id {
                return Ok(reply);
            }
            let key = reply["id"].as_str().ok_or("response id")?.to_owned();
            self.deferred.insert(key, reply);
        }
    }
    fn call(&mut self, method: &str, args: Value) -> Result<Value, Box<dyn std::error::Error>> {
        self.sequence = self.sequence.checked_add(1).ok_or("sequence")?;
        let id = format!("edit:{}", self.sequence);
        self.peer.send(json!({"jsonrpc":"2.0","id":id,"method":method,"params":{"scope":self.scope,"arguments":args}}))?;
        self.response(&id)
    }
    fn prepared(&mut self, root: &Path, source: &str) -> Result<Value, Box<dyn std::error::Error>> {
        let id=self.call("edit/begin",json!({"origin_id":source,"root":root,"mode":"agent","intent":{"kind":"write","path":"file.txt","new_bytes":4},"live":null,"config_revision":3,"policy_revision":7,"review_mode":"auto","save_policy":"save"}))?["result"]["preparation_id"].clone();
        assert!(id.is_string());
        self.call(
            "edit/append",
            json!({"origin_id":source,"preparation_id":id,"part":"new","offset":0,"text":"new\n"}),
        )?;
        let prep = self.call(
            "edit/prepare",
            json!({"origin_id":source,"preparation_id":id}),
        )?["result"]
            .clone();
        assert_eq!(prep["preparation_id"], id);
        Ok(prep)
    }
    fn grant(
        &mut self,
        preparation: &Value,
        source: &str,
    ) -> Result<Value, Box<dyn std::error::Error>> {
        let reply = self.call(
            "edit/authorize",
            json!({"origin_id":source,"preparation_id":preparation,"presenter":"missing"}),
        )?;
        assert_eq!(reply["result"]["state"], "authorized", "{reply}");
        Ok(reply["result"]["edit_id"].clone())
    }
    fn preflight(&mut self, prep: &Value, edit: &Value, source: &str) -> TestResult {
        let reply=self.call("edit/preflight",json!({"origin_id":source,"edit_id":edit,"revision":1,"witness":{"file":0,"base_hash":prep["base_hash"],"document":{"id":"editor_document_12345678-1234-4234-8234-123456789abc","tick":1,"bytes":prep["base_bytes"],"coding":"utf-8-unix","dirty":false,"read_only":false,"disk":prep["disk"]}}}))?;
        assert_eq!(reply["result"]["state"], "preflighted", "{reply}");
        Ok(())
    }
    fn ready(
        &mut self,
        root: &Path,
        source: &str,
    ) -> Result<(Value, Value), Box<dyn std::error::Error>> {
        let prep = self.prepared(root, source)?;
        let edit = self.grant(&prep["preparation_id"], source)?;
        self.preflight(&prep, &edit, source)?;
        Ok((prep, edit))
    }
    fn issue(
        &mut self,
        edit: &Value,
        source: &str,
        journal: &Path,
    ) -> Result<Value, Box<dyn std::error::Error>> {
        self.call(
            "edit/issue",
            json!({"origin_id":source,"edit_id":edit,"revision":1,"journal_directory":journal}),
        )
    }
    fn quiescent(
        &mut self,
        edit: &Value,
        source: &str,
        token: &Value,
        effect: &str,
    ) -> Result<Value, Box<dyn std::error::Error>> {
        self.call("edit/quiescent",json!({"origin_id":source,"edit_id":edit,"revision":1,"issued_token":token,"effect":effect}))
    }
}
fn private() -> Result<tempfile::TempDir, Box<dyn std::error::Error>> {
    let root = tempfile::tempdir()?;
    fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700))?;
    Ok(root)
}
fn recover(root: &Path, edit: &Value) -> Result<RecoveredJournal, CoreError> {
    journal::recover(
        JournalDirectory::try_from(root.to_path_buf())?,
        EditorEditId::try_from(
            edit.as_str()
                .ok_or(CoreError::InvalidToolOutput)?
                .to_owned(),
        )?,
        &CancellationToken::new(),
        Instant::now()
            .checked_add(Duration::from_secs(3))
            .ok_or(CoreError::ArithmeticOverflow)?,
    )
}
fn path(root: &Path, edit: &Value) -> Result<std::path::PathBuf, Box<dyn std::error::Error>> {
    Ok(root.join(format!("{}.ndjson", edit.as_str().ok_or("edit id")?)))
}
#[test]
fn synced_issuance_precedes_external_editor_effect_and_nonce_is_not_replayable() -> TestResult {
    let workspace = private()?;
    let journal = private()?;
    fs::write(workspace.path().join("file.txt"), "old\n")?;
    let mut client = Client::new()?;
    let (_, edit) = client.ready(workspace.path(), SOURCE)?;
    let reply = client.issue(&edit, SOURCE, journal.path())?;
    assert_eq!(reply["result"]["state"], "issued", "{reply}");
    let token = reply["result"]["issued_token"].clone();
    assert!(token.is_string());
    assert_eq!(reply["result"]["applied"], Value::Null);
    assert_eq!(
        fs::read_to_string(workspace.path().join("file.txt"))?,
        "old\n"
    );
    let log = fs::read_to_string(path(journal.path(), &edit)?)?;
    assert_eq!(log.lines().count(), 1);
    let record: Value = serde_json::from_str(log.trim_end())?;
    assert_eq!(record["payload"]["issue"]["issuance"], token);
    assert_eq!(
        record["payload"]["issue"]["preflight"],
        reply["result"]["preflight_digest"]
    );
    assert_eq!(
        record["payload"]["issue"]["scope"]["purpose"],
        "editor_edit"
    );
    assert!(matches!(
        recover(journal.path(), &edit),
        Err(CoreError::Busy)
    ));
    // Controlled editor fixture, deliberately outside the production Rust writer.
    fs::write(workspace.path().join("file.txt"), "new\n")?;
    let settled = client.quiescent(&edit, SOURCE, &token, "outcome_unknown")?;
    assert_eq!(settled["result"]["state"], "quiescent", "{settled}");
    assert_eq!(settled["result"]["journal_committed"], true);
    assert!(matches!(
        recover(journal.path(), &edit)?,
        RecoveredJournal::Resolved {
            resolution: JournalResolution::OutcomeUnknown,
            ..
        }
    ));
    assert!(
        client
            .quiescent(&edit, SOURCE, &token, "outcome_unknown")?
            .get("error")
            .is_some()
    );
    assert!(
        client
            .issue(&edit, SOURCE, journal.path())?
            .get("error")
            .is_some()
    );
    assert_eq!(
        fs::read_to_string(workspace.path().join("file.txt"))?,
        "new\n"
    );
    client.peer.input.take();
    assert!(client.peer.wait()?);
    Ok(())
}
#[test]
fn source_abort_keeps_writer_fence_and_capacity_until_matching_quiescence() -> TestResult {
    let workspace = private()?;
    let journal = private()?;
    fs::write(workspace.path().join("file.txt"), "old\n")?;
    let mut client = Client::new()?;
    let (prep, edit) = client.ready(workspace.path(), SOURCE)?;
    let issued = client.issue(&edit, SOURCE, journal.path())?;
    let token = issued["result"]["issued_token"].clone();
    assert!(token.is_string(), "{issued}");
    let (_, second) = client.ready(workspace.path(), OTHER)?;
    assert_eq!(
        client.issue(&second, OTHER, journal.path())?["error"]["data"]["status"],
        "busy"
    );
    client.call(
        "edit/abort",
        json!({"origin_id":SOURCE,"preparation_id":prep["preparation_id"]}),
    )?;
    assert_eq!(
        client.quiescent(&edit, OTHER, &token, "not_dispatched")?["error"]["data"]["status"],
        "stale_owner"
    );
    let foreign = json!(format!("editor_issue_{}", uuid::Uuid::new_v4()));
    assert_eq!(
        client.quiescent(&edit, SOURCE, &foreign, "not_dispatched")?["error"]["data"]["status"],
        "stale_owner"
    );
    assert_eq!(
        client.issue(&second, OTHER, journal.path())?["error"]["data"]["status"],
        "busy"
    );
    assert!(matches!(
        recover(journal.path(), &edit),
        Err(CoreError::Busy)
    ));
    let settled = client.quiescent(&edit, SOURCE, &token, "not_dispatched")?;
    assert_eq!(settled["result"]["journal_committed"], true, "{settled}");
    assert!(matches!(
        recover(journal.path(), &edit)?,
        RecoveredJournal::Resolved {
            resolution: JournalResolution::NotDispatched,
            ..
        }
    ));
    let issued = client.issue(&second, OTHER, journal.path())?;
    assert_eq!(issued["result"]["state"], "issued", "{issued}");
    client.quiescent(
        &second,
        OTHER,
        &issued["result"]["issued_token"],
        "not_dispatched",
    )?;
    assert_eq!(
        fs::read_to_string(workspace.path().join("file.txt"))?,
        "old\n"
    );
    Ok(())
}
#[test]
fn retired_session_and_application_accept_only_the_original_issued_completion() -> TestResult {
    for close in ["session/close", "application/close"] {
        let workspace = private()?;
        let journal = private()?;
        fs::write(workspace.path().join("file.txt"), "old\n")?;
        let mut client = Client::new()?;
        let (_, edit) = client.ready(workspace.path(), SOURCE)?;
        let issued = client.issue(&edit, SOURCE, journal.path())?;
        let token = issued["result"]["issued_token"].clone();
        assert!(token.is_string(), "{issued}");
        let params = if close == "session/close" {
            client.scope.clone()
        } else {
            json!({"application_id":client.scope["application_id"]})
        };
        client
            .peer
            .send(json!({"jsonrpc":"2.0","id":"close","method":close,"params":params}))?;
        if close == "session/close" {
            assert!(client.response("close")?.get("result").is_some());
        }
        client
            .peer
            .send(json!({"jsonrpc":"2.0","id":"ping","method":"ping"}))?;
        assert!(client.response("ping")?.get("result").is_some());
        if close == "application/close" {
            assert!(!client.deferred.contains_key("close"));
        }
        let done = client.quiescent(&edit, SOURCE, &token, "outcome_unknown")?;
        assert_eq!(done["result"]["journal_committed"], true, "{done}");
        if close == "application/close" {
            assert_eq!(client.response("close")?["result"]["status"], "closed");
        }
        assert!(matches!(
            recover(journal.path(), &edit)?,
            RecoveredJournal::Resolved {
                resolution: JournalResolution::OutcomeUnknown,
                ..
            }
        ));
        client.peer.input.take();
        assert!(client.peer.wait()?);
    }
    Ok(())
}
#[test]
fn eof_after_dispatch_records_unknown_without_replaying_the_editor_effect() -> TestResult {
    let workspace = private()?;
    let journal = private()?;
    fs::write(workspace.path().join("file.txt"), "old\n")?;
    let mut client = Client::new()?;
    let (_, edit) = client.ready(workspace.path(), SOURCE)?;
    let issued = client.issue(&edit, SOURCE, journal.path())?;
    assert_eq!(issued["result"]["state"], "issued", "{issued}");
    fs::write(workspace.path().join("file.txt"), "foreign/editor\n")?;
    client.peer.input.take();
    assert!(client.peer.wait()?);
    assert_eq!(
        fs::read_to_string(workspace.path().join("file.txt"))?,
        "foreign/editor\n"
    );
    assert!(matches!(
        recover(journal.path(), &edit)?,
        RecoveredJournal::Resolved {
            resolution: JournalResolution::OutcomeUnknown,
            ..
        }
    ));
    Ok(())
}
#[test]
fn missing_preflight_changed_source_and_unusable_journal_never_return_a_nonce() -> TestResult {
    let workspace = private()?;
    let journal = private()?;
    let file = workspace.path().join("file.txt");
    fs::write(&file, "old\n")?;
    let mut client = Client::new()?;
    let prep = client.prepared(workspace.path(), SOURCE)?;
    let edit = client.grant(&prep["preparation_id"], SOURCE)?;
    assert_eq!(
        client.issue(&edit, SOURCE, journal.path())?["error"]["data"]["status"],
        "rejected"
    );
    client.preflight(&prep, &edit, SOURCE)?;
    assert_eq!(
        client.issue(&edit, SOURCE, workspace.path())?["error"]["data"]["status"],
        "rejected"
    );
    assert_eq!(fs::read_to_string(&file)?, "old\n");
    let (_, edit) = client.ready(workspace.path(), SOURCE)?;
    fs::write(&file, "foreign\n")?;
    assert_eq!(
        client.issue(&edit, SOURCE, journal.path())?["error"]["data"]["status"],
        "conflict"
    );
    assert!(!path(journal.path(), &edit)?.exists());
    assert_eq!(fs::read_to_string(&file)?, "foreign\n");
    Ok(())
}

#[test]
fn tiny_frames_and_unknown_receipt_only_policy_do_not_allow_a_fabricated_success() -> TestResult {
    let workspace = private()?;
    let journal = private()?;
    fs::write(workspace.path().join("file.txt"), "old\n")?;
    let mut client = Client::with_frame(1024)?;
    let (_, edit) = client.ready(workspace.path(), SOURCE)?;
    let issued = client.issue(&edit, SOURCE, journal.path())?;
    assert_eq!(issued["result"]["state"], "issued", "{issued}");
    assert!(issued.to_string().len() < 1024);
    let token = &issued["result"]["issued_token"];
    let fake=client.call("edit/quiescent",json!({"origin_id":SOURCE,"edit_id":edit,"revision":1,"issued_token":token,"effect":"applied_full"}))?;
    assert_eq!(fake["error"]["data"]["status"], "invalid_params");
    let stale=client.call("edit/quiescent",json!({"origin_id":SOURCE,"edit_id":edit,"revision":2,"issued_token":token,"effect":"not_dispatched"}))?;
    assert_eq!(stale["error"]["data"]["status"], "stale_owner");
    assert!(matches!(
        recover(journal.path(), &edit),
        Err(CoreError::Busy)
    ));
    let reply = client.quiescent(&edit, SOURCE, token, "not_dispatched")?;
    assert_eq!(reply["result"]["journal_committed"], true);
    assert_eq!(
        fs::read_to_string(workspace.path().join("file.txt"))?,
        "old\n"
    );
    Ok(())
}
#[test]
fn failed_settlement_sync_is_unknown_and_never_retries_or_overwrites_an_effect() -> TestResult {
    let workspace = private()?;
    let journal = private()?;
    let file = workspace.path().join("file.txt");
    fs::write(&file, "old\n")?;
    let mut client = Client::new()?;
    let (_, edit) = client.ready(workspace.path(), SOURCE)?;
    let issued = client.issue(&edit, SOURCE, journal.path())?;
    let token = &issued["result"]["issued_token"];
    assert!(token.is_string(), "{issued}");
    fs::write(&file, "editor/foreign\n")?;
    fs::set_permissions(journal.path(), fs::Permissions::from_mode(0o755))?;
    let reply = client.quiescent(&edit, SOURCE, token, "outcome_unknown")?;
    assert_eq!(
        reply["error"]["data"]["status"], "outcome_unknown",
        "{reply}"
    );
    assert_eq!(fs::read_to_string(&file)?, "editor/foreign\n");
    fs::set_permissions(journal.path(), fs::Permissions::from_mode(0o700))?;
    assert!(matches!(
        recover(journal.path(), &edit)?,
        RecoveredJournal::OutcomeUnknown { .. }
    ));
    assert!(
        client
            .issue(&edit, SOURCE, journal.path())?
            .get("error")
            .is_some()
    );
    client.peer.input.take();
    assert!(client.peer.wait()?);
    Ok(())
}
