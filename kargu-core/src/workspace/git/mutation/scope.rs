//! Repo/index and literal workspace scope evidence captured before approval.

use super::{Mutation, Paths};
use crate::{error::CoreError, security::ActionSnapshot, workspace::command::Preparation};
use std::{
    collections::BTreeMap,
    ffi::OsString,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
};

pub(super) fn unborn_reference(
    directory: &Path,
    context: &Preparation,
) -> Result<String, CoreError> {
    use crate::security::file::PinnedFile;
    let path = directory.join("HEAD");
    let file = PinnedFile::open(
        &path,
        path.clone(),
        context.cancellation(),
        context.deadline(),
    )?;
    if file.size() > 4096 {
        return Err(CoreError::Limit);
    }
    let mut reader = file.reader()?;
    let mut bytes = Vec::new();
    let mut chunk = [0; 1024];
    loop {
        let count = reader.read(&mut chunk, context.cancellation(), context.deadline())?;
        if count == 0 {
            break;
        }
        if bytes.len().saturating_add(count) > 4096 {
            return Err(CoreError::Limit);
        }
        bytes.extend_from_slice(chunk.get(..count).ok_or(CoreError::Limit)?);
    }
    reader.finish()?;
    let text = std::str::from_utf8(&bytes).map_err(|_| CoreError::InvalidToolOutput)?;
    let branch = text
        .trim()
        .strip_prefix("ref: refs/heads/")
        .ok_or(CoreError::Rejected)?;
    let branch = super::Branch::try_from(branch.to_owned())?;
    Ok(format!("refs/heads/{}", branch.0))
}

pub(super) fn relative(root: &Path, path: &Path) -> Result<PathBuf, CoreError> {
    let absolute = root.join(path);
    let relative = absolute
        .strip_prefix(root)
        .map_err(|_| CoreError::Rejected)?;
    if relative
        .components()
        .any(|c| matches!(c,std::path::Component::Normal(n) if n==".git"))
    {
        return Err(CoreError::Rejected);
    }
    let mut parent = absolute.as_path();
    loop {
        match parent.canonicalize() {
            Ok(real) if real.starts_with(root) => break,
            Ok(_) => return Err(CoreError::Rejected),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                parent = parent.parent().ok_or(CoreError::Rejected)?;
            }
            Err(e) => return Err(e.into()),
        }
    }
    Ok(if relative.as_os_str().is_empty() {
        PathBuf::from(".")
    } else {
        relative.to_owned()
    })
}
pub(super) fn capture(
    root: &Path,
    directory: &Path,
    common: &Path,
    query: &Mutation,
    context: &Preparation,
) -> Result<ActionSnapshot, CoreError> {
    for dir in [directory, common] {
        crate::workspace::command::validate_path(dir)?;
        if !dir.is_absolute() || dir.canonicalize()? != dir || !dir.is_dir() {
            return Err(CoreError::Rejected);
        }
    }
    let mut roots = vec![
        root.join(".git"),
        directory.join("HEAD"),
        directory.join("index"),
        directory.join("config.worktree"),
        common.join("config"),
        common.join("packed-refs"),
        common.join("refs/heads"),
        common.join("reftable"),
    ];
    // .git can be an administrative directory. Only its identity is needed;
    // the bounded authority subset above owns content-sensitive evidence.
    if root.join(".git").is_dir() {
        roots.remove(0);
    }
    if let Mutation::Stage {
        paths: Paths(paths),
    }
    | Mutation::Unstage {
        paths: Paths(paths),
    } = query
    {
        for path in paths {
            let path = relative(root, path)?;
            if path != Path::new(".") {
                roots.push(root.join(path));
            }
        }
    }
    context.check()?;
    ActionSnapshot::capture(roots, context.cancellation(), context.deadline())
}
pub(super) fn executable(environment: &BTreeMap<OsString, OsString>) -> Result<PathBuf, CoreError> {
    let path = environment
        .get(&OsString::from("PATH"))
        .ok_or(CoreError::Unavailable)?;
    std::env::split_paths(path)
        .filter(|p| p.is_absolute())
        .map(|p| p.join("git"))
        .find(|p| {
            p.metadata()
                .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
        .ok_or(CoreError::Unavailable)
}
