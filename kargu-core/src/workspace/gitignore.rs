//! Repository ignore rules for editor-facing discovery.
//!
//! Applies `.gitignore` files met during a walk and the repository's
//! `.git/info/exclude`, when the workspace root is itself a Git repository
//! or a subdirectory of one. Machine-global Git configuration
//! (`core.excludesFile`) is never read, and no `git` process runs.
//! Oversized or malformed ignore files are skipped rather than failing discovery.

use ignore::gitignore::{Gitignore, GitignoreBuilder};
use std::{
    fs,
    path::{Path, PathBuf},
};

/// Largest ignore file that is parsed.
const MAX_IGNORE_FILE_BYTES: u64 = 256 * 1024;
/// Largest `.git` pointer file (submodule / worktree) parsed.
const MAX_GIT_FILE_BYTES: u64 = 4096;
/// Maximum directory levels to traverse upward looking for a repository root.
const MAX_ANCESTOR_WALK_DEPTH: usize = 32;

/// Location of a repository enclosing a workspace.
struct RepoRoot {
    worktree_root: PathBuf,
    git_dir: PathBuf,
}

/// Whether a discovered path stays visible.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Visibility {
    /// No rule hides it.
    Shown,
    /// An ignore rule hides it (and, for a directory, everything below).
    Ignored,
}

/// Ignore rules of the directories currently open in a walk, outermost first.
pub(crate) struct IgnoreStack {
    levels: Vec<Option<Gitignore>>,
}

impl IgnoreStack {
    /// No rules at all: discovery behaves as before.
    pub(crate) fn disabled() -> Self {
        Self { levels: Vec::new() }
    }

    /// Rules for a walk starting at `target` inside the workspace `root`; empty
    /// unless `root` is inside a Git repository.
    pub(crate) fn for_walk(root: &Path, target: &Path) -> Option<Self> {
        let repo = find_repo_root(root)?;
        let ancestors = collect_ancestors(&repo.worktree_root, root)?;
        let mut stack = Self { levels: Vec::new() };
        for (idx, dir) in ancestors.iter().enumerate() {
            let mut builder = GitignoreBuilder::new(dir);
            if idx == 0 {
                add_file(&mut builder, &repo.git_dir.join("info/exclude"));
            }
            add_file(&mut builder, &dir.join(".gitignore"));
            stack.levels.push(builder.build().ok());
        }
        if target != root {
            push_target_ancestors(&mut stack, root, target);
        }
        Some(stack)
    }

    /// Open `directory`, loading its own `.gitignore` when the stack is active.
    pub(crate) fn enter(&mut self, directory: &Path) {
        if self.levels.is_empty() {
            return;
        }
        let mut builder = GitignoreBuilder::new(directory);
        add_file(&mut builder, &directory.join(".gitignore"));
        self.levels.push(builder.build().ok());
    }

    /// Close the innermost open directory.
    pub(crate) fn leave(&mut self) {
        self.levels.pop();
    }

    /// The deepest rule that matches `path` decides; no rule shows it.
    pub(crate) fn visibility(&self, path: &Path, kind: &fs::FileType) -> Visibility {
        let decided = self
            .levels
            .iter()
            .rev()
            .flatten()
            .map(|rules| rules.matched(path, kind.is_dir()))
            .find(|found| !found.is_none());
        match decided {
            Some(found) if found.is_ignore() => Visibility::Ignored,
            _ => Visibility::Shown,
        }
    }
}

fn push_target_ancestors(stack: &mut IgnoreStack, root: &Path, target: &Path) {
    if let Some(chain) = collect_ancestors(root, target) {
        for dir in chain.iter().skip(1) {
            let mut builder = GitignoreBuilder::new(dir);
            add_file(&mut builder, &dir.join(".gitignore"));
            stack.levels.push(builder.build().ok());
        }
    }
}

/// Find repository root enclosing `root`, searching up to `MAX_ANCESTOR_WALK_DEPTH` levels.
fn find_repo_root(root: &Path) -> Option<RepoRoot> {
    let mut current = root.to_path_buf();
    for _ in 0..MAX_ANCESTOR_WALK_DEPTH {
        if let Some(repo) = check_git_root(&current) {
            return Some(repo);
        }
        let parent = current.parent()?.to_path_buf();
        current = parent;
    }
    None
}

/// Check whether `dir` is a git repository root (either `.git` directory or valid gitfile).
fn check_git_root(dir: &Path) -> Option<RepoRoot> {
    let git_path = dir.join(".git");
    let meta = fs::symlink_metadata(&git_path).ok()?;
    if meta.is_dir() && has_git_markers(&git_path) {
        return Some(RepoRoot {
            worktree_root: dir.to_path_buf(),
            git_dir: git_path,
        });
    }
    if meta.is_file() && meta.len() <= MAX_GIT_FILE_BYTES {
        return parse_gitfile(dir, &git_path);
    }
    None
}

fn has_git_markers(target: &Path) -> bool {
    fs::symlink_metadata(target.join("HEAD")).is_ok()
        || fs::symlink_metadata(target.join("config")).is_ok()
        || fs::symlink_metadata(target.join("info")).is_ok()
        || fs::symlink_metadata(target.join("objects")).is_ok()
        || fs::symlink_metadata(target.join("refs")).is_ok()
}

/// Parse a `.git` file (`gitdir: <path>`) and verify its target directory.
fn parse_gitfile(dir: &Path, git_file: &Path) -> Option<RepoRoot> {
    let content = fs::read_to_string(git_file).ok()?;
    let line = content.lines().next()?;
    let path_str = line.strip_prefix("gitdir:")?.trim();
    if path_str.is_empty() {
        return None;
    }
    let target = dir.join(path_str);
    let meta = fs::metadata(&target).ok()?;
    if !meta.is_dir() || !has_git_markers(&target) {
        return None;
    }
    Some(RepoRoot {
        worktree_root: dir.to_path_buf(),
        git_dir: target,
    })
}

/// Collect sequence of paths from `base` down to `leaf`.
fn collect_ancestors(base: &Path, leaf: &Path) -> Option<Vec<PathBuf>> {
    let rel = leaf.strip_prefix(base).ok()?;
    let mut chain = vec![base.to_path_buf()];
    let mut current = base.to_path_buf();
    for component in rel.components() {
        current.push(component);
        chain.push(current.clone());
    }
    Some(chain)
}

/// Add one regular, bounded ignore file; anything else is skipped.
fn add_file(builder: &mut GitignoreBuilder, path: &Path) {
    let readable = fs::symlink_metadata(path)
        .is_ok_and(|meta| meta.is_file() && meta.len() <= MAX_IGNORE_FILE_BYTES);
    if readable {
        // A parse error leaves the rules read so far; discovery continues.
        let _ = builder.add(path);
    }
}
