//! Owned Git metadata view; original executable configuration is never reopened.

use super::super::command::Preparation;
use crate::{
    error::CoreError,
    security::{CommandSpec, ReadTarget, Workspace, file::PinnedFile},
};
use std::{
    fs,
    path::{Path, PathBuf},
};
use tempfile::TempDir;
use zeroize::Zeroizing;

enum ObjectFormat {
    Sha1,
    Sha256,
}
enum RefFormat {
    Files,
    Reftable,
}
pub(super) struct Layout {
    directory: Workspace,
    common: Workspace,
    object_format: ObjectFormat,
    ref_format: RefFormat,
    evidence: Vec<ReadTarget>,
}
impl TryFrom<&[u8]> for Layout {
    type Error = CoreError;
    fn try_from(bytes: &[u8]) -> Result<Self, CoreError> {
        let mut lines = std::str::from_utf8(bytes)
            .map_err(|_| CoreError::InvalidToolOutput)?
            .lines();
        let directory = administrative_directory(lines.next())?;
        let common = administrative_directory(lines.next())?;
        let object_format = match lines.next() {
            Some("sha1") => ObjectFormat::Sha1,
            Some("sha256") => ObjectFormat::Sha256,
            _ => return Err(CoreError::InvalidToolOutput),
        };
        let ref_format = match lines.next() {
            Some("files") => RefFormat::Files,
            Some("reftable") => RefFormat::Reftable,
            _ => return Err(CoreError::InvalidToolOutput),
        };
        if lines.next().is_some() {
            return Err(CoreError::InvalidToolOutput);
        }
        let evidence = vec![
            ReadTarget::try_from(directory.path().to_owned())?,
            ReadTarget::try_from(common.path().to_owned())?,
        ];
        directory.revalidate()?;
        common.revalidate()?;
        Ok(Self {
            directory,
            common,
            object_format,
            ref_format,
            evidence,
        })
    }
}
fn administrative_directory(value: Option<&str>) -> Result<Workspace, CoreError> {
    let path = PathBuf::from(value.ok_or(CoreError::InvalidToolOutput)?);
    super::super::command::validate_path(&path)?;
    if !path.is_absolute() {
        return Err(CoreError::InvalidToolOutput);
    }
    Workspace::try_from(path)
}

enum ConfigSection {
    Core,
    Diff,
    Status,
}
struct SafeKey {
    section: ConfigSection,
    name: &'static str,
}
impl TryFrom<&str> for SafeKey {
    type Error = CoreError;
    fn try_from(value: &str) -> Result<Self, CoreError> {
        let (section, name) = match value {
            "core.autocrlf" => (ConfigSection::Core, "autocrlf"),
            "core.eol" => (ConfigSection::Core, "eol"),
            "core.safecrlf" => (ConfigSection::Core, "safecrlf"),
            "core.filemode" => (ConfigSection::Core, "filemode"),
            "core.ignorecase" => (ConfigSection::Core, "ignorecase"),
            "core.symlinks" => (ConfigSection::Core, "symlinks"),
            "core.precomposeunicode" => (ConfigSection::Core, "precomposeunicode"),
            "core.excludesfile" => (ConfigSection::Core, "excludesfile"),
            "core.attributesfile" => (ConfigSection::Core, "attributesfile"),
            "core.checkroundtripencoding" => (ConfigSection::Core, "checkroundtripencoding"),
            "diff.algorithm" => (ConfigSection::Diff, "algorithm"),
            "diff.renames" => (ConfigSection::Diff, "renames"),
            "diff.renamelimit" => (ConfigSection::Diff, "renamelimit"),
            "status.showuntrackedfiles" => (ConfigSection::Status, "showuntrackedfiles"),
            _ => return Err(CoreError::InvalidToolOutput),
        };
        Ok(Self { section, name })
    }
}
struct ConfigValue(Zeroizing<String>);
impl TryFrom<&str> for ConfigValue {
    type Error = CoreError;
    fn try_from(value: &str) -> Result<Self, CoreError> {
        if value.len() > 4096 || value.contains(['\0', '\r']) {
            return Err(CoreError::InvalidToolOutput);
        }
        Ok(Self(Zeroizing::new(value.to_owned())))
    }
}
/// Matches exactly the SafeKey domain, not arbitrary repository config entries.
pub(super) const CONFIG_KEYS: &str = "^(core\\.(autocrlf|eol|safecrlf|filemode|ignorecase|symlinks|precomposeunicode|excludesfile|attributesfile|checkroundtripencoding)|diff\\.(algorithm|renames|renamelimit)|status\\.showuntrackedfiles)$";
pub(super) struct SafeConfig(Vec<(SafeKey, ConfigValue)>);
impl TryFrom<&[u8]> for SafeConfig {
    type Error = CoreError;
    fn try_from(bytes: &[u8]) -> Result<Self, CoreError> {
        if bytes.is_empty() {
            return Ok(Self(vec![]));
        }
        let bytes = bytes
            .strip_suffix(&[0])
            .ok_or(CoreError::InvalidToolOutput)?;
        let mut fields = Vec::new();
        for record in bytes.split(|byte| *byte == 0) {
            if fields.len() >= 64 {
                return Err(CoreError::Limit);
            }
            let record = std::str::from_utf8(record).map_err(|_| CoreError::InvalidToolOutput)?;
            let (key, value) = record
                .split_once('\n')
                .ok_or(CoreError::InvalidToolOutput)?;
            fields.push((SafeKey::try_from(key)?, ConfigValue::try_from(value)?));
        }
        Ok(Self(fields))
    }
}
impl SafeConfig {
    fn render(&self, layout: &Layout) -> Zeroizing<String> {
        let object = match layout.object_format {
            ObjectFormat::Sha1 => "sha1",
            ObjectFormat::Sha256 => "sha256",
        };
        let references = match layout.ref_format {
            RefFormat::Files => "files",
            RefFormat::Reftable => "reftable",
        };
        let mut text = Zeroizing::new(format!(
            "[core]\nrepositoryformatversion = 1\nbare = false\n[extensions]\nobjectformat = {object}\nrefstorage = {references}\n"
        ));
        for (key, value) in &self.0 {
            let section = match key.section {
                ConfigSection::Core => "core",
                ConfigSection::Diff => "diff",
                ConfigSection::Status => "status",
            };
            text.push_str(&format!("[{section}]\n{} = \"", key.name));
            for character in value.0.chars() {
                match character {
                    '\n' => text.push_str("\\n"),
                    '\t' => text.push_str("\\t"),
                    '\u{8}' => text.push_str("\\b"),
                    '"' => text.push_str("\\\""),
                    '\\' => text.push_str("\\\\"),
                    other => text.push(other),
                }
            }
            text.push_str("\"\n");
        }
        text
    }
}

pub(super) struct CapturedProfile {
    directory: TempDir,
    common: PathBuf,
    worktree: PathBuf,
    index: PathBuf,
    evidence: Vec<ReadTarget>,
}
pub(crate) struct PreparedProfile {
    directory: Option<TempDir>,
}
pub(crate) struct RunningProfile {
    directory: Option<TempDir>,
}
impl CapturedProfile {
    pub(super) fn capture(
        layout: &Layout,
        config: SafeConfig,
        preparation: &Preparation,
    ) -> Result<Self, CoreError> {
        preparation.check()?;
        layout.directory.revalidate()?;
        layout.common.revalidate()?;
        let directory = tempfile::Builder::new()
            .prefix("kargu-git-read-")
            .tempdir()?;
        let common = directory.path().join("common");
        let worktree = directory.path().join("worktree");
        fs::create_dir(&common)?;
        fs::create_dir(&worktree)?;
        fs::write(worktree.join("commondir"), "../common\n")?;
        fs::write(common.join("config"), config.render(layout).as_bytes())?;
        for entry in ["objects", "refs", "packed-refs", "shallow", "reftable"] {
            preparation.check()?;
            std::os::unix::fs::symlink(layout.common.path().join(entry), common.join(entry))?;
        }
        fs::create_dir(common.join("info"))?;
        for entry in ["attributes", "exclude", "grafts"] {
            std::os::unix::fs::symlink(
                layout.common.path().join("info").join(entry),
                common.join("info").join(entry),
            )?;
        }
        for entry in ["refs", "reftable"] {
            std::os::unix::fs::symlink(layout.directory.path().join(entry), worktree.join(entry))?;
        }
        let head = layout.directory.path().join("HEAD");
        // Do not silently turn legacy symlink HEAD into detached HEAD.
        if fs::symlink_metadata(&head)?.is_symlink() {
            return Err(CoreError::Unavailable);
        }
        let captured = PinnedFile::open(
            &head,
            head.canonicalize()?,
            preparation.cancellation(),
            preparation.deadline(),
        )?;
        if captured.size() > 4096 {
            return Err(CoreError::Limit);
        }
        let mut reader = captured.reader()?;
        let mut bytes = Zeroizing::new(Vec::new());
        let mut chunk = Zeroizing::new([0u8; 512]);
        loop {
            let count = reader.read(
                chunk.as_mut(),
                preparation.cancellation(),
                preparation.deadline(),
            )?;
            if count == 0 {
                break;
            }
            if bytes.len().saturating_add(count) > 4096 {
                return Err(CoreError::Limit);
            }
            bytes.extend_from_slice(chunk.get(..count).ok_or(CoreError::Limit)?);
        }
        reader.finish()?;
        fs::write(worktree.join("HEAD"), bytes.as_slice())?;
        layout.directory.revalidate()?;
        layout.common.revalidate()?;
        preparation.check()?;
        Ok(Self {
            directory,
            common,
            worktree,
            index: layout.directory.path().join("index"),
            evidence: layout
                .evidence
                .iter()
                .map(ReadTarget::duplicate)
                .collect::<Result<_, _>>()?,
        })
    }
    pub(super) fn common(&self) -> &Path {
        &self.common
    }
    pub(super) fn worktree(&self) -> &Path {
        &self.worktree
    }
    pub(super) fn index(&self) -> &Path {
        &self.index
    }
    pub(super) fn bind(&self, mut command: CommandSpec) -> Result<CommandSpec, CoreError> {
        for evidence in &self.evidence {
            command = command.with_target_evidence(evidence.duplicate()?)?;
        }
        command.with_snapshot_target(self.common.join("config"))
    }
    pub(super) fn prepared(self) -> PreparedProfile {
        PreparedProfile {
            directory: Some(self.directory),
        }
    }
}
impl PreparedProfile {
    pub(super) fn issued(mut self) -> RunningProfile {
        RunningProfile {
            directory: self.directory.take(),
        }
    }
    pub(super) fn discard(mut self) -> Result<(), CoreError> {
        self.directory
            .take()
            .ok_or(CoreError::CleanupFailed)?
            .close()
            .map_err(|_| CoreError::CleanupFailed)
    }
}
impl Drop for PreparedProfile {
    fn drop(&mut self) {
        // Normal aborts explicitly join discard() off-mailbox. Unexpected actor
        // abandonment must not block its mailbox or unlink an uncertain view.
        if let Some(directory) = self.directory.take() {
            let _ = directory.keep();
        }
    }
}
impl RunningProfile {
    pub(super) fn finish(mut self, cleanup_complete: bool) -> Result<(), CoreError> {
        if !cleanup_complete {
            return Err(CoreError::CleanupFailed);
        }
        self.directory
            .take()
            .ok_or(CoreError::CleanupFailed)?
            .close()
            .map_err(|_| CoreError::CleanupFailed)
    }
}
impl Drop for RunningProfile {
    fn drop(&mut self) {
        // An abandoned/uncertain running child may still use these paths.
        // Only explicit successful drain is allowed to unlink its metadata.
        if let Some(directory) = self.directory.take() {
            let _ = directory.keep();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    type TestResult = Result<(), Box<dyn std::error::Error>>;
    #[test]
    fn configuration_capture_is_closed_bounded_and_escapes_values_not_commands() -> TestResult {
        for bytes in [
            b"filter.evil.clean\ncommand\0".as_slice(),
            b"core.excludesfile\npath",
            b"core.excludesfile\npath\r\0",
            b"core.excludesfile\npath\0extra\0",
        ] {
            assert!(SafeConfig::try_from(bytes).is_err());
        }
        let root = tempfile::tempdir()?;
        let layout = Layout {
            directory: Workspace::try_from(root.path().to_owned())?,
            common: Workspace::try_from(root.path().to_owned())?,
            object_format: ObjectFormat::Sha256,
            ref_format: RefFormat::Reftable,
            evidence: vec![],
        };
        let config = SafeConfig::try_from(
            b"core.excludesfile\nline\n[filter \"evil\"]\nclean=execute\\path\0".as_slice(),
        )?;
        let rendered = config.render(&layout);
        assert!(
            rendered.contains(
                "excludesfile = \"line\\n[filter \\\"evil\\\"]\\nclean=execute\\\\path\""
            )
        );
        assert!(!rendered.contains("\n[filter"));
        let oversized = format!("core.excludesfile\n{}\0", "x".repeat(4097));
        assert!(SafeConfig::try_from(oversized.as_bytes()).is_err());
        let repeated = "core.eol\nlf\0".repeat(65);
        assert!(SafeConfig::try_from(repeated.as_bytes()).is_err());
        Ok(())
    }
    #[test]
    fn only_a_confirmed_drain_can_remove_issued_private_metadata() -> TestResult {
        let directory = tempfile::tempdir()?;
        let path = directory.path().to_owned();
        PreparedProfile {
            directory: Some(directory),
        }
        .discard()?;
        assert!(
            !path.exists(),
            "a confirmed no-spawn abort releases its prepared view"
        );
        for confirmed in [false, true] {
            let directory = tempfile::tempdir()?;
            let path = directory.path().to_owned();
            fs::write(path.join("owned-metadata"), "fixture")?;
            let profile = RunningProfile {
                directory: Some(directory),
            };
            let result = profile.finish(confirmed);
            if confirmed {
                result?;
                assert!(!path.exists());
            } else {
                assert!(matches!(result, Err(CoreError::CleanupFailed)));
                assert!(path.exists());
                fs::remove_dir_all(&path)?;
            }
        }
        let directory = tempfile::tempdir()?;
        let path = directory.path().to_owned();
        drop(RunningProfile {
            directory: Some(directory),
        });
        assert!(path.exists());
        fs::remove_dir(&path)?;
        Ok(())
    }
}
