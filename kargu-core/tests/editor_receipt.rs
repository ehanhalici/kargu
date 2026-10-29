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
        let mut peer = Peer::start()?;
        peer.initialize()?;
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
        let id = self.call(
            "edit/begin",
            json!({
                "origin_id": source,
                "root": root,
                "mode": "agent",
                "intent": {
                    "kind": "write",
                    "path": "file.txt",
                    "new_bytes": text.len()
                },
                "live": null,
                "config_revision": 3,
                "policy_revision": 7,
                "review_mode": "auto",
                "save_policy": policy
            }),
        )?["result"]["preparation_id"]
            .clone();
        assert!(id.is_string());
        self.call(
            "edit/append",
            json!({
                "origin_id": source,
                "preparation_id": id,
                "part": "new",
                "offset": 0,
                "text": text
            }),
        )?;
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
    assert!(reply["result"]["receipt"]["hunks_applied"].is_null());

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
