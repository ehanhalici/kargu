//! Native session storage layout: the editor names a choice, never a directory.
//!
//! A request carries the project root and the editor's environment facts; the
//! storage directory is derived here, so no request path alone grants a write
//! location. This module is pure; `storage::resolve_location` performs the IO.

use crate::error::CoreError;
use serde::Deserialize;
use sha1::{Digest, Sha1};
use std::path::{Component, Path, PathBuf};

const MAX_PATH_BYTES: usize = 4096;

/// Absolute path without parent components, as received from the editor.
#[derive(Clone, Debug, Eq, PartialEq)]
struct AbsolutePath(PathBuf);

impl TryFrom<PathBuf> for AbsolutePath {
    type Error = &'static str;

    fn try_from(path: PathBuf) -> Result<Self, Self::Error> {
        let bounded = path.as_os_str().len() <= MAX_PATH_BYTES;
        let plain = !path
            .components()
            .any(|component| component == Component::ParentDir);
        if path.is_absolute() && bounded && plain {
            Ok(Self(path))
        } else {
            Err("storage paths must be bounded absolute paths")
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum LocationKind {
    Central,
    Project,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawStorageLocation {
    location: LocationKind,
    project_root: PathBuf,
    #[serde(default)]
    xdg_data_home: Option<PathBuf>,
    #[serde(default)]
    user_emacs_directory: Option<PathBuf>,
    /// The user's explicitly configured central directory, when customized.
    #[serde(default)]
    sessions_directory: Option<PathBuf>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum Base {
    /// Data home under which `kargu/sessions/<project-key>` lives.
    Central(AbsolutePath),
    /// Explicit user grant under which `<project-key>` lives.
    Granted(AbsolutePath),
    /// `<project>/.kargu/sessions`.
    Project,
}

/// Parsed storage choice for one project; resolved to a directory on the worker.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(try_from = "RawStorageLocation")]
pub struct StorageLocation {
    project_root: AbsolutePath,
    base: Base,
}

impl TryFrom<RawStorageLocation> for StorageLocation {
    type Error = &'static str;

    fn try_from(raw: RawStorageLocation) -> Result<Self, Self::Error> {
        let project_root = AbsolutePath::try_from(raw.project_root)?;
        let base = match raw.location {
            LocationKind::Project if raw.sessions_directory.is_none() => Base::Project,
            LocationKind::Project => return Err("project storage takes no central directory"),
            LocationKind::Central => central_base(
                raw.sessions_directory,
                raw.xdg_data_home,
                raw.user_emacs_directory,
            )?,
        };
        Ok(Self { project_root, base })
    }
}

/// Explicit grant first, else XDG data home, else the Emacs directory.
fn central_base(
    sessions_directory: Option<PathBuf>,
    xdg_data_home: Option<PathBuf>,
    user_emacs_directory: Option<PathBuf>,
) -> Result<Base, &'static str> {
    let usable = |path: Option<PathBuf>| {
        path.filter(|path| !path.as_os_str().is_empty())
            .and_then(|path| AbsolutePath::try_from(path).ok())
    };
    if let Some(granted) = sessions_directory {
        return AbsolutePath::try_from(granted).map(Base::Granted);
    }
    usable(xdg_data_home)
        .or_else(|| usable(user_emacs_directory))
        .map(Base::Central)
        .ok_or("central storage needs an absolute data or Emacs directory")
}

/// A derived directory: each core-chosen component beneath the anchor, in order.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StorageLayout {
    steps: Vec<PathBuf>,
}

impl StorageLayout {
    fn new(anchor: &Path, parts: &[&str]) -> Self {
        let mut path = anchor.to_path_buf();
        let steps = parts
            .iter()
            .map(|part| {
                path.push(part);
                path.clone()
            })
            .collect();
        Self { steps }
    }

    /// Every path the editor did not name, outermost first; the last is the directory.
    pub fn steps(&self) -> &[PathBuf] {
        &self.steps
    }
}

impl StorageLocation {
    /// Project-local layout for an absolute project root.
    pub fn project(project_root: PathBuf) -> Result<Self, CoreError> {
        let project_root = AbsolutePath::try_from(project_root).map_err(|_| CoreError::Rejected)?;
        Ok(Self {
            project_root,
            base: Base::Project,
        })
    }

    /// Project root as the editor observed it, before canonicalization.
    pub fn project_root(&self) -> &Path {
        &self.project_root.0
    }

    /// Pure derivation of the session directory for a canonical project root.
    pub fn layout(&self, canonical_project: &Path) -> Result<StorageLayout, CoreError> {
        Ok(match &self.base {
            Base::Project => StorageLayout::new(canonical_project, &[".kargu", "sessions"]),
            Base::Central(data) => {
                let key = project_key(canonical_project)?;
                StorageLayout::new(&data.0, &["kargu", "sessions", &key])
            }
            Base::Granted(sessions) => {
                let key = project_key(canonical_project)?;
                StorageLayout::new(&sessions.0, &[&key])
            }
        })
    }
}

/// Deterministic slug for a canonical project root: `<name>-<sha1[..8]>`.
fn project_key(canonical: &Path) -> Result<String, CoreError> {
    let text = canonical.to_str().ok_or(CoreError::Rejected)?;
    let name = canonical
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .unwrap_or("root");
    let clean: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '_'
            }
        })
        .collect();
    let digest = Sha1::digest(text.as_bytes());
    let hex: String = digest
        .iter()
        .take(4)
        .map(|byte| format!("{byte:02x}"))
        .collect();
    Ok(format!("{clean}-{hex}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::persistence::storage::resolve_location;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[test]
    fn project_key_matches_the_legacy_editor_slug() -> TestResult {
        assert_eq!(
            project_key(Path::new("/home/u/my proj"))?,
            "my_proj-5a6e8a00"
        );
        assert_eq!(project_key(Path::new("/"))?, "root-42099b4a");
        Ok(())
    }

    #[test]
    fn requests_never_name_the_storage_directory() {
        let parse = |value: serde_json::Value| serde_json::from_value::<StorageLocation>(value);
        assert!(parse(serde_json::json!({"location":"project","project_root":"rel"})).is_err());
        assert!(parse(serde_json::json!({"location":"project","project_root":"/a/../b"})).is_err());
        assert!(parse(serde_json::json!({"location":"central","project_root":"/p"})).is_err());
        assert!(
            parse(serde_json::json!({"location":"project","project_root":"/p",
                                     "storage_root":"/etc"}))
            .is_err()
        );
        assert!(
            parse(serde_json::json!({"location":"central","project_root":"/p",
                                     "xdg_data_home":"","user_emacs_directory":"/e"}))
            .is_ok()
        );
        assert!(
            parse(serde_json::json!({"location":"project","project_root":"/p",
                                     "sessions_directory":"/s"}))
            .is_err()
        );
        assert!(
            parse(serde_json::json!({"location":"central","project_root":"/p",
                                     "sessions_directory":"rel"}))
            .is_err()
        );
    }

    #[test]
    fn resolves_project_and_central_layouts() -> TestResult {
        let project = tempfile::tempdir()?;
        let data = tempfile::tempdir()?;
        let canonical = std::fs::canonicalize(project.path())?;
        let local = resolve_location(&StorageLocation::project(project.path().to_path_buf())?)?;
        assert_eq!(local.path(), canonical.join(".kargu/sessions"));
        let central: StorageLocation = serde_json::from_value(serde_json::json!({
            "location": "central",
            "project_root": project.path(),
            "xdg_data_home": data.path(),
        }))?;
        let root = resolve_location(&central)?;
        assert!(root.path().starts_with(data.path().join("kargu/sessions")));
        assert_eq!(
            root.path().file_name().and_then(|name| name.to_str()),
            Some(project_key(&canonical)?.as_str())
        );
        Ok(())
    }

    #[test]
    fn granted_central_directory_still_gets_the_native_project_key() -> TestResult {
        let location: StorageLocation = serde_json::from_value(serde_json::json!({
            "location": "central",
            "project_root": "/home/u/my proj",
            "sessions_directory": "/srv/sessions",
            "xdg_data_home": "/ignored",
        }))?;
        let layout = location.layout(Path::new("/home/u/my proj"))?;
        assert_eq!(
            layout.steps(),
            [PathBuf::from("/srv/sessions/my_proj-5a6e8a00")]
        );
        Ok(())
    }

    #[test]
    fn linked_storage_ancestors_are_refused() -> TestResult {
        let project = tempfile::tempdir()?;
        let elsewhere = tempfile::tempdir()?;
        std::os::unix::fs::symlink(elsewhere.path(), project.path().join(".kargu"))?;
        let location = StorageLocation::project(project.path().to_path_buf())?;
        assert!(matches!(
            resolve_location(&location),
            Err(CoreError::Rejected)
        ));
        Ok(())
    }
}
