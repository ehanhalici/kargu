//! Bounded Unified Diff validation/normalization; never a replacement patch engine.
//!
//! Header-like source lines are consumed in a hunk's body state. Only complete
//! file/hunk records leave parsing; Git subsequently matches and applies them
//! inside an owned isolated workspace, before any editor transaction is issued.
mod hunk;
mod path;
use crate::{
    constants::limits,
    edit::{
        EditError,
        types::{EditPath, EditText, HunkCount},
    },
};
pub use hunk::Hunk;
use serde::Serialize;
use zeroize::Zeroizing;

/// The supported operation set deliberately excludes rename, copy and modes.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum OperationKind {
    /// Create a regular file; target absence must later be verified.
    Add,
    /// Update an existing regular file or captured live document.
    Update,
    /// Delete a regular file; policy and rollback evidence are checked later.
    Delete,
}
/// One complete operation, with a lexically qualified target and actual hunks.
pub struct FileOperation {
    path: EditPath,
    kind: OperationKind,
    hunks: Vec<Hunk>,
}
impl FileOperation {
    /// The validated root-relative target; not a canonical filesystem grant.
    pub fn path(&self) -> &EditPath {
        &self.path
    }
    /// Requested file action, independent of text summaries.
    pub fn kind(&self) -> OperationKind {
        self.kind
    }
    /// Complete original hunk records, in input order.
    pub fn hunks(&self) -> &[Hunk] {
        &self.hunks
    }
    fn render(&self, output: &mut Output) -> Result<(), EditError> {
        let old = path::quote("a/", &self.path)?;
        let new = path::quote("b/", &self.path)?;
        output.line(&format!("diff --git {old} {new}"))?;
        match self.kind {
            OperationKind::Add => output.line("new file mode 100644")?,
            OperationKind::Delete => output.line("deleted file mode 100644")?,
            OperationKind::Update => {}
        }
        output.line(&format!(
            "--- {}",
            if self.kind == OperationKind::Add {
                "/dev/null"
            } else {
                &old
            }
        ))?;
        output.line(&format!(
            "+++ {}",
            if self.kind == OperationKind::Delete {
                "/dev/null"
            } else {
                &new
            }
        ))?;
        for hunk in &self.hunks {
            hunk.render(output)?;
        }
        Ok(())
    }
}
/// Complete bounded framing and normalized input for a later Git preparation.
/// This value has no apply method and is not an edit or approval capability.
pub struct UnifiedPatch {
    operations: Vec<FileOperation>,
    normalized: EditText,
    hunks: HunkCount,
}
impl UnifiedPatch {
    /// Borrow complete file operations in input order, including repeated paths.
    pub fn operations(&self) -> &[FileOperation] {
        &self.operations
    }
    /// Borrow normalized UTF-8 Git input; no caller-controlled extended header survives.
    pub fn normalized(&self) -> &str {
        self.normalized.as_str()
    }
    /// Exact parsed hunk count, never inferred from a success description.
    pub fn hunk_count(&self) -> HunkCount {
        self.hunks
    }
}
struct Output(Zeroizing<String>);
impl Output {
    fn line(&mut self, line: &str) -> Result<(), EditError> {
        self.prefixed("", line)
    }
    fn prefixed(&mut self, prefix: &str, text: &str) -> Result<(), EditError> {
        let size = self
            .0
            .len()
            .checked_add(prefix.len())
            .and_then(|n| n.checked_add(text.len()))
            .and_then(|n| n.checked_add(1))
            .ok_or(EditError::Limit)?;
        if size > limits::EDIT_TEXT_BYTES {
            return Err(EditError::Limit);
        }
        self.0.push_str(prefix);
        self.0.push_str(text);
        self.0.push('\n');
        Ok(())
    }
}
fn file(old: &str, new: &str) -> Result<FileOperation, EditError> {
    let old = path::parse(
        old.strip_prefix("--- ").ok_or(EditError::InvalidPatch)?,
        "a/",
    )?;
    let new = path::parse(
        new.strip_prefix("+++ ").ok_or(EditError::InvalidPatch)?,
        "b/",
    )?;
    let (path, kind) = match (old, new) {
        (None, Some(path)) => (path, OperationKind::Add),
        (Some(path), None) => (path, OperationKind::Delete),
        (Some(old), Some(new)) if old == new => (new, OperationKind::Update),
        (Some(_), Some(_)) => return Err(EditError::UnsupportedPatch),
        (None, None) => return Err(EditError::InvalidPatch),
    };
    Ok(FileOperation {
        path,
        kind,
        hunks: Vec::new(),
    })
}
fn metadata(line: &str) -> Result<(), EditError> {
    if line.starts_with("*** ")
        || line.starts_with("GIT binary patch")
        || line.starts_with("Binary files ")
        || [
            "rename ",
            "copy ",
            "similarity index ",
            "dissimilarity index ",
            "old mode ",
            "new mode ",
        ]
        .iter()
        .any(|prefix| line.starts_with(prefix))
    {
        return Err(EditError::UnsupportedPatch);
    }
    if line.trim().is_empty()
        || line.starts_with("diff --git ")
        || line.starts_with("index ")
        || matches!(line, "new file mode 100644" | "deleted file mode 100644")
    {
        return Ok(());
    }
    if line.starts_with("new file mode ") || line.starts_with("deleted file mode ") {
        return Err(EditError::UnsupportedPatch);
    }
    Err(EditError::InvalidPatch)
}
impl TryFrom<String> for UnifiedPatch {
    type Error = EditError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::parse(Zeroizing::new(value))
    }
}
impl TryFrom<EditText> for UnifiedPatch {
    type Error = EditError;
    fn try_from(value: EditText) -> Result<Self, EditError> {
        Self::parse(value.into_sensitive())
    }
}
impl UnifiedPatch {
    fn parse(value: Zeroizing<String>) -> Result<Self, EditError> {
        if value.len() > limits::EDIT_TEXT_BYTES {
            return Err(EditError::Limit);
        }
        if value.contains('\0') {
            return Err(EditError::InvalidPatch);
        }
        let input = Zeroizing::new(value.replace("\r\n", "\n"));
        if input.split_terminator('\n').count() > limits::EDIT_PATCH_LINES {
            return Err(EditError::Limit);
        }
        let mut lines = input.split_terminator('\n').peekable();
        let mut operations: Vec<FileOperation> = Vec::new();
        let mut hunks = HunkCount::default();
        while let Some(line) = lines.next() {
            if line.starts_with("--- ") {
                if operations.len() >= limits::EDIT_FILES {
                    return Err(EditError::Limit);
                }
                operations.push(file(line, lines.next().ok_or(EditError::InvalidPatch)?)?);
            } else if line.starts_with("@@") {
                let operation = operations.last_mut().ok_or(EditError::InvalidPatch)?;
                hunks = HunkCount::try_from(hunks.get().checked_add(1).ok_or(EditError::Limit)?)?;
                operation.hunks.push(Hunk::parse(line, &mut lines)?);
            } else {
                metadata(line)?;
            }
        }
        if operations.is_empty() {
            return Err(EditError::InvalidPatch);
        }
        let mut normalized = Output(Zeroizing::new(String::new()));
        for operation in &operations {
            operation.render(&mut normalized)?;
        }
        Ok(Self {
            operations,
            normalized: EditText::try_from(normalized.0.to_string())?,
            hunks,
        })
    }
}
