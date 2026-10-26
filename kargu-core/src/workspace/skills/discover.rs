//! Metadata-first bounded traversal and pinned regular-file captures.

use super::{Skill, SkillInput, SkillResult, metadata, render};
use crate::{
    constants::limits,
    error::CoreError,
    security::{
        Workspace,
        file::{PinnedFile, checkpoint},
    },
};
use nix::{
    fcntl::{OFlag, open, openat},
    sys::stat::Mode,
};
use std::{
    collections::{HashSet, VecDeque},
    fs::{self, File},
    os::fd::AsRawFd,
    path::{Component, Path, PathBuf},
    time::Instant,
};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

const PROJECT_DIRS: [&str; 5] = [
    "skills",
    "skill",
    ".agents/skills",
    ".claude/skills",
    ".codex/skills",
];
struct EntryCount(usize);
struct DirectoryCount(usize);
struct SourceBytes(usize);
struct AssetCount(usize);
#[derive(Clone, Copy)]
struct Depth(usize);
struct Directory {
    path: PathBuf,
    held: File,
}
impl Directory {
    fn root(path: &Path) -> Result<Self, CoreError> {
        let mut directory = Self {
            path: PathBuf::from("/"),
            held: File::from(
                open(Path::new("/"), directory_flags(), Mode::empty())
                    .map_err(std::io::Error::from)?,
            ),
        };
        for component in path.components() {
            if let Component::Normal(name) = component {
                directory = directory.child(Path::new(name))?;
            }
        }
        Ok(directory)
    }
    fn child(&self, name: &Path) -> Result<Self, CoreError> {
        Ok(Self {
            path: self.path.join(name),
            held: File::from(
                openat(&self.held, name, directory_flags(), Mode::empty())
                    .map_err(std::io::Error::from)?,
            ),
        })
    }
    fn nested(&self, path: &Path) -> Result<Self, CoreError> {
        let mut directory = Self {
            path: self.path.clone(),
            held: self.held.try_clone()?,
        };
        for component in path.components() {
            if let Component::Normal(name) = component {
                directory = directory.child(Path::new(name))?;
            }
        }
        Ok(directory)
    }
}
fn directory_flags() -> OFlag {
    OFlag::O_RDONLY | OFlag::O_DIRECTORY | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC
}

struct Discovery<'a> {
    input: &'a SkillInput,
    project_root: &'a Path,
    cancel: &'a CancellationToken,
    deadline: Instant,
    entries: EntryCount,
    directories: DirectoryCount,
    source_bytes: SourceBytes,
    seen: HashSet<PathBuf>,
    names: HashSet<String>,
    skills: Vec<Skill>,
    truncated: bool,
    skipped: usize,
}
impl Discovery<'_> {
    fn capture(&mut self, path: &Path) -> Result<(), CoreError> {
        checkpoint(self.cancel, self.deadline)?;
        if !self.seen.insert(path.to_owned()) {
            return Ok(());
        }
        if self.skills.len() >= limits::SKILL_RECORDS {
            self.truncated = true;
            return Ok(());
        }
        match self.read(path) {
            Ok(skill) => {
                if self.names.insert(skill.metadata.name.clone()) {
                    self.skills.push(skill);
                }
            }
            Err(CoreError::Cancelled) => return Err(CoreError::Cancelled),
            Err(CoreError::Deadline) => return Err(CoreError::Deadline),
            Err(CoreError::WorkspaceChanged) => return Err(CoreError::WorkspaceChanged),
            Err(CoreError::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => self.skipped = self.skipped.saturating_add(1),
        }
        Ok(())
    }
    fn read(&mut self, path: &Path) -> Result<Skill, CoreError> {
        // Reject discovered symlinks, including aliases back into a granted root.
        let meta = fs::symlink_metadata(path)?;
        if !meta.is_file() {
            return Err(CoreError::Rejected);
        }
        if meta.len() > self.input.max_file_bytes.0 as u64 {
            return Err(CoreError::Limit);
        }
        let size = usize::try_from(meta.len()).map_err(|_| CoreError::Limit)?;
        if self.source_bytes.0.saturating_add(size) > limits::SKILL_SOURCE_BYTES {
            self.truncated = true;
            return Err(CoreError::Limit);
        }
        // Reserve before reading, including invalid/duplicate metadata.
        self.source_bytes.0 = self.source_bytes.0.saturating_add(size);
        let file = PinnedFile::open(path, path.to_owned(), self.cancel, self.deadline)?;
        if file.size() != meta.len() {
            return Err(CoreError::WorkspaceChanged);
        }
        let mut reader = file.reader()?;
        let mut bytes = Zeroizing::new(Vec::with_capacity(size));
        let mut chunk = Zeroizing::new([0u8; 4096]);
        loop {
            let count = reader.read(chunk.as_mut(), self.cancel, self.deadline)?;
            if count == 0 {
                break;
            }
            if bytes.len().saturating_add(count) > size {
                return Err(CoreError::WorkspaceChanged);
            }
            bytes.extend_from_slice(chunk.get(..count).ok_or(CoreError::Limit)?);
        }
        reader.finish()?;
        let text = std::str::from_utf8(&bytes).map_err(|_| CoreError::InvalidValue {
            field: "SkillEncoding",
        })?;
        metadata::parse(text, path)
    }
    fn scan(
        &mut self,
        root: Directory,
        ordinary_file_limit: usize,
        all_skills: bool,
    ) -> Result<(), CoreError> {
        let mut queue = VecDeque::from([(PathBuf::new(), Depth(0))]);
        let mut files = AssetCount(0);
        while let Some((relative, depth)) = queue.pop_front() {
            checkpoint(self.cancel, self.deadline)?;
            if self.directories.0 >= self.input.max_directories.0
                || self.entries.0 >= limits::SEARCH_ENTRIES
            {
                self.truncated = true;
                break;
            }
            self.directories.0 = self.directories.0.saturating_add(1);
            let directory = match root.nested(&relative) {
                Ok(directory) => directory,
                Err(_) => {
                    self.skipped = self.skipped.saturating_add(1);
                    continue;
                }
            };
            if all_skills || self.relevant(&directory.path) {
                self.capture(&directory.path.join("SKILL.md"))?;
            }
            let children = self.children(&directory, depth, queue.len(), &mut files)?;
            self.capture_children(&directory, &children, all_skills)?;
            if files.0 >= ordinary_file_limit {
                self.truncated = true;
                break;
            }
            for name in children {
                queue.push_back((relative.join(name), Depth(depth.0.saturating_add(1))));
            }
        }
        Ok(())
    }
    fn children(
        &mut self,
        directory: &Directory,
        depth: Depth,
        queued: usize,
        files: &mut AssetCount,
    ) -> Result<Vec<std::ffi::OsString>, CoreError> {
        let entries = fs::read_dir(format!("/proc/self/fd/{}", directory.held.as_raw_fd()))?;
        let mut children = Vec::new();
        for entry in entries {
            checkpoint(self.cancel, self.deadline)?;
            if self.entries.0 >= limits::SEARCH_ENTRIES {
                self.truncated = true;
                break;
            }
            self.entries.0 = self.entries.0.saturating_add(1);
            let entry = entry?;
            let kind = entry.file_type()?;
            if kind.is_dir()
                && !self
                    .input
                    .skip_directories
                    .iter()
                    .any(|name| entry.file_name() == name.as_str())
            {
                if depth.0 >= limits::SEARCH_DEPTH
                    || children
                        .len()
                        .saturating_add(queued)
                        .saturating_add(self.directories.0)
                        >= self.input.max_directories.0
                {
                    self.truncated = true;
                    continue;
                }
                children.push(entry.file_name());
            } else if kind.is_file() && entry.file_name() != "SKILL.md" {
                files.0 = files.0.saturating_add(1);
            }
        }
        children.sort();
        Ok(children)
    }
    fn capture_children(
        &mut self,
        directory: &Directory,
        children: &[std::ffi::OsString],
        all_skills: bool,
    ) -> Result<(), CoreError> {
        // Immediate metadata is inspected before descending into any assets.
        for name in children {
            let path = directory.path.join(name);
            if all_skills || self.relevant(&path) {
                self.capture(&path.join("SKILL.md"))?;
            }
        }
        Ok(())
    }
    fn relevant(&self, path: &Path) -> bool {
        path.strip_prefix(self.project_root).is_ok_and(|relative| {
            relative.components().any(
                |c| matches!(c, Component::Normal(name) if name == "skills" || name == "skill"),
            )
        })
    }
}

pub(super) fn execute(
    input: SkillInput,
    cancel: &CancellationToken,
    deadline: Instant,
) -> Result<SkillResult, CoreError> {
    checkpoint(cancel, deadline)?;
    let workspace = Workspace::try_from(input.root.0.clone())?;
    let project = Directory::root(workspace.path())?;
    let mut discovery = Discovery {
        input: &input,
        project_root: workspace.path(),
        cancel,
        deadline,
        entries: EntryCount(0),
        directories: DirectoryCount(0),
        source_bytes: SourceBytes(0),
        seen: HashSet::new(),
        names: HashSet::new(),
        skills: Vec::new(),
        truncated: false,
        skipped: 0,
    };
    for relative in PROJECT_DIRS {
        if Path::new(relative).components().any(|part| matches!(part, Component::Normal(name) if input.skip_directories.iter().any(|skip| name == skip.as_str()))) { continue; }
        match project.nested(Path::new(relative)) {
            Ok(directory) => discovery.scan(directory, limits::SKILL_PROJECT_ASSETS, true)?,
            Err(CoreError::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => discovery.skipped = discovery.skipped.saturating_add(1),
        }
    }
    discovery.scan(project, limits::SKILL_PROJECT_ASSETS, false)?;
    let user = if let Some(root) = &input.user_root {
        match Workspace::try_from(root.0.clone()) {
            Ok(user) => {
                discovery.scan(
                    Directory::root(user.path())?,
                    limits::SKILL_USER_ASSETS,
                    true,
                )?;
                Some(user)
            }
            Err(CoreError::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => return Err(error),
        }
    } else {
        None
    };
    workspace.revalidate()?;
    if let Some(user) = user {
        user.revalidate()?;
    }
    checkpoint(cancel, deadline)?;
    render(
        discovery.skills,
        &input,
        discovery.truncated,
        discovery.skipped,
    )
}
