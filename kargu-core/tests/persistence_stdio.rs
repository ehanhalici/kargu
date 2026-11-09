//! Real stdio JSON-RPC integration tests for native session persistence CRUD.

mod support;
use serde_json::json;
use support::Peer;

type TestResult = Result<(), Box<dyn std::error::Error>>;

/// Project-local storage choice; the core derives `<root>/.kargu/sessions`.
fn project_storage(project_root: &str) -> serde_json::Value {
    json!({"location": "project", "project_root": project_root})
}

#[test]
fn session_save_load_list_delete_roundtrip_over_pipe() -> TestResult {
    let storage_dir = tempfile::tempdir()?;
    let storage_path = storage_dir.path().to_str().ok_or("invalid path")?;

    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let session_id = scope["session_id"].as_str().ok_or("session_id")?;

    // 1. session/save
    let save_record = json!({
        "schema_version": 2,
        "id": session_id,
        "revision": 1,
        "title": "Pipe Session Title",
        "messages": [
            {
                "role": "user",
                "content": [{"type": "text", "text": "Hello over stdio pipe!"}]
            }
        ]
    });

    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 10,
        "method": "session/save",
        "params": {
            "scope": scope,
            "storage": project_storage(storage_path),
            "expected_revision": 1,
            "record": save_record
        }
    }))?;

    let save_reply = peer.read()?;
    assert_eq!(save_reply["id"], 10);
    assert_eq!(save_reply["result"]["status"], "ok");
    assert_eq!(save_reply["result"]["session_id"], session_id);
    assert_eq!(save_reply["result"]["revision"], 1);

    // Verify snapshot file exists on disk
    let file_path = storage_dir
        .path()
        .join(".kargu/sessions")
        .join(format!("{session_id}.json"));
    assert!(file_path.exists());

    // 2. session/load with matching revision
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 11,
        "method": "session/load",
        "params": {
            "scope": scope,
            "storage": project_storage(storage_path),
            "expected_revision": 1
        }
    }))?;

    let load_reply = peer.read()?;
    assert_eq!(load_reply["id"], 11);
    assert_eq!(load_reply["result"]["status"], "ok");
    let loaded_rec = &load_reply["result"]["record"];
    assert_eq!(loaded_rec["title"], "Pipe Session Title");
    assert_eq!(loaded_rec["messages"].as_array().map(Vec::len), Some(1));

    // 3. session/load with stale revision
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 12,
        "method": "session/load",
        "params": {
            "scope": scope,
            "storage": project_storage(storage_path),
            "expected_revision": 999
        }
    }))?;

    let stale_load = peer.read()?;
    assert_eq!(stale_load["id"], 12);
    assert!(stale_load.get("error").is_some());
    assert_eq!(stale_load["error"]["data"]["status"], "stale_revision");

    // 4. session/list
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 13,
        "method": "session/list",
        "params": {
            "scope": scope,
            "storage": project_storage(storage_path)
        }
    }))?;

    let list_reply = peer.read()?;
    assert_eq!(list_reply["id"], 13);
    assert_eq!(list_reply["result"]["status"], "ok");
    let sessions = list_reply["result"]["sessions"]
        .as_array()
        .ok_or("sessions array")?;
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["id"], session_id);

    // 5. session/delete
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 14,
        "method": "session/delete",
        "params": {
            "scope": scope,
            "storage": project_storage(storage_path),
            "expected_revision": 1
        }
    }))?;

    let delete_reply = peer.read()?;
    assert_eq!(delete_reply["id"], 14);
    assert_eq!(delete_reply["result"]["deleted"], true);
    assert!(!file_path.exists());

    // 6. session/load after delete returns null
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 15,
        "method": "session/load",
        "params": {
            "scope": scope,
            "storage": project_storage(storage_path)
        }
    }))?;

    let load_deleted = peer.read()?;
    assert_eq!(load_deleted["id"], 15);
    assert!(load_deleted["result"]["record"].is_null());

    Ok(())
}

#[test]
fn session_import_and_collision_policy_over_pipe() -> TestResult {
    let storage_dir = tempfile::tempdir()?;
    let storage_path = storage_dir.path().to_str().ok_or("invalid path")?;

    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;

    let fixture = include_str!("fixtures/session-v2.json");

    // Import candidate
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 20,
        "method": "session/import",
        "params": {
            "scope": scope,
            "storage": project_storage(storage_path),
            "source_payload": fixture,
            "collision": "reject"
        }
    }))?;

    let import_reply = peer.read()?;
    assert_eq!(import_reply["id"], 20);
    assert_eq!(import_reply["result"]["status"], "ok");
    assert_eq!(import_reply["result"]["session_id"], "migration-v2");

    // Second import with reject must fail
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 21,
        "method": "session/import",
        "params": {
            "scope": scope,
            "storage": project_storage(storage_path),
            "source_payload": fixture,
            "collision": "reject"
        }
    }))?;

    let collision_reply = peer.read()?;
    assert_eq!(collision_reply["id"], 21);
    assert!(collision_reply.get("error").is_some());
    assert_eq!(
        collision_reply["error"]["data"]["status"],
        "session_collision"
    );

    Ok(())
}

#[test]
fn foreign_or_missing_scope_rejected_before_disk_access() -> TestResult {
    let uncreated_dir = tempfile::tempdir()?;
    let target_path = uncreated_dir.path().join("should_not_be_created");
    let target_str = target_path.to_str().ok_or("invalid path")?;

    let mut peer = Peer::start()?;
    peer.initialize()?;

    // Foreign scope not known to this host
    let foreign_scope = json!({
        "application_id": "app_00000000-0000-4000-8000-000000000099",
        "session_id": "sess_00000000-0000-4000-8000-000000000099"
    });

    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 30,
        "method": "session/save",
        "params": {
            "scope": foreign_scope,
            "storage": project_storage(target_str),
            "expected_revision": 1,
            "record": {"schema_version": 2, "id": "sess_00000000-0000-4000-8000-000000000099", "messages": []}
        }
    }))?;

    let reply = peer.read()?;
    assert_eq!(reply["id"], 30);
    assert!(reply.get("error").is_some());
    assert_eq!(reply["error"]["data"]["status"], "stale_owner");
    // Target directory was NOT created because rejection happened before disk access
    assert!(!target_path.exists());

    // Relative path rejected
    let real_scope = peer.scope()?;
    let real_session = real_scope["session_id"].clone();
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 31,
        "method": "session/save",
        "params": {
            "scope": real_scope,
            "storage": project_storage("relative/path/not/allowed"),
            "expected_revision": 1,
            "record": {"schema_version": 2, "id": real_session, "messages": []}
        }
    }))?;

    let rel_reply = peer.read()?;
    assert_eq!(rel_reply["id"], 31);
    assert!(rel_reply.get("error").is_some());
    assert_eq!(rel_reply["error"]["data"]["status"], "invalid_params");

    Ok(())
}

#[test]
fn session_restore_atomic_roundtrip_over_pipe() -> TestResult {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let app_id = scope["application_id"].as_str().ok_or("app_id")?;
    let session_id = scope["session_id"].as_str().ok_or("session_id")?;

    // 1. Restore v2 fixture
    let v2_str = std::fs::read_to_string("tests/fixtures/session-v2.json")?;
    let v2_json: serde_json::Value = serde_json::from_str(&v2_str)?;

    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 40,
        "method": "session/restore",
        "params": {
            "application_id": app_id,
            "session_id": session_id,
            "candidate": v2_json,
            "expected_root": "/fixture/workspace/"
        }
    }))?;

    let restore_reply = peer.read()?;
    assert_eq!(restore_reply["id"], 40);
    assert_eq!(restore_reply["result"]["mode"], "plan");
    assert_eq!(restore_reply["result"]["session_id"], session_id);
    assert_eq!(restore_reply["result"]["accounting"]["tokens_in"], 24);
    assert_eq!(restore_reply["result"]["accounting"]["tokens_out"], 10);
    assert_eq!(restore_reply["result"]["accounting"]["requests"], 2);

    // Verify snapshot reflects restored mode and history
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 41,
        "method": "session/snapshot",
        "params": {
            "application_id": app_id,
            "session_id": session_id
        }
    }))?;
    let snap_reply = peer.read()?;
    assert_eq!(snap_reply["id"], 41);
    assert_eq!(snap_reply["result"]["mode"], "plan");
    assert_eq!(snap_reply["result"]["history_revision"], 2);

    // 2. Restore legacy fixture into same session
    let leg_str = std::fs::read_to_string("tests/fixtures/session-legacy.json")?;
    let leg_json: serde_json::Value = serde_json::from_str(&leg_str)?;

    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 42,
        "method": "session/restore",
        "params": {
            "application_id": app_id,
            "session_id": session_id,
            "candidate": leg_json
        }
    }))?;

    let leg_reply = peer.read()?;
    assert_eq!(leg_reply["id"], 42);
    assert_eq!(leg_reply["result"]["mode"], "ask");
    assert_eq!(leg_reply["result"]["accounting"]["tokens_in"], 12);
    assert_eq!(leg_reply["result"]["accounting"]["tokens_out"], 7);

    // Snapshot after legacy restore
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 43,
        "method": "session/snapshot",
        "params": {
            "application_id": app_id,
            "session_id": session_id
        }
    }))?;
    let snap_reply2 = peer.read()?;
    assert_eq!(snap_reply2["id"], 43);
    assert_eq!(snap_reply2["result"]["mode"], "ask");

    Ok(())
}

#[test]
fn session_restore_corrupted_candidate_preserves_old_session_over_pipe() -> TestResult {
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let app_id = scope["application_id"].as_str().ok_or("app_id")?;
    let session_id = scope["session_id"].as_str().ok_or("session_id")?;

    // Initial restore to establish Plan mode and 2 messages
    let v2_str = std::fs::read_to_string("tests/fixtures/session-v2.json")?;
    let v2_json: serde_json::Value = serde_json::from_str(&v2_str)?;

    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 50,
        "method": "session/restore",
        "params": {
            "application_id": app_id,
            "session_id": session_id,
            "candidate": v2_json,
            "expected_root": "/fixture/workspace/"
        }
    }))?;
    let reply50 = peer.read()?;
    assert_eq!(reply50["id"], 50);
    assert_eq!(reply50["result"]["mode"], "plan");

    // Failure 1: Corrupted candidate (tool message without tool_call_id)
    let bad_candidate = json!({
        "schema_version": 2,
        "id": "bad-cand",
        "mode": "agent",
        "messages": [
            {"role": "tool", "content": "orphan tool output"}
        ]
    });

    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 51,
        "method": "session/restore",
        "params": {
            "application_id": app_id,
            "session_id": session_id,
            "candidate": bad_candidate
        }
    }))?;
    let fail_reply1 = peer.read()?;
    assert_eq!(fail_reply1["id"], 51);
    assert!(fail_reply1.get("error").is_some());
    assert_eq!(fail_reply1["error"]["data"]["status"], "invalid_params");

    // Verify existing session was NOT corrupted: still plan mode and rev 3
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 52,
        "method": "session/snapshot",
        "params": {
            "application_id": app_id,
            "session_id": session_id
        }
    }))?;
    let snap1 = peer.read()?;
    assert_eq!(snap1["result"]["mode"], "plan");
    assert_eq!(snap1["result"]["history_revision"], 2);

    // Failure 2: Mismatched project root
    let root_mismatch = json!({
        "schema_version": 2,
        "id": "root-cand",
        "mode": "agent",
        "project_root": "/fixture/workspace/",
        "messages": []
    });

    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 53,
        "method": "session/restore",
        "params": {
            "application_id": app_id,
            "session_id": session_id,
            "candidate": root_mismatch,
            "expected_root": "/different/workspace/path/"
        }
    }))?;
    let fail_reply2 = peer.read()?;
    assert_eq!(fail_reply2["id"], 53);
    assert!(fail_reply2.get("error").is_some());
    assert_eq!(fail_reply2["error"]["data"]["status"], "root_mismatch");

    // Verify existing session is STILL plan mode and rev 3
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 54,
        "method": "session/snapshot",
        "params": {
            "application_id": app_id,
            "session_id": session_id
        }
    }))?;
    let snap2 = peer.read()?;
    assert_eq!(snap2["result"]["mode"], "plan");
    assert_eq!(snap2["result"]["history_revision"], 2);

    Ok(())
}

#[test]
fn fixture_acceptance_two_owners_stale_revision_restart_and_close() -> TestResult {
    let storage_dir = tempfile::tempdir()?;
    let storage_path = storage_dir.path().to_str().ok_or("invalid storage path")?;

    // 1. Peer 1 starts and writes session
    let mut peer1 = Peer::start()?;
    peer1.initialize()?;
    let scope1 = peer1.scope()?;
    let sess_id1 = scope1["session_id"].as_str().ok_or("session_id 1")?;

    let rec1 = json!({
        "schema_version": 2,
        "id": sess_id1,
        "revision": 1,
        "title": "Original Session from Peer 1",
        "messages": [
            {
                "role": "user",
                "content": [{"type": "text", "text": "Original message from peer 1"}]
            }
        ]
    });

    peer1.send(json!({
        "jsonrpc": "2.0",
        "id": 60,
        "method": "session/save",
        "params": {
            "scope": scope1,
            "session_id": sess_id1,
            "storage": project_storage(storage_path),
            "expected_revision": 1,
            "record": rec1
        }
    }))?;
    let save1 = peer1.read()?;
    assert_eq!(save1["id"], 60);
    assert_eq!(save1["result"]["status"], "ok");

    let file_path1 = storage_dir
        .path()
        .join(".kargu/sessions")
        .join(format!("{sess_id1}.json"));
    assert!(file_path1.exists());

    // 2. Peer 2 (second distinct owner) cannot corrupt or delete with stale revision
    let mut peer2 = Peer::start()?;
    peer2.initialize()?;
    let scope2 = peer2.scope()?;

    // Peer 2 attempts delete with stale revision 999
    peer2.send(json!({
        "jsonrpc": "2.0",
        "id": 61,
        "method": "session/delete",
        "params": {
            "scope": scope2,
            "session_id": sess_id1,
            "storage": project_storage(storage_path),
            "expected_revision": 999
        }
    }))?;
    let stale_del = peer2.read()?;
    assert_eq!(stale_del["id"], 61);
    assert_eq!(stale_del["error"]["data"]["status"], "stale_revision");
    assert!(
        file_path1.exists(),
        "File must not be deleted on stale revision"
    );

    // Peer 2 attempts save with stale revision 999
    let rec_hijack = json!({
        "schema_version": 2,
        "id": sess_id1,
        "revision": 999,
        "title": "Hijacked Title",
        "messages": []
    });
    peer2.send(json!({
        "jsonrpc": "2.0",
        "id": 62,
        "method": "session/save",
        "params": {
            "scope": scope2,
            "session_id": sess_id1,
            "storage": project_storage(storage_path),
            "expected_revision": 999,
            "record": rec_hijack
        }
    }))?;
    let stale_save = peer2.read()?;
    assert_eq!(stale_save["id"], 62);
    assert_eq!(stale_save["error"]["data"]["status"], "stale_revision");

    // 3. Close peer1 and peer2 (simulate shutdown and process restart)
    drop(peer1);
    drop(peer2);

    // 4. Peer 3 starts fresh on the same storage directory
    let mut peer3 = Peer::start()?;
    peer3.initialize()?;
    let scope3 = peer3.scope()?;

    // List discovers peer1's session on disk
    peer3.send(json!({
        "jsonrpc": "2.0",
        "id": 63,
        "method": "session/list",
        "params": {
            "scope": scope3,
            "storage": project_storage(storage_path)
        }
    }))?;
    let list3 = peer3.read()?;
    assert_eq!(list3["id"], 63);
    let list_arr = list3["result"]["sessions"]
        .as_array()
        .ok_or("sessions array")?;
    assert_eq!(list_arr.len(), 1);
    assert_eq!(list_arr[0]["id"], sess_id1);

    // Load peer1's session
    peer3.send(json!({
        "jsonrpc": "2.0",
        "id": 64,
        "method": "session/load",
        "params": {
            "scope": scope3,
            "session_id": sess_id1,
            "storage": project_storage(storage_path),
            "expected_revision": 1
        }
    }))?;
    let load3 = peer3.read()?;
    assert_eq!(load3["id"], 64);
    assert_eq!(load3["result"]["status"], "ok");
    assert_eq!(
        load3["result"]["record"]["title"],
        "Original Session from Peer 1"
    );

    // Import fixture
    let v2_fixture = include_str!("fixtures/session-v2.json");
    peer3.send(json!({
        "jsonrpc": "2.0",
        "id": 65,
        "method": "session/import",
        "params": {
            "scope": scope3,
            "storage": project_storage(storage_path),
            "source_payload": v2_fixture,
            "collision": "reject"
        }
    }))?;
    let imp3 = peer3.read()?;
    assert_eq!(imp3["id"], 65);
    assert_eq!(imp3["result"]["status"], "ok");

    // Delete peer1's session with valid revision 1
    peer3.send(json!({
        "jsonrpc": "2.0",
        "id": 66,
        "method": "session/delete",
        "params": {
            "scope": scope3,
            "session_id": sess_id1,
            "storage": project_storage(storage_path),
            "expected_revision": 1
        }
    }))?;
    let del3 = peer3.read()?;
    assert_eq!(del3["id"], 66);
    assert_eq!(del3["result"]["deleted"], true);
    assert!(!file_path1.exists());

    // Imported fixture still exists
    let imported_file = storage_dir
        .path()
        .join(".kargu/sessions")
        .join("migration-v2.json");
    assert!(imported_file.exists());

    Ok(())
}

#[test]
fn session_retention_and_prune_over_pipe() -> TestResult {
    let storage_dir = tempfile::tempdir()?;
    let storage_path = storage_dir.path().to_str().ok_or("invalid path")?;

    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;

    // Save 3 sessions: sess_a, sess_b, sess_c with staggered mtimes
    for sid in &["sess_a", "sess_b", "sess_c"] {
        let rec = json!({
            "schema_version": 2,
            "id": sid,
            "title": format!("Title {sid}"),
            "messages": []
        });
        peer.send(json!({
            "jsonrpc": "2.0",
            "id": 70,
            "method": "session/save",
            "params": {
                "scope": scope,
                "session_id": sid,
                "storage": project_storage(storage_path),
                "expected_revision": 1,
                "record": rec
            }
        }))?;
        let reply = peer.read()?;
        assert_eq!(reply["result"]["status"], "ok");
        std::thread::sleep(std::time::Duration::from_millis(15));
    }

    // Create orphaned temp file
    let tmp_file = storage_dir
        .path()
        .join(".kargu/sessions")
        .join(".tmp.orphaned_write");
    std::fs::write(&tmp_file, b"stray uncommitted bytes")?;
    assert!(tmp_file.exists());

    // Call session/prune with max_count: 2 and active_sessions: ["sess_a"]
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 71,
        "method": "session/prune",
        "params": {
            "scope": scope,
            "storage": project_storage(storage_path),
            "max_count": 2,
            "active_sessions": ["sess_a"]
        }
    }))?;
    let prune_reply = peer.read()?;
    assert_eq!(prune_reply["id"], 71);
    assert_eq!(prune_reply["result"]["status"], "ok");
    assert_eq!(prune_reply["result"]["pruned_count"], 1);
    assert_eq!(prune_reply["result"]["cleaned_temp_files"], 1);
    assert_eq!(prune_reply["result"]["retained_count"], 2);

    // sess_a was protected as active
    assert!(
        storage_dir
            .path()
            .join(".kargu/sessions")
            .join("sess_a.json")
            .exists()
    );
    // sess_b was the oldest inactive, so it was pruned
    assert!(
        !storage_dir
            .path()
            .join(".kargu/sessions")
            .join("sess_b.json")
            .exists()
    );
    // sess_c was retained
    assert!(
        storage_dir
            .path()
            .join(".kargu/sessions")
            .join("sess_c.json")
            .exists()
    );
    // Orphaned temp file was cleaned
    assert!(!tmp_file.exists());

    Ok(())
}

#[test]
fn session_delete_recreate_stale_callback_race_over_pipe() -> TestResult {
    let storage_dir = tempfile::tempdir()?;
    let storage_path = storage_dir.path().to_str().ok_or("invalid path")?;

    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let sid = "sess_race_target";

    // 1. Save session at revision 1
    let rec1 = json!({
        "schema_version": 2,
        "id": sid,
        "revision": 1,
        "title": "Incarnation 1",
        "messages": []
    });
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 80,
        "method": "session/save",
        "params": {
            "scope": scope,
            "session_id": sid,
            "storage": project_storage(storage_path),
            "expected_revision": 1,
            "record": rec1
        }
    }))?;
    let r1 = peer.read()?;
    assert_eq!(r1["result"]["status"], "ok");
    let file_path = storage_dir
        .path()
        .join(".kargu/sessions")
        .join(format!("{sid}.json"));
    assert!(file_path.exists());

    // 2. Delete session with expected_revision: 1
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 81,
        "method": "session/delete",
        "params": {
            "scope": scope,
            "session_id": sid,
            "storage": project_storage(storage_path),
            "expected_revision": 1
        }
    }))?;
    let r2 = peer.read()?;
    assert_eq!(r2["result"]["deleted"], true);
    assert!(!file_path.exists());

    // 3. Stale save attempting to write revision 2 with expected_revision: 1 after delete
    let stale_rec = json!({
        "schema_version": 2,
        "id": sid,
        "revision": 2,
        "title": "Stale Callback Write",
        "messages": []
    });
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 82,
        "method": "session/save",
        "params": {
            "scope": scope,
            "session_id": sid,
            "storage": project_storage(storage_path),
            "expected_revision": 2,
            "record": stale_rec
        }
    }))?;
    let r3 = peer.read()?;
    assert_eq!(r3["error"]["data"]["status"], "stale_revision");
    assert!(
        !file_path.exists(),
        "Stale callback must not create or overwrite file"
    );

    // 4. Recreate session as a fresh session (revision 1)
    let rec_fresh = json!({
        "schema_version": 2,
        "id": sid,
        "revision": 1,
        "title": "Incarnation 2 Fresh",
        "messages": []
    });
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 83,
        "method": "session/save",
        "params": {
            "scope": scope,
            "session_id": sid,
            "storage": project_storage(storage_path),
            "expected_revision": 1,
            "record": rec_fresh
        }
    }))?;
    let r4 = peer.read()?;
    assert_eq!(r4["result"]["status"], "ok");
    assert!(file_path.exists());

    // 5. Late stale write with expected_revision: 999 rejected
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 84,
        "method": "session/save",
        "params": {
            "scope": scope,
            "session_id": sid,
            "storage": project_storage(storage_path),
            "expected_revision": 999,
            "record": stale_rec
        }
    }))?;
    let r5 = peer.read()?;
    assert_eq!(r5["error"]["data"]["status"], "stale_revision");

    // 6. Load confirms content is the recreated fresh session
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 85,
        "method": "session/load",
        "params": {
            "scope": scope,
            "session_id": sid,
            "storage": project_storage(storage_path),
            "expected_revision": 1
        }
    }))?;
    let r6 = peer.read()?;
    assert_eq!(r6["result"]["record"]["title"], "Incarnation 2 Fresh");

    Ok(())
}

#[test]
fn save_without_a_record_is_rejected_and_never_writes_a_blank_session() -> TestResult {
    let dir = tempfile::tempdir()?;
    let root = dir.path().join("sessions");
    let root_str = root.to_str().ok_or("invalid path")?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    peer.send(json!({
        "jsonrpc": "2.0",
        "id": 40,
        "method": "session/save",
        "params": {"scope": scope, "storage": project_storage(root_str), "expected_revision": 0}
    }))?;
    let reply = peer.read()?;
    assert_eq!(reply["id"], 40);
    assert_eq!(reply["error"]["data"]["status"], "invalid_params");
    assert!(!root.exists());
    Ok(())
}

#[test]
fn storage_directory_is_derived_natively_never_named_by_the_request() -> TestResult {
    let project = tempfile::tempdir()?;
    let data = tempfile::tempdir()?;
    let arbitrary = tempfile::tempdir()?;
    let project_str = project.path().to_str().ok_or("invalid path")?;
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;
    let sid = scope["session_id"].as_str().ok_or("session_id")?.to_owned();
    let record = json!({"schema_version": 2, "id": sid, "revision": 1, "messages": []});

    // A raw directory is not a storage grant: the field is unknown and rejected.
    peer.send(json!({
        "jsonrpc": "2.0", "id": 50, "method": "session/save",
        "params": {"scope": scope, "storage_root": arbitrary.path(),
                   "expected_revision": 0, "record": record}
    }))?;
    let reply = peer.read()?;
    assert_eq!(reply["error"]["data"]["status"], "invalid_params");
    assert_eq!(std::fs::read_dir(arbitrary.path())?.count(), 0);

    // Central layout: <data>/kargu/sessions/<name>-<sha1[..8]>/<sid>.json
    peer.send(json!({
        "jsonrpc": "2.0", "id": 51, "method": "session/save",
        "params": {"scope": scope, "expected_revision": 0, "record": record,
                   "storage": {"location": "central", "project_root": project_str,
                               "xdg_data_home": data.path()}}
    }))?;
    let reply = peer.read()?;
    assert_eq!(reply["result"]["revision"], 1);
    let sessions = data.path().join("kargu/sessions");
    let keyed: Vec<_> = std::fs::read_dir(&sessions)?.collect::<Result<_, _>>()?;
    assert_eq!(keyed.len(), 1);
    assert!(keyed[0].path().join(format!("{sid}.json")).is_file());
    assert!(!project.path().join(".kargu").exists());

    // Project layout: <project>/.kargu/sessions/<sid>.json
    peer.send(json!({
        "jsonrpc": "2.0", "id": 52, "method": "session/save",
        "params": {"scope": scope, "expected_revision": 0, "record": record,
                   "storage": project_storage(project_str)}
    }))?;
    let reply = peer.read()?;
    assert_eq!(reply["result"]["revision"], 1);
    assert!(
        project
            .path()
            .join(format!(".kargu/sessions/{sid}.json"))
            .is_file()
    );
    Ok(())
}

#[test]
fn import_reads_a_local_legacy_session_natively_and_keeps_the_source() -> TestResult {
    use std::os::unix::fs::PermissionsExt;
    let project = tempfile::tempdir()?;
    let data = tempfile::tempdir()?;
    let project_str = project.path().to_str().ok_or("invalid path")?;
    let local = project.path().join(".kargu/sessions");
    std::fs::create_dir_all(&local)?;
    let source = local.join("migration-legacy.json");
    std::fs::write(&source, include_str!("fixtures/session-legacy.json"))?;
    // Files from the legacy editor writer may predate private modes.
    std::fs::set_permissions(&source, std::fs::Permissions::from_mode(0o644))?;
    let central = json!({"location": "central", "project_root": project_str,
                         "xdg_data_home": data.path()});
    let mut peer = Peer::start()?;
    peer.initialize()?;
    let scope = peer.scope()?;

    for (id, params) in [
        (
            60,
            json!({"scope": scope, "session_id": "migration-legacy", "storage": central,
                    "collision": "override"}),
        ),
        (
            61,
            json!({"scope": scope, "session_id": "migration-legacy", "storage": central,
                    "source": project_storage(project_str), "source_payload": "{}",
                    "collision": "override"}),
        ),
    ] {
        peer.send(
            json!({"jsonrpc": "2.0", "id": id, "method": "session/import", "params": params}),
        )?;
        assert_eq!(peer.read()?["error"]["data"]["status"], "invalid_params");
    }

    peer.send(json!({
        "jsonrpc": "2.0", "id": 62, "method": "session/import",
        "params": {"scope": scope, "session_id": "migration-legacy", "storage": central,
                   "source": project_storage(project_str), "collision": "override"}
    }))?;
    let reply = peer.read()?;
    assert_eq!(reply["result"]["session_id"], "migration-legacy");
    assert!(source.is_file(), "the local source is retained");

    peer.send(json!({
        "jsonrpc": "2.0", "id": 63, "method": "session/load",
        "params": {"scope": scope, "session_id": "migration-legacy", "storage": central}
    }))?;
    let loaded = peer.read()?;
    assert_eq!(loaded["result"]["record"]["schema_version"], 2);
    assert_eq!(loaded["result"]["record"]["tokens_in"], 12);
    Ok(())
}
