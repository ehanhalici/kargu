//! Bounded symbol snapshots and native name/range selection. Editor objects,
//! display text and the first fuzzy match cannot establish a unique definition.
#[cfg(test)]
mod tests;
use super::SymbolKind;
use crate::{
    constants::limits,
    error::CoreError,
    sensors::{
        coordinates::SourceRange,
        diagnostics::DocumentStamp,
        types::{ImenuProviderId, LspVersion, SensorText, ServerId},
    },
};
use serde::{Deserialize, Serialize};

/// Bounded symbol identifier or qualified query; control characters are rejected.
#[derive(Clone, Eq, PartialEq, Deserialize, Serialize)]
#[serde(try_from = "String", into = "String")]
pub struct SymbolName(String);
impl std::fmt::Debug for SymbolName {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SymbolName([REDACTED])")
    }
}
impl TryFrom<String> for SymbolName {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        if value.is_empty()
            || value.len() > limits::SENSOR_SYMBOL_NAME_BYTES
            || value.chars().any(char::is_control)
        {
            return Err(CoreError::InvalidValue {
                field: "SymbolName",
            });
        }
        Ok(Self(value))
    }
}
impl From<SymbolName> for String {
    fn from(value: SymbolName) -> Self {
        value.0
    }
}
impl SymbolName {
    /// Borrow the validated name only at an explicit selection/render boundary.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Actual code-unit encoding used by the captured language connection.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub enum PositionEncoding {
    /// UTF-8 byte columns, with no split multibyte code points.
    #[serde(rename = "utf-8")]
    Utf8,
    /// UTF-16 code-unit columns, with no split surrogate pairs.
    #[serde(rename = "utf-16")]
    Utf16,
    /// Unicode scalar columns.
    #[serde(rename = "utf-32")]
    Utf32,
}
/// Provider identity is captured before issuance and compared at delivery.
#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum LanguageSource {
    /// Actual major-mode/imenu provider generation.
    Imenu {
        /// Opaque captured provider identity; never a symbol label.
        provider: ImenuProviderId,
    },
    /// Actual Eglot transport and document version at capture.
    Eglot {
        /// Opaque server/process identity, renewed on replacement.
        server: ServerId,
        /// Version flushed before the document read.
        version: LspVersion,
        /// Negotiated position converter used to capture ranges.
        encoding: PositionEncoding,
    },
}

/// One raw symbol node; complete-tree construction checks all nesting and ranges.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SymbolNode {
    name: SymbolName,
    kind: SymbolKind,
    range: SourceRange,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    selection_range: Option<SourceRange>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    children: Vec<SymbolNode>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DocumentInput {
    symbols: Vec<SymbolNode>,
    truncated: bool,
}
/// Construction checks the entire hierarchy, including nodes hidden by render limits.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(try_from = "DocumentInput")]
pub struct DocumentSymbols {
    symbols: Vec<SymbolNode>,
    truncated: bool,
}
impl TryFrom<DocumentInput> for DocumentSymbols {
    type Error = CoreError;
    fn try_from(input: DocumentInput) -> Result<Self, CoreError> {
        let mut stack: Vec<_> = input
            .symbols
            .iter()
            .map(|node| (node, 0usize, None))
            .collect();
        let mut count = 0usize;
        while let Some((node, depth, parent)) = stack.pop() {
            count = count.checked_add(1).ok_or(CoreError::Limit)?;
            if count > limits::SENSOR_SYMBOLS || depth > limits::SENSOR_SYMBOL_DEPTH {
                return Err(CoreError::Limit);
            }
            if parent.is_some_and(|range: SourceRange| !range.contains(node.range))
                || node
                    .selection_range
                    .is_some_and(|range| !node.range.contains(range))
            {
                return Err(CoreError::InvalidValue {
                    field: "SymbolRange",
                });
            }
            stack.extend(
                node.children
                    .iter()
                    .map(|child| (child, depth.saturating_add(1), Some(node.range))),
            );
        }
        if serde_json::to_vec(&input.symbols)
            .map_err(|_| CoreError::Limit)?
            .len()
            > limits::SENSOR_SYMBOL_BYTES
        {
            return Err(CoreError::Limit);
        }
        Ok(Self {
            symbols: input.symbols,
            truncated: input.truncated,
        })
    }
}
#[derive(Clone)]
pub(crate) struct SelectedSymbol {
    name: SymbolName,
    kind: SymbolKind,
    range: SourceRange,
}
impl SelectedSymbol {
    pub(crate) fn range(&self) -> SourceRange {
        self.range
    }
}
pub(crate) enum SymbolLookup {
    Unique(SelectedSymbol),
    Ambiguous(Vec<SelectedSymbol>),
    NotFound,
    Truncated,
}
impl SymbolLookup {
    pub(crate) fn refusal_text(&self) -> String {
        match self {
            Self::NotFound => "ERROR: symbol not found in the captured document".to_owned(),
            Self::Truncated => {
                "ERROR: symbol snapshot is truncated; uniqueness cannot be established".to_owned()
            }
            Self::Ambiguous(items) => {
                let mut out = Output::new();
                out.line("ERROR: ambiguous symbol; choose a qualified name or kind:\n");
                for item in items {
                    if !out.line(&format!(
                        "- {:?} {} [L{}:C{}-L{}:C{}]\n",
                        item.kind,
                        item.name.as_str(),
                        item.range.start().line.get(),
                        item.range.start().column.get(),
                        item.range.end().line.get(),
                        item.range.end().column.get()
                    )) {
                        break;
                    }
                }
                out.finish()
            }
            Self::Unique(_) => "ERROR: a unique symbol is not a refusal".to_owned(),
        }
    }
}

struct Output {
    text: String,
    truncated: bool,
}
const NOTICE: &str = "... (symbols truncated)\n";
impl Output {
    fn new() -> Self {
        Self {
            text: String::new(),
            truncated: false,
        }
    }
    fn line(&mut self, line: &str) -> bool {
        if self.text.len().saturating_add(line.len())
            > limits::SENSOR_TEXT_BYTES.saturating_sub(NOTICE.len())
        {
            self.truncated = true;
            return false;
        }
        self.text.push_str(line);
        true
    }
    fn finish(mut self) -> String {
        if self.truncated {
            self.text.push_str(NOTICE);
        }
        self.text
    }
}
impl DocumentSymbols {
    /// Bounded native rendering; a display cap does not change captured metadata.
    pub fn render_tree(&self) -> String {
        let mut out = Output::new();
        self.render_into(&mut out);
        out.finish()
    }
    pub(crate) fn render_for(&self, document: &DocumentStamp) -> String {
        let mut out = Output::new();
        out.line(&format!("File: {:?}\n", document.path.as_str()));
        self.render_into(&mut out);
        out.finish()
    }
    fn render_into(&self, out: &mut Output) {
        if self.symbols.is_empty() && !self.truncated {
            out.line("(no symbols in the captured document)\n");
        }
        let mut stack: Vec<_> = self
            .symbols
            .iter()
            .rev()
            .map(|node| (node, 0usize))
            .collect();
        while let Some((node, depth)) = stack.pop() {
            let line = format!(
                "{}- {:?} {} [L{}:C{}-L{}:C{}]\n",
                "  ".repeat(depth),
                node.kind,
                node.name.as_str(),
                node.range.start().line.get(),
                node.range.start().column.get(),
                node.range.end().line.get(),
                node.range.end().column.get()
            );
            if !out.line(&line) {
                break;
            }
            stack.extend(
                node.children
                    .iter()
                    .rev()
                    .map(|child| (child, depth.saturating_add(1))),
            );
        }
        out.truncated |= self.truncated;
    }
    pub(crate) fn select(
        &self,
        name: &SymbolName,
        kind: Option<&str>,
    ) -> Result<SymbolLookup, CoreError> {
        if self.truncated {
            return Ok(SymbolLookup::Truncated);
        }
        let kind = KindFilter::parse(kind)?;
        let needle = name.as_str().to_lowercase();
        let mut stack: Vec<_> = self
            .symbols
            .iter()
            .map(|node| (node, String::new()))
            .collect();
        let mut matches = Vec::new();
        while let Some((node, container)) = stack.pop() {
            let qualified = if container.is_empty() {
                node.name.as_str().to_owned()
            } else {
                format!("{container}::{}", node.name.as_str())
            };
            let dotted = qualified.replace("::", ".");
            if kind.matches(node.kind)
                && (node.name.as_str().to_lowercase() == needle
                    || qualified.to_lowercase() == needle
                    || dotted.to_lowercase() == needle)
            {
                matches.push(SelectedSymbol {
                    name: SymbolName::try_from(qualified.clone())
                        .unwrap_or_else(|_| node.name.clone()),
                    kind: node.kind,
                    range: node.range,
                });
            }
            stack.extend(node.children.iter().map(|child| (child, qualified.clone())));
        }
        match matches.as_slice() {
            [one] if one.range.start() != one.range.end() => Ok(SymbolLookup::Unique(one.clone())),
            [_] => Err(CoreError::Unavailable),
            [] => Ok(SymbolLookup::NotFound),
            _ => Ok(SymbolLookup::Ambiguous(matches)),
        }
    }
}
enum KindFilter {
    Any,
    Exact(SymbolKind),
    Type,
}
impl KindFilter {
    fn parse(kind: Option<&str>) -> Result<Self, CoreError> {
        let Some(kind) = kind.filter(|kind| !kind.trim().is_empty()) else {
            return Ok(Self::Any);
        };
        let kind = kind.trim();
        if kind.eq_ignore_ascii_case("type") {
            return Ok(Self::Type);
        }
        let mut kind = kind.to_ascii_lowercase().replace([' ', '-', '_'], "");
        if kind == "enummember" {
            kind = "enum_member".to_owned();
        }
        if kind == "typeparameter" {
            kind = "type_parameter".to_owned();
        }
        if kind == "symbol" {
            kind = "unknown".to_owned();
        }
        let value = serde_json::from_value::<SymbolKind>(serde_json::Value::String(kind)).map_err(
            |_| CoreError::InvalidValue {
                field: "SymbolKind",
            },
        )?;
        Ok(Self::Exact(value))
    }
    fn matches(&self, kind: SymbolKind) -> bool {
        match self {
            Self::Any => true,
            Self::Exact(expected) => *expected == kind,
            Self::Type => matches!(
                kind,
                SymbolKind::Class
                    | SymbolKind::Struct
                    | SymbolKind::Enum
                    | SymbolKind::Interface
                    | SymbolKind::TypeParameter
            ),
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
/// Detached symbols with exact requested/observed document and provider identities.
pub struct SymbolSnapshot {
    requested: DocumentStamp,
    observed: DocumentStamp,
    source: LanguageSource,
    observed_source: LanguageSource,
    symbols: DocumentSymbols,
}
impl SymbolSnapshot {
    pub(crate) fn fresh_for(&self, document: &DocumentStamp, source: &LanguageSource) -> bool {
        &self.requested == document
            && self.observed == self.requested
            && &self.source == source
            && self.observed_source == self.source
    }
    pub(crate) fn symbols(&self) -> &DocumentSymbols {
        &self.symbols
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SymbolBody {
    document: DocumentStamp,
    source: LanguageSource,
    range: SourceRange,
    text: SensorText,
    truncated: bool,
}
impl SymbolBody {
    pub(crate) fn render(
        self,
        document: &DocumentStamp,
        source: &LanguageSource,
        selected: &SelectedSymbol,
    ) -> Result<String, CoreError> {
        if self.document != *document || self.source != *source || self.range != selected.range {
            return Err(CoreError::StaleOwner);
        }
        let mut line = self.range.start().line.get();
        let mut column = self.range.start().column.get();
        let mut chars = self.text.as_str().chars().peekable();
        while let Some(character) = chars.next() {
            if character == '\r' && chars.peek() == Some(&'\n') {
                continue;
            }
            if character == '\n' {
                line = line.checked_add(1).ok_or(CoreError::Limit)?;
                column = 0;
            } else {
                column = column.checked_add(1).ok_or(CoreError::Limit)?;
            }
        }
        let actual = crate::sensors::coordinates::Position {
            line: crate::sensors::types::SourceLine::try_from(line)?,
            column: crate::sensors::types::ScalarColumn::try_from(column)?,
        };
        if actual > self.range.end() || (!self.truncated && actual != self.range.end()) {
            return Err(CoreError::InvalidToolOutput);
        }
        let mut out = format!(
            "File: {:?}\n{:?} {} [L{}:C{}-L{}:C{}]\n",
            document.path.as_str(),
            selected.kind,
            selected.name.as_str(),
            self.range.start().line.get(),
            self.range.start().column.get(),
            self.range.end().line.get(),
            self.range.end().column.get()
        );
        let room = limits::SENSOR_TEXT_BYTES
            .saturating_sub(out.len())
            .saturating_sub(NOTICE.len());
        let text = self.text.as_str();
        let mut end = room.min(text.len());
        while !text.is_char_boundary(end) {
            end = end.saturating_sub(1);
        }
        out.push_str(text.get(..end).ok_or(CoreError::InvalidToolOutput)?);
        if self.truncated || end < text.len() {
            out.push_str(NOTICE);
        }
        Ok(out)
    }
}

/// Native-only witness: wire data cannot construct an authorized symbol edit.
#[derive(Clone, Serialize)]
pub(crate) struct SymbolEditSelection {
    pub(crate) document: DocumentStamp,
    pub(crate) source: LanguageSource,
    pub(crate) range: SourceRange,
}
impl SymbolSnapshot {
    pub(crate) fn select_edit(
        &self,
        document: &DocumentStamp,
        source: &LanguageSource,
        name: &SymbolName,
        kind: Option<&str>,
    ) -> Result<SymbolEditSelection, CoreError> {
        if !self.fresh_for(document, source) {
            return Err(CoreError::StaleOwner);
        }
        let SymbolLookup::Unique(selected) = self.symbols.select(name, kind)? else {
            return Err(CoreError::Unavailable);
        };
        Ok(SymbolEditSelection {
            document: document.clone(),
            source: source.clone(),
            range: selected.range,
        })
    }
}
