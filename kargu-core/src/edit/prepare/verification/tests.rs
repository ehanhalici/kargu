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
