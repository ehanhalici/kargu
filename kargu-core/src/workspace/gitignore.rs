//! Repository ignore rules for editor-facing discovery.
//!
//! Applies `.gitignore` files met during a walk and the repository's
//! `.git/info/exclude`, only when the workspace root is itself a Git
//! repository. Machine-global Git configuration (`core.excludesFile`) is never
//! read, and no `git` process runs. Oversized or malformed ignore files are
//! skipped rather than failing discovery.

use ignore::gitignore::{Gitignore, GitignoreBuilder};
use std::{fs, path::Path};

/// Largest ignore file that is parsed.
const MAX_IGNORE_FILE_BYTES: u64 = 256 * 1024;

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
    /// unless `root` is a Git repository.
    pub(crate) fn for_walk(root: &Path, target: &Path) -> Option<Self> {
        if !fs::symlink_metadata(root.join(".git")).is_ok_and(|meta| meta.is_dir()) {
            return None;
        }
        let mut stack = Self { levels: Vec::new() };
        let mut builder = GitignoreBuilder::new(target);
        add_file(&mut builder, &root.join(".git/info/exclude"));
        add_file(&mut builder, &target.join(".gitignore"));
        stack.levels.push(builder.build().ok());
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

/// Add one regular, bounded ignore file; anything else is skipped.
fn add_file(builder: &mut GitignoreBuilder, path: &Path) {
    let readable = fs::symlink_metadata(path)
        .is_ok_and(|meta| meta.is_file() && meta.len() <= MAX_IGNORE_FILE_BYTES);
    if readable {
        // A parse error leaves the rules read so far; discovery continues.
        let _ = builder.add(path);
    }
}
