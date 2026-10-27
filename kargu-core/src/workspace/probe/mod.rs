//! Bounded declarative discovery. No executable is run or installed.
mod toolchain;
use crate::{
    constants::limits,
    error::CoreError,
    security::{Workspace, file::checkpoint},
    workspace::search::{FindFilesInput, FindFilesPlan},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    time::Instant,
};
use tokio_util::sync::CancellationToken;
macro_rules! scan_limit {
    ($name:ident, $max:expr) => {
        #[derive(Deserialize, Clone, Copy)]
        #[serde(try_from = "usize")]
        struct $name(usize);
        impl TryFrom<usize> for $name {
            type Error = CoreError;
            fn try_from(value: usize) -> Result<Self, CoreError> {
                if value > $max {
                    return Err(CoreError::Limit);
                }
                Ok(Self(value))
            }
        }
    };
}
scan_limit!(FileVisitLimit, limits::SEARCH_FILES);
scan_limit!(DirectoryVisitLimit, limits::SEARCH_DIRECTORIES);

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Condition {
    Path {
        path: PathBuf,
    },
    Extension {
        extensions: Vec<String>,
        #[serde(default)]
        recursive: bool,
    },
    Any {
        items: Vec<Condition>,
    },
    All {
        items: Vec<Condition>,
    },
}
#[derive(Deserialize, Serialize, Clone, Default)]
#[serde(deny_unknown_fields)]
struct Commands {
    build_cmd: Option<String>,
    test_cmd: Option<String>,
    lint_cmd: Option<String>,
    notes: Option<String>,
}
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Toolchain {
    Static {
        commands: Commands,
    },
    Javascript {
        #[serde(default)]
        typescript: bool,
    },
    Java {},
    Elisp {},
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Profile {
    #[serde(default)]
    fallback: bool,
    id: String,
    name: String,
    priority: i32,
    detectors: Vec<Condition>,
    toolchain: Toolchain,
}
#[derive(Deserialize)]
#[serde(try_from = "ProbeDto")]
pub(crate) struct ProbeInput(ProbeDto);
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProbeDto {
    root: PathBuf,
    profiles: Vec<Profile>,
    executables: Vec<String>,
    search_path: Vec<PathBuf>,
    skip_directories: Vec<String>,
    max_files: FileVisitLimit,
    max_directories: DirectoryVisitLimit,
}
impl TryFrom<ProbeDto> for ProbeInput {
    type Error = CoreError;
    fn try_from(d: ProbeDto) -> Result<Self, CoreError> {
        super::command::validate_path(&d.root)?;
        if !d.root.is_absolute()
            || d.profiles.len() > 64
            || d.executables.len() > 256
            || d.search_path.len() > 128
        {
            return Err(CoreError::Limit);
        }
        super::command::exclusions(d.skip_directories.clone())?;
        for p in &d.search_path {
            super::command::validate_path(p)?;
            if !p.is_absolute() {
                return Err(CoreError::Rejected);
            }
        }
        for exe in &d.executables {
            if exe.is_empty() || exe.len() > 4096 || exe.contains('\0') {
                return Err(CoreError::Rejected);
            }
        }
        let mut count = 0usize;
        let mut ids = std::collections::BTreeSet::new();
        for profile in &d.profiles {
            if !ids.insert(&profile.id) {
                return Err(CoreError::Rejected);
            }
            if profile.id.is_empty()
                || profile.id.len() > 128
                || profile.name.len() > 256
                || profile.id.contains('\0')
                || profile.name.contains('\0')
            {
                return Err(CoreError::Limit);
            }
            for c in &profile.detectors {
                validate(c, 0, &mut count)?;
            }
            if let Toolchain::Static { commands } = &profile.toolchain {
                for v in [
                    &commands.build_cmd,
                    &commands.test_cmd,
                    &commands.lint_cmd,
                    &commands.notes,
                ]
                .into_iter()
                .flatten()
                {
                    if v.len() > 8192 || v.contains('\0') {
                        return Err(CoreError::Limit);
                    }
                }
            }
        }
        Ok(Self(d))
    }
}
fn validate(c: &Condition, depth: usize, count: &mut usize) -> Result<(), CoreError> {
    *count = count.saturating_add(1);
    if depth > 8 || *count > 512 {
        return Err(CoreError::Limit);
    }
    match c {
        Condition::Path { path } => {
            super::command::validate_path(path)?;
            if path.is_absolute() || path.as_os_str().is_empty() {
                return Err(CoreError::Rejected);
            }
        }
        Condition::Extension { extensions, .. } => {
            if extensions.len() > 32
                || extensions.iter().any(|s| {
                    s.is_empty()
                        || s.len() > 32
                        || !s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                })
            {
                return Err(CoreError::Rejected);
            }
        }
        Condition::Any { items } | Condition::All { items } => {
            for item in items {
                validate(item, depth.saturating_add(1), count)?;
            }
        }
    }
    Ok(())
}
pub(super) struct Probe<'a> {
    input: &'a ProbeDto,
    root: &'a Path,
    cancel: &'a CancellationToken,
    deadline: Instant,
    complete: bool,
}
impl Probe<'_> {
    fn exists(&self, path: &str) -> bool {
        self.path_exists(Path::new(path))
    }
    fn path_exists(&self, path: &Path) -> bool {
        let file = self.root.join(path);
        file.canonicalize()
            .is_ok_and(|p| p.starts_with(self.root) && (p.is_file() || p.is_dir()))
    }
    fn condition(&mut self, condition: &Condition) -> Result<bool, CoreError> {
        checkpoint(self.cancel, self.deadline)?;
        match condition {
            Condition::Path { path } => Ok(self.path_exists(path)),
            Condition::Any { items } => {
                for c in items {
                    if self.condition(c)? {
                        return Ok(true);
                    }
                }
                Ok(false)
            }
            Condition::All { items } => {
                for c in items {
                    if !self.condition(c)? {
                        return Ok(false);
                    }
                }
                Ok(true)
            }
            Condition::Extension {
                extensions,
                recursive,
            } => {
                if !recursive {
                    for (index, entry) in std::fs::read_dir(self.root)?.enumerate() {
                        checkpoint(self.cancel, self.deadline)?;
                        if index >= self.input.max_files.0 {
                            self.complete = false;
                            return Ok(false);
                        }
                        let e = entry?;
                        if e.file_type()?.is_file()
                            && e.path()
                                .extension()
                                .and_then(|s| s.to_str())
                                .is_some_and(|s| extensions.iter().any(|ext| ext == s))
                        {
                            return Ok(true);
                        }
                    }
                    return Ok(false);
                }
                for ext in extensions {
                    let result = FindFilesPlan::try_from(FindFilesInput {
                        root: self.root.to_owned(),
                        path: None,
                        pattern: format!("*.{ext}"),
                        skip_directories: self.input.skip_directories.clone(),
                        max_files: self.input.max_files.0,
                        max_directories: self.input.max_directories.0,
                    })?
                    .execute(self.cancel, self.deadline)?;
                    if !result.files.is_empty() {
                        return Ok(true);
                    }
                    if result.truncated {
                        self.complete = false;
                    }
                }
                Ok(false)
            }
        }
    }
}
#[derive(Serialize)]
pub(crate) struct ProbeResult {
    text: String,
    language: Option<String>,
    language_name: Option<String>,
    toolchains: BTreeMap<String, Commands>,
    executables: BTreeMap<String, bool>,
    complete: bool,
    package_manager: String,
}
impl ProbeInput {
    pub(crate) fn execute(
        self,
        cancel: &CancellationToken,
        deadline: Instant,
    ) -> Result<ProbeResult, CoreError> {
        checkpoint(cancel, deadline)?;
        let mut input = self.0;
        let workspace = Workspace::try_from(input.root.clone())?;
        input.profiles.sort_by(|a, b| {
            a.fallback
                .cmp(&b.fallback)
                .then(b.priority.cmp(&a.priority))
                .then(a.id.cmp(&b.id))
        });
        let mut probe = Probe {
            input: &input,
            root: workspace.path(),
            cancel,
            deadline,
            complete: true,
        };
        let mut language = None;
        let mut toolchains = BTreeMap::new();
        for profile in &input.profiles {
            checkpoint(cancel, deadline)?;
            if language.is_none() {
                for detector in &profile.detectors {
                    if probe.condition(detector)? {
                        language = Some(profile.id.clone());
                        break;
                    }
                }
            }
            toolchains.insert(
                profile.id.clone(),
                toolchain::commands(&profile.toolchain, &mut probe)?,
            );
        }
        let mut executables = BTreeMap::new();
        for name in &input.executables {
            checkpoint(cancel, deadline)?;
            let found = if Path::new(name).is_absolute() {
                is_executable(Path::new(name))
            } else if name.contains('/') {
                false
            } else {
                input
                    .search_path
                    .iter()
                    .any(|p| is_executable(&p.join(name)))
            };
            executables.insert(name.clone(), found);
        }
        workspace.revalidate()?;
        checkpoint(cancel, deadline)?;
        let language_name = language
            .as_ref()
            .and_then(|id| input.profiles.iter().find(|p| &p.id == id))
            .map(|p| p.name.clone());
        Ok(ProbeResult {
            language_name,
            text: String::new(),
            language,
            toolchains,
            executables,
            complete: probe.complete,
            package_manager: toolchain::manager(&probe).into(),
        })
    }
}
fn is_executable(path: &Path) -> bool {
    path.metadata().is_ok_and(|m| m.is_file())
        && nix::unistd::access(path, nix::unistd::AccessFlags::X_OK).is_ok()
}
