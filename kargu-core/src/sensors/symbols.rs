//! Typed symbol, xref and hover structures for editor language integration.

use super::{
    coordinates::SourceRange,
    types::{SensorText, SourceLine},
};
use crate::error::CoreError;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Standard LSP symbol kinds.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SymbolKind {
    /// File symbol.
    File,
    /// Module symbol.
    Module,
    /// Namespace symbol.
    Namespace,
    /// Package symbol.
    Package,
    /// Class symbol.
    Class,
    /// Method symbol.
    Method,
    /// Property symbol.
    Property,
    /// Field symbol.
    Field,
    /// Constructor symbol.
    Constructor,
    /// Enum symbol.
    Enum,
    /// Interface symbol.
    Interface,
    /// Function symbol.
    Function,
    /// Variable symbol.
    Variable,
    /// Constant symbol.
    Constant,
    /// String symbol.
    String,
    /// Number symbol.
    Number,
    /// Boolean symbol.
    Boolean,
    /// Array symbol.
    Array,
    /// Object symbol.
    Object,
    /// Key symbol.
    Key,
    /// Null symbol.
    Null,
    /// Enum member symbol.
    EnumMember,
    /// Struct symbol.
    Struct,
    /// Event symbol.
    Event,
    /// Operator symbol.
    Operator,
    /// Type parameter symbol.
    TypeParameter,
    /// Unknown or unclassified symbol.
    Unknown,
}

/// Canonical text label for a symbol kind.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SymbolLabel(&'static str);

impl SymbolLabel {
    /// Return the static label string.
    pub const fn as_str(self) -> &'static str {
        self.0
    }
}

impl SymbolKind {
    /// Canonical human-readable label for the symbol kind.
    pub fn label(&self) -> SymbolLabel {
        SymbolLabel(match self {
            Self::File => "File",
            Self::Module => "Module",
            Self::Namespace => "Namespace",
            Self::Package => "Package",
            Self::Class => "Class",
            Self::Method => "Method",
            Self::Property => "Property",
            Self::Field => "Field",
            Self::Constructor => "Constructor",
            Self::Enum => "Enum",
            Self::Interface => "Interface",
            Self::Function => "Function",
            Self::Variable => "Variable",
            Self::Constant => "Constant",
            Self::String => "String",
            Self::Number => "Number",
            Self::Boolean => "Boolean",
            Self::Array => "Array",
            Self::Object => "Object",
            Self::Key => "Key",
            Self::Null => "Null",
            Self::EnumMember => "EnumMember",
            Self::Struct => "Struct",
            Self::Event => "Event",
            Self::Operator => "Operator",
            Self::TypeParameter => "TypeParameter",
            Self::Unknown => "Symbol",
        })
    }
}

mod document;
pub use document::{
    DocumentSymbols, LanguageSource, PositionEncoding, SymbolName, SymbolNode, SymbolSnapshot,
};
pub(crate) use document::{SelectedSymbol, SymbolBody, SymbolLookup};

/// A location returned by Xref / Definition / References.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct XrefLocation {
    /// Path of the target file.
    pub path: PathBuf,
    /// Location range in the target file.
    pub range: SourceRange,
    /// Optional preview or summary line.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<SensorText>,
}

/// Format a list of Xref locations with explicit truncation.
pub fn format_xrefs(locations: &[XrefLocation], max_items: usize) -> String {
    let mut out = String::new();
    let total = locations.len();
    for (i, loc) in locations.iter().take(max_items).enumerate() {
        let summary = loc.summary.as_ref().map(|s| s.as_str()).unwrap_or("");
        out.push_str(&format!(
            "{}. {}:L{}:C{}-L{}:C{} {}\n",
            i + 1,
            loc.path.display(),
            loc.range.start().line.get(),
            loc.range.start().column.get(),
            loc.range.end().line.get(),
            loc.range.end().column.get(),
            summary
        ));
    }
    if total > max_items {
        out.push_str(&format!("... and {} more locations\n", total - max_items));
    }
    out
}

/// Cap on the total symbols in a skeleton.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MaxSymbols(usize);

impl MaxSymbols {
    /// Wrap a numerical cap.
    pub const fn new(limit: usize) -> Self {
        Self(limit)
    }

    /// Access the underlying limit.
    pub const fn as_usize(self) -> usize {
        self.0
    }
}

/// Cap on the symbols shown per file in a skeleton.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MaxPerFile(usize);

impl MaxPerFile {
    /// Wrap a numerical cap.
    pub const fn new(limit: usize) -> Self {
        Self(limit)
    }

    /// Access the underlying limit.
    pub const fn as_usize(self) -> usize {
        self.0
    }
}

/// Bounded display limits for a project skeleton.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SkeletonLimits {
    max_symbols: MaxSymbols,
    max_per_file: MaxPerFile,
}

impl SkeletonLimits {
    /// Construct bounded skeleton limits.
    pub const fn new(max_symbols: MaxSymbols, max_per_file: MaxPerFile) -> Self {
        Self {
            max_symbols,
            max_per_file,
        }
    }

    /// Maximum total symbols shown.
    pub const fn max_symbols(self) -> MaxSymbols {
        self.max_symbols
    }

    /// Maximum symbols shown per file.
    pub const fn max_per_file(self) -> MaxPerFile {
        self.max_per_file
    }
}

/// Truncation status of a project skeleton.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SkeletonTruncated(bool);

impl SkeletonTruncated {
    /// Wrap a truncation flag.
    pub const fn new(truncated: bool) -> Self {
        Self(truncated)
    }

    /// Whether the collection was truncated.
    pub const fn is_truncated(self) -> bool {
        self.0
    }
}

/// A single symbol entry in a project skeleton.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SkeletonSymbol {
    name: SymbolName,
    kind: SymbolKind,
    line: SourceLine,
}

impl SkeletonSymbol {
    /// Create a new skeleton symbol entry.
    pub fn new(name: SymbolName, kind: SymbolKind, line: SourceLine) -> Self {
        Self { name, kind, line }
    }

    /// Symbol identifier name.
    pub fn name(&self) -> &SymbolName {
        &self.name
    }

    /// Symbol kind.
    pub fn kind(&self) -> SymbolKind {
        self.kind
    }

    /// Source line number.
    pub fn line(&self) -> SourceLine {
        self.line
    }
}

/// Source provider label for a project skeleton.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SkeletonSource(String);

impl SkeletonSource {
    /// Create a new skeleton source identifier.
    pub fn new(source: String) -> Self {
        Self(source)
    }

    /// Borrow the source string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Project skeleton representation containing files and their symbols.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProjectSkeleton {
    root: PathBuf,
    source: String,
    files: Vec<(PathBuf, Vec<SkeletonSymbol>)>,
    truncated: bool,
}

impl ProjectSkeleton {
    /// Create a new project skeleton.
    pub fn new(root: PathBuf, source: SkeletonSource) -> Self {
        Self {
            root,
            source: source.0,
            files: Vec::new(),
            truncated: false,
        }
    }

    /// Add a file with its symbols to the project skeleton.
    pub fn add_file(&mut self, path: PathBuf, symbols: Vec<SkeletonSymbol>) {
        self.files.push((path, symbols));
    }

    /// Mark the skeleton as truncated at the collection limit.
    pub fn set_truncated(&mut self, truncated: SkeletonTruncated) {
        self.truncated = truncated.is_truncated();
    }

    /// Target project root directory.
    pub fn root(&self) -> &std::path::Path {
        &self.root
    }

    /// Discovery source label.
    pub fn source(&self) -> SkeletonSource {
        SkeletonSource::new(self.source.clone())
    }

    /// Collected files and their symbols.
    pub fn files(&self) -> &[(PathBuf, Vec<SkeletonSymbol>)] {
        &self.files
    }

    /// Truncation status of this skeleton.
    pub fn is_truncated(&self) -> SkeletonTruncated {
        SkeletonTruncated::new(self.truncated)
    }

    fn render_file(&self, file_idx: usize, limit: usize) -> (String, usize) {
        let Some((path, syms)) = self.files.get(file_idx) else {
            return (String::new(), 0);
        };
        let mut out = String::new();
        let rel = path.strip_prefix(&self.root).unwrap_or(path);
        out.push_str(&format!("{}:\n", rel.display()));
        let count = syms.len().min(limit);
        for sym in syms.iter().take(count) {
            out.push_str(&format!(
                "  {} ({}) :{}\n",
                sym.name.as_str(),
                sym.kind.label().as_str(),
                sym.line.get()
            ));
        }
        let hidden = syms.len().saturating_sub(count);
        if hidden > 0 {
            out.push_str(&format!("  ... ({hidden} more hidden)\n"));
        }
        (out, count)
    }

    /// Render the project skeleton text with bounded symbol limits.
    pub fn render(&self, limits: SkeletonLimits) -> Result<SensorText, CoreError> {
        let total_symbols: usize = self.files.iter().map(|(_, syms)| syms.len()).sum();
        let mut out = format!(
            "# Project skeleton (LSP: {})\n# root: {}\n# {} files, {} symbols\n",
            self.source,
            self.root.display(),
            self.files.len(),
            total_symbols
        );
        let mut shown = 0usize;
        let max_sym = limits.max_symbols.as_usize();
        let max_file = limits.max_per_file.as_usize();
        for i in 0..self.files.len() {
            if shown >= max_sym {
                break;
            }
            let per_file = max_file.min(max_sym.saturating_sub(shown));
            let (file_out, file_shown) = self.render_file(i, per_file);
            out.push_str(&file_out);
            shown = shown.saturating_add(file_shown);
        }
        if shown >= max_sym || self.truncated {
            out.push_str(&format!(
                "# symbol cap reached ({max_sym}); raise `kargu-lsp-skeleton-max-symbols' for more\n"
            ));
        }
        SensorText::try_from(out)
    }
}

pub(crate) use document::SymbolEditSelection;
