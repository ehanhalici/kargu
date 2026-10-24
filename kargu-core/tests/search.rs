//! Native equivalents of the former Elisp glob and fallback contracts.

use kargu_core::{
    error::CoreError,
    workspace::search::{FindFilesInput, FindFilesPlan, FindFilesResult},
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

fn input(root: &Path, pattern: &str, path: Option<&str>) -> FindFilesInput {
    FindFilesInput {
        root: root.to_owned(),
        path: path.map(Into::into),
        pattern: pattern.into(),
        skip_directories: vec![".git".into(), "node_modules".into(), "target".into()],
        max_files: 2000,
        max_directories: 2000,
    }
}

fn run(input: FindFilesInput) -> Result<FindFilesResult, CoreError> {
    FindFilesPlan::try_from(input)?.execute(
        &CancellationToken::new(),
        Instant::now()
            .checked_add(Duration::from_secs(5))
            .ok_or(CoreError::ArithmeticOverflow)?,
    )
}

#[test]
fn recursive_globs_include_zero_or_more_directories_and_escape_literals() -> TestResult {
    let root = tree(&[
        "main.el",
        "src/main.el",
        "src/deep/main.el",
        "main.elc",
        "main+.el",
        "src/test1.el",
        "src/a/test2.el",
        "src/a/b/test3.el",
        "src/test12.el",
    ])?;
    for pattern in ["*.el", "**/*.el"] {
        let result = run(input(root.path(), pattern, None))?;
        for name in ["main.el", "src/main.el", "src/deep/main.el"] {
            assert!(result.files.iter().any(|file| file == name));
        }
        assert!(!result.files.iter().any(|file| file == "main.elc"));
        assert!(!result.truncated);
    }
    assert_eq!(
        run(input(root.path(), "src/**/test?.el", None))?.files,
        ["src/a/b/test3.el", "src/a/test2.el", "src/test1.el"]
    );
    assert_eq!(
        run(input(root.path(), "main+.el", None))?.files,
        ["main+.el"]
    );
    assert_eq!(
        run(input(root.path(), "*.el", Some("src/deep")))?.files,
        ["src/deep/main.el"]
    );
    assert_eq!(
        run(input(root.path(), "*.el", Some("main.el")))?.text,
        "main.el\n"
    );
    assert!(
        run(input(root.path(), "absent", None))?
            .text
            .starts_with("No files matching")
    );
    Ok(())
}

#[test]
fn shared_exclusions_artifacts_hidden_sources_and_configurable_policy() -> TestResult {
    let root = tree(&[
        "visible.el",
        ".hidden.el",
        ".git/config",
        "node_modules/pkg/main.el",
        "src/target/generated.el",
        "backup.el~",
        ".#locked.el",
        "compiled.elc",
        "byte.pyc",
    ])?;
    assert_eq!(
        run(input(root.path(), "*", None))?.files,
        [".hidden.el", "visible.el"]
    );
    let mut request = input(root.path(), "*.el", None);
    request.skip_directories.retain(|name| name != "target");
    assert_eq!(
        run(request)?.files,
        [".hidden.el", "src/target/generated.el", "visible.el"]
    );
    Ok(())
}

#[test]
fn traversal_and_symlink_escapes_are_rejected_and_discovered_links_not_followed() -> TestResult {
    let root = tree(&["inside.el", "src/child.el"])?;
    let outside = tree(&["secret.el"])?;
    std::os::unix::fs::symlink(outside.path(), root.path().join("escape"))?;
    std::os::unix::fs::symlink(root.path().join("src"), root.path().join("alias"))?;
    std::os::unix::fs::symlink(root.path(), root.path().join("src/cycle"))?;
    assert!(matches!(
        FindFilesPlan::try_from(input(root.path(), "*", Some("../no-such-path"))),
        Err(CoreError::InvalidValue { .. })
    ));
    assert!(matches!(
        FindFilesPlan::try_from(input(root.path(), "*", Some("escape"))),
        Err(CoreError::Rejected)
    ));
    assert_eq!(
        run(input(root.path(), "*.el", None))?.files,
        ["inside.el", "src/child.el"]
    );
    let plan = FindFilesPlan::try_from(input(root.path(), "*", Some("src")))?;
    fs::rename(root.path().join("src"), root.path().join("moved"))?;
    std::os::unix::fs::symlink(outside.path(), root.path().join("src"))?;
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
fn visit_output_and_directory_limits_never_silently_claim_exhaustive_results() -> TestResult {
    let names: Vec<String> = (0..205).map(|n| format!("src/f{n:04}.el")).collect();
    let refs: Vec<&str> = names.iter().map(String::as_str).collect();
    let root = tree(&refs)?;
    let result = run(input(root.path(), "*", None))?;
    assert_eq!(result.files.len(), 200);
    assert!(result.truncated);
    assert!(result.text.contains("omitted"));
    let mut limited = input(root.path(), "absent", None);
    limited.max_files = 3;
    assert!(run(limited)?.truncated);
    let mut limited = input(root.path(), "*", None);
    limited.max_directories = 1;
    let result = run(limited)?;
    assert!(result.files.is_empty() && result.truncated);
    let mut limited = input(root.path(), "*", None);
    limited.max_files = 0;
    assert!(run(limited)?.truncated);
    let exact = tree(&["a.el", "b.el"])?;
    let mut limited = input(exact.path(), "*.el", None);
    limited.max_files = 2;
    assert!(!run(limited)?.truncated);
    Ok(())
}

#[test]
fn invalid_configuration_cancel_deadline_and_replaced_workspace_fail_closed() -> TestResult {
    let root = tree(&["a.el"])?;
    for pattern in ["", " ", "["] {
        assert!(matches!(
            FindFilesPlan::try_from(input(root.path(), pattern, None)),
            Err(CoreError::InvalidValue { .. })
        ));
    }
    let mut too_many = input(root.path(), "*", None);
    too_many.max_files = usize::MAX;
    assert!(matches!(
        FindFilesPlan::try_from(too_many),
        Err(CoreError::Limit)
    ));
    let cancel = CancellationToken::new();
    cancel.cancel();
    assert!(matches!(
        FindFilesPlan::try_from(input(root.path(), "*", None))?
            .execute(&cancel, Instant::now() + Duration::from_secs(1)),
        Err(CoreError::Cancelled)
    ));
    assert!(matches!(
        FindFilesPlan::try_from(input(root.path(), "*", None))?
            .execute(&CancellationToken::new(), Instant::now()),
        Err(CoreError::Deadline)
    ));
    let parent = tempfile::tempdir()?;
    let path = parent.path().join("workspace");
    fs::create_dir(&path)?;
    let plan = FindFilesPlan::try_from(input(&path, "*", None))?;
    fs::rename(&path, parent.path().join("old"))?;
    fs::create_dir(&path)?;
    assert!(matches!(
        plan.execute(
            &CancellationToken::new(),
            Instant::now() + Duration::from_secs(1)
        ),
        Err(CoreError::WorkspaceChanged)
    ));
    Ok(())
}
