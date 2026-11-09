//! Pure domain types and invariants for persistent session storage and schemas.
//!
//! Enforces:
//! - Strict private-field newtypes (StorageSessionId, StorageRoot, StorageRevision, StorageSequence).
//! - Bounded depth, node, size and message validation before admission.
//! - Redacted Debug representations that never disclose sensitive conversation or transcript text.
//! - Canonical v2 schema conversion.

use crate::{
    constants::limits,
    domain::{ProviderCallId, RequestCount, TokenCount, ToolName},
};
use serde::{Deserialize, Serialize};
use std::{
    fmt,
    path::{Component, Path, PathBuf},
};

pub use crate::error::PersistenceError;

/// A validated, safe filename component identifying a session.
///
/// Invariant: 1..=128 bytes, begins with ASCII alphanumeric, subsequent characters
/// in `[a-zA-Z0-9_.-]`, no path separators, no `..` traversal, no null bytes.
#[derive(Clone, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(try_from = "String")]
pub struct StorageSessionId(String);

impl StorageSessionId {
    /// Borrow the validated session identifier string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for StorageSessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "StorageSessionId({:?})", self.0)
    }
}

impl fmt::Display for StorageSessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl TryFrom<String> for StorageSessionId {
    type Error = PersistenceError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        validate_session_id(&value)?;
        Ok(Self(value))
    }
}

impl TryFrom<&str> for StorageSessionId {
    type Error = PersistenceError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        validate_session_id(value)?;
        Ok(Self(value.to_owned()))
    }
}

fn validate_session_id(id: &str) -> Result<(), PersistenceError> {
    if id.is_empty() {
        return Err(PersistenceError::InvalidId("identifier cannot be empty"));
    }
    if id.len() > 128 {
        return Err(PersistenceError::InvalidId("identifier exceeds 128 bytes"));
    }
    let first = id
        .chars()
        .next()
        .ok_or(PersistenceError::InvalidId("empty"))?;
    if !first.is_ascii_alphanumeric() {
        return Err(PersistenceError::InvalidId(
            "first character must be alphanumeric",
        ));
    }
    if id.contains("..") {
        return Err(PersistenceError::InvalidId(
            "path traversal sequence forbidden",
        ));
    }
    check_session_id_chars(id)
}

fn check_session_id_chars(id: &str) -> Result<(), PersistenceError> {
    for ch in id.chars() {
        if !ch.is_ascii_alphanumeric() && ch != '_' && ch != '.' && ch != '-' {
            return Err(PersistenceError::InvalidId(
                "illegal character in identifier",
            ));
        }
    }
    Ok(())
}

/// Validated canonical directory root for persistent session files.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StorageRoot(PathBuf);

impl StorageRoot {
    /// Borrow the storage root path.
    pub fn path(&self) -> &Path {
        &self.0
    }

    /// Resolve a contained session file path for `id`, ensuring it cannot escape the root.
    pub fn session_file(&self, id: &StorageSessionId) -> Result<PathBuf, PersistenceError> {
        let file_name = format!("{}.json", id.as_str());
        let candidate = self.0.join(file_name);
        for comp in candidate.components() {
            if matches!(comp, Component::ParentDir) {
                return Err(PersistenceError::PathEscape);
            }
        }
        if !candidate.starts_with(&self.0) {
            return Err(PersistenceError::PathEscape);
        }
        Ok(candidate)
    }
}

impl TryFrom<PathBuf> for StorageRoot {
    type Error = PersistenceError;

    fn try_from(path: PathBuf) -> Result<Self, Self::Error> {
        if !path.is_absolute() {
            return Err(PersistenceError::Validation(
                "storage root must be an absolute path",
            ));
        }
        Ok(Self(path))
    }
}

impl TryFrom<&Path> for StorageRoot {
    type Error = PersistenceError;

    fn try_from(path: &Path) -> Result<Self, Self::Error> {
        Self::try_from(path.to_path_buf())
    }
}

/// Monotonic session persistence revision counter.
#[derive(
    Clone, Copy, Debug, Default, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize,
)]
pub struct StorageRevision(u64);

impl StorageRevision {
    /// Return the raw integer counter.
    pub const fn as_u64(self) -> u64 {
        self.0
    }

    /// Construct from raw integer counter.
    pub const fn from_u64(val: u64) -> Self {
        Self(val)
    }

    /// Monotonically advance or report overflow.
    pub fn next(self) -> Result<Self, PersistenceError> {
        self.0
            .checked_add(1)
            .map(Self)
            .ok_or(PersistenceError::Validation("revision counter overflow"))
    }
}

impl TryFrom<u64> for StorageRevision {
    type Error = PersistenceError;

    fn try_from(value: u64) -> Result<Self, Self::Error> {
        Ok(Self(value))
    }
}

/// Monotonic journal sequence counter within a session.
#[derive(
    Clone, Copy, Debug, Default, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize,
)]
pub struct StorageSequence(u64);

impl StorageSequence {
    /// Return the raw integer counter.
    pub const fn as_u64(self) -> u64 {
        self.0
    }

    /// Construct from raw integer counter.
    pub const fn from_u64(val: u64) -> Self {
        Self(val)
    }

    /// Monotonically advance or report overflow.
    pub fn next(self) -> Result<Self, PersistenceError> {
        self.0
            .checked_add(1)
            .map(Self)
            .ok_or(PersistenceError::Validation("sequence counter overflow"))
    }
}

impl TryFrom<u64> for StorageSequence {
    type Error = PersistenceError;

    fn try_from(value: u64) -> Result<Self, Self::Error> {
        Ok(Self(value))
    }
}

/// Schema version identifier.
#[derive(
    Clone, Copy, Debug, Default, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize,
)]
#[serde(try_from = "u32")]
pub struct StorageSchemaVersion(u32);

impl StorageSchemaVersion {
    /// Canonical v2 schema version.
    pub const V2: Self = Self(2);

    /// Return raw integer value.
    pub const fn as_u32(self) -> u32 {
        self.0
    }
}

impl TryFrom<u32> for StorageSchemaVersion {
    type Error = PersistenceError;

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        if value != Self::V2.0 {
            return Err(PersistenceError::UnsupportedVersion(value));
        }
        Ok(Self(value))
    }
}

/// Bounded session transcript. Debug formatting redacts contents to prevent leaking sensitive chat history.
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String")]
pub struct SessionTranscript(String);

impl SessionTranscript {
    /// Borrow the transcript text.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for SessionTranscript {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "SessionTranscript([REDACTED {} bytes])", self.0.len())
    }
}

impl TryFrom<String> for SessionTranscript {
    type Error = PersistenceError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.len() > limits::SESSION_MAX_FILE_BYTES {
            return Err(PersistenceError::SizeLimitExceeded);
        }
        Ok(Self(value))
    }
}

/// Validated session mode identifier.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String")]
pub struct SessionMode(String);

impl SessionMode {
    /// Borrow the mode string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for SessionMode {
    type Error = PersistenceError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.is_empty() || value.len() > 64 {
            return Err(PersistenceError::Validation("invalid session mode"));
        }
        Ok(Self(value))
    }
}

impl TryFrom<&str> for SessionMode {
    type Error = PersistenceError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::try_from(value.to_owned())
    }
}

/// Validated provider name identifier.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String")]
pub struct SessionProvider(String);

impl SessionProvider {
    /// Borrow the provider string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for SessionProvider {
    type Error = PersistenceError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.is_empty() || value.len() > 128 {
            return Err(PersistenceError::Validation("invalid session provider"));
        }
        Ok(Self(value))
    }
}

impl TryFrom<&str> for SessionProvider {
    type Error = PersistenceError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::try_from(value.to_owned())
    }
}

/// Validated model name identifier.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String")]
pub struct SessionModel(String);

impl SessionModel {
    /// Borrow the model string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for SessionModel {
    type Error = PersistenceError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.is_empty() || value.len() > 128 {
            return Err(PersistenceError::Validation("invalid session model"));
        }
        Ok(Self(value))
    }
}

impl TryFrom<&str> for SessionModel {
    type Error = PersistenceError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::try_from(value.to_owned())
    }
}

/// Validated session project name.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String")]
pub struct SessionProjectName(String);

impl SessionProjectName {
    /// Borrow the project name string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for SessionProjectName {
    type Error = PersistenceError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.is_empty() || value.len() > 256 {
            return Err(PersistenceError::Validation("invalid project name"));
        }
        Ok(Self(value))
    }
}

impl TryFrom<&str> for SessionProjectName {
    type Error = PersistenceError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::try_from(value.to_owned())
    }
}

/// Persisted spend in USD: finite, non-negative and bounded.
///
/// The JSON number is kept as written, so an editor's integer `0` is not
/// returned as `0.0` and editor-side integer contracts still hold.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "serde_json::Number", into = "serde_json::Number")]
pub struct SessionMonetaryAmount(serde_json::Number);

impl SessionMonetaryAmount {
    const MAX_USD: f64 = 1.0e9;
}

impl TryFrom<serde_json::Number> for SessionMonetaryAmount {
    type Error = PersistenceError;

    fn try_from(value: serde_json::Number) -> Result<Self, Self::Error> {
        match value.as_f64() {
            Some(usd) if usd.is_finite() && (0.0..=Self::MAX_USD).contains(&usd) => Ok(Self(value)),
            _ => Err(PersistenceError::Validation("invalid monetary amount")),
        }
    }
}

impl From<SessionMonetaryAmount> for serde_json::Number {
    fn from(amount: SessionMonetaryAmount) -> Self {
        amount.0
    }
}

/// Validated session title.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String")]
pub struct SessionTitle(String);

impl SessionTitle {
    /// Borrow the title string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for SessionTitle {
    type Error = PersistenceError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.is_empty() || value.len() > 512 {
            return Err(PersistenceError::Validation("invalid session title"));
        }
        Ok(Self(value))
    }
}

impl TryFrom<&str> for SessionTitle {
    type Error = PersistenceError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::try_from(value.to_owned())
    }
}

/// Validated session timestamp string.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String")]
pub struct SessionTimestamp(String);

impl SessionTimestamp {
    /// Borrow the timestamp string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for SessionTimestamp {
    type Error = PersistenceError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.is_empty() || value.len() > 64 {
            return Err(PersistenceError::Validation("invalid session timestamp"));
        }
        Ok(Self(value))
    }
}

impl TryFrom<&str> for SessionTimestamp {
    type Error = PersistenceError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::try_from(value.to_owned())
    }
}

/// Validated tool call identifier; the rule is `domain::ProviderCallId`'s.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PersistedToolCallId(ProviderCallId);

impl PersistedToolCallId {
    /// Borrow the tool call identifier.
    pub fn as_str(&self) -> &str {
        self.0.as_str()
    }
}

impl TryFrom<String> for PersistedToolCallId {
    type Error = PersistenceError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        ProviderCallId::try_from(value)
            .map(Self)
            .map_err(|_| PersistenceError::Validation("invalid tool call id"))
    }
}

impl TryFrom<&str> for PersistedToolCallId {
    type Error = PersistenceError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::try_from(value.to_owned())
    }
}

/// Validated tool name; the rule is `domain::ToolName`'s.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PersistedToolName(ToolName);

impl PersistedToolName {
    /// Borrow the tool name.
    pub fn as_str(&self) -> &str {
        self.0.as_str()
    }
}

impl TryFrom<String> for PersistedToolName {
    type Error = PersistenceError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        ToolName::try_from(value)
            .map(Self)
            .map_err(|_| PersistenceError::Validation("invalid tool name"))
    }
}

impl TryFrom<&str> for PersistedToolName {
    type Error = PersistenceError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::try_from(value.to_owned())
    }
}

/// Validated tool arguments payload.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String")]
pub struct PersistedToolArguments(String);

impl PersistedToolArguments {
    /// Borrow the arguments string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for PersistedToolArguments {
    type Error = PersistenceError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.len() > limits::SESSION_MAX_FILE_BYTES {
            return Err(PersistenceError::SizeLimitExceeded);
        }
        Ok(Self(value))
    }
}

impl TryFrom<&str> for PersistedToolArguments {
    type Error = PersistenceError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::try_from(value.to_owned())
    }
}

/// Validated tool call type identifier (typically "function").
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String")]
pub struct PersistedToolKind(String);

impl PersistedToolKind {
    /// Canonical function kind.
    pub const FUNCTION: &'static str = "function";

    /// Borrow kind string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for PersistedToolKind {
    type Error = PersistenceError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.is_empty() || value.len() > 32 {
            return Err(PersistenceError::Validation("invalid tool call kind"));
        }
        Ok(Self(value))
    }
}

impl TryFrom<&str> for PersistedToolKind {
    type Error = PersistenceError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::try_from(value.to_owned())
    }
}

/// Reasoning content within a message. Redacted in Debug representations.
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "String")]
pub struct ReasoningContent(String);

impl ReasoningContent {
    /// Borrow reasoning string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for ReasoningContent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "ReasoningContent([REDACTED {} bytes])", self.0.len())
    }
}

impl TryFrom<String> for ReasoningContent {
    type Error = PersistenceError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.len() > limits::SESSION_MAX_FILE_BYTES {
            return Err(PersistenceError::SizeLimitExceeded);
        }
        Ok(Self(value))
    }
}

impl TryFrom<&str> for ReasoningContent {
    type Error = PersistenceError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::try_from(value.to_owned())
    }
}

/// Reasoning effort preference in v2 session schema.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum SessionEffort {
    /// Inherit configured default.
    #[serde(rename = "inherit")]
    Inherit,
    /// Explicitly disabled.
    #[serde(rename = "off")]
    Off,
    /// Explicit provider-specific effort value.
    #[serde(rename = "value")]
    Value {
        /// Selected effort name.
        value: String,
    },
}

/// Validated conversation role.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MessageRole {
    /// System prompt.
    System,
    /// End-user input.
    User,
    /// Model answer.
    Assistant,
    /// Tool result.
    Tool,
}

/// Validated tool function invocation.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PersistedToolFunction {
    name: PersistedToolName,
    arguments: PersistedToolArguments,
}

impl PersistedToolFunction {
    /// Name of the function.
    pub fn name(&self) -> &PersistedToolName {
        &self.name
    }

    /// Arguments payload.
    pub fn arguments(&self) -> &PersistedToolArguments {
        &self.arguments
    }
}

/// Validated tool call in an assistant message.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PersistedToolCall {
    id: PersistedToolCallId,
    #[serde(rename = "type")]
    kind: PersistedToolKind,
    function: PersistedToolFunction,
}

impl PersistedToolCall {
    /// Tool call identifier.
    pub fn id(&self) -> &PersistedToolCallId {
        &self.id
    }

    /// Tool call kind.
    pub fn kind(&self) -> &PersistedToolKind {
        &self.kind
    }

    /// Invoked function.
    pub fn function(&self) -> &PersistedToolFunction {
        &self.function
    }
}

/// Single message content element: string, text block array, or null/none.
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum MessageContent {
    /// Text string.
    Text(String),
    /// Structured block list.
    Blocks(Vec<serde_json::Value>),
    /// Null or omitted content.
    Null,
}

impl fmt::Debug for MessageContent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Text(s) => write!(f, "MessageContent::Text([REDACTED {} bytes])", s.len()),
            Self::Blocks(b) => write!(f, "MessageContent::Blocks({} blocks)", b.len()),
            Self::Null => write!(f, "MessageContent::Null"),
        }
    }
}

/// One conversation message within a persisted session.
#[derive(Clone, Serialize, Deserialize)]
pub struct SessionMessage {
    role: MessageRole,
    #[serde(default = "default_content")]
    content: MessageContent,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_calls: Option<Vec<PersistedToolCall>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_call_id: Option<PersistedToolCallId>,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<PersistedToolName>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reasoning_content: Option<ReasoningContent>,
}

fn default_content() -> MessageContent {
    MessageContent::Null
}

impl SessionMessage {
    /// Role of the message.
    pub fn role(&self) -> MessageRole {
        self.role
    }

    /// Content of the message.
    pub fn content(&self) -> &MessageContent {
        &self.content
    }

    /// Tool calls if present.
    pub fn tool_calls(&self) -> Option<&[PersistedToolCall]> {
        self.tool_calls.as_deref()
    }

    /// Tool call id if this is a tool result.
    pub fn tool_call_id(&self) -> Option<&PersistedToolCallId> {
        self.tool_call_id.as_ref()
    }

    /// Name if present.
    pub fn name(&self) -> Option<&PersistedToolName> {
        self.name.as_ref()
    }

    /// Reasoning content if present.
    pub fn reasoning_content(&self) -> Option<&ReasoningContent> {
        self.reasoning_content.as_ref()
    }

    /// Create a tool result message.
    pub fn tool_result(
        tool_call_id: PersistedToolCallId,
        name: Option<PersistedToolName>,
        content: MessageContent,
    ) -> Self {
        Self {
            role: MessageRole::Tool,
            content,
            tool_calls: None,
            tool_call_id: Some(tool_call_id),
            name,
            reasoning_content: None,
        }
    }
}

impl fmt::Debug for SessionMessage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SessionMessage")
            .field("role", &self.role)
            .field("content", &self.content)
            .field("tool_calls", &self.tool_calls.as_ref().map(|c| c.len()))
            .field("tool_call_id", &self.tool_call_id)
            .field("name", &self.name)
            .field("reasoning_content", &self.reasoning_content)
            .finish()
    }
}

/// An optional text field written empty means absent; any other value must
/// pass its type's constructor. Editors record "no choice" as an empty string.
fn empty_as_absent<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: TryFrom<String>,
    T::Error: fmt::Display,
{
    match Option::<String>::deserialize(deserializer)? {
        Some(text) if !text.is_empty() => T::try_from(text)
            .map(Some)
            .map_err(serde::de::Error::custom),
        _ => Ok(None),
    }
}

/// Validated canonical v2 session record.
///
/// All fields are private to guarantee that an unvalidated record cannot be constructed.
#[derive(Clone, Serialize, Deserialize)]
pub struct SessionRecord {
    schema_version: StorageSchemaVersion,
    id: StorageSessionId,
    #[serde(default)]
    revision: StorageRevision,
    #[serde(
        default,
        deserialize_with = "empty_as_absent",
        skip_serializing_if = "Option::is_none"
    )]
    mode: Option<SessionMode>,
    #[serde(
        default,
        deserialize_with = "empty_as_absent",
        skip_serializing_if = "Option::is_none"
    )]
    provider: Option<SessionProvider>,
    #[serde(
        default,
        deserialize_with = "empty_as_absent",
        skip_serializing_if = "Option::is_none"
    )]
    model: Option<SessionModel>,
    #[serde(skip_serializing_if = "Option::is_none")]
    effort: Option<SessionEffort>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tokens_in: Option<TokenCount>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tokens_out: Option<TokenCount>,
    #[serde(skip_serializing_if = "Option::is_none")]
    requests: Option<RequestCount>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tokens_spent: Option<TokenCount>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tokens_unknown: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    monetary_spent: Option<SessionMonetaryAmount>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    monetary_reserved: Option<SessionMonetaryAmount>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    monetary_unknown: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    project_root: Option<PathBuf>,
    #[serde(
        default,
        deserialize_with = "empty_as_absent",
        skip_serializing_if = "Option::is_none"
    )]
    project_name: Option<SessionProjectName>,
    #[serde(
        default,
        deserialize_with = "empty_as_absent",
        skip_serializing_if = "Option::is_none"
    )]
    title: Option<SessionTitle>,
    #[serde(
        default,
        deserialize_with = "empty_as_absent",
        skip_serializing_if = "Option::is_none"
    )]
    created_at: Option<SessionTimestamp>,
    #[serde(
        default,
        deserialize_with = "empty_as_absent",
        skip_serializing_if = "Option::is_none"
    )]
    updated_at: Option<SessionTimestamp>,
    #[serde(skip_serializing_if = "Option::is_none")]
    transcript: Option<SessionTranscript>,
    messages: Vec<SessionMessage>,
}

impl SessionRecord {
    /// Return the canonical schema version.
    pub const fn schema_version(&self) -> StorageSchemaVersion {
        self.schema_version
    }

    /// Return the validated session identifier.
    pub fn id(&self) -> &StorageSessionId {
        &self.id
    }

    /// Return the session revision.
    pub const fn revision(&self) -> StorageRevision {
        self.revision
    }

    /// Update record revision.
    pub fn with_revision(mut self, rev: StorageRevision) -> Self {
        self.revision = rev;
        self
    }

    /// Optional mode.
    pub fn mode(&self) -> Option<&SessionMode> {
        self.mode.as_ref()
    }

    /// Optional provider.
    pub fn provider(&self) -> Option<&SessionProvider> {
        self.provider.as_ref()
    }

    /// Optional model.
    pub fn model(&self) -> Option<&SessionModel> {
        self.model.as_ref()
    }

    /// Optional effort.
    pub fn effort(&self) -> Option<&SessionEffort> {
        self.effort.as_ref()
    }

    /// Optional tokens in.
    pub const fn tokens_in(&self) -> Option<TokenCount> {
        self.tokens_in
    }

    /// Optional tokens out.
    pub const fn tokens_out(&self) -> Option<TokenCount> {
        self.tokens_out
    }

    /// Optional requests.
    pub const fn requests(&self) -> Option<RequestCount> {
        self.requests
    }

    /// Optional project root.
    pub fn project_root(&self) -> Option<&Path> {
        self.project_root.as_deref()
    }

    /// Optional project name.
    pub fn project_name(&self) -> Option<&SessionProjectName> {
        self.project_name.as_ref()
    }

    /// Optional title.
    pub fn title(&self) -> Option<&SessionTitle> {
        self.title.as_ref()
    }

    /// Optional created_at.
    pub fn created_at(&self) -> Option<&SessionTimestamp> {
        self.created_at.as_ref()
    }

    /// Optional updated_at.
    pub fn updated_at(&self) -> Option<&SessionTimestamp> {
        self.updated_at.as_ref()
    }

    /// Optional transcript.
    pub fn transcript(&self) -> Option<&SessionTranscript> {
        self.transcript.as_ref()
    }

    /// Slice of stored messages.
    pub fn messages(&self) -> &[SessionMessage] {
        &self.messages
    }

    /// Append a validated message to the session record.
    pub fn append_message(&mut self, message: SessionMessage) -> Result<(), PersistenceError> {
        validate_message(&message)?;
        if self.messages.len().saturating_add(1) > limits::SESSION_MAX_MESSAGES {
            return Err(PersistenceError::MessageLimitExceeded);
        }
        self.messages.push(message);
        if let Err(err) = self.validate_record() {
            let _ = self.messages.pop();
            return Err(err);
        }
        Ok(())
    }

    /// Validate the record against domain limits and invariants.
    pub fn validate_record(&self) -> Result<(), PersistenceError> {
        self.validate()?;
        let encoded_len = serde_json::to_vec(self)
            .map_err(|_| PersistenceError::Validation("serialization error"))?
            .len();
        if encoded_len > limits::SESSION_MAX_FILE_BYTES {
            return Err(PersistenceError::SizeLimitExceeded);
        }
        Ok(())
    }

    pub(crate) fn with_id(mut self, id: StorageSessionId) -> Self {
        self.id = id;
        self
    }

    pub(crate) fn set_messages(
        &mut self,
        messages: Vec<SessionMessage>,
    ) -> Result<(), PersistenceError> {
        self.messages = messages;
        self.validate_record()
    }

    fn validate(&self) -> Result<(), PersistenceError> {
        if self.messages.len() > limits::SESSION_MAX_MESSAGES {
            return Err(PersistenceError::MessageLimitExceeded);
        }
        for msg in &self.messages {
            validate_message(msg)?;
        }
        Ok(())
    }
}

fn validate_message(msg: &SessionMessage) -> Result<(), PersistenceError> {
    if msg.role == MessageRole::Tool && msg.tool_call_id.is_none() {
        return Err(PersistenceError::Validation(
            "tool message missing tool_call_id",
        ));
    }
    Ok(())
}

impl fmt::Debug for SessionRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SessionRecord")
            .field("schema_version", &self.schema_version)
            .field("id", &self.id)
            .field("mode", &self.mode)
            .field("provider", &self.provider)
            .field("model", &self.model)
            .field("effort", &self.effort)
            .field("tokens_in", &self.tokens_in)
            .field("tokens_out", &self.tokens_out)
            .field("requests", &self.requests)
            .field("tokens_spent", &self.tokens_spent)
            .field("tokens_unknown", &self.tokens_unknown)
            .field("monetary_spent", &self.monetary_spent)
            .field("monetary_reserved", &self.monetary_reserved)
            .field("monetary_unknown", &self.monetary_unknown)
            .field("project_root", &self.project_root)
            .field("project_name", &self.project_name)
            .field("title", &self.title)
            .field("created_at", &self.created_at)
            .field("updated_at", &self.updated_at)
            .field("transcript", &self.transcript)
            .field("messages_count", &self.messages.len())
            .finish()
    }
}

impl TryFrom<&str> for SessionRecord {
    type Error = PersistenceError;

    fn try_from(json_str: &str) -> Result<Self, Self::Error> {
        parse_session_record(json_str)
    }
}

impl TryFrom<String> for SessionRecord {
    type Error = PersistenceError;

    fn try_from(json_str: String) -> Result<Self, Self::Error> {
        Self::try_from(json_str.as_str())
    }
}

fn parse_session_record(json_str: &str) -> Result<SessionRecord, PersistenceError> {
    if json_str.len() > limits::SESSION_MAX_FILE_BYTES {
        return Err(PersistenceError::SizeLimitExceeded);
    }
    let parsed: serde_json::Value =
        serde_json::from_str(json_str).map_err(|_| PersistenceError::Validation("invalid JSON"))?;
    let mut nodes = 0;
    validate_json_tree(&parsed, 0, &mut nodes)?;
    check_schema_version(&parsed)?;
    let record: SessionRecord = serde_json::from_value(parsed)
        .map_err(|_| PersistenceError::Validation("schema deserialization failed"))?;
    record.validate()?;
    Ok(record)
}

fn check_schema_version(val: &serde_json::Value) -> Result<(), PersistenceError> {
    let ver = val
        .get("schema_version")
        .and_then(serde_json::Value::as_u64)
        .ok_or(PersistenceError::Validation("missing schema_version"))?;
    if ver != u64::from(StorageSchemaVersion::V2.as_u32()) {
        return Err(PersistenceError::UnsupportedVersion(ver as u32));
    }
    Ok(())
}

fn validate_json_tree(
    value: &serde_json::Value,
    depth: usize,
    nodes: &mut usize,
) -> Result<(), PersistenceError> {
    if depth > limits::SESSION_VALIDATE_MAX_DEPTH {
        return Err(PersistenceError::DepthLimitExceeded);
    }
    *nodes += 1;
    if *nodes > limits::SESSION_VALIDATE_MAX_NODES {
        return Err(PersistenceError::NodeLimitExceeded);
    }
    match value {
        serde_json::Value::Array(items) => validate_json_array(items, depth + 1, nodes),
        serde_json::Value::Object(map) => validate_json_object(map, depth + 1, nodes),
        _ => Ok(()),
    }
}

fn validate_json_array(
    items: &[serde_json::Value],
    depth: usize,
    nodes: &mut usize,
) -> Result<(), PersistenceError> {
    for item in items {
        validate_json_tree(item, depth, nodes)?;
    }
    Ok(())
}

fn validate_json_object(
    map: &serde_json::Map<String, serde_json::Value>,
    depth: usize,
    nodes: &mut usize,
) -> Result<(), PersistenceError> {
    for val in map.values() {
        validate_json_tree(val, depth, nodes)?;
    }
    Ok(())
}

/// Count of messages in a persisted session.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
pub struct SessionMessageCount(usize);

impl SessionMessageCount {
    /// Wrap message count.
    pub const fn from_usize(count: usize) -> Self {
        Self(count)
    }

    /// Access message count.
    pub const fn as_usize(&self) -> usize {
        self.0
    }
}

/// Byte offset in a journal file.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
pub struct JournalByteOffset(usize);

impl JournalByteOffset {
    /// Wrap byte offset.
    pub const fn from_usize(offset: usize) -> Self {
        Self(offset)
    }

    /// Access raw byte offset.
    pub const fn as_usize(&self) -> usize {
        self.0
    }
}

/// Compact metadata summary of a persisted session.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SessionSummary {
    id: StorageSessionId,
    title: Option<SessionTitle>,
    created_at: Option<SessionTimestamp>,
    updated_at: Option<SessionTimestamp>,
    mode: Option<SessionMode>,
    provider: Option<SessionProvider>,
    model: Option<SessionModel>,
    requests: Option<RequestCount>,
    tokens_in: Option<TokenCount>,
    tokens_out: Option<TokenCount>,
    message_count: SessionMessageCount,
}

impl SessionSummary {
    /// Create a summary from a session record.
    pub fn from_record(record: &SessionRecord) -> Self {
        Self {
            id: record.id().clone(),
            title: record.title().cloned(),
            created_at: record.created_at().cloned(),
            updated_at: record.updated_at().cloned(),
            mode: record.mode().cloned(),
            provider: record.provider().cloned(),
            model: record.model().cloned(),
            requests: record.requests(),
            tokens_in: record.tokens_in(),
            tokens_out: record.tokens_out(),
            message_count: SessionMessageCount::from_usize(record.messages().len()),
        }
    }

    /// Access session identifier.
    pub fn id(&self) -> &StorageSessionId {
        &self.id
    }

    /// Access optional title.
    pub fn title(&self) -> Option<&SessionTitle> {
        self.title.as_ref()
    }

    /// Access optional creation timestamp.
    pub fn created_at(&self) -> Option<&SessionTimestamp> {
        self.created_at.as_ref()
    }

    /// Access optional update timestamp.
    pub fn updated_at(&self) -> Option<&SessionTimestamp> {
        self.updated_at.as_ref()
    }

    /// Access optional mode.
    pub fn mode(&self) -> Option<&SessionMode> {
        self.mode.as_ref()
    }

    /// Access optional provider.
    pub fn provider(&self) -> Option<&SessionProvider> {
        self.provider.as_ref()
    }

    /// Access optional model.
    pub fn model(&self) -> Option<&SessionModel> {
        self.model.as_ref()
    }

    /// Access optional request count.
    pub const fn requests(&self) -> Option<RequestCount> {
        self.requests
    }

    /// Access optional token in count.
    pub const fn tokens_in(&self) -> Option<TokenCount> {
        self.tokens_in
    }

    /// Access optional token out count.
    pub const fn tokens_out(&self) -> Option<TokenCount> {
        self.tokens_out
    }

    /// Access message count.
    pub const fn message_count(&self) -> SessionMessageCount {
        self.message_count
    }
}

/// Truncation indicator for bounded collection queries.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum ListTruncation {
    /// Listing returned all eligible entries within limits.
    Complete,
    /// Listing was truncated due to entry count or byte limits.
    Truncated,
}

/// Result of a bounded session listing query.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SessionListResult {
    summaries: Vec<SessionSummary>,
    truncation: ListTruncation,
}

impl SessionListResult {
    /// Wrap summaries and truncation indicator.
    pub fn new(summaries: Vec<SessionSummary>, truncation: ListTruncation) -> Self {
        Self {
            summaries,
            truncation,
        }
    }

    /// Access summaries slice.
    pub fn summaries(&self) -> &[SessionSummary] {
        &self.summaries
    }

    /// Access truncation status.
    pub const fn truncation(&self) -> ListTruncation {
        self.truncation
    }
}

/// Count of protocol repair messages inserted.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
pub struct SessionRepairCount(usize);

impl SessionRepairCount {
    /// Wrap repair count.
    pub const fn from_usize(count: usize) -> Self {
        Self(count)
    }

    /// Access raw repair count.
    pub const fn as_usize(&self) -> usize {
        self.0
    }
}

/// Maximum number of sessions to retain.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
pub struct MaxSessionCount(usize);

impl MaxSessionCount {
    /// Construct from raw usize.
    pub const fn from_usize(val: usize) -> Self {
        Self(val)
    }

    /// Access raw usize.
    pub const fn as_usize(&self) -> usize {
        self.0
    }
}

/// Maximum total session bytes to retain.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
pub struct MaxSessionBytes(u64);

impl MaxSessionBytes {
    /// Construct from raw u64.
    pub const fn from_u64(val: u64) -> Self {
        Self(val)
    }

    /// Access raw u64.
    pub const fn as_u64(&self) -> u64 {
        self.0
    }
}

/// Maximum age of a session in seconds before pruning.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
pub struct MaxSessionAge(u64);

impl MaxSessionAge {
    /// Construct from raw seconds.
    pub const fn from_secs(val: u64) -> Self {
        Self(val)
    }

    /// Access raw seconds.
    pub const fn as_secs(&self) -> u64 {
        self.0
    }
}

/// Count of sessions pruned during retention.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
pub struct PrunedSessionCount(usize);

impl PrunedSessionCount {
    /// Construct from raw usize.
    pub const fn from_usize(val: usize) -> Self {
        Self(val)
    }

    /// Access raw usize.
    pub const fn as_usize(&self) -> usize {
        self.0
    }
}

/// Bytes freed by pruning sessions during retention.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
pub struct PrunedByteCount(u64);

impl PrunedByteCount {
    /// Construct from raw u64.
    pub const fn from_u64(val: u64) -> Self {
        Self(val)
    }

    /// Access raw u64.
    pub const fn as_u64(&self) -> u64 {
        self.0
    }
}

/// Count of sessions retained after retention pruning.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
pub struct RetainedSessionCount(usize);

impl RetainedSessionCount {
    /// Construct from raw usize.
    pub const fn from_usize(val: usize) -> Self {
        Self(val)
    }

    /// Access raw usize.
    pub const fn as_usize(&self) -> usize {
        self.0
    }
}

/// Count of orphaned temporary files cleaned up.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
pub struct CleanedTempCount(usize);

impl CleanedTempCount {
    /// Construct from raw usize.
    pub const fn from_usize(val: usize) -> Self {
        Self(val)
    }

    /// Access raw usize.
    pub const fn as_usize(&self) -> usize {
        self.0
    }
}

/// Policy governing session retention across count, byte budget, and maximum age.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct SessionRetentionPolicy {
    max_count: Option<MaxSessionCount>,
    max_bytes: Option<MaxSessionBytes>,
    max_age_secs: Option<MaxSessionAge>,
}

impl SessionRetentionPolicy {
    /// Create a new retention policy.
    pub const fn new(
        max_count: Option<MaxSessionCount>,
        max_bytes: Option<MaxSessionBytes>,
        max_age_secs: Option<MaxSessionAge>,
    ) -> Self {
        Self {
            max_count,
            max_bytes,
            max_age_secs,
        }
    }

    /// Access optional maximum session count.
    pub const fn max_count(&self) -> Option<MaxSessionCount> {
        self.max_count
    }

    /// Access optional maximum total session bytes.
    pub const fn max_bytes(&self) -> Option<MaxSessionBytes> {
        self.max_bytes
    }

    /// Access optional maximum session age in seconds.
    pub const fn max_age_secs(&self) -> Option<MaxSessionAge> {
        self.max_age_secs
    }
}

/// Outcome report of a storage retention and cleanup cycle.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct RetentionReport {
    pruned_count: PrunedSessionCount,
    pruned_bytes: PrunedByteCount,
    retained_count: RetainedSessionCount,
    cleaned_temp_files: CleanedTempCount,
}

impl RetentionReport {
    /// Create an empty report.
    pub const fn empty() -> Self {
        Self {
            pruned_count: PrunedSessionCount(0),
            pruned_bytes: PrunedByteCount(0),
            retained_count: RetainedSessionCount(0),
            cleaned_temp_files: CleanedTempCount(0),
        }
    }

    /// Record pruned items and bytes.
    pub const fn with_pruned(mut self, count: PrunedSessionCount, bytes: PrunedByteCount) -> Self {
        self.pruned_count = count;
        self.pruned_bytes = bytes;
        self
    }

    /// Record retained items and cleaned temp files.
    pub const fn with_retained(
        mut self,
        retained: RetainedSessionCount,
        cleaned_temp_files: CleanedTempCount,
    ) -> Self {
        self.retained_count = retained;
        self.cleaned_temp_files = cleaned_temp_files;
        self
    }

    /// Number of sessions pruned.
    pub const fn pruned_count(&self) -> PrunedSessionCount {
        self.pruned_count
    }

    /// Total bytes freed from pruned sessions.
    pub const fn pruned_bytes(&self) -> PrunedByteCount {
        self.pruned_bytes
    }

    /// Number of sessions retained.
    pub const fn retained_count(&self) -> RetainedSessionCount {
        self.retained_count
    }

    /// Number of orphaned temp files cleaned.
    pub const fn cleaned_temp_files(&self) -> CleanedTempCount {
        self.cleaned_temp_files
    }
}
