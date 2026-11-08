//! Typed symbol, xref and hover structures for editor language integration.

use super::{coordinates::SourceRange, types::SensorText};
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

/// A hover tooltip snapshot.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HoverSnapshot {
    /// Target source range of hover.
    #[serde(skip_serializing_if = "Option::is_none")]
    range: Option<SourceRange>,
    /// Markdown or text documentation chunks.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    contents: Vec<SensorText>,
}

/// Outcome of symbol resolution.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum SymbolResolution {
    /// A single unambiguous definition or reference.
    Resolved {
        /// Target location.
        location: XrefLocation,
    },
    /// Multiple candidate definitions or references.
    Ambiguous {
        /// All resolved candidate locations.
        candidates: Vec<XrefLocation>,
    },
    /// Symbol was not found.
    NotFound,
    /// Symbol resolution service is unavailable.
    Unavailable {
        /// Reason for unavailability.
        reason: String,
    },
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

/// Format a hover snapshot.
pub fn format_hover(hover: &HoverSnapshot) -> String {
    if hover.contents.is_empty() {
        return "(no hover information)".to_string();
    }
    hover
        .contents
        .iter()
        .map(|c| c.as_str())
        .collect::<Vec<_>>()
        .join("\n---\n")
}

pub(crate) use document::SymbolEditSelection;
