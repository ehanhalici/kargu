//! Run the real binary on fixtures: every rule fires where expected, and
//! nothing fires where the skill allows it.

use std::{
    ffi::OsStr,
    path::{Path, PathBuf},
    process::Command,
};

type TestResult = Result<(), Box<dyn std::error::Error>>;

fn run(fixture: &str) -> Result<(Option<i32>, String), Box<dyn std::error::Error>> {
    run_with(fixture, &[])
}

fn run_with(
    fixture: &str,
    options: &[&std::ffi::OsStr],
) -> Result<(Option<i32>, String), Box<dyn std::error::Error>> {
    // Read at run time: a cached test binary must not remember an old checkout.
    let manifest = std::env::var("CARGO_MANIFEST_DIR")?;
    let dir = Path::new(&manifest).join("tests/fixtures").join(fixture);
    let output = Command::new(env!("CARGO_BIN_EXE_arch-checker"))
        .args(options)
        .arg(dir)
        .output()?;
    Ok((output.status.code(), String::from_utf8(output.stderr)?))
}

fn scratch(name: &str) -> PathBuf {
    Path::new(env!("CARGO_TARGET_TMPDIR")).join(name)
}

/// Write the `violations` baseline to `name` and return its path and lines.
fn violations_baseline(name: &str) -> Result<(PathBuf, String), Box<dyn std::error::Error>> {
    let path = scratch(name);
    let (status, _) = run_with(
        "violations",
        &[OsStr::new("--write-baseline"), path.as_os_str()],
    )?;
    assert_eq!(status, Some(0));
    let text = std::fs::read_to_string(&path)?;
    Ok((path, text))
}

fn expect_line(report: &str, location: &str, rule: &str) {
    let needle = format!("{location} [{rule}]");
    assert!(
        report.lines().any(|line| line.starts_with(&needle)),
        "missing `{needle}` in:\n{report}"
    );
}

#[test]
fn every_rule_fires_at_its_location() -> TestResult {
    let (status, report) = run("violations")?;
    assert_eq!(status, Some(1));
    let expected = [
        ("src/domain.rs:1:1", "impure-dependency"),
        ("src/domain.rs:2:1", "glob-reexport"),
        ("src/domain.rs:5:5", "pub-field"),
        ("src/domain.rs:8:20", "pub-field"),
        ("src/domain.rs:10:1", "global-state"),
        ("src/domain.rs:14:8", "primitive-boundary"),
        ("src/domain.rs:18:8", "unit-return"),
        ("src/domain.rs:23:13", "impure-dependency"),
        ("src/domain.rs:24:5", "impure-dependency"),
        ("src/domain.rs:29:11", "panic"),
        ("src/domain.rs:33:5", "panic"),
        ("src/domain.rs:36:8", "too-many-statements"),
        ("src/domain.rs:36:8", "too-many-parameters"),
        ("src/domain.rs:43:8", "too-deep"),
        ("src/domain.rs:55:1", "impure-dependency"),
        ("src/domain.rs:58:5", "impure-dependency"),
        ("src/domain.rs:65:10", "impure-dependency"),
        ("src/worker.rs:1:8", "primitive-boundary"),
    ];
    for (location, rule) in expected {
        expect_line(&report, location, rule);
    }
    assert!(
        !report.contains("src/worker.rs:2"),
        "shell module may perform effects:\n{report}"
    );
    assert!(
        !report.contains("src/edge.rs"),
        "edge module must allow primitives:\n{report}"
    );
    Ok(())
}

#[test]
fn allowed_patterns_stay_clean() -> TestResult {
    let (status, report) = run("allowed")?;
    assert_eq!(status, Some(0), "{report}");
    assert!(report.is_empty(), "{report}");
    Ok(())
}

#[test]
fn reference_crate_is_clean() -> TestResult {
    let (status, report) = run("../../../../examples/order-billing")?;
    assert_eq!(status, Some(0), "{report}");
    Ok(())
}

#[test]
fn missing_contract_is_an_error_not_a_pass() -> TestResult {
    let (status, report) = run("does-not-exist")?;
    assert_eq!(status, Some(2));
    assert!(report.contains("arch-checker.conf"), "{report}");
    Ok(())
}

#[test]
fn exact_baseline_passes() -> TestResult {
    let (path, text) = violations_baseline("exact.baseline")?;
    assert!(
        !text.contains(":1:"),
        "keys must not carry locations:\n{text}"
    );
    let (status, report) = run_with("violations", &[OsStr::new("--baseline"), path.as_os_str()])?;
    assert_eq!(status, Some(0), "{report}");
    assert!(report.contains("0 new, 0 stale"), "{report}");
    Ok(())
}

#[test]
fn finding_outside_baseline_fails() -> TestResult {
    let (path, text) = violations_baseline("short.baseline")?;
    let kept: Vec<&str> = text
        .lines()
        .filter(|line| !line.starts_with("panic\t"))
        .collect();
    std::fs::write(&path, kept.join("\n"))?;
    let (status, report) = run_with("violations", &[OsStr::new("--baseline"), path.as_os_str()])?;
    assert_eq!(status, Some(1), "{report}");
    expect_line(&report, "src/domain.rs:29:11", "panic");
    Ok(())
}

#[test]
fn stale_baseline_entry_fails() -> TestResult {
    let (path, mut text) = violations_baseline("stale.baseline")?;
    text.push_str("pub-field\tsrc/gone.rs\tfixed long ago\n");
    std::fs::write(&path, text)?;
    let (status, report) = run_with("violations", &[OsStr::new("--baseline"), path.as_os_str()])?;
    assert_eq!(status, Some(1), "{report}");
    assert!(report.contains("stale baseline entry"), "{report}");
    Ok(())
}

#[test]
fn ratchet_rejects_a_grown_baseline() -> TestResult {
    let (path, text) = violations_baseline("grown.baseline")?;
    let previous = scratch("previous.baseline");
    let kept: Vec<&str> = text
        .lines()
        .filter(|line| !line.starts_with("panic\t"))
        .collect();
    std::fs::write(&previous, kept.join("\n"))?;
    let options = [
        OsStr::new("--baseline"),
        path.as_os_str(),
        OsStr::new("--ratchet"),
        previous.as_os_str(),
    ];
    let (status, report) = run_with("violations", &options)?;
    assert_eq!(status, Some(1), "{report}");
    assert!(
        report.contains("[panic] baseline grew from 0 to 2"),
        "{report}"
    );
    let (status, report) = run_with(
        "violations",
        &[
            OsStr::new("--baseline"),
            path.as_os_str(),
            OsStr::new("--ratchet"),
            path.as_os_str(),
        ],
    )?;
    assert_eq!(status, Some(0), "{report}");
    Ok(())
}
