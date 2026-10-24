//! Native direct-listing parity, resource limits and no-follow ownership tests.

use kargu_core::{
    error::CoreError,
    workspace::listing::{EntryKind, ListFilesInput, ListFilesPlan, ListFilesResult},
};
use std::{
    fs,
    path::Path,
    time::{Duration, Instant},
};
use tempfile::TempDir;
use tokio_util::sync::CancellationToken;

type TestResult = Result<(), Box<dyn std::error::Error>>;

fn tree(names: &[&str]) -> Result<TempDir, Box<dyn std::error::Error>> {
    let directory = tempfile::tempdir()?;
    for name in names {
        let file = directory.path().join(name);
        fs::create_dir_all(file.parent().ok_or("missing parent")?)?;
        fs::write(file, "fixture")?;
    }
    Ok(directory)
}

fn input(root: &Path, path: Option<&str>) -> ListFilesInput {
    ListFilesInput {
        root: root.to_owned(),
        path: path.map(Into::into),
        skip_directories: vec![".git".into(), "node_modules".into(), "target".into()],
        max_entries: 2000,
    }
}

fn run(input: ListFilesInput) -> Result<ListFilesResult, CoreError> {
    ListFilesPlan::try_from(input)?.execute(
        &CancellationToken::new(),
        Instant::now()
            .checked_add(Duration::from_secs(5))
            .ok_or(CoreError::ArithmeticOverflow)?,
    )
}

#[test]
fn direct_listing_preserves_labels_sorting_hidden_files_and_shared_exclusions() -> TestResult {
    let root = tree(&[
        "top.el",
        "sub/inner.el",
        ".hidden",
        "compiled.elc",
        "backup.el~",
        ".git/config",
        "node_modules/module.el",
        "target",
    ])?;
    let result = run(input(root.path(), None))?;
    assert_eq!(
        result.text,
        "[DIR]  sub\n[FILE] .hidden\n[FILE] backup.el~\n[FILE] compiled.elc\n[FILE] top.el"
    );
    assert!(!result.truncated);
    assert!(
        !result
            .entries
            .iter()
            .any(|entry| entry.path.contains("inner.el"))
    );
    assert_eq!(
        run(input(root.path(), Some("sub")))?.text,
        "[FILE] sub/inner.el"
    );
    let mut config = input(root.path(), None);
    config.skip_directories.clear();
    assert!(
        run(config)?
            .entries
            .iter()
            .any(|entry| entry.path == "target")
    );
    Ok(())
}

#[test]
fn links_and_special_entries_are_reported_without_following_or_opening_them() -> TestResult {
    let root = tree(&["inside.el"])?;
    let outside = tree(&["secret.el"])?;
    std::os::unix::fs::symlink(outside.path(), root.path().join("escape"))?;
    std::os::unix::fs::symlink("missing", root.path().join("broken"))?;
    std::os::unix::fs::symlink(root.path(), root.path().join("cycle"))?;
    let _socket = std::os::unix::net::UnixListener::bind(root.path().join("service.sock"))?;
    let result = run(input(root.path(), None))?;
    for name in ["escape", "broken", "cycle"] {
        let entry = result
            .entries
            .iter()
            .find(|entry| entry.path == name)
            .ok_or("missing link")?;
        assert_eq!(entry.kind, EntryKind::Symlink);
        assert!(result.text.contains(&format!("[LINK] {name}")));
    }
    assert_eq!(
        result
            .entries
            .iter()
            .find(|entry| entry.path == "service.sock")
            .ok_or("missing socket")?
            .kind,
        EntryKind::Other
    );
    assert!(!result.text.contains("secret.el"));
    assert!(matches!(
        ListFilesPlan::try_from(input(root.path(), Some("escape"))),
        Err(CoreError::Rejected)
    ));
    Ok(())
}

#[test]
fn traversal_invalid_configuration_and_non_directory_targets_fail_closed() -> TestResult {
    let root = tree(&["file.el"])?;
    let mut request = input(root.path(), Some("../missing"));
    request.root = root.path().join("not-created");
    assert!(matches!(
        ListFilesPlan::try_from(request),
        Err(CoreError::InvalidValue { .. })
    ));
    assert!(matches!(
        ListFilesPlan::try_from(input(root.path(), Some("/not-created-kargu-outside"))),
        Err(CoreError::Rejected)
    ));
    assert!(ListFilesPlan::try_from(input(root.path(), Some("file.el"))).is_err());
    let fifo = root.path().join("pipe");
    nix::unistd::mkfifo(
        &fifo,
        nix::sys::stat::Mode::S_IRUSR | nix::sys::stat::Mode::S_IWUSR,
    )?;
    // Opening a FIFO as a normal File would wait for a writer indefinitely.
    assert!(ListFilesPlan::try_from(input(&fifo, None)).is_err());
    assert!(ListFilesPlan::try_from(input(root.path(), Some("pipe"))).is_err());
    let mut request = input(root.path(), None);
    request.max_entries = usize::MAX;
    assert!(matches!(
        ListFilesPlan::try_from(request),
        Err(CoreError::Limit)
    ));
    let mut request = input(root.path(), None);
    request.skip_directories.push("../escape".into());
    assert!(matches!(
        ListFilesPlan::try_from(request),
        Err(CoreError::InvalidValue { .. })
    ));
    Ok(())
}

#[test]
fn replaced_root_or_target_cannot_publish_from_a_new_directory() -> TestResult {
    for replace_root in [true, false] {
        let parent = tempfile::tempdir()?;
        let root = parent.path().join("workspace");
        fs::create_dir_all(root.join("sub"))?;
        let plan = ListFilesPlan::try_from(input(&root, Some("sub")))?;
        let target = if replace_root {
            root.clone()
        } else {
            root.join("sub")
        };
        fs::rename(&target, parent.path().join("old"))?;
        fs::create_dir(&target)?;
        fs::write(target.join("replacement.txt"), "fixture")?;
        assert!(matches!(
            plan.execute(
                &CancellationToken::new(),
                Instant::now() + Duration::from_secs(1)
            ),
            Err(CoreError::WorkspaceChanged)
        ));
    }
    let root = tree(&["sub/inside.el"])?;
    let outside = tree(&["foreign.el"])?;
    let plan = ListFilesPlan::try_from(input(root.path(), Some("sub")))?;
    fs::rename(root.path().join("sub"), root.path().join("old"))?;
    std::os::unix::fs::symlink(outside.path(), root.path().join("sub"))?;
    assert!(matches!(
        plan.execute(
            &CancellationToken::new(),
            Instant::now() + Duration::from_secs(1)
        ),
        Err(CoreError::WorkspaceChanged)
    ));
    Ok(())
}

#[test]
fn empty_zero_exact_and_exhausted_entry_budgets_are_distinct() -> TestResult {
    let empty = tempfile::tempdir()?;
    let mut request = input(empty.path(), None);
    request.max_entries = 0;
    let result = run(request)?;
    assert_eq!(result.text, "(empty directory)");
    assert!(!result.truncated);
    let root = tree(&["a.el", "b.el"])?;
    for limit in [0, 1, 2] {
        let mut request = input(root.path(), None);
        request.max_entries = limit;
        let result = run(request)?;
        assert_eq!(result.entries.len(), limit);
        assert_eq!(result.truncated, limit < 2);
        if limit < 2 {
            assert!(result.text.contains("omitted"));
            assert!(!result.text.contains("empty directory"));
        }
    }
    Ok(())
}

#[test]
fn retained_entry_and_output_byte_limits_are_explicit() -> TestResult {
    let root = tempfile::tempdir()?;
    for n in 0..201 {
        fs::write(root.path().join(format!("file-{n:04}")), "fixture")?;
    }
    let result = run(input(root.path(), None))?;
    assert_eq!(result.entries.len(), 200);
    assert!(result.truncated);
    let nested = format!("{}/{}", "a".repeat(240), "b".repeat(240));
    fs::create_dir_all(root.path().join(&nested))?;
    for n in 0..200 {
        fs::write(
            root.path().join(&nested).join(format!("file-{n:04}")),
            "fixture",
        )?;
    }
    let result = run(input(root.path(), Some(&nested)))?;
    assert!(result.truncated && result.entries.len() < 200);
    assert!(result.text.len() <= kargu_core::constants::limits::SEARCH_RESULT_BYTES);
    Ok(())
}

#[test]
fn cancelled_expired_and_invalid_path_records_never_claim_success() -> TestResult {
    let root = tree(&["Türkçe🦀.el"])?;
    assert!(run(input(root.path(), None))?.text.contains("Türkçe🦀.el"));
    let cancel = CancellationToken::new();
    cancel.cancel();
    assert!(matches!(
        ListFilesPlan::try_from(input(root.path(), None))?
            .execute(&cancel, Instant::now() + Duration::from_secs(1)),
        Err(CoreError::Cancelled)
    ));
    assert!(matches!(
        ListFilesPlan::try_from(input(root.path(), None))?
            .execute(&CancellationToken::new(), Instant::now()),
        Err(CoreError::Deadline)
    ));
    fs::write(root.path().join("bad\nrecord"), "fixture")?;
    assert!(matches!(
        run(input(root.path(), None)),
        Err(CoreError::InvalidValue { .. })
    ));
    Ok(())
}

#[test]
fn success_and_failure_release_pinned_directory_descriptors() -> TestResult {
    let root = tree(&["file.el"])?;
    for _ in 0..5 {
        run(input(root.path(), None))?;
    }
    fs::write(root.path().join("bad\nrecord"), "fixture")?;
    assert!(run(input(root.path(), None)).is_err());
    let retained = fs::read_dir("/proc/self/fd")?
        .filter_map(Result::ok)
        .filter_map(|entry| fs::read_link(entry.path()).ok())
        .any(|path| path.starts_with(root.path()));
    assert!(!retained);
    Ok(())
}
