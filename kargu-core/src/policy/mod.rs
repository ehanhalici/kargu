//! Explicit tool policy: the pinned workspace, the application-owned tool
//! registry with its mode admission, and the user's approval decision.
//!
//! Pure policy values every module may consult; command capture and the
//! single-use approval grants built on them live in `security`.

use crate::{constants::limits, domain::*, error::CoreError};
use std::{
    collections::HashMap,
    fs::File,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    sync::Arc,
};

mod catalog;
pub mod schema;
pub use catalog::{ToolModes, ToolPresentation, ToolRoute};

/// Pinned directory identity used by settings and commands.
#[derive(Clone)]
pub struct Workspace {
    path: PathBuf,
    directory: Arc<File>,
}
impl TryFrom<PathBuf> for Workspace {
    type Error = CoreError;
    fn try_from(path: PathBuf) -> Result<Self, CoreError> {
        use nix::fcntl::{OFlag, open};
        use nix::sys::stat::Mode as FileMode;
        let path = path.canonicalize()?;
        // O_DIRECTORY rejects FIFOs/devices before opening for IO; O_NOFOLLOW
        // also rejects replacement of the canonical root with a symlink.
        let directory = open(
            &path,
            OFlag::O_RDONLY | OFlag::O_DIRECTORY | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
            FileMode::empty(),
        )
        .map_err(std::io::Error::from)?;
        Ok(Self {
            path,
            directory: Arc::new(File::from(directory)),
        })
    }
}
impl Workspace {
    pub(crate) fn same_capture(&self, other: &Self) -> bool {
        self.path == other.path && Arc::ptr_eq(&self.directory, &other.directory)
    }
    /// Metadata of the held directory handle, the identity a digest pins.
    pub(crate) fn held_metadata(&self) -> Result<std::fs::Metadata, CoreError> {
        Ok(self.directory.metadata()?)
    }
    /// Canonical captured directory; no fallback to the process cwd.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Compare current path identity to the held directory, before side effects.
    pub fn revalidate(&self) -> Result<(), CoreError> {
        let held = self.directory.metadata()?;
        let current = self
            .path
            .metadata()
            .map_err(|_| CoreError::WorkspaceChanged)?;
        if !current.is_dir()
            || held.dev() != current.dev()
            || held.ino() != current.ino()
            || self
                .path
                .canonicalize()
                .map_err(|_| CoreError::WorkspaceChanged)?
                != self.path
        {
            return Err(CoreError::WorkspaceChanged);
        }
        Ok(())
    }
}

/// Canonical tool metadata; callers cannot relabel a general program as read-only.
#[derive(Clone)]
pub struct ToolDescriptor {
    name: ToolName,
    safety: ToolSafetyLevel,
    presentation: Option<Arc<ToolPresentation>>,
}
impl ToolDescriptor {
    /// Canonical name after alias resolution.
    pub fn name(&self) -> &ToolName {
        &self.name
    }
    /// Actual executor's effect class.
    pub fn safety(&self) -> ToolSafetyLevel {
        self.safety
    }
    /// Immutable model/schema metadata, absent for internal-only execution helpers.
    pub fn presentation(&self) -> Option<&ToolPresentation> {
        self.presentation.as_deref()
    }
    /// Captured mode admission shared by model visibility and delegated execution.
    pub fn permits_mode(&self, mode: Mode) -> bool {
        self.presentation
            .as_ref()
            .map(|metadata| metadata.modes().permits(mode))
            .unwrap_or(self.safety == ToolSafetyLevel::SafeReadOnly || mode == Mode::Agent)
    }
}

/// Monotonic definition generation, distinct from a run's config/policy revisions.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, serde::Serialize)]
pub struct RegistryRevision(u64);
impl RegistryRevision {
    fn next(self) -> Result<Self, CoreError> {
        self.0
            .checked_add(1)
            .map(Self)
            .ok_or(CoreError::ArithmeticOverflow)
    }
    /// Exact native registry generation for a captured run or approval digest.
    pub fn get(self) -> u64 {
        self.0
    }
}

/// Explicit application-owned definitions and flattened aliases; no global registry.
#[derive(Clone, Default)]
pub struct ToolRegistry {
    definitions: HashMap<ToolName, ToolDescriptor>,
    aliases: HashMap<ToolName, ToolName>,
    revision: RegistryRevision,
}
impl ToolRegistry {
    /// Current native generation; immutable run snapshots retain this exact catalog.
    pub fn revision(&self) -> RegistryRevision {
        self.revision
    }
    /// Return sorted tool names admitted under the requested mode.
    pub fn available_tools_for_mode(&self, mode: Mode) -> Vec<ToolName> {
        let mut names: Vec<ToolName> = self
            .definitions
            .iter()
            .filter(|(_, desc)| desc.permits_mode(mode))
            .map(|(name, _)| name.clone())
            .collect();
        names.sort_by(|a, b| a.as_str().cmp(b.as_str()));
        names
    }
    /// Register a process executor atomically. Every process is arbitrary code.
    pub fn register_process(
        &mut self,
        name: ToolName,
        aliases: Vec<ToolName>,
    ) -> Result<(), CoreError> {
        self.register(name, aliases, ToolSafetyLevel::ExecutesArbitraryCode)
    }
    /// Register the closed editor executor with its actual mutation effect class.
    pub fn register_editor(
        &mut self,
        name: ToolName,
        aliases: Vec<ToolName>,
    ) -> Result<(), CoreError> {
        self.register(name, aliases, ToolSafetyLevel::MutatesState)
    }
    pub(crate) fn register_listing(&mut self) -> Result<(), CoreError> {
        self.register(
            ToolName::try_from("list_files".to_owned())?,
            vec![],
            ToolSafetyLevel::SafeReadOnly,
        )
    }
    pub(crate) fn register_grep(&mut self) -> Result<(), CoreError> {
        self.register(
            ToolName::try_from("workspace_grep".to_owned())?,
            vec![],
            ToolSafetyLevel::SafeReadOnly,
        )
    }
    pub(crate) fn register_git_status(&mut self) -> Result<(), CoreError> {
        self.register(
            ToolName::try_from("git_status".to_owned())?,
            vec![],
            ToolSafetyLevel::SafeReadOnly,
        )
    }
    pub(crate) fn register_git_reads(&mut self) -> Result<(), CoreError> {
        for name in [
            "git_log",
            "git_branches",
            "git_stashes",
            "git_diff",
            "git_blame",
            "git_mutation_prepare",
            "edit_patch_prepare",
        ] {
            self.register(
                ToolName::try_from(name.to_owned())?,
                vec![],
                ToolSafetyLevel::SafeReadOnly,
            )?;
        }
        Ok(())
    }
    pub(crate) fn register_git_mutations(&mut self) -> Result<(), CoreError> {
        for name in [
            "git_stage",
            "git_unstage",
            "git_commit",
            "git_branch",
            "git_stash",
        ] {
            self.register_process(ToolName::try_from(name.to_owned())?, vec![])?;
        }
        Ok(())
    }
    fn register(
        &mut self,
        name: ToolName,
        aliases: Vec<ToolName>,
        safety: ToolSafetyLevel,
    ) -> Result<(), CoreError> {
        if aliases.len() > limits::TOOL_DEFINITIONS
            || (!self.definitions.contains_key(&name)
                && self.definitions.len() >= limits::TOOL_DEFINITIONS)
        {
            return Err(CoreError::Limit);
        }
        if self.aliases.contains_key(&name)
            || aliases.iter().any(|alias| {
                alias != &name
                    && (self.definitions.contains_key(alias)
                        || self
                            .aliases
                            .get(alias)
                            .is_some_and(|target| target != &name))
            })
        {
            return Err(CoreError::Rejected);
        }
        let revision = self.revision.next()?;
        let new_aliases = aliases
            .iter()
            .filter(|alias| *alias != &name && !self.aliases.contains_key(*alias))
            .collect::<std::collections::HashSet<_>>()
            .len();
        if self
            .aliases
            .len()
            .checked_add(new_aliases)
            .is_none_or(|count| count > limits::TOOL_DEFINITIONS)
        {
            return Err(CoreError::Limit);
        }
        let presentation = self
            .definitions
            .get(&name)
            .filter(|descriptor| descriptor.safety == safety)
            .and_then(|descriptor| descriptor.presentation.clone());
        self.definitions.insert(
            name.clone(),
            ToolDescriptor {
                name: name.clone(),
                safety,
                presentation,
            },
        );
        for alias in aliases {
            if alias != name {
                self.aliases.insert(alias, name.clone());
            }
        }
        self.revision = revision;
        Ok(())
    }
    /// Resolve aliases to current definitions, never an old metadata snapshot.
    pub fn resolve(&self, name: &ToolName) -> Result<&ToolDescriptor, CoreError> {
        self.definitions
            .get(self.aliases.get(name).unwrap_or(name))
            .ok_or(CoreError::Unavailable)
    }
}

/// UI decision; missing UI must use Rejected, never Approved.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UserDecision {
    /// Exact captured action was approved.
    Approved,
    /// User or missing UI denied the action.
    Rejected,
}
