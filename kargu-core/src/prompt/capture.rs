//! Bounded native file capture for project instruction files.

use super::instruction::{
    CandidateInstructionFiles, InstructionByteLimit, InstructionError, InstructionFilename,
    InstructionMetadata, InstructionSize, InstructionText, InstructionWorkspaceRoot,
    ProjectInstruction, SourceHash,
};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
};

fn verify_containment(root: &Path, file_path: &Path) -> Result<PathBuf, InstructionError> {
    let canonical_root = root
        .canonicalize()
        .map_err(|e| InstructionError::ReadError(e.to_string()))?;
    let canonical_file = file_path
        .canonicalize()
        .map_err(|e| InstructionError::ReadError(e.to_string()))?;
    if !canonical_file.starts_with(&canonical_root) {
        return Err(InstructionError::PathEscape);
    }
    Ok(canonical_file)
}

fn read_file_bounded(
    path: &Path,
    limit: InstructionByteLimit,
) -> Result<(Vec<u8>, usize), InstructionError> {
    let meta = fs::metadata(path).map_err(|e| InstructionError::ReadError(e.to_string()))?;
    if !meta.is_file() {
        return Err(InstructionError::ReadError("not a regular file".to_owned()));
    }
    let size = meta.len() as usize;
    if size > limit.get() {
        return Err(InstructionError::Oversize {
            size: InstructionSize::new(size),
            limit,
        });
    }
    let bytes = fs::read(path).map_err(|e| InstructionError::ReadError(e.to_string()))?;
    Ok((bytes, size))
}

fn try_capture_candidate(
    root: &Path,
    candidate: &InstructionFilename,
    limit: InstructionByteLimit,
) -> Result<Option<ProjectInstruction>, InstructionError> {
    let candidate_path = root.join(candidate.as_str());
    if !candidate_path.exists() {
        return Ok(None);
    }
    let canonical = verify_containment(root, &candidate_path)?;
    let (bytes, size) = read_file_bounded(&canonical, limit)?;
    let text = String::from_utf8(bytes).map_err(|_| InstructionError::InvalidUtf8)?;
    let mut hasher = Sha256::new();
    hasher.update(text.as_bytes());
    let digest: [u8; 32] = hasher.finalize().into();
    let metadata = InstructionMetadata::new(SourceHash::new(digest), InstructionSize::new(size));
    Ok(Some(ProjectInstruction::new(
        candidate.clone(),
        InstructionText::new(text),
        metadata,
    )))
}

/// Capture the first readable instruction file matching candidates in root.
pub fn capture_project_instruction(
    root: &InstructionWorkspaceRoot,
    candidates: &CandidateInstructionFiles,
    limit: InstructionByteLimit,
) -> Result<Option<ProjectInstruction>, InstructionError> {
    let root_path = root.as_path();
    if !root_path.is_dir() {
        return Err(InstructionError::NotFound);
    }
    for candidate in candidates.iter() {
        if let Some(instruction) = try_capture_candidate(root_path, candidate, limit)? {
            return Ok(Some(instruction));
        }
    }
    Ok(None)
}
