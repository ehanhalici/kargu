//! Stdio editor receipt: streaming raw observations and verified journal settlement.
mod support;
use kargu_core::{
    edit::{
        journal::{self, JournalDirectory, RecoveredJournal},
        types::EditorEditId,
    },
    error::CoreError,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::Path,
    time::{Duration, Instant},
};
use support::Peer;
use tokio_util::sync::CancellationToken;

type TestResult = Result<(), Box<dyn std::error::Error>>;
const SOURCE: &str = "editor_source_12345678-1234-4234-8234-123456789abc";

struct Client {
    peer: Peer,
    scope: Value,
    sequence: u64,
    notices: Vec<Value>,
    deferred: HashMap<String, Value>,
}

impl Client {
    fn new() -> Result<Self, Box<dyn std::error::Error>> {
        Self::new_with_limit(1_048_576)
    }

    fn new_with_limit(max_frame_bytes: usize) -> Result<Self, Box<dyn std::error::Error>> {
        let mut peer = Peer::start()?;
        peer.initialize_with_limit(max_frame_bytes)?;
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
        self.peer.send(json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": {
                "scope": self.scope,
                "arguments": args
            }
        }))?;
        self.response(&id)
    }

    fn prepared(&mut self, root: &Path, source: &str) -> Result<Value, Box<dyn std::error::Error>> {
        self.prepared_with_policy(root, source, "save")
    }

    fn prepared_with_policy(
        &mut self,
        root: &Path,
        source: &str,
        policy: &str,
    ) -> Result<Value, Box<dyn std::error::Error>> {
        self.prepared_with_text(root, source, policy, "new\n")
    }

    fn prepared_with_text(
        &mut self,
        root: &Path,
        source: &str,
        policy: &str,
        text: &str,
    ) -> Result<Value, Box<dyn std::error::Error>> {
        self.prepared_with_review(root, source, policy, text, "auto")
    }
    fn prepared_with_review(
        &mut self,
        root: &Path,
        source: &str,
        policy: &str,
        text: &str,
        review: &str,
    ) -> Result<Value, Box<dyn std::error::Error>> {
        self.prepared_with_service(root, source, policy, text, review, None)
    }
    fn prepared_with_service(
        &mut self,
        root: &Path,
        source: &str,
        policy: &str,
        text: &str,
        review: &str,
        service: Option<&str>,
    ) -> Result<Value, Box<dyn std::error::Error>> {
        let id = self.call(
            "edit/begin",
            json!({
                "origin_id": source,
                "root": root,
                "service_id": service,
                "mode": "agent",
                "intent": {
                    "kind": "write",
                    "path": "file.txt",
                    "new_bytes": text.len()
                },
                "live": null,
                "config_revision": 3,
                "policy_revision": 7,
                "review_mode": review,
                "save_policy": policy
            }),
        )?["result"]["preparation_id"]
            .clone();
        assert!(id.is_string());
        let mut offset = 0usize;
        while offset < text.len() {
            let mut end = offset.saturating_add(16384).min(text.len());
            while !text.is_char_boundary(end) {
                end = end.checked_sub(1).ok_or("boundary")?;
            }
            let ack = self.call("edit/append",json!({"origin_id":source,"preparation_id":id,"part":"new","offset":offset,"text":&text[offset..end]}))?;
            assert!(ack.get("result").is_some(), "{ack}");
            offset = end;
        }
        let prep = self.call(
            "edit/prepare",
            json!({
                "origin_id": source,
                "preparation_id": id
            }),
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
            json!({
                "origin_id": source,
                "preparation_id": preparation,
                "presenter": "missing"
            }),
        )?;
        assert_eq!(reply["result"]["state"], "authorized", "{reply}");
        Ok(reply["result"]["edit_id"].clone())
    }

    fn preflight(&mut self, prep: &Value, edit: &Value, source: &str) -> TestResult {
        let reply = self.call(
            "edit/preflight",
            json!({
                "origin_id": source,
                "edit_id": edit,
                "revision": 1,
                "witness": {
                    "file": 0,
                    "base_hash": prep["base_hash"],
                    "document": {
                        "id": "editor_document_12345678-1234-4234-8234-123456789abc",
                        "tick": 1,
                        "bytes": prep["base_bytes"],
                        "coding": "utf-8-unix",
                        "dirty": false,
                        "read_only": false,
                        "disk": prep["disk"]
                    }
                }
            }),
        )?;
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
            json!({
                "origin_id": source,
                "edit_id": edit,
                "revision": 1,
                "journal_directory": journal
            }),
        )
    }

    fn receipt(
        &mut self,
        edit: &Value,
        source: &str,
        token: &Value,
        input: Value,
    ) -> Result<Value, Box<dyn std::error::Error>> {
        self.receipt_with_revision(edit, source, token, 1, input)
    }

    fn receipt_with_revision(
        &mut self,
        edit: &Value,
        source: &str,
        token: &Value,
        revision: u64,
        input: Value,
    ) -> Result<Value, Box<dyn std::error::Error>> {
        self.call(
            "edit/receipt",
            json!({
                "origin_id": source,
                "edit_id": edit,
                "revision": revision,
                "issued_token": token,
                "input": input
            }),
        )
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
        EditorEditId::try_from(edit.as_str().unwrap_or_default().to_owned())?,
        &CancellationToken::new(),
        Instant::now() + Duration::from_secs(5),
    )
}

#[test]
fn positive_single_file_receipt_verifies_applied_and_commits_journal() -> TestResult {
    let workspace = private()?;
    let journal = private()?;
    let path = workspace.path().join("file.txt");
    fs::write(&path, "old\n")?;
    let mut client = Client::new()?;
    let (_, edit) = client.ready(workspace.path(), SOURCE)?;
    let issued = client.issue(&edit, SOURCE, journal.path())?;
    assert_eq!(issued["result"]["state"], "issued");
    fs::write(&path, "new\n")?;
    let reply = upload(
        &mut client,
        &edit,
        &issued["result"]["issued_token"],
        observed(&path, "new\n", "new\n")?,
        "new\n",
        "new\n",
    )?;
    assert_eq!(reply["result"]["journal_committed"], true, "{reply}");
    let receipt = &reply["result"]["receipt"];
    assert_eq!(receipt["outcome"], "applied_full", "{reply}");
    assert_eq!(receipt["files_total"], 1);
    assert_eq!(receipt["files_applied"], 1);
    assert_eq!(receipt["files"][0]["saved"], true);
    assert_eq!(receipt["files"][0]["hook_modified"], false);
    assert!(matches!(
        recover(journal.path(), &edit)?,
        RecoveredJournal::Resolved {
            resolution: journal::JournalResolution::Receipt { .. },
            ..
        }
    ));
    Ok(())
}

#[test]
fn save_hook_modification_is_measured_and_reported() -> TestResult {
    let workspace = private()?;
    let journal = private()?;
    let path = workspace.path().join("file.txt");
    fs::write(&path, "old\n")?;
    let mut client = Client::new()?;
    let (_, edit) = client.ready(workspace.path(), SOURCE)?;
    let issued = client.issue(&edit, SOURCE, journal.path())?;
    fs::write(&path, "new\n#hook\n")?;
    let reply = upload(
        &mut client,
        &edit,
        &issued["result"]["issued_token"],
        observed(&path, "new\n", "new\n#hook\n")?,
        "new\n",
        "new\n#hook\n",
    )?;
    assert_eq!(
        reply["result"]["receipt"]["outcome"], "applied_full",
        "{reply}"
    );
    assert_eq!(
        reply["result"]["receipt"]["files"][0]["hook_modified"],
        true
    );
    Ok(())
}

#[test]
fn receipt_with_stale_token_or_wrong_owner_is_rejected() -> TestResult {
    let workspace = private()?;
    let journal = private()?;
    fs::write(workspace.path().join("file.txt"), "old\n")?;

    let mut client = Client::new()?;
    let (_, edit) = client.ready(workspace.path(), SOURCE)?;
    let issued = client.issue(&edit, SOURCE, journal.path())?;
    let _token = &issued["result"]["issued_token"];

    let wrong_token = "editor_issue_00000000-0000-4000-8000-000000000000";
    let stale_reply = client.receipt(
        &edit,
        SOURCE,
        &json!(wrong_token),
        json!({
            "action": "commit"
        }),
    )?;
    assert_eq!(stale_reply["error"]["data"]["status"], "stale_owner");

    Ok(())
}

#[test]
fn unmatched_written_text_against_proposal_results_in_unknown() -> TestResult {
    let workspace = private()?;
    let journal = private()?;
    fs::write(workspace.path().join("file.txt"), "old\n")?;

    let mut client = Client::new()?;
    let (_, edit) = client.ready(workspace.path(), SOURCE)?;
    let issued = client.issue(&edit, SOURCE, journal.path())?;
    let token = &issued["result"]["issued_token"];

    client.receipt(
        &edit,
        SOURCE,
        token,
        json!({
            "action": "file",
            "observation": {
                "file": 0,
                "progress": "save_returned",
                "failure": null,
                "write_tick": 2,
                "written_bytes": 4,
                "after": {
                    "kind": "document",
                    "document": {
                        "id": "editor_document_12345678-1234-4234-8234-123456789abc",
                        "tick": 2,
                        "bytes": 4,
                        "coding": "utf-8-unix",
                        "dirty": false,
                        "read_only": false,
                        "disk": {
                            "kind": "file",
                            "version": {
                                "device": 1,
                                "inode": 1,
                                "bytes": 4,
                                "mtime_ns": "1000",
                                "ctime_ns": "1000"
                            }
                        }
                    },
                    "encoded_hash": null
                }
            }
        }),
    )?;

    client.receipt(
        &edit,
        SOURCE,
        token,
        json!({
            "action": "append",
            "file": 0,
            "part": "written",
            "offset": 0,
            "text": "bad\n"
        }),
    )?;

    client.receipt(
        &edit,
        SOURCE,
        token,
        json!({
            "action": "append",
            "file": 0,
            "part": "after",
            "offset": 0,
            "text": "bad\n"
        }),
    )?;

    let commit_reply = client.receipt(
        &edit,
        SOURCE,
        token,
        json!({
            "action": "commit"
        }),
    )?;

    assert_eq!(commit_reply["result"]["state"], "quiescent");
    let receipt = &commit_reply["result"]["receipt"];
    assert_eq!(receipt["outcome"], "outcome_unknown");
    assert_eq!(receipt["files"][0]["outcome"], "outcome_unknown");

    Ok(())
}

#[test]
fn unavailable_after_observation_results_in_unknown_outcome() -> TestResult {
    let workspace = private()?;
    let journal = private()?;
    fs::write(workspace.path().join("file.txt"), "old\n")?;

    let mut client = Client::new()?;
    let (_, edit) = client.ready(workspace.path(), SOURCE)?;
    let issued = client.issue(&edit, SOURCE, journal.path())?;
    let token = &issued["result"]["issued_token"];

    client.receipt(
        &edit,
        SOURCE,
        token,
        json!({
            "action": "file",
            "observation": {
                "file": 0,
                "progress": "save_returned",
                "failure": null,
                "write_tick": 2,
                "written_bytes": 4,
                "after": {
                    "kind": "unavailable"
                }
            }
        }),
    )?;

    client.receipt(
        &edit,
        SOURCE,
        token,
        json!({
            "action": "append",
            "file": 0,
            "part": "written",
            "offset": 0,
            "text": "new\n"
        }),
    )?;

    let commit_reply = client.receipt(
        &edit,
        SOURCE,
        token,
        json!({
            "action": "commit"
        }),
    )?;

    assert_eq!(commit_reply["result"]["state"], "quiescent");
    let receipt = &commit_reply["result"]["receipt"];
    assert_eq!(receipt["outcome"], "outcome_unknown");
    assert_eq!(receipt["files"][0]["outcome"], "outcome_unknown");

    Ok(())
}

fn disk(path: &Path) -> Result<Value, Box<dyn std::error::Error>> {
    match fs::metadata(path) {
        Ok(m) => Ok(
            json!({"kind":"file","version":{"device":m.dev(),"inode":m.ino(),"bytes":m.len(),
            "mtime_ns":(i128::from(m.mtime())*1_000_000_000+i128::from(m.mtime_nsec())).to_string(),
            "ctime_ns":(i128::from(m.ctime())*1_000_000_000+i128::from(m.ctime_nsec())).to_string()}}),
        ),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(json!({"kind":"absent"})),
        Err(error) => Err(error.into()),
    }
}

fn observed(path: &Path, written: &str, after: &str) -> Result<Value, Box<dyn std::error::Error>> {
    Ok(
        json!({"file":0,"progress":"save_returned","write_tick":2,"written_bytes":written.len(),
        "after":{"kind":"document","document":{"id":"editor_document_12345678-1234-4234-8234-123456789abc",
        "tick":3,"bytes":after.len(),"coding":"utf-8-unix","dirty":false,"read_only":false,"disk":disk(path)?},
        "encoded_hash":format!("{:x}",Sha256::digest(after.as_bytes()))}}),
    )
}

fn upload(
    client: &mut Client,
    edit: &Value,
    token: &Value,
    observation: Value,
    written: &str,
    after: &str,
) -> Result<Value, Box<dyn std::error::Error>> {
    upload_with_revision(client, edit, token, 1, observation, written, after)
}

fn upload_with_revision(
    client: &mut Client,
    edit: &Value,
    token: &Value,
    revision: u64,
    observation: Value,
    written: &str,
    after: &str,
) -> Result<Value, Box<dyn std::error::Error>> {
    let reply = client.receipt_with_revision(
        edit,
        SOURCE,
        token,
        revision,
        json!({"action":"file","observation":observation}),
    )?;
    assert_eq!(reply["result"]["recorded"], true, "{reply}");
    for (part, text) in [("written", written), ("after", after)] {
        let reply = client.receipt_with_revision(
            edit,
            SOURCE,
            token,
            revision,
            json!({"action":"append","file":0,"part":part,"offset":0,"text":text}),
        )?;
        assert_eq!(reply["result"]["complete"], true, "{reply}");
    }
    client.receipt_with_revision(edit, SOURCE, token, revision, json!({"action":"commit"}))
}

#[test]
fn raw_save_claims_cannot_substitute_for_actual_final_evidence() -> TestResult {
    for case in [
        "not_written",
        "foreign_disk",
        "stale_stat",
        "dirty_final",
        "buffer_only_disk_change",
        "false_noop",
        "encoded_hash",
        "forged_encoded_pair",
    ] {
        let root = private()?;
        let journal = private()?;
        let path = root.path().join("file.txt");
        fs::write(
            &path,
            if case == "false_noop" {
                "new\n"
            } else {
                "old\n"
            },
        )?;
        let mut client = Client::new()?;
        let prep = client.prepared_with_policy(
            root.path(),
            SOURCE,
            if case == "buffer_only_disk_change" {
                "buffer_only"
            } else {
                "save"
            },
        )?;
        let edit = client.grant(&prep["preparation_id"], SOURCE)?;
        client.preflight(&prep, &edit, SOURCE)?;
        let issued = client.issue(&edit, SOURCE, journal.path())?;
        let token = &issued["result"]["issued_token"];
        if case != "not_written" && case != "forged_encoded_pair" {
            fs::write(&path, "new\n")?;
        }
        let after = if case == "false_noop" {
            "bad\n"
        } else {
            "new\n"
        };
        let mut observation = observed(&path, "new\n", after)?;
        match case {
            "foreign_disk" => fs::write(&path, "external\n")?,
            "stale_stat" => observation["after"]["document"]["disk"] = prep["disk"].clone(),
            "dirty_final" => observation["after"]["document"]["dirty"] = json!(true),
            "buffer_only_disk_change" => observation["progress"] = json!("replaced"),
            "encoded_hash" => observation["after"]["encoded_hash"] = json!("0".repeat(64)),
            "forged_encoded_pair" => {
                observation["after"]["encoded_hash"] =
                    json!(format!("{:x}", Sha256::digest(fs::read(&path)?)))
            }
            _ => {}
        }
        let reply = upload(&mut client, &edit, token, observation, "new\n", after)?;
        assert_ne!(
            reply["result"]["receipt"]["outcome"], "applied_full",
            "false success for {case}: {reply}"
        );
        if case == "dirty_final" {
            assert_eq!(reply["result"]["receipt"]["files"][0]["saved"], true);
        }
        assert!(
            reply["result"].get("receipt").is_some(),
            "must preserve per-file evidence for {case}: {reply}"
        );
    }
    Ok(())
}

#[test]
fn real_saved_receipt_remains_acceptable_after_owner_retirement() -> TestResult {
    for close in ["edit/abort", "session/close", "application/close"] {
        let root = private()?;
        let journal = private()?;
        let path = root.path().join("file.txt");
        fs::write(&path, "old\n")?;
        let mut client = Client::new()?;
        let (prep, edit) = client.ready(root.path(), SOURCE)?;
        let issued = client.issue(&edit, SOURCE, journal.path())?;
        fs::write(&path, "new\n")?;
        let observation = observed(&path, "new\n", "new\n")?;
        if close == "edit/abort" {
            client.call(
                close,
                json!({"origin_id":SOURCE,"preparation_id":prep["preparation_id"]}),
            )?;
        } else {
            let params = if close == "session/close" {
                client.scope.clone()
            } else {
                json!({"application_id":client.scope["application_id"]})
            };
            client
                .peer
                .send(json!({"jsonrpc":"2.0","id":"close","method":close,"params":params}))?;
            if close == "session/close" {
                client.response("close")?;
            }
        }
        // A round trip ensures teardown has reached the actual actor.
        client
            .peer
            .send(json!({"jsonrpc":"2.0","id":"barrier","method":"ping"}))?;
        client.response("barrier")?;
        let reply = upload(
            &mut client,
            &edit,
            &issued["result"]["issued_token"],
            observation,
            "new\n",
            "new\n",
        )?;
        assert_eq!(
            reply["result"]["receipt"]["outcome"], "applied_full",
            "{close}: {reply}"
        );
        if close == "application/close" {
            assert_eq!(client.response("close")?["result"]["status"], "closed");
        }
    }
    Ok(())
}

#[test]
fn buffer_only_and_noop_counts_preserve_actual_disk() -> TestResult {
    for policy in ["buffer_only", "save"] {
        for noop in [false, true] {
            let root = private()?;
            let journal = private()?;
            let path = root.path().join("file.txt");
            let base = if noop { "new\n" } else { "old\n" };
            fs::write(&path, base)?;
            let mut client = Client::new()?;
            let prep = client.prepared_with_policy(root.path(), SOURCE, policy)?;
            let edit = client.grant(&prep["preparation_id"], SOURCE)?;
            client.preflight(&prep, &edit, SOURCE)?;
            let issued = client.issue(&edit, SOURCE, journal.path())?;
            if policy == "save" && !noop {
                fs::write(&path, "new\n")?;
            }
            let mut observation = observed(&path, "new\n", "new\n")?;
            observation["progress"] = json!(if policy == "save" {
                "save_returned"
            } else {
                "replaced"
            });
            observation["after"]["document"]["dirty"] = json!(policy == "buffer_only" && !noop);
            let reply = upload(
                &mut client,
                &edit,
                &issued["result"]["issued_token"],
                observation,
                "new\n",
                "new\n",
            )?;
            let receipt = &reply["result"]["receipt"];
            assert_eq!(receipt["outcome"], "applied_full", "{reply}");
            assert_eq!(receipt["files_applied"], if noop { 0 } else { 1 });
            assert_eq!(
                receipt["files"][0]["outcome"],
                if noop { "unchanged" } else { "applied" }
            );
            assert_eq!(receipt["files"][0]["saved"], policy == "save" && !noop);
            assert_eq!(
                fs::read_to_string(&path)?,
                if policy == "save" { "new\n" } else { base }
            );
        }
    }
    Ok(())
}

#[test]
fn newly_created_and_empty_files_need_actual_save_evidence() -> TestResult {
    for text in ["new\n", ""] {
        let root = private()?;
        let journal = private()?;
        let path = root.path().join("file.txt");
        let mut client = Client::new()?;
        let prep = client.prepared_with_text(root.path(), SOURCE, "save", text)?;
        let edit = client.grant(&prep["preparation_id"], SOURCE)?;
        client.preflight(&prep, &edit, SOURCE)?;
        let issued = client.issue(&edit, SOURCE, journal.path())?;
        fs::write(&path, text)?;
        let reply = upload(
            &mut client,
            &edit,
            &issued["result"]["issued_token"],
            observed(&path, text, text)?,
            text,
            text,
        )?;
        assert_eq!(
            reply["result"]["receipt"]["outcome"], "applied_full",
            "{reply}"
        );
        assert_eq!(fs::read_to_string(&path)?, text);
    }
    Ok(())
}

#[test]
fn deletion_receipts_verify_actual_absence_after_real_git_preparation() -> TestResult {
    for remove in [false, true] {
        let root = private()?;
        let journal = private()?;
        let path = root.path().join("file.txt");
        fs::write(&path, "old\n")?;
        let mut client = Client::new()?;
        let patch = "--- a/file.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n";
        let reply=client.call("edit/begin",json!({"origin_id":SOURCE,"root":root.path(),"mode":"agent","live":null,
            "intent":{"kind":"patch","patch_bytes":patch.len()},"config_revision":3,"policy_revision":7,"review_mode":"auto","save_policy":"save"}))?;
        let id = reply["result"]["preparation_id"].clone();
        assert!(id.is_string(), "{reply}");
        client.call(
            "edit/append",
            json!({"origin_id":SOURCE,"preparation_id":id,"part":"patch","offset":0,"text":patch}),
        )?;
        let inspected = client.call(
            "edit/inspect",
            json!({"origin_id":SOURCE,"preparation_id":id}),
        )?;
        assert_eq!(inspected["result"]["inspected"], true, "{inspected}");
        let prepared = client.call(
            "edit/prepare",
            json!({"origin_id":SOURCE,"preparation_id":id}),
        )?;
        assert_eq!(prepared["result"]["file_count"], 1, "{prepared}");
        let page = client.call(
            "edit/files",
            json!({"origin_id":SOURCE,"preparation_id":id,"offset":0}),
        )?;
        let edit = client.grant(&id, SOURCE)?;
        client.preflight(&page["result"]["files"][0], &edit, SOURCE)?;
        let issued = client.issue(&edit, SOURCE, journal.path())?;
        if remove {
            fs::remove_file(&path)?;
        }
        let token = &issued["result"]["issued_token"];
        let recorded=client.receipt(&edit,SOURCE,token,json!({"action":"file","observation":{"file":0,"progress":"deleted",
            "after":{"kind":"closed","document_id":"editor_document_12345678-1234-4234-8234-123456789abc","disk":{"kind":"absent"}}}}))?;
        assert_eq!(recorded["result"]["recorded"], true, "{recorded}");
        let reply = client.receipt(&edit, SOURCE, token, json!({"action":"commit"}))?;
        assert_eq!(
            reply["result"]["receipt"]["outcome"],
            if remove {
                "applied_full"
            } else {
                "outcome_unknown"
            },
            "{reply}"
        );
    }
    Ok(())
}

#[tokio::test]
async fn test_edit_revise_bumps_revision_and_rejects_stale_decision() -> TestResult {
    let root = private()?;
    let journal = private()?;
    let path = root.path().join("file.txt");
    fs::write(&path, "old\n")?;

    let mut client = Client::new()?;
    let prep_id = client.call(
        "edit/begin",
        json!({
            "origin_id": SOURCE,
            "root": root.path(),
            "mode": "agent",
            "intent": {
                "kind": "write",
                "path": "file.txt",
                "new_bytes": 4
            },
            "live": null,
            "config_revision": 3,
            "policy_revision": 7,
            "review_mode": "async",
            "save_policy": "save"
        }),
    )?["result"]["preparation_id"]
        .clone();
    client.call(
        "edit/append",
        json!({
            "origin_id": SOURCE,
            "preparation_id": prep_id,
            "part": "new",
            "offset": 0,
            "text": "new\n"
        }),
    )?;
    let prep = client.call(
        "edit/prepare",
        json!({
            "origin_id": SOURCE,
            "preparation_id": prep_id
        }),
    )?["result"]
        .clone();

    // Authorize with an available presenter yields interactive review
    let auth_reply = client.call(
        "edit/authorize",
        json!({
            "origin_id": SOURCE,
            "preparation_id": prep_id,
            "presenter": "available"
        }),
    )?;
    assert_eq!(auth_reply["result"]["state"], "review", "{auth_reply}");
    assert_eq!(auth_reply["result"]["revision"], 1);
    let edit_id = auth_reply["result"]["edit_id"].clone();

    let invalid = client.call("edit/revise", json!({"origin_id":SOURCE,"edit_id":edit_id,"revision":1,"file_index":1,"new_text":"wrong\n"}))?;
    assert!(invalid.get("error").is_some(), "{invalid}");
    let original = client.call(
        "edit/read",
        json!({"origin_id":SOURCE,"preparation_id":prep_id,"part":"proposed","offset":0}),
    )?;
    assert_eq!(original["result"]["text"], "new\n");
    // Revise proposed text from review UI
    let revise_reply = client.call(
        "edit/revise",
        json!({
            "origin_id": SOURCE,
            "edit_id": edit_id,
            "revision": 1,
            "file_index": 0,
            "new_text": "revised\n"
        }),
    )?;
    assert_eq!(revise_reply["result"]["edit_id"], edit_id);
    assert_eq!(revise_reply["result"]["revision"], 2, "{revise_reply}");

    // Calling decision with stale revision 1 must be rejected
    let stale_decision = client.call(
        "edit/decision",
        json!({
            "origin_id": SOURCE,
            "edit_id": edit_id,
            "revision": 1,
            "decision": "accept"
        }),
    )?;
    assert!(
        stale_decision.get("error").is_some(),
        "Expected stale decision error: {stale_decision}"
    );

    // Calling decision with updated revision 2 must succeed
    let valid_decision = client.call(
        "edit/decision",
        json!({
            "origin_id": SOURCE,
            "edit_id": edit_id,
            "revision": 2,
            "decision": "accept"
        }),
    )?;
    assert_eq!(
        valid_decision["result"]["state"], "authorized",
        "{valid_decision}"
    );
    assert_eq!(valid_decision["result"]["revision"], 2);

    // Preflight with revision 2
    let preflight_reply = client.call(
        "edit/preflight",
        json!({
            "origin_id": SOURCE,
            "edit_id": edit_id,
            "revision": 2,
            "witness": {
                "file": 0,
                "base_hash": prep["base_hash"],
                "document": {
                    "id": "editor_document_12345678-1234-4234-8234-123456789abc",
                    "tick": 1,
                    "bytes": prep["base_bytes"],
                    "coding": "utf-8-unix",
                    "dirty": false,
                    "read_only": false,
                    "disk": prep["disk"]
                }
            }
        }),
    )?;
    assert_eq!(preflight_reply["result"]["state"], "preflighted");

    // Issue with revision 2
    let issued = client.call(
        "edit/issue",
        json!({
            "origin_id": SOURCE,
            "edit_id": edit_id,
            "revision": 2,
            "journal_directory": journal.path()
        }),
    )?;
    assert_eq!(issued["result"]["state"], "issued");
    let token = &issued["result"]["issued_token"];

    // Write the revised text to disk and upload receipt
    fs::write(&path, "revised\n")?;
    let reply = upload_with_revision(
        &mut client,
        &edit_id,
        token,
        2,
        observed(&path, "revised\n", "revised\n")?,
        "revised\n",
        "revised\n",
    )?;
    assert_eq!(reply["result"]["receipt"]["outcome"], "applied_full");
    assert_eq!(reply["result"]["receipt"]["hunks_total"], 1);
    assert_eq!(reply["result"]["receipt"]["hunks_applied"], 1);

    Ok(())
}

#[tokio::test]
async fn test_edit_rollback_reverses_applied_edit_and_rejects_foreign_modifications() -> TestResult
{
    let root = private()?;
    let journal = private()?;
    let path = root.path().join("file.txt");
    fs::write(&path, "old\n")?;

    let mut client = Client::new()?;
    let (_prep, edit_id) = client.ready(root.path(), SOURCE)?;
    let issued = client.issue(&edit_id, SOURCE, journal.path())?;
    let token = &issued["result"]["issued_token"];

    fs::write(&path, "new\n")?;
    let commit_reply = upload(
        &mut client,
        &edit_id,
        token,
        observed(&path, "new\n", "new\n")?,
        "new\n",
        "new\n",
    )?;
    assert_eq!(commit_reply["result"]["receipt"]["outcome"], "applied_full");

    // Prepare rollback for the edit
    let rollback_prep = client.call(
        "edit/rollback",
        json!({
            "origin_id": SOURCE,
            "target_edit_id": edit_id,
            "mode":"agent","review_mode":"auto","save_policy":"save",
            "config_revision":9,"policy_revision":11
        }),
    )?;
    assert!(rollback_prep["result"]["preparation_id"].is_string());
    assert_eq!(rollback_prep["result"]["target_edit_id"], edit_id);
    let rollback_prep_id = &rollback_prep["result"]["preparation_id"];

    // Authorize rollback
    let rollback_auth = client.call(
        "edit/authorize",
        json!({
            "origin_id": SOURCE,
            "preparation_id": rollback_prep_id,
            "presenter": "missing"
        }),
    )?;
    assert_eq!(rollback_auth["result"]["state"], "authorized");
    assert_eq!(rollback_auth["result"]["scope"]["config_revision"], 9);
    assert_eq!(rollback_auth["result"]["scope"]["policy_revision"], 11);
    let rollback_edit_id = &rollback_auth["result"]["edit_id"];

    // If file has foreign modifications, preflight must fail with conflict
    let stat = fs::metadata(&path)?;
    let dev = stat.dev();
    let ino = stat.ino();
    let mtime = stat.mtime_nsec();
    let ctime = stat.ctime_nsec();

    let foreign_witness = json!({
        "file": 0,
        "base_hash": "0000000000000000000000000000000000000000000000000000000000000000",
        "document": {
            "id": "editor_document_12345678-1234-4234-8234-123456789abc",
            "tick": 3,
            "bytes": 12,
            "coding": "utf-8-unix",
            "dirty": false,
            "read_only": false,
            "disk": {
                "kind": "file",
                "version": {
                    "device": dev,
                    "inode": ino,
                    "bytes": 12,
                    "mtime_ns": mtime.to_string(),
                    "ctime_ns": ctime.to_string()
                }
            }
        }
    });
    let preflight_fail = client.call(
        "edit/preflight",
        json!({
            "origin_id": SOURCE,
            "edit_id": rollback_edit_id,
            "revision": 1,
            "witness": foreign_witness
        }),
    )?;
    assert!(
        preflight_fail.get("error").is_some(),
        "Expected preflight conflict on foreign hash: {preflight_fail}"
    );

    // Preflight with matching base_hash ("new\n")
    let rollback_files = client.call(
        "edit/files",
        json!({"origin_id":SOURCE,"preparation_id":rollback_prep_id,"offset":0}),
    )?;
    let rollback_descriptor = &rollback_files["result"]["files"][0];
    let preflight_ok = client.call(
        "edit/preflight",
        json!({
            "origin_id": SOURCE,
            "edit_id": rollback_edit_id,
            "revision": 1,
            "witness": {
                "file": 0,
                "base_hash": rollback_descriptor["base_hash"],
                "document": {
                    "id": "editor_document_12345678-1234-4234-8234-123456789abc",
                    "tick": 3,
                    "bytes": rollback_descriptor["base_bytes"],
                    "coding": "utf-8-unix",
                    "dirty": false,
                    "read_only": false,
                    "disk": rollback_descriptor["disk"]
                }
            }
        }),
    )?;
    assert_eq!(
        preflight_ok["result"]["state"], "preflighted",
        "{preflight_ok}"
    );

    // Issue rollback
    let rollback_issued = client.call(
        "edit/issue",
        json!({
            "origin_id": SOURCE,
            "edit_id": rollback_edit_id,
            "revision": 1,
            "journal_directory": journal.path()
        }),
    )?;
    assert_eq!(rollback_issued["result"]["state"], "issued");
    let rollback_token = &rollback_issued["result"]["issued_token"];

    // Restore "old\n" to disk and upload rollback receipt
    fs::write(&path, "old\n")?;
    let rollback_commit = upload(
        &mut client,
        rollback_edit_id,
        rollback_token,
        {
            let mut fact = observed(&path, "old\n", "old\n")?;
            fact["write_tick"] = json!(4);
            fact["after"]["document"]["tick"] = json!(5);
            fact
        },
        "old\n",
        "old\n",
    )?;
    assert_eq!(
        rollback_commit["result"]["receipt"]["outcome"],
        "applied_full"
    );
    assert_eq!(fs::read_to_string(&path)?, "old\n");

    Ok(())
}

#[test]
fn rollback_rejects_real_foreign_disk_change_before_preparation() -> TestResult {
    for final_body in ["new\n", "save hook result\n"] {
        let root = private()?;
        let journal = private()?;
        let path = root.path().join("file.txt");
        fs::write(&path, "old\n")?;
        let mut client = Client::new()?;
        let (_, edit) = client.ready(root.path(), SOURCE)?;
        let issued = client.issue(&edit, SOURCE, journal.path())?;
        fs::write(&path, final_body)?;
        let reply = upload(
            &mut client,
            &edit,
            &issued["result"]["issued_token"],
            observed(&path, "new\n", final_body)?,
            "new\n",
            final_body,
        )?;
        assert_eq!(reply["result"]["receipt"]["outcome"], "applied_full");
        fs::write(&path, "foreign owner\n")?;
        let rollback=client.call("edit/rollback",json!({"origin_id":SOURCE,"target_edit_id":edit,"mode":"agent","review_mode":"auto","save_policy":"save","config_revision":3,"policy_revision":7}))?;
        assert!(rollback.get("error").is_some(), "{rollback}");
        assert_eq!(fs::read_to_string(&path)?, "foreign owner\n");
    }
    Ok(())
}

#[test]
fn hunk_measurement_distinguishes_zero_single_multi_and_hook_modified_unproven() -> TestResult {
    let root = private()?;
    let journal = private()?;
    let path = root.path().join("file.txt");
    let base: String = (0..12).map(|i| format!("line-{i}\n")).collect();
    let mut multi_lines: Vec<String> = (0..12).map(|i| format!("line-{i}\n")).collect();
    multi_lines[0] = "changed-0\n".to_owned();
    multi_lines[11] = "changed-11\n".to_owned();
    let multi = multi_lines.concat();

    fs::write(&path, &base)?;
    let mut client = Client::new()?;

    // 1. Multi-hunk write (2 hunks separated by 10 unchanged lines)
    let prep = client.prepared_with_text(root.path(), SOURCE, "save", &multi)?;
    assert_eq!(prep["hunks_total"], 2, "{prep}");
    let edit = client.grant(&prep["preparation_id"], SOURCE)?;
    client.preflight(&prep, &edit, SOURCE)?;
    let issued = client.issue(&edit, SOURCE, journal.path())?;
    fs::write(&path, &multi)?;
    let reply = upload(
        &mut client,
        &edit,
        &issued["result"]["issued_token"],
        observed(&path, &multi, &multi)?,
        &multi,
        &multi,
    )?;
    assert_eq!(reply["result"]["receipt"]["hunks_total"], 2);
    assert_eq!(reply["result"]["receipt"]["hunks_applied"], 2);

    // 2. Rollback of multi-hunk edit preserves 2 hunks
    let rollback_prep = client.call(
        "edit/rollback",
        json!({
            "origin_id": SOURCE,
            "target_edit_id": edit,
            "mode": "agent",
            "review_mode": "auto",
            "save_policy": "save",
            "config_revision": 3,
            "policy_revision": 7
        }),
    )?;
    assert_eq!(rollback_prep["result"]["descriptor"]["hunks_total"], 2);

    // 3. Save-hook modification leaves hunks_applied unproven (null) while hunks_total is 2
    let prep2 = client.prepared_with_text(root.path(), SOURCE, "save", &base)?;
    assert_eq!(prep2["hunks_total"], 2);
    let edit2 = client.grant(&prep2["preparation_id"], SOURCE)?;
    client.preflight(&prep2, &edit2, SOURCE)?;
    let issued2 = client.issue(&edit2, SOURCE, journal.path())?;
    let hooked = format!("{base}#hook\n");
    fs::write(&path, &hooked)?;
    let reply2 = upload(
        &mut client,
        &edit2,
        &issued2["result"]["issued_token"],
        observed(&path, &base, &hooked)?,
        &base,
        &hooked,
    )?;
    assert_eq!(reply2["result"]["receipt"]["hunks_total"], 2);
    assert!(reply2["result"]["receipt"]["hunks_applied"].is_null());

    // Undo enumeration comes from the native owner, without retaining bodies in UI.
    let history = client.call(
        "edit/history",
        json!({"action":"list", "offset":0, "revision":null}),
    )?;
    let revision = history["result"]["revision"].clone();
    assert!(revision.is_u64(), "{history}");
    let rows = history["result"]["files"]
        .as_array()
        .ok_or("history rows missing")?;
    assert!(rows.iter().any(|row| row["edit_id"] == edit2));
    let foreign_service = "edit_service_12345678-1234-4234-8234-123456789abc";
    let isolated = client.call(
        "edit/history",
        json!({"action":"list", "offset":0, "revision":null, "service_id":foreign_service}),
    )?;
    assert_eq!(isolated["result"]["files"], json!([]));
    let foreign_files = client.call(
        "edit/history",
        json!({"action":"files", "edit_id":edit2, "offset":0, "revision":revision,
               "service_id":foreign_service}),
    )?;
    assert!(foreign_files.get("error").is_some(), "{foreign_files}");
    let files = client.call(
        "edit/history",
        json!({"action":"files", "edit_id":edit2, "offset":0, "revision":revision}),
    )?;
    assert_eq!(files["result"]["files"][0]["path"], "file.txt");
    assert!(!files.to_string().contains("changed-0"));
    let stale = client.call(
        "edit/history",
        json!({"action":"list", "offset":0, "revision":0}),
    )?;
    assert!(stale.get("error").is_some(), "{stale}");

    // 4. Native change and verification ledger is revision-bound and exact-identity consumed
    let changes = client.call(
        "edit/history",
        json!({
            "action": "changes",
            "offset": 0,
            "revision": null,
            "pending_only": true
        }),
    )?;
    assert_eq!(changes["result"]["files"].as_array().map(Vec::len), Some(1));
    assert_eq!(changes["result"]["files"][0]["edit_id"], edit2);
    assert_eq!(changes["result"]["files"][0]["path"], "file.txt");
    assert_eq!(changes["result"]["files"][0]["verification_pending"], true);
    let edit2_hash = changes["result"]["files"][0]["final_hash"].clone();

    // Consuming an older edit_id on the same file does NOT consume the newer edit's pending state
    let stale_consume = client.call(
        "edit/history",
        json!({
            "action": "consume",
            "edit_id": edit,
            "file": 0,
            "final_hash": edit2_hash
        }),
    )?;
    assert_eq!(stale_consume["result"]["consumed"], false);

    // Consuming exact (edit_id, file, final_hash) clears verification_pending while keeping modified-file entry
    let exact_consume = client.call(
        "edit/history",
        json!({
            "action": "consume",
            "edit_id": edit2,
            "file": 0,
            "final_hash": edit2_hash
        }),
    )?;
    assert_eq!(exact_consume["result"]["consumed"], true);

    let pending_after = client.call(
        "edit/history",
        json!({
            "action": "changes",
            "offset": 0,
            "revision": null,
            "pending_only": true
        }),
    )?;
    assert_eq!(pending_after["result"]["files"], json!([]));

    let all_after = client.call(
        "edit/history",
        json!({
            "action": "changes",
            "offset": 0,
            "revision": null,
            "pending_only": false
        }),
    )?;
    assert_eq!(
        all_after["result"]["files"].as_array().map(Vec::len),
        Some(1)
    );
    assert_eq!(
        all_after["result"]["files"][0]["verification_pending"],
        false
    );

    // Resetting run changes clears modified files without dropping rollback snapshots
    let reset = client.call(
        "edit/history",
        json!({
            "action": "reset_changes"
        }),
    )?;
    assert_eq!(reset["result"]["reset"], true);
    let after_reset = client.call(
        "edit/history",
        json!({
            "action": "changes",
            "offset": 0,
            "revision": null
        }),
    )?;
    assert_eq!(after_reset["result"]["files"], json!([]));
    let snapshots_still_exist = client.call(
        "edit/history",
        json!({"action":"list", "offset":0, "revision":null}),
    )?;
    assert!(
        !snapshots_still_exist["result"]["files"]
            .as_array()
            .ok_or("snapshots missing")?
            .is_empty()
    );

    // 5. Edit recovery RPC surfaces journal resolution over stdio
    let recovered = client.call(
        "edit/recover",
        json!({
            "edit_id": edit2,
            "journal_directory": journal.path()
        }),
    )?;
    assert_eq!(recovered["result"]["state"], "resolved", "{recovered}");
    assert_eq!(recovered["result"]["resolution"]["kind"], "receipt");
    Ok(())
}

#[test]
fn chunked_revise_and_paged_receipt_succeed_under_one_kib_negotiated_frames() -> TestResult {
    paged_receipt_case(false)
}
#[test]
fn application_close_preserves_unread_receipt_pages_until_the_last_page() -> TestResult {
    paged_receipt_case(true)
}
fn paged_receipt_case(close_application: bool) -> TestResult {
    let root = private()?;
    let journal = private()?;
    let first = root.path().join("first.txt");
    let second = root.path().join("second.txt");
    let third = root.path().join("third.txt");
    fs::write(&first, "old-1\n")?;
    fs::write(&second, "old-2\n")?;
    fs::write(&third, "old-3\n")?;

    let mut client = Client::new_with_limit(1024)?;
    let patch = concat!(
        "--- a/first.txt\n+++ b/first.txt\n@@ -1 +1 @@\n-old-1\n+new-1\n",
        "--- a/second.txt\n+++ b/second.txt\n@@ -1 +1 @@\n-old-2\n+new-2\n",
        "--- a/third.txt\n+++ b/third.txt\n@@ -1 +1 @@\n-old-3\n+new-3\n"
    );
    let prep_id = client.call(
        "edit/begin",
        json!({
            "origin_id": SOURCE,
            "root": root.path(),
            "mode": "agent",
            "live": null,
            "intent": {"kind": "patch", "patch_bytes": patch.len()},
            "config_revision": 3,
            "policy_revision": 7,
            "review_mode": "async",
            "save_policy": "save"
        }),
    )?["result"]["preparation_id"]
        .clone();
    client.call(
        "edit/append",
        json!({
            "origin_id": SOURCE,
            "preparation_id": prep_id,
            "part": "patch",
            "offset": 0,
            "text": patch
        }),
    )?;
    client.call(
        "edit/inspect",
        json!({"origin_id": SOURCE, "preparation_id": prep_id}),
    )?;
    client.call(
        "edit/prepare",
        json!({"origin_id": SOURCE, "preparation_id": prep_id}),
    )?;
    let f0_reply = client.call(
        "edit/files",
        json!({"origin_id": SOURCE, "preparation_id": prep_id, "offset": 0}),
    )?;
    assert!(f0_reply["result"]["files"].is_array(), "{f0_reply}");
    let f0 = f0_reply["result"]["files"][0].clone();
    let f1_reply = client.call(
        "edit/files",
        json!({"origin_id": SOURCE, "preparation_id": prep_id, "offset": 1}),
    )?;
    assert!(f1_reply["result"]["files"].is_array(), "{f1_reply}");
    let f1 = f1_reply["result"]["files"][0].clone();
    let f2_reply = client.call(
        "edit/files",
        json!({"origin_id": SOURCE, "preparation_id": prep_id, "offset": 2}),
    )?;
    assert!(f2_reply["result"]["files"].is_array(), "{f2_reply}");
    let f2 = f2_reply["result"]["files"][0].clone();

    let auth = client.call(
        "edit/authorize",
        json!({"origin_id": SOURCE, "preparation_id": prep_id, "presenter": "available"}),
    )?;
    assert_eq!(auth["result"]["state"], "review", "{auth}");
    let edit_id = auth["result"]["edit_id"].clone();

    // Stream a 390-byte revision across 4 chunks under the 1 KiB frame cap
    let revised = "revised line\n".repeat(30);
    let begin_rev = client.call(
        "edit/revise",
        json!({
            "origin_id": SOURCE,
            "edit_id": edit_id,
            "revision": 1,
            "input": {
                "action": "begin",
                "file_index": 0,
                "new_bytes": revised.len()
            }
        }),
    )?;
    assert_eq!(begin_rev["result"]["bytes"], revised.len(), "{begin_rev}");
    let mut offset = 0usize;
    while offset < revised.len() {
        let end = (offset + 120).min(revised.len());
        let chunk = &revised[offset..end];
        let step = client.call(
            "edit/revise",
            json!({
                "origin_id": SOURCE,
                "edit_id": edit_id,
                "revision": 1,
                "input": {
                    "action": "append",
                    "file_index": 0,
                    "offset": offset,
                    "text": chunk
                }
            }),
        )?;
        assert_eq!(step["result"]["offset"], end, "{step}");
        offset = end;
    }
    let commit_rev = client.call(
        "edit/revise",
        json!({
            "origin_id": SOURCE,
            "edit_id": edit_id,
            "revision": 1,
            "input": {
                "action": "commit",
                "file_index": 0
            }
        }),
    )?;
    assert_eq!(commit_rev["result"]["revision"], 2, "{commit_rev}");

    let decision = client.call(
        "edit/decision",
        json!({
            "origin_id": SOURCE,
            "edit_id": edit_id,
            "revision": 2,
            "decision": "accept"
        }),
    )?;
    assert_eq!(decision["result"]["state"], "authorized", "{decision}");

    for (index, desc, doc_id) in [
        (
            0,
            &f0,
            "editor_document_12345678-1234-4234-8234-123456789abc",
        ),
        (
            1,
            &f1,
            "editor_document_22345678-1234-4234-8234-123456789abc",
        ),
        (
            2,
            &f2,
            "editor_document_32345678-1234-4234-8234-123456789abc",
        ),
    ] {
        let pf = client.call(
            "edit/preflight",
            json!({
                "origin_id": SOURCE,
                "edit_id": edit_id,
                "revision": 2,
                "witness": {
                    "file": index,
                    "base_hash": desc["base_hash"],
                    "document": {
                        "id": doc_id,
                        "tick": 1,
                        "bytes": desc["base_bytes"],
                        "coding": "utf-8-unix",
                        "dirty": false,
                        "read_only": false,
                        "disk": desc["disk"]
                    }
                }
            }),
        )?;
        if index < 2 {
            assert_eq!(pf["result"]["ready"], false, "{pf}");
        } else {
            assert_eq!(pf["result"]["state"], "preflighted", "{pf}");
        }
    }

    let issued = client.call(
        "edit/issue",
        json!({
            "origin_id": SOURCE,
            "edit_id": edit_id,
            "revision": 2,
            "journal_directory": journal.path()
        }),
    )?;
    let token = &issued["result"]["issued_token"];

    fs::write(&first, &revised)?;
    fs::write(&second, "new-2\n")?;
    fs::write(&third, "new-3\n")?;

    for (index, path, body, doc_id) in [
        (
            0usize,
            &first,
            revised.as_str(),
            "editor_document_12345678-1234-4234-8234-123456789abc",
        ),
        (
            1usize,
            &second,
            "new-2\n",
            "editor_document_22345678-1234-4234-8234-123456789abc",
        ),
        (
            2usize,
            &third,
            "new-3\n",
            "editor_document_32345678-1234-4234-8234-123456789abc",
        ),
    ] {
        let mut obs = observed(path, body, body)?;
        obs["file"] = json!(index);
        obs["after"]["document"]["id"] = json!(doc_id);
        client.receipt_with_revision(
            &edit_id,
            SOURCE,
            token,
            2,
            json!({"action": "file", "observation": obs}),
        )?;
        for part in ["written", "after"] {
            let mut off = 0usize;
            while off < body.len() {
                let end = (off + 120).min(body.len());
                client.receipt_with_revision(
                    &edit_id,
                    SOURCE,
                    token,
                    2,
                    json!({
                        "action": "append",
                        "file": index,
                        "part": part,
                        "offset": off,
                        "text": &body[off..end]
                    }),
                )?;
                off = end;
            }
        }
    }

    let settled =
        client.receipt_with_revision(&edit_id, SOURCE, token, 2, json!({"action": "commit"}))?;
    assert_eq!(
        settled["result"]["receipt"]["complete"], false,
        "3-file receipt under 1 KiB frame must return paged summary: {settled}"
    );
    if close_application {
        client.peer.send(json!({"jsonrpc":"2.0","id":"close-with-pages","method":"application/close","params":{"application_id":client.scope["application_id"]}}))?;
    }
    let page0 = client.receipt_with_revision(
        &edit_id,
        SOURCE,
        token,
        2,
        json!({"action": "files", "offset": 0}),
    )?;
    assert_eq!(page0["result"]["files"][0]["path"], "first.txt", "{page0}");
    assert_eq!(page0["result"]["next_offset"], 2, "{page0}");
    assert_eq!(page0["result"]["complete"], false, "{page0}");
    let page1 = client.receipt_with_revision(
        &edit_id,
        SOURCE,
        token,
        2,
        json!({"action": "files", "offset": 2}),
    )?;
    assert_eq!(page1["result"]["files"][0]["path"], "third.txt", "{page1}");
    assert_eq!(page1["result"]["next_offset"], 3, "{page1}");
    assert_eq!(page1["result"]["complete"], true, "{page1}");
    if close_application {
        assert_eq!(
            client.response("close-with-pages")?["result"]["status"],
            "closed"
        );
    }
    Ok(())
}

#[test]
fn streamed_review_reserves_its_body_once_and_releases_capacity_after_commit() -> TestResult {
    let root = private()?;
    let path = root.path().join("file.txt");
    let body = "a".repeat(kargu_core::constants::limits::EDIT_TEXT_BYTES);
    fs::write(&path, &body)?;
    let mut client = Client::new()?;
    let prepared = client.prepared_with_review(root.path(), SOURCE, "save", &body, "blocking")?;
    let prep = &prepared["preparation_id"];
    let auth = client.call(
        "edit/authorize",
        json!({"origin_id":SOURCE,"preparation_id":prep,"presenter":"available"}),
    )?;
    let edit = &auth["result"]["edit_id"];
    assert_eq!(auth["result"]["state"], "review", "{auth}");
    let competing=client.call("edit/begin",json!({"origin_id":SOURCE,"root":root.path(),"mode":"agent","intent":{"kind":"write","path":"other.txt","new_bytes":0},"live":null,"config_revision":3,"policy_revision":7,"review_mode":"auto","save_policy":"save"}))?;
    assert!(
        competing["result"]["preparation_id"].is_string(),
        "{competing}"
    );
    let begin=client.call("edit/revise",json!({"origin_id":SOURCE,"edit_id":edit,"revision":1,"input":{"action":"begin","file_index":0,"new_bytes":body.len()}}))?;
    assert_eq!(begin["result"]["bytes"], body.len(), "{begin}");
    for offset in (0..body.len()).step_by(16384) {
        let end = offset.saturating_add(16384).min(body.len());
        let ack=client.call("edit/revise",json!({"origin_id":SOURCE,"edit_id":edit,"revision":1,"input":{"action":"append","file_index":0,"offset":offset,"text":&body[offset..end]}}))?;
        assert_eq!(ack["result"]["next_offset"], end, "{ack}");
    }
    let committed=client.call("edit/revise",json!({"origin_id":SOURCE,"edit_id":edit,"revision":1,"input":{"action":"commit","file_index":0}}))?;
    assert_eq!(committed["result"]["revision"], 2, "{committed}");
    let rejected = client.call(
        "edit/decision",
        json!({"origin_id":SOURCE,"edit_id":edit,"revision":2,"decision":"reject"}),
    )?;
    assert!(rejected.get("error").is_some());
    assert_eq!(fs::read_to_string(path)?, body);
    Ok(())
}

#[test]
fn pending_revision_upload_cannot_be_replaced_or_approved_as_old_text() -> TestResult {
    let root = private()?;
    fs::write(root.path().join("file.txt"), "old\n")?;
    let mut client = Client::new()?;
    let prepared = client.prepared_with_review(root.path(), SOURCE, "save", "new\n", "blocking")?;
    let auth=client.call("edit/authorize",json!({"origin_id":SOURCE,"preparation_id":prepared["preparation_id"],"presenter":"available"}))?;
    let edit = &auth["result"]["edit_id"];
    let begin = || json!({"origin_id":SOURCE,"edit_id":edit,"revision":1,"input":{"action":"begin","file_index":0,"new_bytes":6}});
    assert!(client.call("edit/revise", begin())?.get("result").is_some());
    assert!(
        client.call("edit/revise", begin())?.get("error").is_some(),
        "second upload must not replace the first"
    );
    let accept = client.call(
        "edit/decision",
        json!({"origin_id":SOURCE,"edit_id":edit,"revision":1,"decision":"accept"}),
    )?;
    assert!(
        accept.get("error").is_some(),
        "unfinished review text must not authorize the old proposal: {accept}"
    );
    let append=client.call("edit/revise",json!({"origin_id":SOURCE,"edit_id":edit,"revision":1,"input":{"action":"append","file_index":0,"offset":0,"text":"human\n"}}))?;
    assert_eq!(append["result"]["next_offset"], 6, "{append}");
    let committed=client.call("edit/revise",json!({"origin_id":SOURCE,"edit_id":edit,"revision":1,"input":{"action":"commit","file_index":0}}))?;
    assert_eq!(committed["result"]["revision"], 2, "{committed}");
    Ok(())
}

#[test]
fn native_service_close_retires_identity_and_drains_late_editor_receipt_without_republishing_history()
-> TestResult {
    let root = private()?;
    let journal = private()?;
    let path = root.path().join("file.txt");
    fs::write(&path, "old\n")?;
    let mut client = Client::new()?;
    let service = "edit_service_12345678-1234-4234-8234-123456789abc";
    let prep = client.prepared_with_service(
        root.path(),
        SOURCE,
        "save",
        "new\n",
        "auto",
        Some(service),
    )?;
    let edit = client.grant(&prep["preparation_id"], SOURCE)?;
    client.preflight(&prep, &edit, SOURCE)?;
    let issued = client.issue(&edit, SOURCE, journal.path())?;
    fs::write(&path, "new\n")?;
    let closing = client.call(
        "edit/history",
        json!({"action":"close_service","service_id":service}),
    )?;
    assert_eq!(closing["result"]["closed"], true);
    assert_eq!(closing["result"]["drained"], false);
    let late_prepare = client.call(
        "edit/begin",
        json!({
        "origin_id":SOURCE,"service_id":service,"root":root.path(),"mode":"agent",
        "intent":{"kind":"write","path":"file.txt","new_bytes":4},"live":null,
        "config_revision":3,"policy_revision":7,"review_mode":"auto","save_policy":"save"}),
    )?;
    assert!(
        late_prepare.get("error").is_some(),
        "closed identity must not restart: {late_prepare}"
    );
    assert_eq!(late_prepare["error"]["data"]["status"], "cancelled");
    // A cancellation can interrupt validation, or a completed verifier can still
    // report facts. Neither case may revive a retired service's undo/change view.
    let settled = upload(
        &mut client,
        &edit,
        &issued["result"]["issued_token"],
        observed(&path, "new\n", "new\n")?,
        "new\n",
        "new\n",
    )?;
    assert_eq!(settled["result"]["receipt"]["outcome"], "applied_full");
    assert_eq!(settled["result"]["rollback_available"], false);
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let state = client.call(
            "edit/history",
            json!({"action":"close_service","service_id":service}),
        )?;
        if state["result"]["drained"] == true {
            break;
        }
        if Instant::now() >= deadline {
            return Err("retired service did not drain".into());
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    for action in ["list", "changes"] {
        let view = client.call(
            "edit/history",
            json!({"action":action,"offset":0,"revision":null,"service_id":service}),
        )?;
        assert_eq!(view["result"]["files"], json!([]));
    }
    assert_eq!(fs::read_to_string(path)?, "new\n");
    Ok(())
}
