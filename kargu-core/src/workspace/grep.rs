//! Fixed-argv rg/GNU grep composition; regex and file glob matching remain external.

use super::command;
use crate::{
    application::{Mode, RunSettings},
    constants::limits,
    domain::{
        CapturePolicy, ConfigRevision, OutputLimit, PolicyRevision, RecordLimit, SuccessCodes,
        ToolCallLimit,
    },
    error::CoreError,
    security::{CommandEnvironment, CommandInput, CommandSpec, Workspace},
};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    ffi::OsString,
    path::{Component, Path, PathBuf},
};

/// Search request, never an arbitrary program/argv or effect-class override.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GrepInput {
    root: PathBuf,
    path: Option<PathBuf>,
    pattern: SearchPattern,
    glob: Option<SearchPattern>,
    max_matches: MatchLimit,
    skip_directories: Vec<String>,
    #[serde(default)]
    output_bytes: OutputLimit,
    #[serde(default)]
    timeout_ms: command::ReadTimeout,
}

/// Nonempty bounded regex/glob expression, interpreted only by the Unix tool.
#[derive(Deserialize)]
#[serde(try_from = "String")]
struct SearchPattern(String);
impl TryFrom<String> for SearchPattern {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        if value.is_empty() || value.len() > limits::SEARCH_PATTERN_BYTES || value.contains('\0') {
            return Err(CoreError::InvalidValue {
                field: "SearchPattern",
            });
        }
        Ok(Self(value))
    }
}

/// Global reported hit count; distinct from the extra captured lookahead record.
#[derive(Clone, Copy, Deserialize)]
#[serde(try_from = "u64")]
struct MatchLimit(u64);
impl TryFrom<u64> for MatchLimit {
    type Error = CoreError;
    fn try_from(value: u64) -> Result<Self, CoreError> {
        if value == 0 || value >= limits::PROCESS_RECORDS {
            return Err(CoreError::InvalidValue {
                field: "MatchLimit",
            });
        }
        Ok(Self(value))
    }
}
impl MatchLimit {
    fn probe(self) -> Result<RecordLimit, CoreError> {
        RecordLimit::try_from(self.0.checked_add(1).ok_or(CoreError::ArithmeticOverflow)?)
    }
}

/// Immutable reporting context captured with the executable action, not reparsed argv.
pub(crate) struct GrepReport {
    pattern: SearchPattern,
    limit: MatchLimit,
    pub(crate) output_limit: OutputLimit,
}
impl GrepReport {
    pub(crate) fn text(&self, stdout: &str) -> Result<String, CoreError> {
        if stdout.trim().is_empty() {
            return Ok(format!("No matches for {:?}", self.pattern.0));
        }
        let count = usize::try_from(self.limit.0).map_err(|_| CoreError::ArithmeticOverflow)?;
        let mut records = stdout.split_terminator('\n');
        let mut text = records.by_ref().take(count).collect::<Vec<_>>().join("\n");
        if records.next().is_some() {
            text.push_str(
                "\n... (additional hits omitted; raise max_matches or narrow the search)",
            );
        } else {
            text.push('\n');
        }
        Ok(text)
    }
}

impl GrepInput {
    pub(crate) fn prepare(self) -> Result<(CommandSpec, RunSettings, GrepReport), CoreError> {
        let path = self.path.as_deref().unwrap_or(Path::new("."));
        for input in [&self.root, path] {
            if input.as_os_str().len() > limits::SEARCH_PATH_BYTES
                || input.components().any(|c| c == Component::ParentDir)
            {
                return Err(CoreError::Rejected);
            }
        }
        if !self.root.is_absolute() {
            return Err(CoreError::Rejected);
        }
        let exclusions = command::exclusions(self.skip_directories)?;
        let workspace = Workspace::try_from(self.root)?;
        let target = workspace.path().join(path).canonicalize()?;
        if !target.starts_with(workspace.path()) {
            return Err(CoreError::Rejected);
        }
        let metadata = target.metadata()?;
        if !(metadata.is_dir() || metadata.is_file()) {
            return Err(CoreError::Rejected);
        }
        let (program, mut args): (_, Vec<OsString>) = match command::executable("rg") {
            Ok(program) => {
                let mut args: Vec<_> = [
                    "-n",
                    "-H",
                    "--no-heading",
                    "--color=never",
                    "--line-buffered",
                    "--no-config",
                ]
                .into_iter()
                .map(OsString::from)
                .collect();
                if let Some(glob) = self.glob {
                    args.extend(["--glob".into(), glob.0.into()]);
                }
                for name in exclusions {
                    args.extend(["--glob".into(), format!("!**/{name}/**").into()]);
                }
                (program, args)
            }
            Err(CoreError::Unavailable) => {
                let mut args: Vec<_> = ["-r", "-n", "-H", "-I", "--line-buffered"]
                    .into_iter()
                    .map(OsString::from)
                    .collect();
                for name in exclusions {
                    args.push(format!("--exclude-dir={name}").into());
                }
                if let Some(glob) = self.glob {
                    // Preserve the old GNU fallback's basename-only include semantics.
                    args.push(
                        format!("--include={}", glob.0.rsplit('/').next().unwrap_or(&glob.0))
                            .into(),
                    );
                }
                (command::executable("grep")?, args)
            }
            Err(error) => return Err(error),
        };
        args.extend([
            OsString::from("--"),
            OsString::from(&self.pattern.0),
            target.as_os_str().to_os_string(),
        ]);
        let timeout = self.timeout_ms.duration();
        let command = CommandSpec::workspace_grep(CommandInput {
            program,
            arguments: args,
            working_directory: workspace.path().to_path_buf(),
            timeout,
            environment: CommandEnvironment::try_from(BTreeMap::from([(
                "LC_ALL".into(),
                "C".into(),
            )]))?,
        })?
        .with_read_target(target)?
        .with_capture(CapturePolicy::Records(self.max_matches.probe()?))
        .with_success_codes(SuccessCodes::ZeroOrOne)
        .with_output_limit(self.output_bytes);
        let settings = match timeout {
            Some(timeout) => RunSettings::new(
                Mode::Ask,
                workspace,
                ToolCallLimit::default(),
                timeout,
                ConfigRevision::ZERO,
                PolicyRevision::ZERO,
            )?,
            None => RunSettings::persistent(
                Mode::Ask,
                workspace,
                ToolCallLimit::default(),
                ConfigRevision::ZERO,
                PolicyRevision::ZERO,
            ),
        };
        Ok((
            command,
            settings,
            GrepReport {
                pattern: self.pattern,
                limit: self.max_matches,
                output_limit: self.output_bytes,
            },
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::constants::timeouts;
    use serde_json::json;

    #[test]
    fn built_in_capture_is_fixed_argv_without_per_file_limit_or_implicit_environment()
    -> Result<(), Box<dyn std::error::Error>> {
        let root = tempfile::tempdir()?;
        let input: GrepInput = serde_json::from_value(json!({
            "root":root.path(),"path":null,"pattern":"-needle;$(touch injected)",
            "glob":"**/*.el","max_matches":3,"skip_directories":["node_modules"]
        }))?;
        let (command, _, report) = input.prepare()?;
        assert_eq!(command.timeout.duration(), Some(timeouts::WORKSPACE_READ));
        assert_eq!(command.capture.records().map(RecordLimit::as_u64), Some(4));
        assert_eq!(command.environment.entries().count(), 1);
        assert!(command.arguments.iter().any(|arg| arg == "--line-buffered"));
        assert!(!command.arguments.iter().any(|arg| arg == "--max-count"));
        let mut arguments = command.arguments.iter().rev();
        assert_eq!(
            arguments.next(),
            Some(&root.path().as_os_str().to_os_string())
        );
        assert_eq!(
            arguments.next(),
            Some(&OsString::from("-needle;$(touch injected)"))
        );
        assert_eq!(arguments.next(), Some(&OsString::from("--")));
        assert_eq!(
            report.text("a:1:x\nb:1:x\nc:1:x\nd:1:x\n")?.lines().count(),
            4
        );
        assert!(report.text("a:1:x\nb:1:x\nc:1:x\n")?.ends_with("c:1:x\n"));
        assert!(!root.path().join("injected").exists());
        Ok(())
    }

    #[test]
    fn omitted_timeout_is_bounded_but_explicit_null_remains_unlimited()
    -> Result<(), Box<dyn std::error::Error>> {
        let unlimited: command::ReadTimeout = serde_json::from_value(serde_json::Value::Null)?;
        assert_eq!(unlimited.duration(), None);
        assert_eq!(
            command::ReadTimeout::default().duration(),
            Some(timeouts::WORKSPACE_READ)
        );
        Ok(())
    }
}
