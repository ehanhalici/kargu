//! Exact provider metadata normalization. Opaque fields never drive policy.
//!
//! Different declarations cannot be substituted for each other:
//! ```compile_fail
//! use kargu_core::models::metadata::{MetadataLabel, ParameterName};
//! fn parameter(_: ParameterName) {}
//! fn wrong(label: MetadataLabel) { parameter(label); }
//! ```

mod effort;
mod raw;
mod text;

pub use effort::EffortSpecs;
pub(crate) use raw::RawMetadata;
pub use text::{MetadataLabel, ParameterName};

use super::{
    CacheReadTokenRate, CacheWriteTokenRate, ContextCapacity, InputTokenRate, NumericError,
    OutputCapacity, OutputTokenRate,
};
use serde::Serialize;
use serde_json::Value;
use std::str::FromStr;

/// Unknown, malformed and known-zero are deliberately different states.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(tag = "state", content = "value", rename_all = "snake_case")]
pub enum Field<T> {
    /// No observation (including explicit null).
    Missing,
    /// An observation exists but does not satisfy the field's domain.
    Invalid,
    /// Parsed once at the boundary.
    Known(T),
}
impl<T> Field<T> {
    /// Borrow a successfully parsed observation, never coerce an invalid one.
    pub fn known(&self) -> Option<&T> {
        match self {
            Self::Known(value) => Some(value),
            Self::Missing | Self::Invalid => None,
        }
    }
}

/// Closed, payload-free structural failures. Field failures remain observations.
#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum MetadataError {
    /// Malformed or duplicate metadata object/control field.
    #[error("Invalid model metadata object")]
    Shape,
    /// Input, path or field collection exceeded its hard bound.
    #[error("Model metadata limit exceeded")]
    Limit,
}

/// A canonical field set; private fields can only originate at the raw boundary.
#[derive(Clone, Debug, Serialize)]
pub struct ModelFields {
    context_window: Field<ContextCapacity>,
    max_output: Field<OutputCapacity>,
    input_cost: Field<InputTokenRate>,
    output_cost: Field<OutputTokenRate>,
    cache_read_cost: Field<CacheReadTokenRate>,
    cache_write_cost: Field<CacheWriteTokenRate>,
    supports_tools: Field<bool>,
    supports_reasoning: Field<bool>,
    supported_parameters: Field<Vec<ParameterName>>,
    reasoning_efforts: Field<Vec<effort::EffortName>>,
    vision: Field<bool>,
    free: Field<bool>,
    params: Field<MetadataLabel>,
}

/// Parsed raw record and its derived immutable canonical fields.
/// Prices and token limits enter through RawValue, never a floating-point Value.
pub struct ModelMetadata {
    raw: RawMetadata,
    fields: ModelFields,
}
impl ModelMetadata {
    /// Normalize one bounded object using captured, declared effort paths.
    pub fn parse(source: &str, specs: &EffortSpecs) -> Result<Self, MetadataError> {
        let raw = RawMetadata::try_from(source)?;
        let fields = ModelFields::from_raw(&raw, specs);
        Ok(Self { raw, fields })
    }
    /// Borrow only the validated immutable projection, not raw field decisions.
    pub fn fields(&self) -> &ModelFields {
        &self.fields
    }
    /// Detach the opaque inspector record without exposing a mutable authority.
    pub fn raw_snapshot(&self) -> Result<Value, MetadataError> {
        self.raw.snapshot()
    }
}

fn numeric<T: FromStr<Err = NumericError>>(value: Option<&str>) -> Field<T> {
    match value {
        None | Some("null") => Field::Missing,
        Some(source) => {
            let parsed = if source.starts_with('"') {
                serde_json::from_str::<String>(source)
                    .ok()
                    .and_then(|literal| literal.parse().ok())
            } else {
                source.parse().ok()
            };
            parsed.map_or(Field::Invalid, Field::Known)
        }
    }
}
fn flag(value: Option<&str>) -> Field<bool> {
    match value {
        None | Some("null") => Field::Missing,
        Some("true" | "\"true\"") => Field::Known(true),
        Some("false" | "\"false\"") => Field::Known(false),
        Some(_) => Field::Invalid,
    }
}
fn label(value: Option<&str>) -> Field<MetadataLabel> {
    match value {
        None | Some("null") => Field::Missing,
        Some(source) => {
            serde_json::from_str::<MetadataLabel>(source).map_or(Field::Invalid, Field::Known)
        }
    }
}
fn parameters(value: Option<&str>) -> Field<Vec<ParameterName>> {
    match value {
        None | Some("null" | "[]") => Field::Missing,
        Some(source) => serde_json::from_str::<Vec<ParameterName>>(source)
            .ok()
            .filter(|values| values.len() <= 256)
            .map_or(Field::Invalid, |values| {
                if values.is_empty() {
                    Field::Missing
                } else {
                    Field::Known(values)
                }
            }),
    }
}
impl ModelFields {
    /// Detached UI values; absent/invalid observations remain unknown. The tagged
    /// fields remain available separately for inspectors and exact policy ports.
    pub fn display_snapshot(&self) -> Value {
        serde_json::json!({
            "context-window":self.context_window.known(), "max-output":self.max_output.known(),
            "reasoning-efforts":self.reasoning_efforts.known(),
            "vision":self.vision == Field::Known(true),
            "free":self.free == Field::Known(true) || self.input_is_zero(),
            "params":self.params.known(), "input-cost":self.input_cost.known(),
            "price-label":self.input_cost.known().filter(|rate| !rate.is_zero()).map(InputTokenRate::per_million_label)
        })
    }
    pub(crate) fn from_raw(raw: &RawMetadata, specs: &EffortSpecs) -> Self {
        let context_window = numeric(raw.first(&[
            "context_length",
            "context_window",
            "inputTokenLimit",
            "context-window",
        ]));
        let max_output = numeric(
            raw.first(&["max_output", "outputTokenLimit", "max_completion_tokens"])
                .or_else(|| raw.nested("top_provider", "max_completion_tokens"))
                .or_else(|| raw.first(&["max-output"])),
        );
        let input_cost = numeric(
            raw.nested("pricing", "prompt")
                .or_else(|| raw.first(&["input-cost"])),
        );
        let output_cost = numeric(
            raw.nested("pricing", "completion")
                .or_else(|| raw.first(&["output-cost"])),
        );
        let cache_read_cost = numeric(raw.nested("pricing", "input_cache_read"));
        let cache_write_cost = numeric(raw.nested("pricing", "input_cache_write"));
        let supports_tools = flag(raw.first(&["supports_tools", "supports-tools"]));
        let supports_reasoning = flag(raw.first(&["supports_reasoning", "supports-reasoning"]));
        let supported_parameters = parameters(raw.first(&[
            "supported_parameters",
            "supportedParameters",
            "supported-parameters",
        ]));
        let reasoning_efforts = if supports_reasoning == Field::Known(false) {
            Field::Known(Vec::new())
        } else {
            specs.read(raw)
        };
        let vision = match flag(raw.first(&["vision"])) {
            Field::Missing => match label(
                raw.nested("architecture", "modality")
                    .or_else(|| raw.first(&["modality"])),
            ) {
                Field::Known(modality) => Field::Known(modality.as_str().contains("image")),
                Field::Missing => Field::Missing,
                Field::Invalid => Field::Invalid,
            },
            explicit => explicit,
        };
        // A legacy input-zero badge is NOT a statement about all billable rates.
        let free = flag(raw.first(&["free"]));
        let params = match label(raw.first(&["params"])) {
            Field::Missing => match label(raw.nested("details", "parameter_size")) {
                Field::Known(size) => match label(raw.nested("details", "quantization_level")) {
                    Field::Known(quant) => {
                        MetadataLabel::try_from(format!("{} {}", size.as_str(), quant.as_str()))
                            .map_or(Field::Invalid, Field::Known)
                    }
                    _ => Field::Known(size),
                },
                other => other,
            },
            explicit => explicit,
        };
        Self {
            context_window,
            max_output,
            input_cost,
            output_cost,
            cache_read_cost,
            cache_write_cost,
            supports_tools,
            supports_reasoning,
            supported_parameters,
            reasoning_efforts,
            vision,
            free,
            params,
        }
    }
    /// Legacy input-only marketing observation; never billing authorization.
    pub fn input_is_zero(&self) -> bool {
        self.input_cost.known().is_some_and(InputTokenRate::is_zero)
    }
    /// Missing parameter metadata is unknown, not an explicit tool prohibition.
    pub fn allows_tools(&self) -> bool {
        self.supports_tools != Field::Known(false)
            && self
                .supported_parameters
                .known()
                .is_none_or(|values| values.iter().any(|value| value.as_str() == "tools"))
    }
    /// An explicit disable beats effort lists; absent data invents no support.
    pub fn allows_reasoning(&self) -> bool {
        self.supports_reasoning != Field::Known(false)
            && (self.supports_reasoning == Field::Known(true)
                || self
                    .reasoning_efforts
                    .known()
                    .is_some_and(|values| !values.is_empty()))
    }
}
impl Default for ModelFields {
    fn default() -> Self {
        Self::from_raw(&RawMetadata::default(), &EffortSpecs::default())
    }
}
