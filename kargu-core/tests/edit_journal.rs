//! Durable bounded journal evidence and conservative recovery; no original-file writer.
use kargu_core::{
    application::{ApplicationActor, Mode, RunHandle, RunSettings},
    constants::limits,
    domain::{ApplicationId, ConfigRevision, PolicyRevision, ToolCallLimit},
    edit::{
        intent::{EditorAction, EditorActionInput, EditorFileInput},
        journal::{
            self, IssuedJournal, JournalDirectory, JournalIssue, JournalResolution,
            RecoveredJournal, RecoveryReason,
        },
        types::{
            CaptureDigest, EditText, EditorEditId, EditorRevision, EditorSourceId, ReviewMode,
            SavePolicy,
        },
    },
    error::CoreError,
    security::Workspace,
};
use serde_json::{Value, json};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    os::unix::fs::{MetadataExt, PermissionsExt, symlink},
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio_util::sync::CancellationToken;
type TestResult = Result<(), Box<dyn std::error::Error>>;
struct Fixture {
    directory: tempfile::TempDir,
    workspace: tempfile::TempDir,
    _actor: ApplicationActor,
    run: RunHandle,
    action: EditorAction,
    id: EditorEditId,
    cancel: CancellationToken,
}
impl Fixture {
    fn new() -> Result<Self, CoreError> {
        let directory = tempfile::tempdir()?;
        let workspace = tempfile::tempdir()?;
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700))?;
        fs::set_permissions(workspace.path(), fs::Permissions::from_mode(0o700))?;
        fs::write(workspace.path().join("source"), "private base text")?;
        let root = Workspace::try_from(workspace.path().to_path_buf())?;
        let mut actor = ApplicationActor::new(ApplicationId::new());
        let session = actor.create_session();
        let config = ConfigRevision::try_from(3)?;
        let policy = PolicyRevision::try_from(7)?;
        let run = actor.admit(
            &session,
            RunSettings::new(
                Mode::Agent,
                root.clone(),
                ToolCallLimit::default(),
                Duration::from_secs(60),
                config,
                policy,
            )?,
        )?;
        let action = EditorAction::try_from(EditorActionInput {
            source: EditorSourceId::try_from(
                "editor_source_12345678-1234-4234-8234-123456789abc".to_owned(),
            )?,
            revision: EditorRevision::try_from(1)?,
            workspace: root,
            config_revision: config,
            policy_revision: policy,
            review_mode: ReviewMode::Auto,
            save_policy: SavePolicy::Save,
            files: vec![EditorFileInput::Update {
                path: "source".to_owned().try_into()?,
                base: Arc::new(EditText::try_from("private base text".to_owned())?),
                proposed: Arc::new(EditText::try_from("private proposed text".to_owned())?),
                capture: CaptureDigest::try_from("a".repeat(64))?,
            }],
        })?;
        Ok(Self {
            directory,
            workspace,
            _actor: actor,
            run,
            action,
            id: EditorEditId::try_from(format!("editor_edit_{}", uuid::Uuid::new_v4()))?,
            cancel: CancellationToken::new(),
        })
    }
    fn root(&self) -> Result<JournalDirectory, CoreError> {
        JournalDirectory::try_from(self.directory.path().to_path_buf())
    }
    fn deadline(&self) -> Result<Instant, CoreError> {
        Instant::now()
            .checked_add(Duration::from_secs(5))
            .ok_or(CoreError::ArithmeticOverflow)
    }
    fn issue(&self) -> Result<JournalIssue, CoreError> {
        JournalIssue::capture(self.id.clone(), self.run.scope(), &self.action)
    }
    fn create(&self) -> Result<IssuedJournal, CoreError> {
        IssuedJournal::create(self.root()?, self.issue()?, &self.cancel, self.deadline()?)
    }
    fn recover(&self) -> Result<RecoveredJournal, CoreError> {
        journal::recover(
            self.root()?,
            self.id.clone(),
            &self.cancel,
            self.deadline()?,
        )
    }
    fn path(&self) -> PathBuf {
        self.directory
            .path()
            .join(format!("{}.ndjson", String::from(self.id.clone())))
    }
}
fn receipt() -> Result<JournalResolution, CoreError> {
    Ok(JournalResolution::Receipt {
        digest: CaptureDigest::try_from("b".repeat(64))?,
    })
}
#[test]
fn issuance_unknown_and_late_receipt_are_synced_locked_and_consumed_once() -> TestResult {
    let f = Fixture::new()?;
    let pending = f.create()?;
    assert_eq!(f.path().metadata()?.mode() & 0o777, 0o600);
    let raw = fs::read_to_string(f.path())?;
    assert!(raw.ends_with('\n'));
    assert!(!raw.contains("private base text"));
    assert!(!raw.contains("private proposed text"));
    assert!(matches!(f.recover(), Err(CoreError::Busy)));
    assert!(matches!(f.create(), Err(CoreError::AlreadyCompleted)));
    let pending = pending.mark_unknown(&f.cancel, f.deadline()?)?;
    assert!(matches!(f.recover(), Err(CoreError::Busy)));
    let committed = pending.resolve(receipt()?, &f.cancel, f.deadline()?)?;
    assert!(committed.id() == &f.id);
    assert!(committed.resolution() == &receipt()?);
    match f.recover()? {
        RecoveredJournal::Resolved { issue, resolution } => {
            assert!(issue.id() == &f.id);
            assert_eq!(issue.scope(), f.run.scope());
            assert!(resolution == receipt()?);
        }
        _ => return Err("full journal was not resolved".into()),
    }
    assert_eq!(
        fs::read_to_string(f.workspace.path().join("source"))?,
        "private base text"
    );
    Ok(())
}
#[test]
fn dropped_issuance_and_unknown_marker_recover_as_unknown_without_changing_disk() -> TestResult {
    for mark in [false, true] {
        let f = Fixture::new()?;
        let pending = f.create()?;
        if mark {
            drop(pending.mark_unknown(&f.cancel, f.deadline()?)?);
        } else {
            drop(pending);
        }
        let before = fs::read(f.path())?;
        match f.recover()? {
            RecoveredJournal::OutcomeUnknown { issue, reason } => {
                assert!(issue.id() == &f.id);
                assert_eq!(reason, RecoveryReason::MissingResolution);
            }
            _ => return Err("unterminated journal claimed resolution".into()),
        }
        assert_eq!(fs::read(f.path())?, before);
        assert!(matches!(f.create(), Err(CoreError::AlreadyCompleted)));
    }
    Ok(())
}
#[test]
fn every_cut_in_terminal_record_and_trailing_junk_is_unknown_never_success() -> TestResult {
    let f = Fixture::new()?;
    let pending = f.create()?;
    let issue = fs::read(f.path())?;
    pending.resolve(receipt()?, &f.cancel, f.deadline()?)?;
    let full = fs::read(f.path())?;
    for cut in issue.len()..full.len() {
        fs::write(f.path(), full.get(..cut).ok_or("cut")?)?;
        assert!(
            matches!(f.recover()?, RecoveredJournal::OutcomeUnknown { .. }),
            "cut={cut}"
        );
    }
    for cut in [0, 1, issue.len() / 2, issue.len().saturating_sub(1)] {
        fs::write(f.path(), issue.get(..cut).ok_or("cut")?)?;
        assert!(
            matches!(f.recover()?, RecoveredJournal::Unconfirmed(_)),
            "issue cut={cut}"
        );
    }
    let mut with_tail = full.clone();
    with_tail.extend_from_slice(b"junk\n");
    fs::write(f.path(), with_tail)?;
    assert!(matches!(
        f.recover()?,
        RecoveredJournal::OutcomeUnknown {
            reason: RecoveryReason::InvalidRecord,
            ..
        }
    ));
    fs::write(f.path(), full)?;
    assert!(matches!(f.recover()?, RecoveredJournal::Resolved { .. }));
    Ok(())
}
#[test]
fn schema_sequence_identity_and_chain_changes_cannot_fabricate_a_terminal_receipt() -> TestResult {
    let f = Fixture::new()?;
    f.create()?.resolve(receipt()?, &f.cancel, f.deadline()?)?;
    let raw = fs::read_to_string(f.path())?;
    let records: Vec<Value> = raw
        .lines()
        .map(serde_json::from_str)
        .collect::<Result<_, _>>()?;
    for key in [
        "version",
        "sequence",
        "previous",
        "payload",
        "digest",
        "unexpected",
    ] {
        let mut changed = records.clone();
        let terminal = changed.get_mut(1).ok_or("terminal")?;
        terminal[key] = match key {
            "version" => json!(2),
            "sequence" => json!(3),
            "payload" => json!({"event":"unknown"}),
            "unexpected" => json!("not allowed"),
            _ => json!(vec![0; 32]),
        };
        let encoded = changed
            .iter()
            .map(|value| format!("{value}\n"))
            .collect::<String>();
        fs::write(f.path(), encoded)?;
        assert!(
            matches!(
                f.recover()?,
                RecoveredJournal::OutcomeUnknown {
                    reason: RecoveryReason::InvalidRecord,
                    ..
                }
            ),
            "{key}"
        );
    }
    let mut changed = records;
    changed.first_mut().ok_or("issue")?["payload"]["issue"]["id"] =
        json!(format!("editor_edit_{}", uuid::Uuid::new_v4()));
    fs::write(
        f.path(),
        changed
            .iter()
            .map(|value| format!("{value}\n"))
            .collect::<String>(),
    )?;
    assert!(matches!(
        f.recover()?,
        RecoveredJournal::Unconfirmed(RecoveryReason::InvalidRecord)
    ));
    Ok(())
}
#[test]
fn root_replacement_foreign_append_and_hardlink_do_not_overwrite_foreign_state() -> TestResult {
    let f = Fixture::new()?;
    let pending = f.create()?;
    let before = fs::read(f.path())?;
    let relocated = f.workspace.path().join("relocated-journal");
    fs::rename(f.directory.path(), &relocated)?;
    fs::create_dir(f.directory.path())?;
    fs::set_permissions(f.directory.path(), fs::Permissions::from_mode(0o700))?;
    assert!(matches!(
        pending.resolve(receipt()?, &f.cancel, f.deadline()?),
        Err(CoreError::WorkspaceChanged)
    ));
    let old = relocated.join(f.path().file_name().ok_or("name")?);
    assert_eq!(fs::read(old)?, before);
    let f = Fixture::new()?;
    let pending = f.create()?;
    let mut file = OpenOptions::new().append(true).open(f.path())?;
    file.write_all(b"foreign")?;
    drop(file);
    let before = fs::read(f.path())?;
    assert!(matches!(
        pending.resolve(receipt()?, &f.cancel, f.deadline()?),
        Err(CoreError::WorkspaceChanged)
    ));
    assert_eq!(fs::read(f.path())?, before);
    let link = f.workspace.path().join("linked-journal");
    fs::hard_link(f.path(), &link)?;
    assert!(matches!(f.recover(), Err(CoreError::WorkspaceChanged)));
    assert_eq!(fs::read(link)?, before);
    Ok(())
}
#[test]
fn private_permissions_workspace_exclusion_symlinks_and_special_files_fail_before_io() -> TestResult
{
    let f = Fixture::new()?;
    fs::set_permissions(f.directory.path(), fs::Permissions::from_mode(0o755))?;
    assert!(matches!(f.create(), Err(CoreError::WorkspaceChanged)));
    assert!(!f.path().exists());
    let f = Fixture::new()?;
    assert!(matches!(
        IssuedJournal::create(
            JournalDirectory::try_from(f.workspace.path().to_path_buf())?,
            f.issue()?,
            &f.cancel,
            f.deadline()?
        ),
        Err(CoreError::Rejected)
    ));
    symlink(f.workspace.path().join("source"), f.path())?;
    assert!(f.recover().is_err());
    assert!(matches!(f.create(), Err(CoreError::AlreadyCompleted)));
    assert_eq!(
        fs::read_to_string(f.workspace.path().join("source"))?,
        "private base text"
    );
    let f = Fixture::new()?;
    nix::unistd::mkfifo(
        &f.path(),
        nix::sys::stat::Mode::S_IRUSR | nix::sys::stat::Mode::S_IWUSR,
    )?;
    assert!(matches!(f.recover(), Err(CoreError::WorkspaceChanged)));
    let f = Fixture::new()?;
    drop(f.create()?);
    fs::set_permissions(f.path(), fs::Permissions::from_mode(0o644))?;
    assert!(matches!(f.recover(), Err(CoreError::WorkspaceChanged)));
    Ok(())
}
#[test]
fn cancellation_and_sparse_oversize_leave_unconfirmed_evidence_without_replay() -> TestResult {
    let f = Fixture::new()?;
    f.cancel.cancel();
    assert!(matches!(f.create(), Err(CoreError::Cancelled)));
    assert!(!f.path().exists());
    let f = Fixture::new()?;
    let pending = f.create()?;
    f.cancel.cancel();
    assert!(matches!(
        pending.resolve(receipt()?, &f.cancel, f.deadline()?),
        Err(CoreError::Cancelled)
    ));
    let active = CancellationToken::new();
    assert!(matches!(
        journal::recover(f.root()?, f.id.clone(), &active, f.deadline()?)?,
        RecoveredJournal::OutcomeUnknown { .. }
    ));
    let file = OpenOptions::new().write(true).open(f.path())?;
    file.set_len(
        u64::try_from(limits::EDIT_JOURNAL_BYTES)?
            .checked_add(1)
            .ok_or("size")?,
    )?;
    assert!(matches!(
        journal::recover(f.root()?, f.id.clone(), &active, f.deadline()?),
        Err(CoreError::Limit)
    ));
    Ok(())
}
#[test]
fn source_bodies_duplicate_targets_and_foreign_revisions_cannot_enter_journal_metadata()
-> TestResult {
    let f = Fixture::new()?;
    let original = serde_json::to_value(f.issue()?)?;
    for field in ["revision", "config", "source_body", "duplicate", "too_many"] {
        let mut value = original.clone();
        match field {
            "revision" => value["revision"] = json!(2),
            "config" => value["action"]["config_revision"] = json!(999),
            "source_body" => value["action"]["files"][0]["proposed"] = json!("private body"),
            "duplicate" => {
                let file = value["action"]["files"][0].clone();
                value["action"]["files"]
                    .as_array_mut()
                    .ok_or("files")?
                    .push(file);
            }
            _ => {
                let file = value["action"]["files"][0].clone();
                value["action"]["files"] =
                    Value::Array(vec![file; limits::EDIT_FILES.saturating_add(1)]);
            }
        }
        assert!(
            serde_json::from_value::<JournalIssue>(value).is_err(),
            "{field}"
        );
    }
    assert!(!f.path().exists());
    Ok(())
}
