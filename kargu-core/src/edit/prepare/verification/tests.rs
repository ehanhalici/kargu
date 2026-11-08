use super::*;
use crate::edit::prepare::{history::ChangeBaseline, receipt::FileOutcome};
use serde_json::{Value, json};
use std::path::PathBuf;
type TestResult = Result<(), Box<dyn std::error::Error>>;
const DOCUMENT: &str = "editor_document_12345678-1234-4234-8234-123456789abc";
fn document() -> Result<DocumentStamp, serde_json::Error> {
    serde_json::from_value(json!({"path":"file.txt","document_id":DOCUMENT,"tick":7}))
}
fn snapshot() -> Value {
    let stamp = json!({"path":"file.txt","document_id":DOCUMENT,"tick":7});
    json!({"requested":stamp,"observed":stamp,"available":true,"truncated":false,
        "server":null,"diagnostics":[],"backends":[{"backend":"checker", "requested":1,
        "observed":1,"tick":7,"reported":true}]})
}
fn rows(session: &SessionId) -> Result<VecDeque<ChangedFileRecord>, Box<dyn std::error::Error>> {
    Ok(VecDeque::from([ChangedFileRecord {
        session: session.clone(),
        service_id: None,
        edit_id: EditorEditId::new(),
        revision: HistoryRevision::default(),
        file: FileIndex::try_from(0)?,
        root: PathBuf::from("/owned"),
        full_path: PathBuf::from("/owned/file.txt"),
        path: crate::edit::types::EditPath::try_from("file.txt".to_owned())?,
        outcome: FileOutcome::Applied,
        final_hash: Some(ContentHash::try_from("0".repeat(64))?),
        baseline: ChangeBaseline::Unavailable,
        document: Some(serde_json::from_value(
            json!({"id":DOCUMENT,"tick":7,"bytes":4,
            "coding":"utf-8-unix","dirty":true,"read_only":false,"disk":{"kind":"absent"}}),
        )?),
        disk: super::super::types::DiskState::Absent {},
        hunks: None,
        saved: false,
        hook_modified: false,
        verification_pending: true,
    }]))
}
#[test]
fn exact_fresh_clean_document_settles_only_its_captured_owner() -> TestResult {
    let session = SessionId::new();
    let mut changes = rows(&session)?;
    let mut foreign = changes.front().ok_or("row")?.clone();
    foreign.session = SessionId::new();
    changes.push_back(foreign);
    let mut editor = changes.front().ok_or("row")?.clone();
    editor.service_id = Some(crate::domain::EditServiceId::new());
    changes.push_back(editor);
    assert!(capture(&changes, &session, Path::new("/foreign"), &document()?).is_none());
    let ticket = capture(&changes, &session, Path::new("/owned"), &document()?).ok_or("ticket")?;
    let mut revision = HistoryRevision::default();
    assert!(settle(
        &mut changes,
        &mut revision,
        &session,
        ticket,
        &serde_json::from_value(snapshot())?
    )?);
    assert!(!changes.front().ok_or("row")?.verification_pending);
    assert!(changes.iter().skip(1).all(|row| row.verification_pending));
    assert!(capture(&changes, &session, Path::new("/owned"), &document()?).is_none());
    Ok(())
}
#[test]
fn incomplete_foreign_or_error_diagnostics_preserve_the_debt() -> TestResult {
    let session = SessionId::new();
    for case in [
        "pending",
        "stale",
        "foreign",
        "unavailable",
        "truncated",
        "error",
    ] {
        let mut changes = rows(&session)?;
        let ticket =
            capture(&changes, &session, Path::new("/owned"), &document()?).ok_or("ticket")?;
        let mut observation = snapshot();
        match case {
            "pending" => observation["backends"][0]["reported"] = json!(false),
            "stale" => observation["observed"]["tick"] = json!(8),
            "foreign" => {
                observation["requested"]["document_id"] = json!("foreign");
                observation["observed"]["document_id"] = json!("foreign");
            }
            "unavailable" => observation["available"] = json!(false),
            "truncated" => observation["truncated"] = json!(true),
            "error" => {
                observation["diagnostics"] = json!([{"source":"checker","code":null,
                "severity":"error","message":"synthetic error","range":{
                "start":{"line":1,"column":0},"end":{"line":1,"column":1}}}])
            }
            _ => return Err("case".into()),
        }
        let mut revision = HistoryRevision::default();
        assert!(
            !settle(
                &mut changes,
                &mut revision,
                &session,
                ticket,
                &serde_json::from_value(observation)?
            )?,
            "{case}"
        );
        assert!(changes.front().ok_or("row")?.verification_pending);
        assert!(revision == HistoryRevision::default());
    }
    Ok(())
}
#[test]
fn reanchored_publication_and_changed_content_reject_an_old_capture() -> TestResult {
    let session = SessionId::new();
    for case in ["revision", "hash", "tick", "service", "session"] {
        let mut changes = rows(&session)?;
        let ticket =
            capture(&changes, &session, Path::new("/owned"), &document()?).ok_or("ticket")?;
        let row = changes.front_mut().ok_or("row")?;
        match case {
            "revision" => row.revision = serde_json::from_value(json!(1))?,
            "hash" => row.final_hash = Some(ContentHash::try_from("1".repeat(64))?),
            "tick" => {
                row.document.as_mut().ok_or("document")?.tick =
                    super::super::types::DocumentTick::try_from(8)?
            }
            "service" => row.service_id = Some(crate::domain::EditServiceId::new()),
            "session" => row.session = SessionId::new(),
            _ => return Err("case".into()),
        }
        assert!(
            !settle(
                &mut changes,
                &mut HistoryRevision::default(),
                &session,
                ticket,
                &serde_json::from_value(snapshot())?
            )?,
            "{case}"
        );
        assert!(changes.front().ok_or("row")?.verification_pending);
    }
    Ok(())
}
#[test]
fn revision_overflow_never_partially_consumes_verification() -> TestResult {
    let session = SessionId::new();
    let mut changes = rows(&session)?;
    let ticket = capture(&changes, &session, Path::new("/owned"), &document()?).ok_or("ticket")?;
    let mut revision = serde_json::from_value(json!(u64::MAX))?;
    assert!(matches!(
        settle(
            &mut changes,
            &mut revision,
            &session,
            ticket,
            &serde_json::from_value(snapshot())?
        ),
        Err(CoreError::ArithmeticOverflow)
    ));
    assert!(changes.front().ok_or("row")?.verification_pending);
    Ok(())
}

#[test]
fn pre_existing_baseline_errors_settle_only_when_producer_document_and_hash_match() -> TestResult {
    let session = SessionId::new();
    let error = json!({
        "source":"checker",
        "code":"E1",
        "severity":{"flymake":3},
        "message":"pre-existing error",
        "range":{"start":{"line":1,"column":0},"end":{"line":1,"column":1}}
    });
    let mut base = snapshot();
    base["requested"]["tick"] = json!(5);
    base["observed"]["tick"] = json!(5);
    base["backends"][0]["tick"] = json!(5);
    base["server"] = json!({
        "requested_server":"srv-1",
        "observed_server":"srv-1",
        "requested_version":1,
        "published_version":1,
        "tick":5
    });
    base["diagnostics"] = json!([error.clone()]);
    for case in [
        "same_pre_existing",
        "new_error",
        "server_replaced",
        "new_document_same_path",
        "unavailable_baseline",
    ] {
        let mut changes = rows(&session)?;
        if case != "unavailable_baseline" {
            let mut baseline = base.clone();
            if case == "new_document_same_path" {
                baseline["requested"]["document_id"] =
                    json!("editor_document_99999999-1234-4234-8234-123456789abc");
                baseline["observed"]["document_id"] =
                    json!("editor_document_99999999-1234-4234-8234-123456789abc");
            }
            changes.front_mut().ok_or("row")?.baseline = ChangeBaseline::Known {
                original: Some(ContentHash::try_from("a".repeat(64))?),
                diagnostics: DiagnosticBaseline::Captured {
                    base_hash: ContentHash::try_from("a".repeat(64))?,
                    snapshot: Box::new(serde_json::from_value(baseline)?),
                },
            };
        }
        let ticket =
            capture(&changes, &session, Path::new("/owned"), &document()?).ok_or("ticket")?;
        let mut post = snapshot();
        let server_id = if case == "server_replaced" {
            "srv-2"
        } else {
            "srv-1"
        };
        post["server"] = json!({
            "requested_server":server_id,
            "observed_server":server_id,
            "requested_version":2,
            "published_version":2,
            "tick":7
        });
        let mut shifted = error.clone();
        shifted["range"]["start"]["line"] = json!(10);
        shifted["range"]["end"]["line"] = json!(10);
        if case == "new_error" {
            shifted["message"] = json!("brand new error");
        }
        post["diagnostics"] = json!([shifted]);
        let post_snapshot: DiagnosticSnapshot = serde_json::from_value(post)?;
        let sig = ticket.healing_signature(&post_snapshot);
        assert_eq!(sig.is_some(), case == "new_error", "{case}");
        let round_one = std::num::NonZeroU8::new(1).ok_or("round")?;
        let note = ticket
            .baseline_note(
                &post_snapshot,
                Some(HealingVerdict::Admitted { round: round_one }),
            )
            .ok_or("baseline note")?;
        let text = note.as_str();
        if case == "new_error" {
            let repeated = ticket
                .baseline_note(&post_snapshot, Some(HealingVerdict::RepeatedErrors))
                .ok_or("repeated note")?;
            assert!(repeated.as_str().contains("SELF-HEALING STOPPED"));
            let exhausted = ticket
                .baseline_note(&post_snapshot, Some(HealingVerdict::BudgetExhausted))
                .ok_or("exhausted note")?;
            assert!(exhausted.as_str().contains("SELF-HEALING BUDGET SPENT"));
        }
        let mut revision = HistoryRevision::default();
        let settled = settle(
            &mut changes,
            &mut revision,
            &session,
            ticket,
            &post_snapshot,
        )?;
        match case {
            "same_pre_existing" => {
                assert!(settled, "{case}");
                assert!(!changes.front().ok_or("row")?.verification_pending);
                assert!(
                    text.contains("0 new error(s), 1 pre-existing error(s), 0 resolved error(s)")
                );
                assert!(!text.contains("SELF-HEALING"));
            }
            "new_error" => {
                assert!(!settled, "{case}");
                assert!(changes.front().ok_or("row")?.verification_pending);
                assert!(
                    text.contains("1 new error(s), 0 pre-existing error(s), 1 resolved error(s)")
                );
                assert!(text.contains("SELF-HEALING (round 1 of 2)"));
            }
            _ => {
                assert!(!settled, "{case}");
                assert!(changes.front().ok_or("row")?.verification_pending);
                assert!(text.contains("Baseline comparison unavailable"));
                assert!(!text.contains("0 new error(s)"));
            }
        }
    }
    Ok(())
}

#[test]
fn second_edit_on_same_path_is_never_consumed_by_first_edit_late_diagnostic() -> TestResult {
    let session = SessionId::new();
    let mut changes = rows(&session)?;
    let ticket_a =
        capture(&changes, &session, Path::new("/owned"), &document()?).ok_or("ticket_a")?;
    let snapshot_a: DiagnosticSnapshot = serde_json::from_value(snapshot())?;

    let row_b = changes.front_mut().ok_or("row_b")?;
    row_b.edit_id = EditorEditId::new();
    row_b.revision = serde_json::from_value(json!(2))?;
    row_b.final_hash = Some(ContentHash::try_from("b".repeat(64))?);
    row_b.document.as_mut().ok_or("doc")?.tick = super::super::types::DocumentTick::try_from(9)?;

    let mut revision: HistoryRevision = serde_json::from_value(json!(2))?;
    assert!(!settle(
        &mut changes,
        &mut revision,
        &session,
        ticket_a,
        &snapshot_a,
    )?);
    assert!(changes.front().ok_or("row")?.verification_pending);

    let doc_b: DocumentStamp =
        serde_json::from_value(json!({"path":"file.txt","document_id":DOCUMENT,"tick":9}))?;
    let mut raw_b = snapshot();
    raw_b["requested"]["tick"] = json!(9);
    raw_b["observed"]["tick"] = json!(9);
    raw_b["backends"][0]["tick"] = json!(9);
    let snapshot_b: DiagnosticSnapshot = serde_json::from_value(raw_b)?;
    let ticket_b = capture(&changes, &session, Path::new("/owned"), &doc_b).ok_or("ticket_b")?;
    assert!(settle(
        &mut changes,
        &mut revision,
        &session,
        ticket_b,
        &snapshot_b,
    )?);
    assert!(!changes.front().ok_or("row")?.verification_pending);
    Ok(())
}

#[test]
fn delete_closed_file_and_explicit_service_retain_separate_publication_debt() -> TestResult {
    let session = SessionId::new();
    let service = EditServiceId::new();
    let mut changes = rows(&session)?;
    let base = changes.front().ok_or("base")?.clone();

    let mut closed = base.clone();
    closed.edit_id = EditorEditId::new();
    closed.path = EditPath::try_from("closed.txt".to_owned())?;
    closed.full_path = PathBuf::from("/owned/closed.txt");
    closed.document = None;
    closed.final_hash = Some(ContentHash::try_from("c".repeat(64))?);
    changes.push_back(closed);

    let mut deleted = base.clone();
    deleted.edit_id = EditorEditId::new();
    deleted.path = EditPath::try_from("deleted.txt".to_owned())?;
    deleted.full_path = PathBuf::from("/owned/deleted.txt");
    deleted.document = None;
    deleted.final_hash = None;
    changes.push_back(deleted);

    let mut explicit = base.clone();
    explicit.service_id = Some(service.clone());
    explicit.edit_id = EditorEditId::new();
    changes.push_back(explicit);

    let conv_sched = schedule_pending(&changes, &session, None);
    assert_eq!(conv_sched.len(), 3);
    assert_eq!(conv_sched.first().ok_or("0")?.session(), &session);
    assert!(conv_sched.first().ok_or("0")?.service_id().is_none());
    assert!(matches!(
        conv_sched.first().ok_or("0")?.target(),
        VerificationTarget::LiveDocument { .. }
    ));
    assert_eq!(conv_sched.get(1).ok_or("1")?.path().as_str(), "closed.txt");
    assert!(matches!(
        conv_sched.get(1).ok_or("1")?.target(),
        VerificationTarget::ClosedFile
    ));
    assert_eq!(conv_sched.get(2).ok_or("2")?.path().as_str(), "deleted.txt");
    assert!(matches!(
        conv_sched.get(2).ok_or("2")?.target(),
        VerificationTarget::DeletedFile
    ));

    let svc_sched = schedule_pending(&changes, &session, Some(&service));
    assert_eq!(svc_sched.len(), 1);
    assert_eq!(svc_sched.first().ok_or("svc")?.service_id(), Some(&service));
    assert!(svc_sched.first().ok_or("svc")?.edit_id() == &changes.back().ok_or("back")?.edit_id);
    assert!(svc_sched.first().ok_or("svc")?.revision() == HistoryRevision::default());
    assert_eq!(svc_sched.first().ok_or("svc")?.file().get(), 0);

    let closed_doc: DocumentStamp =
        serde_json::from_value(json!({"path":"closed.txt","document_id":DOCUMENT,"tick":7}))?;
    let deleted_doc: DocumentStamp =
        serde_json::from_value(json!({"path":"deleted.txt","document_id":DOCUMENT,"tick":7}))?;
    assert!(capture(&changes, &session, Path::new("/owned"), &closed_doc).is_none());
    assert!(capture(&changes, &session, Path::new("/owned"), &deleted_doc).is_none());

    let svc_ticket = capture_for_service(
        &changes,
        (&session, Some(&service)),
        (Path::new("/owned"), &document()?),
    )
    .ok_or("svc_ticket")?;
    let mut revision = HistoryRevision::default();
    assert!(settle(
        &mut changes,
        &mut revision,
        &session,
        svc_ticket,
        &serde_json::from_value(snapshot())?,
    )?);
    assert!(!changes.back().ok_or("back")?.verification_pending);
    assert_eq!(schedule_pending(&changes, &session, None).len(), 3);
    assert!(schedule_pending(&changes, &session, Some(&service)).is_empty());
    Ok(())
}

#[test]
fn queue_pressure_evicts_only_settled_rows_and_never_drops_pending_debt() -> TestResult {
    let session = SessionId::new();
    let template = rows(&session)?.pop_front().ok_or("template")?;
    let mut changes = VecDeque::new();
    for idx in 0..crate::constants::limits::EDIT_FILES {
        let mut row = template.clone();
        row.edit_id = EditorEditId::new();
        row.path = EditPath::try_from(format!("f-{idx}.txt"))?;
        row.full_path = PathBuf::from(format!("/owned/f-{idx}.txt"));
        row.verification_pending = idx != 0;
        changes.push_back(row);
    }
    let mut extra = template.clone();
    extra.edit_id = EditorEditId::new();
    extra.path = EditPath::try_from("extra.txt".to_owned())?;
    extra.full_path = PathBuf::from("/owned/extra.txt");
    super::super::history::publish_change(&mut changes, extra.clone())?;
    assert_eq!(
        schedule_pending(&changes, &session, None).len(),
        crate::constants::limits::EDIT_FILES
    );
    assert!(matches!(
        super::super::history::publish_change(&mut changes, extra),
        Err(CoreError::CleanupFailed)
    ));
    assert_eq!(
        schedule_pending(&changes, &session, None).len(),
        crate::constants::limits::EDIT_FILES
    );
    Ok(())
}
