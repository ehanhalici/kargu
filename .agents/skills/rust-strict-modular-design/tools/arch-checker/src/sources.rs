//! The checker's only effectful module: finding and parsing source files.

use std::{fmt, fs, path::Path};

/// One parsed source file, named relative to the crate root.
pub struct Source {
    path: String,
    syntax: syn::File,
}

/// Why sources could not be loaded.
#[derive(Debug)]
pub enum SourceError {
    /// A file or directory could not be read.
    Io(String, std::io::Error),
    /// A file is not valid Rust.
    Parse(String, syn::Error),
}

impl fmt::Display for SourceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(path, error) => write!(f, "{path}: {error}"),
            Self::Parse(path, error) => {
                let start = error.span().start();
                write!(
                    f,
                    "{path}:{}:{}: {error}",
                    start.line,
                    start.column.saturating_add(1)
                )
            }
        }
    }
}

impl std::error::Error for SourceError {}

impl Source {
    /// Path relative to the crate root, with `/` separators.
    pub fn path(&self) -> &str {
        &self.path
    }

    /// The parsed syntax tree.
    pub fn syntax(&self) -> &syn::File {
        &self.syntax
    }
}

/// Parse every `.rs` file under `root/src`, in a stable order.
pub fn load(root: &Path) -> Result<Vec<Source>, SourceError> {
    let mut paths = Vec::new();
    collect(root, Path::new("src"), &mut paths)?;
    paths.sort();
    paths
        .into_iter()
        .map(|relative| parse(root, relative))
        .collect()
}

fn collect(root: &Path, relative: &Path, out: &mut Vec<String>) -> Result<(), SourceError> {
    let name = relative.to_string_lossy().replace('\\', "/");
    let entries =
        fs::read_dir(root.join(relative)).map_err(|error| SourceError::Io(name.clone(), error))?;
    for entry in entries {
        let entry = entry.map_err(|error| SourceError::Io(name.clone(), error))?;
        let child = relative.join(entry.file_name());
        let kind = entry
            .file_type()
            .map_err(|error| SourceError::Io(name.clone(), error))?;
        if kind.is_dir() {
            collect(root, &child, out)?;
        } else if child.extension().is_some_and(|extension| extension == "rs") {
            out.push(child.to_string_lossy().replace('\\', "/"));
        }
    }
    Ok(())
}

fn parse(root: &Path, relative: String) -> Result<Source, SourceError> {
    let text = fs::read_to_string(root.join(&relative))
        .map_err(|error| SourceError::Io(relative.clone(), error))?;
    let syntax =
        syn::parse_file(&text).map_err(|error| SourceError::Parse(relative.clone(), error))?;
    Ok(Source {
        path: relative,
        syntax,
    })
}
