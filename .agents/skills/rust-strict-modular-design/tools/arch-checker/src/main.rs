//! `arch-checker [OPTIONS] [CRATE_DIR]`: enforce rust-strict-modular-design on
//! `CRATE_DIR/src`.
//!
//! The crate opts in with `CRATE_DIR/arch-checker.conf`.  Options:
//!
//! - `--baseline FILE`: known violations are allowed, but the findings must
//!   match `FILE` exactly (new findings and stale entries both fail);
//! - `--ratchet FILE`: no rule may have more baseline entries than in `FILE`
//!   (the previous commit's baseline);
//! - `--write-baseline FILE`: write the current findings as a baseline and pass.
//!
//! Exit status: 0 clean, 1 violations found, 2 the check itself could not run.

mod analyze;
mod baseline;
mod config;
mod finding;
mod nesting;
mod sources;
mod types;

use std::{
    collections::BTreeSet,
    io::Write,
    path::{Path, PathBuf},
    process::ExitCode,
};

type Failure = Box<dyn std::error::Error>;

/// Parsed command line.
#[derive(Default)]
struct Options {
    root: Option<PathBuf>,
    baseline: Option<PathBuf>,
    ratchet: Option<PathBuf>,
    write_baseline: Option<PathBuf>,
}

fn main() -> ExitCode {
    match options().and_then(|options| execute(&options)) {
        Ok(code) => code,
        Err(error) => {
            let _ = writeln!(std::io::stderr(), "arch-checker: {error}");
            ExitCode::from(2)
        }
    }
}

fn options() -> Result<Options, Failure> {
    let mut options = Options::default();
    let mut args = std::env::args_os().skip(1);
    while let Some(arg) = args.next() {
        let mut value = || args.next().map(PathBuf::from).ok_or("option needs a FILE");
        match arg.to_str() {
            Some("--baseline") => options.baseline = Some(value()?),
            Some("--ratchet") => options.ratchet = Some(value()?),
            Some("--write-baseline") => options.write_baseline = Some(value()?),
            Some(flag) if flag.starts_with("--") => {
                return Err(format!("unknown option {flag}").into());
            }
            _ if options.root.is_none() => options.root = Some(PathBuf::from(arg)),
            _ => return Err("more than one CRATE_DIR".into()),
        }
    }
    Ok(options)
}

fn execute(options: &Options) -> Result<ExitCode, Failure> {
    let root = options.root.clone().unwrap_or_else(|| PathBuf::from("."));
    let findings = run(&root)?;
    if let Some(path) = &options.write_baseline {
        std::fs::write(path, baseline::render(&findings))
            .map_err(|error| format!("{}: {error}", path.display()))?;
        return Ok(ExitCode::SUCCESS);
    }
    let Some(path) = &options.baseline else {
        return Ok(report(&findings));
    };
    let known = baseline::parse(&read(path)?);
    let previous = options
        .ratchet
        .as_deref()
        .map(read)
        .transpose()?
        .map(|text| baseline::parse(&text));
    Ok(report_against(&findings, &known, previous.as_deref()))
}

fn read(path: &Path) -> Result<String, Failure> {
    std::fs::read_to_string(path).map_err(|error| format!("{}: {error}", path.display()).into())
}

/// Load the contract and sources, then apply every rule.
fn run(root: &Path) -> Result<Vec<finding::Finding>, Failure> {
    let text = read(&root.join("arch-checker.conf"))?;
    let config = config::Config::parse(&text)?;
    let mut sources = sources::load(root)?;
    let tests: Vec<String> = sources
        .iter()
        .flat_map(|source| analyze::test_module_files(source.path(), source.syntax()))
        .collect();
    sources.retain(|source| {
        !tests.iter().any(|test| {
            source.path() == test
                || (test.ends_with('/') && source.path().starts_with(test.as_str()))
        })
    });
    let newtypes: BTreeSet<String> = sources
        .iter()
        .flat_map(|source| analyze::newtypes(source.syntax()))
        .collect();
    Ok(sources
        .iter()
        .flat_map(|source| analyze::check(source.path(), source.syntax(), &config, &newtypes))
        .collect())
}

/// Print findings and turn them into the exit status.
fn report(findings: &[finding::Finding]) -> ExitCode {
    let mut stderr = std::io::stderr();
    for finding in findings {
        let _ = writeln!(stderr, "{finding}");
    }
    if findings.is_empty() {
        return ExitCode::SUCCESS;
    }
    let rules: BTreeSet<&str> = findings.iter().map(|finding| finding.rule().id()).collect();
    let _ = writeln!(
        stderr,
        "arch-checker: {} violation(s) of: {}",
        findings.len(),
        rules.into_iter().collect::<Vec<_>>().join(", ")
    );
    ExitCode::FAILURE
}

/// Print what differs from the baseline and turn it into the exit status.
fn report_against(
    findings: &[finding::Finding],
    known: &[String],
    previous: Option<&[String]>,
) -> ExitCode {
    let mut stderr = std::io::stderr();
    let comparison = baseline::compare(findings, known);
    for finding in comparison.new_findings() {
        let _ = writeln!(stderr, "{finding}");
    }
    for key in comparison.stale() {
        let _ = writeln!(stderr, "stale baseline entry (fixed? delete it): {key}");
    }
    let growth = previous
        .map(|old| baseline::growth(known, old))
        .unwrap_or_default();
    for grown in &growth {
        let _ = writeln!(stderr, "{grown}");
    }
    let failed = !comparison.new_findings().is_empty()
        || !comparison.stale().is_empty()
        || !growth.is_empty();
    let _ = writeln!(
        stderr,
        "arch-checker: {} new, {} stale, {} baselined",
        comparison.new_findings().len(),
        comparison.stale().len(),
        known.len().saturating_sub(comparison.stale().len())
    );
    if failed {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}
