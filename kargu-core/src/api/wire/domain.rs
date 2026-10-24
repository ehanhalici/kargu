//! Captured format metadata is parsed once into usable request/response codecs.

use super::super::ApiError;
use crate::domain::TokenCount;
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Clone, Copy, Deserialize, serde::Serialize)]
#[serde(try_from = "u64")]
pub struct OutputLimit(TokenCount);
impl TryFrom<u64> for OutputLimit {
    type Error = ApiError;
    fn try_from(value: u64) -> Result<Self, ApiError> {
        if value == 0 {
            return Err(ApiError::InvalidRequest);
        }
        Ok(Self(
            TokenCount::try_from(value).map_err(|_| ApiError::InvalidRequest)?,
        ))
    }
}

#[derive(Clone, Deserialize, Eq, Ord, PartialEq, PartialOrd)]
#[serde(try_from = "String")]
pub(super) struct Field(String);
impl TryFrom<String> for Field {
    type Error = ApiError;
    fn try_from(value: String) -> Result<Self, ApiError> {
        if value.is_empty() || value.len() > 128 || value.chars().any(char::is_control) {
            return Err(ApiError::InvalidRequest);
        }
        Ok(Self(value))
    }
}
impl Field {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "kebab-case")]
enum Shape {
    Blocks,
}
#[derive(Deserialize)]
#[serde(rename_all = "kebab-case")]
enum BlockRole {
    Text,
    Reasoning,
    ToolCall,
}

#[derive(Clone)]
pub(super) struct TextRule {
    pub kind: Field,
    pub field: Field,
}
#[derive(Clone)]
pub(super) struct ToolRule {
    pub kind: Field,
    pub id: Field,
    pub name: Field,
    pub input: Field,
}
#[derive(Clone, Deserialize)]
pub(super) struct ToolResultRule {
    #[serde(rename = "type")]
    pub kind: Field,
    pub id: Field,
    pub content: Field,
}
#[derive(Deserialize)]
struct BlockDto {
    #[serde(rename = "as")]
    role: BlockRole,
    #[serde(rename = "type")]
    kind: Field,
    field: Option<Field>,
    id: Option<Field>,
    name: Option<Field>,
    input: Option<Field>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub(super) struct CacheUsage {
    pub read: Field,
    pub write: Field,
    #[serde(default)]
    pub input_excludes_cache: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "kebab-case")]
struct WireDto {
    stream: Option<bool>,
    message_shape: Option<Shape>,
    response_shape: Option<Shape>,
    #[serde(default)]
    blocks: Vec<BlockDto>,
    tool_result: Option<ToolResultRule>,
    tool_schema_key: Option<Field>,
    system_key: Option<Field>,
    max_tokens_default: Option<OutputLimit>,
    #[serde(default)]
    copy_keys: Vec<Field>,
    content_key: Option<Field>,
    #[serde(default)]
    detect: Vec<Field>,
    detect_type: Option<Field>,
    #[serde(default)]
    finish: BTreeMap<Field, Field>,
    finish_default: Option<Field>,
    #[serde(default)]
    usage: BTreeMap<Field, Field>,
    cache_usage: Option<CacheUsage>,
    request: Option<crate::api::policy::DefaultsPatch>,
    reasoning_shape: Option<crate::api::policy::ReasoningShape>,
}

pub(super) struct RequestRules {
    pub text: TextRule,
    pub tool: ToolRule,
    pub result: ToolResultRule,
    pub schema: Field,
    pub system: Option<Field>,
    pub max_tokens: OutputLimit,
    pub copy: Vec<Field>,
}
pub(super) struct ResponseRules {
    pub text: TextRule,
    pub tool: ToolRule,
    pub reasoning: Option<TextRule>,
    pub content: Field,
    pub detect: Vec<Field>,
    pub detect_type: Option<Field>,
    pub finish: BTreeMap<Field, Field>,
    pub finish_default: Field,
    pub usage: BTreeMap<Field, Field>,
    pub cache: Option<CacheUsage>,
}

/// No credential data. Unused metadata fields are left to the metadata service.
#[derive(Deserialize)]
#[serde(try_from = "serde_json::Value")]
pub struct WireSpec {
    pub(super) request: Option<RequestRules>,
    pub(super) response: Option<ResponseRules>,
    pub(super) stream: bool,
    pub(super) revision: WireRevision,
    pub(super) policy: crate::api::policy::DefaultsPatch,
    pub(super) reasoning: crate::api::policy::ReasoningShape,
}
pub(super) struct WireRevision(pub String);
impl Default for WireSpec {
    fn default() -> Self {
        Self {
            request: None,
            response: None,
            stream: true,
            revision: WireRevision(String::new()),
            policy: Default::default(),
            reasoning: Default::default(),
        }
    }
}
impl TryFrom<serde_json::Value> for WireSpec {
    type Error = ApiError;
    fn try_from(value: serde_json::Value) -> Result<Self, ApiError> {
        use sha2::{Digest, Sha256};
        let raw = serde_json::to_vec(&value).map_err(|_| ApiError::InvalidRequest)?;
        if raw.len() > 64 * 1024 {
            return Err(ApiError::Limit);
        }
        let dto: WireDto = serde_json::from_value(value).map_err(|_| ApiError::InvalidRequest)?;
        let mut spec = Self::try_from(dto)?;
        spec.revision = WireRevision(format!("{:x}", Sha256::digest(raw)));
        Ok(spec)
    }
}
impl TryFrom<WireDto> for WireSpec {
    type Error = ApiError;
    fn try_from(dto: WireDto) -> Result<Self, ApiError> {
        if dto.blocks.len() > 16
            || dto.copy_keys.len() > 32
            || dto.detect.len() > 16
            || dto.finish.len() > 32
            || dto.usage.len() > 32
        {
            return Err(ApiError::Limit);
        }
        let mut text = None;
        let mut reasoning = None;
        let mut tool = None;
        for block in dto.blocks {
            match block.role {
                BlockRole::Text | BlockRole::Reasoning => {
                    let target = if matches!(block.role, BlockRole::Text) {
                        &mut text
                    } else {
                        &mut reasoning
                    };
                    if target.is_some() {
                        return Err(ApiError::InvalidRequest);
                    }
                    *target = Some(TextRule {
                        kind: block.kind,
                        field: block.field.ok_or(ApiError::InvalidRequest)?,
                    });
                }
                BlockRole::ToolCall => {
                    if tool.is_some() {
                        return Err(ApiError::InvalidRequest);
                    }
                    tool = Some(ToolRule {
                        kind: block.kind,
                        id: block.id.ok_or(ApiError::InvalidRequest)?,
                        name: block.name.ok_or(ApiError::InvalidRequest)?,
                        input: block.input.ok_or(ApiError::InvalidRequest)?,
                    });
                }
            }
        }
        let request = if dto.message_shape.is_some() {
            let max_tokens = dto.max_tokens_default.ok_or(ApiError::InvalidRequest)?;
            Some(RequestRules {
                text: text.clone().ok_or(ApiError::InvalidRequest)?,
                tool: tool.clone().ok_or(ApiError::InvalidRequest)?,
                result: dto.tool_result.ok_or(ApiError::InvalidRequest)?,
                schema: dto.tool_schema_key.ok_or(ApiError::InvalidRequest)?,
                system: dto.system_key,
                max_tokens,
                copy: dto.copy_keys,
            })
        } else {
            None
        };
        let response = if dto.response_shape.is_some() {
            Some(ResponseRules {
                text: text.ok_or(ApiError::InvalidRequest)?,
                tool: tool.ok_or(ApiError::InvalidRequest)?,
                reasoning,
                content: dto
                    .content_key
                    .unwrap_or(Field::try_from("content".to_owned())?),
                detect: dto.detect,
                detect_type: dto.detect_type,
                finish: dto.finish,
                finish_default: dto
                    .finish_default
                    .unwrap_or(Field::try_from("stop".to_owned())?),
                usage: dto.usage,
                cache: dto.cache_usage,
            })
        } else {
            None
        };
        Ok(Self {
            request,
            response,
            stream: dto.stream.unwrap_or(true),
            revision: WireRevision(String::new()),
            policy: dto.request.unwrap_or_default(),
            reasoning: dto.reasoning_shape.unwrap_or_default(),
        })
    }
}
