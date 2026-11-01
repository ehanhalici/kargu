//! Verification debt must survive capacity pressure and revoked editor work.
use super::*;
use crate::edit::prepare::{
    history::{self, ChangedFileRecord},
    receipt::FileOutcome,
    types::{DiskState, FileIndex},
};
use crate::edit::types::{EditPath, EditorEditId};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};
use tokio_util::sync::CancellationToken;
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn record(
    session: &SessionId,
    index: usize,
    pending: bool,
) -> Result<ChangedFileRecord, CoreError> {
    let relative = format!("record-{index}.txt");
    Ok(ChangedFileRecord {
        session: session.clone(),
        service_id: None,
        edit_id: EditorEditId::new(),
        revision: history::HistoryRevision::default(),
        file: FileIndex::try_from(0)?,
        root: PathBuf::from("/retained"),
        full_path: PathBuf::from("/retained").join(&relative),
        path: EditPath::try_from(relative)?,
        outcome: FileOutcome::Partial,
        final_hash: None,
        baseline: history::ChangeBaseline::Unavailable,
        document: None,
        disk: DiskState::Absent {},
        hunks: None,
        saved: false,
        hook_modified: false,
        verification_pending: pending,
    })
}
fn seed(service: &mut EditPreparations, session: &SessionId, count: usize) -> TestResult {
    for index in 0..count {
        service.changes.push_back(record(session, index, true)?);
    }
    Ok(())
}
fn ready(
    service: &mut EditPreparations,
    session: &SessionId,
    root: &Path,
) -> Result<(PreparationId, Value), Box<dyn std::error::Error>> {
    let origin = crate::edit::types::EditorSourceId::new();
    let now = Instant::now();
    let frame = ByteLimit::WIRE_MAX;
    let begin = service.call(
        session,
        methods::EDIT_BEGIN,
        json!({"origin_id":origin,"root":root,"mode":"agent",
            "intent":{"kind":"write","path":"file.txt","new_bytes":4},"live":null,
            "config_revision":3,"policy_revision":7,"review_mode":"auto","save_policy":"save"}),
        frame,
        now,
    )?;
    let id: PreparationId = serde_json::from_value(begin["preparation_id"].clone())?;
    let ticket = json!({"origin_id":origin,"preparation_id":id});
    service.call(
        session,
        methods::EDIT_APPEND,
        json!({"origin_id":origin,
        "preparation_id":id,"part":"new","offset":0,"text":"new\n"}),
        frame,
        now,
    )?;
    let PrepareWork::Read(work) = service.take_inner(session, ticket.clone(), false)? else {
        return Err("read work".into());
    };
    let result = work.execute(
        &CancellationToken::new(),
        now.checked_add(Duration::from_secs(5)).ok_or("deadline")?,
    )?;
    service.finish_inner(session, &id, Ok(result), now)?;
    Ok((id, ticket))
}

#[test]
fn full_verification_queue_refuses_claim_before_editor_authority_without_evicting_debt()
-> TestResult {
    let root = tempfile::tempdir()?;
    std::fs::write(root.path().join("file.txt"), "old\n")?;
    let session = SessionId::new();
    let mut service = EditPreparations::default();
    seed(&mut service, &session, limits::EDIT_FILES)?;
    let retained: Vec<_> = service
        .changes
        .iter()
        .map(|row| row.edit_id.clone())
        .collect();
    let (id, ticket) = ready(&mut service, &session, root.path())?;
    assert!(matches!(
        service.claim(&session, ticket, Instant::now()),
        Err(CoreError::Limit)
    ));
    assert!(matches!(
        &service.entries.get(&id).ok_or("entry")?.phase,
        Phase::Ready(_)
    ));
    assert!(
        retained
            == service
                .changes
                .iter()
                .map(|row| row.edit_id.clone())
                .collect::<Vec<_>>()
    );
    assert_eq!(
        std::fs::read_to_string(root.path().join("file.txt"))?,
        "old\n"
    );
    Ok(())
}

#[test]
fn a_revoked_claim_keeps_the_last_change_slot_until_actual_release() -> TestResult {
    let root = tempfile::tempdir()?;
    std::fs::write(root.path().join("file.txt"), "old\n")?;
    let second_root = tempfile::tempdir()?;
    std::fs::write(second_root.path().join("file.txt"), "old\n")?;
    let session = SessionId::new();
    let mut service = EditPreparations::default();
    seed(&mut service, &session, limits::EDIT_FILES - 1)?;
    let (first, first_ticket) = ready(&mut service, &session, root.path())?;
    let (_, second_ticket) = ready(&mut service, &session, second_root.path())?;
    let first_work = service.claim(&session, first_ticket.clone(), Instant::now())?;
    service.call(
        &session,
        methods::EDIT_ABORT,
        first_ticket,
        ByteLimit::WIRE_MAX,
        Instant::now(),
    )?;
    assert!(matches!(
        service.claim(&session, second_ticket.clone(), Instant::now()),
        Err(CoreError::Limit)
    ));
    drop(first_work);
    service.release_claim(&session, &first)?;
    let _second_work = service.claim(&session, second_ticket, Instant::now())?;
    assert_eq!(
        std::fs::read_to_string(root.path().join("file.txt"))?,
        "old\n"
    );
    Ok(())
}

#[test]
fn publication_evicts_only_consumed_metadata_even_when_it_is_not_the_oldest_row() -> TestResult {
    let session = SessionId::new();
    let mut service = EditPreparations::default();
    seed(&mut service, &session, limits::EDIT_FILES)?;
    let oldest = service.changes.front().ok_or("oldest")?.edit_id.clone();
    let consumed = service.changes.get_mut(1).ok_or("consumed")?;
    consumed.verification_pending = false;
    let discarded = consumed.edit_id.clone();
    let next = record(&session, limits::EDIT_FILES, true)?;
    let next_id = next.edit_id.clone();
    history::publish_change(&mut service.changes, next)?;
    assert_eq!(service.changes.len(), limits::EDIT_FILES);
    assert!(
        service
            .changes
            .iter()
            .any(|row| row.edit_id == oldest && row.verification_pending)
    );
    assert!(service.changes.iter().any(|row| row.edit_id == next_id));
    assert!(!service.changes.iter().any(|row| row.edit_id == discarded));
    let pending = service.call(
        &session,
        methods::EDIT_HISTORY,
        json!({"action":"changes","offset":0,"pending_only":true}),
        ByteLimit::WIRE_MAX,
        Instant::now(),
    )?;
    assert_eq!(
        pending["files"].as_array().ok_or("rows")?.len(),
        limits::EDIT_FILES
    );
    Ok(())
}

#[test]
fn an_existing_pending_path_can_be_edited_at_capacity() -> TestResult {
    let root = tempfile::tempdir()?;
    std::fs::write(root.path().join("file.txt"), "old\n")?;
    let session = SessionId::new();
    let mut service = EditPreparations::default();
    seed(&mut service, &session, limits::EDIT_FILES - 1)?;
    let mut existing = record(&session, limits::EDIT_FILES, true)?;
    existing.root = root.path().canonicalize()?;
    existing.full_path = existing.root.join("file.txt");
    existing.path = EditPath::try_from("file.txt".to_owned())?;
    service.changes.push_back(existing);
    let (_, ticket) = ready(&mut service, &session, root.path())?;
    let _work = service.claim(&session, ticket, Instant::now())?;
    assert_eq!(service.changes.len(), limits::EDIT_FILES);
    assert!(service.changes.iter().all(|row| row.verification_pending));
    Ok(())
}

#[test]
fn a_foreign_session_cannot_borrow_an_existing_paths_slot() -> TestResult {
    let root = tempfile::tempdir()?;
    std::fs::write(root.path().join("file.txt"), "old\n")?;
    let retained_session = SessionId::new();
    let incoming_session = SessionId::new();
    let mut service = EditPreparations::default();
    seed(&mut service, &retained_session, limits::EDIT_FILES - 1)?;
    let mut existing = record(&retained_session, limits::EDIT_FILES, true)?;
    existing.root = root.path().canonicalize()?;
    existing.full_path = existing.root.join("file.txt");
    existing.path = EditPath::try_from("file.txt".to_owned())?;
    service.changes.push_back(existing);
    let (_, ticket) = ready(&mut service, &incoming_session, root.path())?;
    assert!(matches!(
        service.claim(&incoming_session, ticket, Instant::now()),
        Err(CoreError::Limit)
    ));
    assert_eq!(service.changes.len(), limits::EDIT_FILES);
    assert!(service.changes.iter().all(|row| row.verification_pending));
    assert_eq!(
        std::fs::read_to_string(root.path().join("file.txt"))?,
        "old\n"
    );
    Ok(())
}

#[test]
fn conversation_summary_excludes_foreign_sessions_and_editor_services() -> TestResult {
    let session = SessionId::new();
    let foreign = SessionId::new();
    let mut service = EditPreparations::default();
    seed(&mut service, &session, 2)?;
    service.changes.push_back(record(&foreign, 2, true)?);
    let mut editor = record(&session, 3, true)?;
    editor.service_id = Some(crate::domain::EditServiceId::new());
    service.changes.push_back(editor);
    let before = serde_json::to_value(service.conversation_changes(&session)?)?;
    assert_eq!(before["pending_files"], 2);
    assert_eq!(before["retained_files"], 2);
    let row = service.changes.front().ok_or("pending row")?;
    let consume = json!({"action":"consume","edit_id":row.edit_id,"edit_revision":row.revision,"file":row.file,"final_hash":null});
    service.call(
        &session,
        methods::EDIT_HISTORY,
        consume,
        ByteLimit::WIRE_MAX,
        Instant::now(),
    )?;
    let after = serde_json::to_value(service.conversation_changes(&session)?)?;
    assert_eq!(after["pending_files"], 1);
    assert_eq!(after["retained_files"], 2);
    assert!(after["revision"].as_u64() > before["revision"].as_u64());
    Ok(())
}
