//! Bounded porcelain-v1 presentation, not repository/index/diff mechanics.

use crate::error::CoreError;
use std::path::PathBuf;

pub(crate) struct StatusReport {
    root: PathBuf,
}
impl StatusReport {
    pub(super) fn new(root: PathBuf) -> Self {
        Self { root }
    }
    pub(crate) fn text(&self, stdout: &str) -> Result<String, CoreError> {
        let complete = stdout.strip_suffix('\0').ok_or(invalid())?;
        let mut records = complete.split('\0');
        let header = records
            .next()
            .and_then(|header| header.strip_prefix("## "))
            .ok_or(invalid())?;
        if header.is_empty() || header.chars().any(char::is_control) {
            return Err(invalid());
        }
        let branch = header.split("...").next().ok_or(invalid())?;
        let branch = branch.split(" [").next().ok_or(invalid())?;
        let branch = if branch.starts_with("HEAD (no branch)") {
            "HEAD (detached)"
        } else {
            branch
        };
        let mut text = format!("Head:     {branch}\n");
        if header.contains('[') {
            text.push_str(&format!("Tracking: ## {header}\n"));
        }
        text.push_str(&format!(
            "Root:     {}\n\n",
            display(&self.root.to_string_lossy())
        ));
        let mut sections = Sections::default();
        while let Some(record) = records.next() {
            let state = State::try_from(record.get(..2).ok_or(invalid())?)?;
            if record.as_bytes().get(2) != Some(&b' ') {
                return Err(invalid());
            }
            let path = record
                .get(3..)
                .filter(|path| !path.is_empty())
                .ok_or(invalid())?;
            let old_path = if state.renamed() {
                Some(
                    records
                        .next()
                        .filter(|path| !path.is_empty())
                        .ok_or(invalid())?,
                )
            } else {
                None
            };
            let entry = Entry { path, old_path };
            sections.push(state, entry);
        }
        for (index, (name, entries)) in [
            ("Staged changes", sections.staged),
            ("Unstaged changes", sections.unstaged),
            ("Untracked files", sections.untracked),
            ("Merge conflicts", sections.conflicts),
        ]
        .into_iter()
        .enumerate()
        {
            if index != 0 {
                text.push('\n');
            }
            text.push_str(&format!("{name} ({}):\n", entries.len()));
            if entries.is_empty() {
                text.push_str("  (none)\n");
            }
            for (status, entry) in entries {
                text.push_str("  ");
                if !status.is_empty() {
                    text.push_str(status);
                    text.push(' ');
                }
                if let Some(old) = entry.old_path {
                    text.push_str(&display(old));
                    text.push_str(" -> ");
                }
                text.push_str(&display(entry.path));
                text.push('\n');
            }
        }
        Ok(text)
    }
}

fn invalid() -> CoreError {
    CoreError::InvalidToolOutput
}
fn display(path: &str) -> String {
    if path
        .chars()
        .any(|c| c.is_control() || matches!(c, '"' | '\\'))
    {
        format!("{path:?}")
    } else {
        path.to_owned()
    }
}

#[derive(Clone, Copy)]
enum Change {
    Modified,
    TypeChanged,
    Added,
    Deleted,
    Renamed,
    Copied,
}
impl Change {
    fn parse(value: u8) -> Result<Option<Self>, CoreError> {
        Ok(match value {
            b' ' => None,
            b'M' => Some(Self::Modified),
            b'T' => Some(Self::TypeChanged),
            b'A' => Some(Self::Added),
            b'D' => Some(Self::Deleted),
            b'R' => Some(Self::Renamed),
            b'C' => Some(Self::Copied),
            _ => return Err(invalid()),
        })
    }
    fn text(self) -> &'static str {
        match self {
            Self::Modified => "M",
            Self::TypeChanged => "T",
            Self::Added => "A",
            Self::Deleted => "D",
            Self::Renamed => "R",
            Self::Copied => "C",
        }
    }
}
enum Conflict {
    BothDeleted,
    AddedByUs,
    DeletedByThem,
    AddedByThem,
    DeletedByUs,
    BothAdded,
    BothModified,
}
impl Conflict {
    fn text(self) -> &'static str {
        match self {
            Self::BothDeleted => "DD",
            Self::AddedByUs => "AU",
            Self::DeletedByThem => "UD",
            Self::AddedByThem => "UA",
            Self::DeletedByUs => "DU",
            Self::BothAdded => "AA",
            Self::BothModified => "UU",
        }
    }
}
enum State {
    Untracked,
    Conflict(Conflict),
    Tracked {
        index: Option<Change>,
        worktree: Option<Change>,
    },
}
impl TryFrom<&str> for State {
    type Error = CoreError;
    fn try_from(value: &str) -> Result<Self, CoreError> {
        match value {
            "??" => Ok(Self::Untracked),
            "DD" => Ok(Self::Conflict(Conflict::BothDeleted)),
            "AU" => Ok(Self::Conflict(Conflict::AddedByUs)),
            "UD" => Ok(Self::Conflict(Conflict::DeletedByThem)),
            "UA" => Ok(Self::Conflict(Conflict::AddedByThem)),
            "DU" => Ok(Self::Conflict(Conflict::DeletedByUs)),
            "AA" => Ok(Self::Conflict(Conflict::BothAdded)),
            "UU" => Ok(Self::Conflict(Conflict::BothModified)),
            _ => {
                let mut bytes = value.bytes();
                let index = Change::parse(bytes.next().ok_or(invalid())?)?;
                let worktree = Change::parse(bytes.next().ok_or(invalid())?)?;
                if bytes.next().is_some() || (index.is_none() && worktree.is_none()) {
                    return Err(invalid());
                }
                Ok(Self::Tracked { index, worktree })
            }
        }
    }
}
impl State {
    fn renamed(&self) -> bool {
        matches!(
            self,
            Self::Tracked {
                index: Some(Change::Renamed | Change::Copied),
                ..
            } | Self::Tracked {
                worktree: Some(Change::Renamed | Change::Copied),
                ..
            }
        )
    }
}
#[derive(Clone, Copy)]
struct Entry<'a> {
    path: &'a str,
    old_path: Option<&'a str>,
}
#[derive(Default)]
struct Sections<'a> {
    staged: Vec<(&'static str, Entry<'a>)>,
    unstaged: Vec<(&'static str, Entry<'a>)>,
    untracked: Vec<(&'static str, Entry<'a>)>,
    conflicts: Vec<(&'static str, Entry<'a>)>,
}
impl<'a> Sections<'a> {
    fn push(&mut self, state: State, entry: Entry<'a>) {
        match state {
            State::Untracked => self.untracked.push(("", entry)),
            State::Conflict(code) => self.conflicts.push((code.text(), entry)),
            State::Tracked { index, worktree } => {
                if let Some(change) = index {
                    self.staged.push((change.text(), entry));
                }
                if let Some(change) = worktree {
                    self.unstaged.push((change.text(), entry));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn report() -> StatusReport {
        StatusReport::new(PathBuf::from("/fixture"))
    }

    #[test]
    fn nul_paths_rename_source_conflicts_and_double_modified_keep_their_sections()
    -> Result<(), CoreError> {
        let text = report().text("## main\0??  leading ünicode\nfile.txt \0R  renamed.txt\0original -> file.txt\0UU conflict.txt\0?? after-rename.txt\0MM both.txt\0")?;
        assert!(text.contains("Untracked files (2)"));
        assert!(text.contains("\" leading ünicode\\nfile.txt \""));
        assert!(text.contains("R original -> file.txt -> renamed.txt"));
        assert!(text.contains("Staged changes (2)"));
        assert!(text.contains("Unstaged changes (1)"));
        assert!(text.contains("Merge conflicts (1):\n  UU conflict.txt"));
        assert_eq!(text.matches("M both.txt").count(), 2);
        Ok(())
    }

    #[test]
    fn incomplete_or_malformed_output_is_never_a_partial_success() {
        for text in [
            "",
            "## main",
            "## \0",
            "## main\0?? file",
            "## main\0R  dest\0",
            "## main\0ZZ file\0",
            "## main\0??file\0",
            "## main\0?? \0",
            "## main\0\0",
            "## main\nforged\0",
        ] {
            assert!(
                matches!(report().text(text), Err(CoreError::InvalidToolOutput)),
                "accepted malformed records {text:?}"
            );
        }
    }

    #[test]
    fn branch_tracking_detached_and_unborn_headers_preserve_presentation() -> Result<(), CoreError>
    {
        assert!(
            report()
                .text("## main...origin/main [ahead 1]\0")?
                .starts_with("Head:     main\nTracking: ## main...origin/main [ahead 1]\n")
        );
        assert!(
            report()
                .text("## HEAD (no branch)\0")?
                .starts_with("Head:     HEAD (detached)\n")
        );
        assert!(
            report()
                .text("## No commits yet on main\0")?
                .starts_with("Head:     No commits yet on main\n")
        );
        Ok(())
    }
}
