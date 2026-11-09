use super::{domain::*, journal::*, migration::*, recovery::*, repair::*, storage::*, worker::*};
use crate::{
    domain::{RequestCount, TokenCount},
    error::CoreError,
};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};

type TestResult = Result<(), Box<dyn std::error::Error>>;

#[test]
fn storage_session_id_accepts_valid_ids() {
    assert!(StorageSessionId::try_from("session-1").is_ok());
    assert!(StorageSessionId::try_from("sess_12345678-1234-4234-8234-000000000001").is_ok());
    assert!(StorageSessionId::try_from("migration-v2").is_ok());
    assert!(StorageSessionId::try_from("abc.DEF_123").is_ok());
}

#[test]
fn storage_session_id_rejects_invalid_and_traversal_ids() {
    assert!(StorageSessionId::try_from("").is_err());
    assert!(StorageSessionId::try_from("..").is_err());
    assert!(StorageSessionId::try_from("../etc").is_err());
    assert!(StorageSessionId::try_from("a/b").is_err());
    assert!(StorageSessionId::try_from("a\\b").is_err());
    assert!(StorageSessionId::try_from(".hidden").is_err());
    assert!(StorageSessionId::try_from("-dash").is_err());
    assert!(StorageSessionId::try_from("_under").is_err());
    assert!(StorageSessionId::try_from("has null\0byte").is_err());
    assert!(StorageSessionId::try_from("has space").is_err());
    let long_id = "a".repeat(129);
    assert!(StorageSessionId::try_from(long_id.as_str()).is_err());
}

#[test]
fn storage_root_rejects_relative_and_traversal_paths() -> TestResult {
    assert!(StorageRoot::try_from(PathBuf::from("relative/path")).is_err());
    let root = StorageRoot::try_from(PathBuf::from("/var/data/sessions"))?;
    let valid_id = StorageSessionId::try_from("test-session")?;
    let file = root.session_file(&valid_id)?;
    assert_eq!(file, PathBuf::from("/var/data/sessions/test-session.json"));
    Ok(())
}

#[test]
fn debug_formatting_redacts_sensitive_transcript_and_message_content() -> TestResult {
    let transcript = SessionTranscript::try_from("Secret transcript text 123".to_owned())?;
    let debug_str = format!("{:?}", transcript);
    assert!(!debug_str.contains("Secret transcript text"));
    assert!(debug_str.contains("[REDACTED 26 bytes]"));
    Ok(())
}

#[test]
fn session_record_parses_canonical_v2_fixture() -> TestResult {
    let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("session-v2.json");
    let content = std::fs::read_to_string(fixture_path)?;
    let record = SessionRecord::try_from(content.as_str())?;
    assert_eq!(record.schema_version().as_u32(), 2);
    assert_eq!(record.id().as_str(), "migration-v2");
    assert_eq!(record.mode().map(|m| m.as_str()), Some("plan"));
    assert_eq!(
        record.provider().map(|p| p.as_str()),
        Some("fixture-provider")
    );
    assert_eq!(record.model().map(|m| m.as_str()), Some("fixture-model"));
    assert_eq!(record.effort(), Some(&SessionEffort::Off));
    assert_eq!(record.tokens_in(), Some(TokenCount::from_u64(24)));
    assert_eq!(record.tokens_out(), Some(TokenCount::from_u64(10)));
    assert_eq!(record.requests(), Some(RequestCount::from_u64(2)));
    assert_eq!(record.messages().len(), 2);

    let debug_str = format!("{:?}", record);
    assert!(!debug_str.contains("schema v2 transcript"));
    assert!(!debug_str.contains("Plan the change"));
    Ok(())
}

#[test]
fn session_record_rejects_unsupported_future_version() -> TestResult {
    let raw = r#"{
        "schema_version": 3,
        "id": "test-3",
        "messages": []
    }"#;
    let err = match SessionRecord::try_from(raw) {
        Err(e) => e,
        Ok(_) => return Err("expected unsupported version rejection".into()),
    };
    assert!(matches!(err, PersistenceError::UnsupportedVersion(3)));
    Ok(())
}

#[test]
fn session_record_rejects_deep_nesting() -> TestResult {
    let mut deep =
        String::from(r#"{"schema_version": 2, "id": "deep", "messages": [], "nested": "#);
    for _ in 0..40 {
        deep.push_str(r#"{"inner": "#);
    }
    deep.push('1');
    for _ in 0..40 {
        deep.push('}');
    }
    deep.push('}');
    let err = match SessionRecord::try_from(deep.as_str()) {
        Err(e) => e,
        Ok(_) => return Err("expected depth limit rejection".into()),
    };
    assert!(matches!(err, PersistenceError::DepthLimitExceeded));
    Ok(())
}

#[test]
fn session_record_rejects_invalid_tool_message_without_call_id() -> TestResult {
    let raw = r#"{
        "schema_version": 2,
        "id": "invalid-tool",
        "messages": [
            {"role": "tool", "content": "result without id"}
        ]
    }"#;
    let err = match SessionRecord::try_from(raw) {
        Err(e) => e,
        Ok(_) => return Err("expected missing tool_call_id rejection".into()),
    };
    assert!(matches!(err, PersistenceError::Validation(_)));
    Ok(())
}

#[test]
fn migrate_candidate_converts_legacy_fixture() -> TestResult {
    let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("session-legacy.json");
    let original_bytes = std::fs::read(&fixture_path)?;
    let payload = RawSessionPayload::try_from(std::str::from_utf8(&original_bytes)?)?;

    let candidate = migrate_candidate(&payload, &CollisionPolicy::Reject)?;
    assert_eq!(candidate.source_format(), SessionSourceFormat::LegacyV1);
    assert_eq!(candidate.id().as_str(), "migration-legacy");

    let rec = candidate.record();
    assert_eq!(rec.schema_version().as_u32(), 2);
    assert_eq!(rec.tokens_in(), Some(TokenCount::from_u64(12)));
    assert_eq!(rec.tokens_out(), Some(TokenCount::from_u64(7)));
    assert_eq!(rec.requests(), Some(RequestCount::from_u64(1)));
    assert_eq!(rec.effort(), Some(&SessionEffort::Inherit));
    assert_eq!(rec.messages().len(), 4);

    let after_bytes = std::fs::read(&fixture_path)?;
    assert_eq!(
        original_bytes, after_bytes,
        "source file must not be modified"
    );
    Ok(())
}

#[test]
fn migrate_candidate_supports_collision_policies() -> TestResult {
    let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("session-legacy.json");
    let content = std::fs::read_to_string(fixture_path)?;
    let payload = RawSessionPayload::try_from(content.as_str())?;

    let prefix = StorageSessionId::try_from("imported")?;
    let derived = migrate_candidate(&payload, &CollisionPolicy::DeriveWithPrefix(prefix))?;
    assert_eq!(derived.id().as_str(), "imported-migration-legacy");
    assert_eq!(derived.record().id().as_str(), "imported-migration-legacy");

    let explicit_id = StorageSessionId::try_from("new-sess-100")?;
    let overridden = migrate_candidate(&payload, &CollisionPolicy::Override(explicit_id))?;
    assert_eq!(overridden.id().as_str(), "new-sess-100");
    assert_eq!(overridden.record().id().as_str(), "new-sess-100");
    Ok(())
}

#[test]
fn migrate_candidate_preserves_canonical_v2() -> TestResult {
    let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("session-v2.json");
    let content = std::fs::read_to_string(fixture_path)?;
    let payload = RawSessionPayload::try_from(content.as_str())?;

    let candidate = migrate_candidate(&payload, &CollisionPolicy::Reject)?;
    assert_eq!(candidate.source_format(), SessionSourceFormat::CanonicalV2);
    assert_eq!(candidate.id().as_str(), "migration-v2");
    assert_eq!(candidate.record().effort(), Some(&SessionEffort::Off));
    Ok(())
}

#[test]
fn migrate_candidate_is_idempotent() -> TestResult {
    let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("session-legacy.json");
    let content = std::fs::read_to_string(fixture_path)?;
    let payload = RawSessionPayload::try_from(content.as_str())?;

    let first = migrate_candidate(&payload, &CollisionPolicy::Reject)?;
    let second = migrate_candidate(&payload, &CollisionPolicy::Reject)?;
    assert_eq!(first.id(), second.id());
    assert_eq!(first.source_format(), second.source_format());
    assert_eq!(
        first.record().schema_version(),
        second.record().schema_version()
    );
    assert_eq!(
        first.record().messages().len(),
        second.record().messages().len()
    );
    Ok(())
}

#[test]
fn stable_writer_lock_prevents_concurrent_access() -> TestResult {
    let temp_dir = tempfile::tempdir()?;
    let root = StorageRoot::try_from(temp_dir.path().to_path_buf())?;
    let storage = SessionStorage::new(root)?;
    let sid = StorageSessionId::try_from("concurrent-sess")?;

    let lock1 = storage.lock(&sid)?;
    let lock2_attempt = storage.lock(&sid);
    assert!(matches!(lock2_attempt, Err(CoreError::Busy)));

    drop(lock1);
    let lock2 = storage.lock(&sid)?;
    assert_eq!(lock2.id().as_str(), "concurrent-sess");
    Ok(())
}

#[test]
fn unlinking_journal_cannot_bypass_stable_writer_lock() -> TestResult {
    let temp_dir = tempfile::tempdir()?;
    let root = StorageRoot::try_from(temp_dir.path().to_path_buf())?;
    let storage = SessionStorage::new(root)?;
    let sid = StorageSessionId::try_from("unlink-sess")?;

    let lock = storage.lock(&sid)?;

    let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("session-v2.json");
    let content = std::fs::read_to_string(fixture_path)?;
    let record = SessionRecord::try_from(content.as_str())?.with_id(sid.clone());
    storage.save_snapshot(&lock, &record)?;

    let journal_path = temp_dir.path().join("unlink-sess.journal");
    std::fs::write(&journal_path, b"test-journal-content")?;

    storage.delete_session(&lock)?;
    assert!(!journal_path.exists());

    let rival_lock_attempt = storage.lock(&sid);
    assert!(matches!(rival_lock_attempt, Err(CoreError::Busy)));

    drop(lock);
    let rival_lock = storage.lock(&sid)?;
    assert_eq!(rival_lock.id().as_str(), "unlink-sess");
    Ok(())
}

#[test]
fn journal_only_session_conflicts_with_import_under_reject_policy() -> TestResult {
    let temp_dir = tempfile::tempdir()?;
    let root = StorageRoot::try_from(temp_dir.path().to_path_buf())?;
    let storage = SessionStorage::new(root)?;
    let sid = StorageSessionId::try_from("journal-only-sess")?;

    let journal_path = temp_dir.path().join("journal-only-sess.journal");
    std::fs::write(&journal_path, b"dummy journal bytes")?;

    let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("session-legacy.json");
    let content = std::fs::read_to_string(fixture_path)?;
    let payload = RawSessionPayload::try_from(content.as_str())?;
    let candidate = migrate_candidate(&payload, &CollisionPolicy::Override(sid.clone()))?;

    let lock = storage.lock(&sid)?;
    let import_result = storage.import_candidate(&lock, &candidate);
    assert!(matches!(
        import_result,
        Err(CoreError::Persistence(PersistenceError::Collision))
    ));
    Ok(())
}

#[test]
fn foreign_or_symlink_storage_root_rejected() -> TestResult {
    let temp_dir = tempfile::tempdir()?;
    let symlink_path = temp_dir.path().join("symlink_root");
    std::os::unix::fs::symlink(temp_dir.path(), &symlink_path)?;

    let root = StorageRoot::try_from(symlink_path)?;
    let storage_res = SessionStorage::new(root);
    assert!(matches!(storage_res, Err(CoreError::Rejected)));
    Ok(())
}

#[tokio::test]
async fn async_worker_save_and_completion_publishing() -> TestResult {
    let temp_dir = tempfile::tempdir()?;
    let root = StorageRoot::try_from(temp_dir.path().to_path_buf())?;
    let storage = Arc::new(SessionStorage::new(root)?);
    let mut service = PersistenceService::new(storage);

    let sid = StorageSessionId::try_from("async-sess")?;
    let rev = StorageRevision::from_u64(1);

    let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("session-v2.json");
    let content = std::fs::read_to_string(fixture_path)?;
    let record = SessionRecord::try_from(content.as_str())?.with_id(sid.clone());

    let req = SaveRequest::new(sid.clone(), rev, record);
    let deadline = Instant::now() + Duration::from_secs(5);
    let handle = service.submit_save(req, deadline)?;

    // Mailbox remains responsive while write is running
    assert!(service.ping().is_ok());

    let completion = handle.await?;
    assert_eq!(completion.durability(), Durability::Durable);
    assert_eq!(completion.session_id().as_str(), "async-sess");

    let verdict = service.validate_completion(&completion);
    assert_eq!(verdict, CompletionVerdict::Valid);
    assert_eq!(service.published_revision(&sid), Some(rev));
    Ok(())
}

#[tokio::test]
async fn async_worker_aborted_turn_prevents_stale_publication() -> TestResult {
    let temp_dir = tempfile::tempdir()?;
    let root = StorageRoot::try_from(temp_dir.path().to_path_buf())?;
    let storage = Arc::new(SessionStorage::new(root)?);
    let mut service = PersistenceService::new(storage);

    let sid = StorageSessionId::try_from("abort-sess")?;
    let rev = StorageRevision::from_u64(1);

    let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("session-v2.json");
    let content = std::fs::read_to_string(fixture_path)?;
    let record = SessionRecord::try_from(content.as_str())?.with_id(sid.clone());

    let req = SaveRequest::new(sid.clone(), rev, record);
    let deadline = Instant::now() + Duration::from_secs(5);
    let handle = service.submit_save(req, deadline)?;

    // Abort turn: epoch advances
    service.abort(&sid);

    let completion = handle.await?;
    // Durable write was performed
    assert_eq!(completion.durability(), Durability::Durable);

    // But completion is recognized as stale, never publishing stale revision
    let verdict = service.validate_completion(&completion);
    assert_eq!(verdict, CompletionVerdict::StaleEpoch);
    assert_eq!(service.published_revision(&sid), None);
    Ok(())
}

#[tokio::test]
async fn async_worker_enforces_deadline_and_close() -> TestResult {
    let temp_dir = tempfile::tempdir()?;
    let root = StorageRoot::try_from(temp_dir.path().to_path_buf())?;
    let storage = Arc::new(SessionStorage::new(root)?);
    let mut service = PersistenceService::new(storage);

    let sid = StorageSessionId::try_from("deadline-sess")?;
    let rev = StorageRevision::from_u64(1);

    let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("session-v2.json");
    let content = std::fs::read_to_string(fixture_path)?;
    let record = SessionRecord::try_from(content.as_str())?.with_id(sid.clone());

    // Past deadline rejected
    let past_deadline = Instant::now() - Duration::from_secs(1);
    let req = SaveRequest::new(sid.clone(), rev, record.clone());
    let res = service.submit_save(req, past_deadline);
    assert!(matches!(res, Err(CoreError::Deadline)));

    // Closed service rejects submissions and pings
    service.close();
    assert!(matches!(service.ping(), Err(CoreError::Cancelled)));
    let future_deadline = Instant::now() + Duration::from_secs(5);
    let req2 = SaveRequest::new(sid, rev, record);
    let res2 = service.submit_save(req2, future_deadline);
    assert!(matches!(res2, Err(CoreError::Cancelled)));
    Ok(())
}

#[test]
fn journal_writer_monotonic_sequence_and_hash_chaining() -> TestResult {
    let temp_dir = tempfile::tempdir()?;
    let root = StorageRoot::try_from(temp_dir.path().to_path_buf())?;
    let storage = SessionStorage::new(root)?;
    let sid = StorageSessionId::try_from("journal-seq-sess")?;

    let lock = storage.lock(&sid)?;
    let mut writer = SessionJournalWriter::open(&storage, lock)?;
    assert_eq!(writer.sequence().as_u64(), 0);
    assert_eq!(writer.state(), WriterState::Active);

    let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("session-v2.json");
    let content = std::fs::read_to_string(fixture_path)?;
    let record = SessionRecord::try_from(content.as_str())?.with_id(sid.clone());

    let d1 = writer.append_checkpoint(&record)?;
    assert_eq!(writer.sequence().as_u64(), 1);

    let msg = record.messages().first().ok_or("missing message")?;
    let d2 = writer.append_delta(msg)?;
    assert_eq!(writer.sequence().as_u64(), 2);
    assert_ne!(d1.as_bytes(), d2.as_bytes());

    drop(writer);

    // Reopening the journal replays and recovers sequence and digest
    let lock2 = storage.lock(&sid)?;
    let writer2 = SessionJournalWriter::open(&storage, lock2)?;
    assert_eq!(writer2.sequence().as_u64(), 2);
    assert_eq!(writer2.state(), WriterState::Active);
    Ok(())
}

#[test]
fn journal_recovers_last_checkpoint_when_snapshot_is_missing() -> TestResult {
    let temp_dir = tempfile::tempdir()?;
    let root = StorageRoot::try_from(temp_dir.path().to_path_buf())?;
    let storage = SessionStorage::new(root)?;
    let sid = StorageSessionId::try_from("missing-snapshot-sess")?;

    let lock = storage.lock(&sid)?;
    let mut writer = SessionJournalWriter::open(&storage, lock)?;

    let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("session-v2.json");
    let content = std::fs::read_to_string(fixture_path)?;
    let record = SessionRecord::try_from(content.as_str())?.with_id(sid.clone());

    // Commit checkpoint order: checkpoint is fsynced to journal
    writer.append_checkpoint(&record)?;

    // Snapshot file was never written or was deleted
    let snapshot_file = storage.root().session_file(&sid)?;
    assert!(!snapshot_file.exists());

    // Recovery from journal successfully finds the durable checkpoint
    let recovered = recover_last_checkpoint(&storage, &sid)?;
    assert!(recovered.is_some());
    let rec = recovered.ok_or("missing recovered record")?;
    assert_eq!(rec.id().as_str(), "missing-snapshot-sess");
    assert_eq!(rec.tokens_in(), Some(TokenCount::from_u64(24)));
    Ok(())
}

fn load_fixture_record(id: &str) -> Result<SessionRecord, Box<dyn std::error::Error>> {
    let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("session-v2.json");
    let content = std::fs::read_to_string(fixture_path)?;
    let sid = StorageSessionId::try_from(id)?;
    Ok(SessionRecord::try_from(content.as_str())?.with_id(sid))
}

fn create_test_storage() -> Result<(tempfile::TempDir, SessionStorage), Box<dyn std::error::Error>>
{
    let temp_dir = tempfile::tempdir()?;
    let root = StorageRoot::try_from(temp_dir.path().to_path_buf())?;
    let storage = SessionStorage::new(root)?;
    Ok((temp_dir, storage))
}

#[test]
fn journal_tail_recovery_truncates_only_incomplete_trailing_record() -> TestResult {
    let (_tmp, storage) = create_test_storage()?;
    let sid = StorageSessionId::try_from("tail-rec-sess")?;
    let lock = storage.lock(&sid)?;
    let mut writer = SessionJournalWriter::open(&storage, lock)?;
    let record = load_fixture_record("tail-rec-sess")?;
    writer.append_checkpoint(&record)?;
    let msg = record.messages().first().ok_or("missing msg")?;
    writer.append_delta(msg)?;
    drop(writer);

    let journal_path = storage.root().path().join("tail-rec-sess.journal");
    let valid_len = std::fs::metadata(&journal_path)?.len();
    let mut f = std::fs::OpenOptions::new()
        .append(true)
        .open(&journal_path)?;
    std::io::Write::write_all(&mut f, b"{\"sequence\":3,\"previous_digest\":[1,2,3")?;
    drop(f);

    let outcome = replay_journal_file(&journal_path, &sid, TailTruncation::AllowTruncate)?;
    assert_eq!(outcome.sequence().as_u64(), 2);
    assert_eq!(std::fs::metadata(&journal_path)?.len(), valid_len);

    let lock2 = storage.lock(&sid)?;
    let mut writer2 = SessionJournalWriter::open(&storage, lock2)?;
    assert_eq!(writer2.sequence().as_u64(), 2);
    writer2.append_delta(msg)?;
    assert_eq!(writer2.sequence().as_u64(), 3);
    Ok(())
}

#[test]
fn complete_corrupted_record_fails_without_modifying_or_truncating_file() -> TestResult {
    let (_tmp, storage) = create_test_storage()?;
    let sid = StorageSessionId::try_from("corrupt-rec-sess")?;
    let lock = storage.lock(&sid)?;
    let mut writer = SessionJournalWriter::open(&storage, lock)?;
    let record = load_fixture_record("corrupt-rec-sess")?;
    writer.append_checkpoint(&record)?;
    drop(writer);

    let journal_path = storage.root().path().join("corrupt-rec-sess.journal");
    let mut bytes = std::fs::read(&journal_path)?;
    let orig_len = bytes.len() as u64;
    let target_idx = bytes.len().saturating_sub(10);
    if let Some(b) = bytes.get_mut(target_idx) {
        *b ^= 0xFF;
    }
    std::fs::write(&journal_path, &bytes)?;

    let result = replay_journal_file(&journal_path, &sid, TailTruncation::AllowTruncate);
    assert!(result.is_err());
    assert_eq!(std::fs::metadata(&journal_path)?.len(), orig_len);
    Ok(())
}

#[test]
fn middle_record_corruption_fails_without_modifying_file() -> TestResult {
    let (_tmp, storage) = create_test_storage()?;
    let sid = StorageSessionId::try_from("middle-corrupt-sess")?;
    let lock = storage.lock(&sid)?;
    let mut writer = SessionJournalWriter::open(&storage, lock)?;
    let record = load_fixture_record("middle-corrupt-sess")?;
    writer.append_checkpoint(&record)?;
    let msg = record.messages().first().ok_or("missing msg")?;
    writer.append_delta(msg)?;
    drop(writer);

    let journal_path = storage.root().path().join("middle-corrupt-sess.journal");
    let mut bytes = std::fs::read(&journal_path)?;
    let orig_len = bytes.len() as u64;
    if let Some(b) = bytes.get_mut(20) {
        *b ^= 0xFF;
    }
    std::fs::write(&journal_path, &bytes)?;

    let result = replay_journal_file(&journal_path, &sid, TailTruncation::AllowTruncate);
    assert!(result.is_err());
    assert_eq!(std::fs::metadata(&journal_path)?.len(), orig_len);
    Ok(())
}

#[test]
fn snapshot_and_journal_identity_mismatch_rejected() -> TestResult {
    let (_tmp, storage) = create_test_storage()?;
    let sid_alpha = StorageSessionId::try_from("session-alpha")?;
    let _sid_beta = StorageSessionId::try_from("session-beta")?;

    let lock_alpha = storage.lock(&sid_alpha)?;
    let record_beta = load_fixture_record("session-beta")?;

    assert!(storage.save_snapshot(&lock_alpha, &record_beta).is_err());

    let path = storage.root().session_file(&sid_alpha)?;
    let json_bytes = serde_json::to_vec(&record_beta)?;
    std::fs::write(&path, &json_bytes)?;

    let load_res = storage.load_session(&lock_alpha);
    assert!(matches!(load_res, Err(CoreError::Rejected)));
    Ok(())
}

#[test]
fn load_and_list_share_identical_committed_recovery_view() -> TestResult {
    let (_tmp, storage) = create_test_storage()?;
    let sid1 = StorageSessionId::try_from("sess-with-snapshot")?;
    let lock1 = storage.lock(&sid1)?;
    let rec1 = load_fixture_record("sess-with-snapshot")?;
    storage.save_snapshot(&lock1, &rec1)?;

    let sid2 = StorageSessionId::try_from("sess-journal-only")?;
    let lock2 = storage.lock(&sid2)?;
    let mut writer2 = SessionJournalWriter::open(&storage, lock2)?;
    let rec2 = load_fixture_record("sess-journal-only")?;
    writer2.append_checkpoint(&rec2)?;
    drop(writer2);

    let list = storage.list_sessions()?;
    assert_eq!(list.truncation(), ListTruncation::Complete);
    let ids: Vec<&str> = list.summaries().iter().map(|s| s.id().as_str()).collect();
    assert!(ids.contains(&"sess-with-snapshot"));
    assert!(ids.contains(&"sess-journal-only"));

    let lock2_again = storage.lock(&sid2)?;
    let recovered2 = storage.load_session(&lock2_again)?;
    assert!(recovered2.is_some());
    assert_eq!(
        recovered2.as_ref().map(|r| r.id().as_str()),
        Some("sess-journal-only")
    );
    Ok(())
}

#[test]
fn snapshot_failure_preserves_prior_committed_view() -> TestResult {
    let (_tmp, storage) = create_test_storage()?;
    let sid = StorageSessionId::try_from("snap-failure-sess")?;
    let lock = storage.lock(&sid)?;
    let mut writer = SessionJournalWriter::open(&storage, lock)?;
    let rec = load_fixture_record("snap-failure-sess")?;

    writer.append_checkpoint(&rec)?;
    let snap_path = storage.root().session_file(&sid)?;
    assert!(!snap_path.exists());
    drop(writer);

    let lock2 = storage.lock(&sid)?;
    let recovered = storage.load_session(&lock2)?;
    assert!(recovered.is_some());
    assert_eq!(
        recovered.as_ref().map(|r| r.id().as_str()),
        Some("snap-failure-sess")
    );
    Ok(())
}

#[test]
fn session_record_append_message_validates_limits() -> TestResult {
    let mut record = load_fixture_record("limit-test-sess")?;
    let msg = record.messages().first().ok_or("missing msg")?.clone();
    assert!(record.append_message(msg).is_ok());
    assert_eq!(record.messages().len(), 3);

    let invalid_tool_msg: SessionMessage =
        serde_json::from_str(r#"{"role":"tool","content":"result"}"#)?;
    assert!(record.append_message(invalid_tool_msg).is_err());
    assert_eq!(record.messages().len(), 3);
    Ok(())
}

#[test]
fn protocol_repair_injects_outcome_unknown_for_incomplete_calls() -> TestResult {
    let raw = r#"{
        "schema_version": 2,
        "id": "repair-test",
        "messages": [
            {
                "role": "assistant",
                "content": null,
                "tool_calls": [
                    {
                        "id": "call_1",
                        "type": "function",
                        "function": {"name": "bash", "arguments": "{}"}
                    },
                    {
                        "id": "call_2",
                        "type": "function",
                        "function": {"name": "edit", "arguments": "{}"}
                    }
                ]
            },
            {
                "role": "tool",
                "content": "bash result",
                "tool_call_id": "call_1"
            },
            {
                "role": "user",
                "content": "next turn"
            }
        ]
    }"#;
    let mut record = SessionRecord::try_from(raw)?;
    let count = repair_protocol(&mut record)?;
    assert_eq!(count.as_usize(), 1);
    assert_eq!(record.messages().len(), 4);
    let m2 = record.messages().get(2).ok_or("missing msg 2")?;
    assert_eq!(m2.role(), MessageRole::Tool);
    assert_eq!(m2.tool_call_id().map(|id| id.as_str()), Some("call_2"));
    assert_eq!(m2.name().map(|n| n.as_str()), Some("edit"));
    let m3 = record.messages().get(3).ok_or("missing msg 3")?;
    assert_eq!(m3.role(), MessageRole::User);

    let count2 = repair_protocol(&mut record)?;
    assert_eq!(count2.as_usize(), 0);
    assert_eq!(record.messages().len(), 4);
    Ok(())
}

#[test]
fn protocol_repair_rejects_duplicate_call_id() -> TestResult {
    let raw = r#"{
        "schema_version": 2,
        "id": "dup-call-test",
        "messages": [
            {
                "role": "assistant",
                "content": null,
                "tool_calls": [
                    {"id": "call_1", "type": "function", "function": {"name": "bash", "arguments": "{}"}},
                    {"id": "call_1", "type": "function", "function": {"name": "edit", "arguments": "{}"}}
                ]
            }
        ]
    }"#;
    let mut record = SessionRecord::try_from(raw)?;
    assert!(repair_protocol(&mut record).is_err());
    Ok(())
}

#[test]
fn protocol_repair_rejects_orphan_and_duplicate_tool_result() -> TestResult {
    let orphan_raw = r#"{
        "schema_version": 2,
        "id": "orphan-test",
        "messages": [
            {"role": "tool", "content": "orphan", "tool_call_id": "call_never_called"}
        ]
    }"#;
    let mut orphan_record = SessionRecord::try_from(orphan_raw)?;
    assert!(repair_protocol(&mut orphan_record).is_err());

    let dup_res_raw = r#"{
        "schema_version": 2,
        "id": "dup-res-test",
        "messages": [
            {
                "role": "assistant",
                "content": null,
                "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "bash", "arguments": "{}"}}]
            },
            {"role": "tool", "content": "res1", "tool_call_id": "call_1"},
            {"role": "tool", "content": "res2", "tool_call_id": "call_1"}
        ]
    }"#;
    let mut dup_res_record = SessionRecord::try_from(dup_res_raw)?;
    assert!(repair_protocol(&mut dup_res_record).is_err());
    Ok(())
}

#[test]
fn protocol_repair_preserves_start_action_only() -> TestResult {
    let raw = r#"{
        "schema_version": 2,
        "id": "start-action-test",
        "messages": [
            {
                "role": "assistant",
                "content": null,
                "tool_calls": [{"id": "call_start", "type": "function", "function": {"name": "run", "arguments": "{}"}}]
            }
        ]
    }"#;
    let mut record = SessionRecord::try_from(raw)?;
    let count = repair_protocol(&mut record)?;
    assert_eq!(count.as_usize(), 1);
    assert_eq!(record.messages().len(), 2);
    let m0 = record.messages().first().ok_or("missing msg 0")?;
    assert_eq!(m0.role(), MessageRole::Assistant);
    assert!(m0.tool_calls().is_some());
    let m1 = record.messages().get(1).ok_or("missing msg 1")?;
    assert_eq!(m1.role(), MessageRole::Tool);
    assert_eq!(m1.tool_call_id().map(|id| id.as_str()), Some("call_start"));
    Ok(())
}

#[test]
fn restart_recovery_idempotence_and_no_stale_authority() -> TestResult {
    let (_tmp, storage) = create_test_storage()?;
    let sid = StorageSessionId::try_from("restart-auth-test")?;
    let lock = storage.lock(&sid)?;
    let mut writer = SessionJournalWriter::open(&storage, lock)?;

    let raw = r#"{
        "schema_version": 2,
        "id": "restart-auth-test",
        "messages": [
            {
                "role": "assistant",
                "content": null,
                "tool_calls": [{"id": "call_restart", "type": "function", "function": {"name": "save", "arguments": "{}"}}]
            }
        ]
    }"#;
    let record = SessionRecord::try_from(raw)?;
    writer.append_checkpoint(&record)?;
    drop(writer);

    let lock1 = storage.lock(&sid)?;
    let recovered1 = storage.load_session(&lock1)?.ok_or("missing session 1")?;
    drop(lock1);
    assert_eq!(recovered1.messages().len(), 2);

    let lock2 = storage.lock(&sid)?;
    let recovered2 = storage.load_session(&lock2)?.ok_or("missing session 2")?;
    drop(lock2);
    assert_eq!(recovered2.messages().len(), 2);
    let tool_msg = recovered2.messages().get(1).ok_or("missing tool msg")?;
    assert_eq!(
        tool_msg.tool_call_id().map(|id| id.as_str()),
        Some("call_restart")
    );
    Ok(())
}

#[test]
fn cleanup_temp_files_removes_orphans_and_preserves_valid_sessions() -> TestResult {
    let (tmp, storage) = create_test_storage()?;
    let valid_id = StorageSessionId::try_from("valid-sess")?;
    let lock = storage.lock(&valid_id)?;
    let rec =
        SessionRecord::try_from(r#"{"schema_version": 2, "id": "valid-sess", "messages": []}"#)?;
    storage.save_snapshot(&lock, &rec)?;
    drop(lock);

    // Create orphaned temp files
    let tmp_path1 = tmp.path().join(".tmp.12345");
    let tmp_path2 = tmp.path().join(".tmp.67890");
    std::fs::write(&tmp_path1, b"in-flight data 1")?;
    std::fs::write(&tmp_path2, b"in-flight data 2")?;
    assert!(tmp_path1.exists());
    assert!(tmp_path2.exists());

    let cleaned = storage.cleanup_temp_files()?;
    assert_eq!(cleaned.as_usize(), 2);
    assert!(!tmp_path1.exists());
    assert!(!tmp_path2.exists());
    assert!(tmp.path().join("valid-sess.json").exists());

    // Subsequent call finds nothing
    let cleaned_again = storage.cleanup_temp_files()?;
    assert_eq!(cleaned_again.as_usize(), 0);
    Ok(())
}

#[test]
fn prune_sessions_by_count_and_preserves_active() -> TestResult {
    let (tmp, storage) = create_test_storage()?;
    let sids = ["s1", "s2", "s3", "s4"];
    for sid_str in &sids {
        let sid = StorageSessionId::try_from(*sid_str)?;
        let lock = storage.lock(&sid)?;
        let json = format!(r#"{{"schema_version": 2, "id": "{sid_str}", "messages": []}}"#);
        let rec = SessionRecord::try_from(json.as_str())?;
        storage.save_snapshot(&lock, &rec)?;
        // Stagger mtimes slightly
        std::thread::sleep(Duration::from_millis(15));
    }

    // Active session s1 must NOT be pruned even if it is the oldest
    let mut active = std::collections::BTreeSet::new();
    let s1_id = StorageSessionId::try_from("s1")?;
    active.insert(s1_id.clone());

    let policy = SessionRetentionPolicy::new(Some(MaxSessionCount::from_usize(2)), None, None);
    let report = storage.prune_sessions(&policy, &active)?;
    assert_eq!(report.pruned_count().as_usize(), 2);
    assert_eq!(report.retained_count().as_usize(), 2);

    // s1 (active) must still exist
    assert!(tmp.path().join("s1.json").exists());
    // s4 (newest) must still exist
    assert!(tmp.path().join("s4.json").exists());
    // s2 and s3 (oldest prunable) were pruned
    assert!(!tmp.path().join("s2.json").exists());
    assert!(!tmp.path().join("s3.json").exists());
    Ok(())
}

#[test]
fn prune_sessions_skips_concurrently_locked_session() -> TestResult {
    let (tmp, storage) = create_test_storage()?;
    for sid_str in &["lock-s1", "lock-s2"] {
        let sid = StorageSessionId::try_from(*sid_str)?;
        let lock = storage.lock(&sid)?;
        let json = format!(r#"{{"schema_version": 2, "id": "{sid_str}", "messages": []}}"#);
        let rec = SessionRecord::try_from(json.as_str())?;
        storage.save_snapshot(&lock, &rec)?;
    }

    // Hold lock on lock-s1 to simulate active writer
    let held_id = StorageSessionId::try_from("lock-s1")?;
    let held_lock = storage.lock(&held_id)?;

    // Prune with max_count: 1
    let policy = SessionRetentionPolicy::new(Some(MaxSessionCount::from_usize(1)), None, None);
    let report = storage.prune_sessions(&policy, &std::collections::BTreeSet::new())?;
    // Only lock-s2 can be pruned because lock-s1 is held!
    assert_eq!(report.pruned_count().as_usize(), 1);
    assert!(tmp.path().join("lock-s1.json").exists());
    assert!(!tmp.path().join("lock-s2.json").exists());
    drop(held_lock);
    Ok(())
}

#[tokio::test]
async fn persistence_service_delete_recreate_rejects_stale_callback() -> TestResult {
    let (_tmp, storage) = create_test_storage()?;
    let mut service = PersistenceService::new(Arc::new(storage));
    let sid = StorageSessionId::try_from("delete-recreate-test")?;

    // 1. Submit save at epoch 0
    let rec1 = SessionRecord::try_from(
        r#"{"schema_version": 2, "id": "delete-recreate-test", "revision": 1, "messages": []}"#,
    )?;
    let epoch_before = service.current_epoch(&sid);
    let req1 = SaveRequest::new(sid.clone(), StorageRevision::from_u64(1), rec1);
    let handle1 = service.submit_save(req1, Instant::now() + Duration::from_secs(5))?;
    let comp1 = handle1.await?;
    assert_eq!(comp1.epoch(), epoch_before);
    let verdict1 = service.validate_completion(&comp1);
    assert_eq!(verdict1, CompletionVerdict::Valid);
    assert_eq!(
        service.published_revision(&sid),
        Some(StorageRevision::from_u64(1))
    );

    // 2. Submit delete -> advances epoch
    let del_handle = service.submit_delete(sid.clone(), Instant::now() + Duration::from_secs(5))?;
    let del_comp = del_handle.await?;
    let del_verdict = service.validate_completion(&del_comp);
    assert_eq!(del_verdict, CompletionVerdict::Valid);
    assert_eq!(service.published_revision(&sid), None);

    // 3. Recreate session: submit new save at revision 1 -> advances epoch to new incarnation
    let rec_recreated = SessionRecord::try_from(
        r#"{"schema_version": 2, "id": "delete-recreate-test", "revision": 1, "messages": []}"#,
    )?;
    let req_recreate = SaveRequest::new(sid.clone(), StorageRevision::from_u64(1), rec_recreated);
    let handle_recreate =
        service.submit_save(req_recreate, Instant::now() + Duration::from_secs(5))?;
    let comp_recreate = handle_recreate.await?;
    assert_eq!(comp_recreate.epoch(), service.current_epoch(&sid));
    let verdict_recreate = service.validate_completion(&comp_recreate);
    assert_eq!(verdict_recreate, CompletionVerdict::Valid);

    // 4. Stale completion from epoch_before (step 1) arriving late must be rejected as StaleEpoch
    let stale_completion = PersistenceCompletion::SnapshotSaved {
        epoch: epoch_before,
        session_id: sid.clone(),
        revision: StorageRevision::from_u64(1),
        durability: Durability::Durable,
    };
    let verdict_stale = service.validate_completion(&stale_completion);
    assert_eq!(verdict_stale, CompletionVerdict::StaleEpoch);
    Ok(())
}

#[test]
fn editor_accounting_fields_survive_a_save_round_trip() -> TestResult {
    let source = r#"{"schema_version":2,"id":"acct","revision":1,"messages":[],
        "tokens_in":10,"tokens_out":5,"tokens_spent":15,"tokens_unknown":false,
        "monetary_spent":0.25,"monetary_reserved":0.1,"monetary_unknown":false}"#;
    let record = SessionRecord::try_from(source)?;
    let value = serde_json::to_value(&record)?;
    assert_eq!(value["tokens_spent"], 15);
    assert_eq!(value["tokens_unknown"], false);
    assert_eq!(value["monetary_spent"], 0.25);
    assert_eq!(value["monetary_reserved"], 0.1);
    assert_eq!(value["monetary_unknown"], false);
    let integral = SessionRecord::try_from(source.replace("0.25", "0").as_str())?;
    assert!(serde_json::to_value(&integral)?["monetary_spent"].is_u64());
    let negative = source.replace("\"monetary_spent\":0.25", "\"monetary_spent\":-1");
    assert!(SessionRecord::try_from(negative.as_str()).is_err());
    Ok(())
}

#[test]
fn listing_is_newest_first_with_descending_id_ties() -> TestResult {
    let temp_dir = tempfile::tempdir()?;
    let storage = SessionStorage::new(StorageRoot::try_from(temp_dir.path().to_path_buf())?)?;
    for (id, updated) in [
        ("a-old", "2026-01-01 00:00:00"),
        ("z-new", "2026-03-01 00:00:00"),
        ("b-tie", "2026-02-01 00:00:00"),
        ("c-tie", "2026-02-01 00:00:00"),
    ] {
        let sid = StorageSessionId::try_from(id)?;
        let lock = storage.lock(&sid)?;
        let source =
            format!(r#"{{"schema_version":2,"id":"{id}","updated_at":"{updated}","messages":[]}}"#);
        storage.save_snapshot(&lock, &SessionRecord::try_from(source.as_str())?)?;
    }
    let listed = storage.list_sessions()?;
    let ids: Vec<&str> = listed.summaries().iter().map(|s| s.id().as_str()).collect();
    assert_eq!(ids, ["z-new", "c-tie", "b-tie", "a-old"]);
    Ok(())
}

#[test]
fn loading_runs_every_field_constructor_and_reads_empty_choices_as_absent() -> TestResult {
    let record = |extra: &str| {
        SessionRecord::try_from(format!(
            r#"{{"schema_version":2,"id":"v","messages":[]{extra}}}"#
        ))
    };
    // Editors record "no choice" as an empty string; it is absent, not invalid.
    let unselected = record(r#","provider":"","model":"","title":"""#)?;
    let value = serde_json::to_value(&unselected)?;
    assert!(value.get("provider").is_none() && value.get("model").is_none());
    // Bounds that used to be skipped on load now hold.
    assert!(record(&format!(r#","title":"{}""#, "t".repeat(513))).is_err());
    assert!(SessionRecord::try_from(r#"{"schema_version":3,"id":"v","messages":[]}"#).is_err());
    let call = |id: &str| {
        record(&format!(
            r#","messages":[{{"role":"assistant","tool_calls":[{{"id":"{id}","type":"function","function":{{"name":"read_file","arguments":"{{}}"}}}}]}}]"#
        ))
    };
    assert!(call("call-1").is_ok());
    assert!(call("bad\\u0007id").is_err());
    assert!(call(&"x".repeat(300)).is_err());
    Ok(())
}

/// Every field the editor writes (`kargu-session--build-data`) must survive the
/// native record; a field the schema does not know would be dropped silently.
#[test]
fn every_editor_written_field_survives_the_native_record() -> TestResult {
    let editor = serde_json::json!({
        "schema_version": 2, "revision": 1, "id": "editor-shape",
        "effort": {"kind": "inherit"}, "project_root": "/p/", "project_name": "p",
        "title": "T", "created_at": "2026-01-01 00:00", "updated_at": "2026-01-01 00:00:01",
        "mode": "agent", "provider": "prov", "model": "mod", "requests": 3,
        "tokens_in": 10, "tokens_out": 5, "tokens_spent": 15, "tokens_unknown": false,
        "monetary_spent": 0, "monetary_reserved": 0.5, "monetary_unknown": false,
        "transcript": "tx",
        "messages": [{"role": "user", "content": "hi"}]
    });
    let record = SessionRecord::try_from(editor.to_string())?;
    let saved = serde_json::to_value(&record)?;
    let (Some(written), Some(kept)) = (editor.as_object(), saved.as_object()) else {
        return Err("records are objects".into());
    };
    for (key, value) in written {
        assert_eq!(kept.get(key), Some(value), "field {key} must survive");
    }
    Ok(())
}
