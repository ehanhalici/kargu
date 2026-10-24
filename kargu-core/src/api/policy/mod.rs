//! Native request policy from captured explicit settings and capability metadata.

mod domain;
use super::{ApiError, wire::OutputLimit};
pub use domain::{DefaultsPatch, ReasoningShape};
use domain::{OutputField, Override, Parameters, ReasoningSelection, Temperature};
use serde::Deserialize;
use serde_json::{Map, Value, json};

/// Editor preferences and exact model metadata, before format policy is applied.
#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RequestTuning {
    temperature: Option<Temperature>,
    max_tokens: Option<OutputLimit>,
    effort: Option<ReasoningSelection>,
    thinking_budget: Option<OutputLimit>,
    supported_parameters: Option<Parameters>,
    #[serde(default)]
    provider_policy: DefaultsPatch,
}

struct Defaults<'a> {
    output: Option<OutputField>,
    sampling: Option<&'a Parameters>,
    default_temperature: bool,
    reasoning_disallows_temperature: bool,
}
impl<'a> Defaults<'a> {
    fn patch(&mut self, patch: &'a DefaultsPatch) {
        if let Override::Set(value) = patch.max_output_key {
            self.output = value;
        }
        if let Override::Set(ref value) = patch.sampling_parameters {
            self.sampling = value.as_ref();
            self.default_temperature = false;
        }
        if let Override::Set(value) = patch.reasoning_disallows_temperature {
            self.reasoning_disallows_temperature = value;
        }
    }
}

impl RequestTuning {
    /// Resolve one output field and declared sampling, then merge explicit extras.
    pub fn apply(
        &self,
        payload: Value,
        format: &DefaultsPatch,
        shape: ReasoningShape,
    ) -> Result<Value, ApiError> {
        let mut defaults = Defaults {
            output: Some(OutputField::MaxTokens),
            sampling: None,
            default_temperature: true,
            reasoning_disallows_temperature: false,
        };
        defaults.patch(format);
        defaults.patch(&self.provider_policy);
        let parameters = self
            .supported_parameters
            .as_ref()
            .filter(|parameters| !parameters.is_empty());
        let output = match parameters {
            None => defaults.output,
            Some(parameters) => defaults
                .output
                .filter(|field| parameters.contains(field.as_str()))
                .or_else(|| {
                    [OutputField::MaxTokens, OutputField::MaxCompletionTokens]
                        .into_iter()
                        .find(|field| parameters.contains(field.as_str()))
                }),
        };
        let effort = self.effort.as_ref().and_then(ReasoningSelection::effort);
        let temperature_supported = parameters.map_or_else(
            || {
                defaults.default_temperature
                    || defaults
                        .sampling
                        .is_some_and(|parameters| parameters.contains("temperature"))
            },
            |parameters| parameters.contains("temperature"),
        );
        let payload = payload.as_object().ok_or(ApiError::InvalidRequest)?;
        // Explicit extras are a separate input boundary, not an escape hatch
        // around the captured cap or finite/supported sampling contract.
        for field in [OutputField::MaxTokens, OutputField::MaxCompletionTokens] {
            if let Some(value) = payload.get(field.as_str()) {
                let _: OutputLimit =
                    serde_json::from_value(value.clone()).map_err(|_| ApiError::InvalidRequest)?;
                if parameters.is_some_and(|parameters| !parameters.contains(field.as_str())) {
                    return Err(ApiError::InvalidRequest);
                }
            }
        }
        if let Some(value) = payload.get("temperature") {
            let _: Temperature =
                serde_json::from_value(value.clone()).map_err(|_| ApiError::InvalidRequest)?;
            if !temperature_supported
                || (effort.is_some() && defaults.reasoning_disallows_temperature)
            {
                return Err(ApiError::InvalidRequest);
            }
        }
        let mut fields = Map::new();
        if let Some(temperature) = self.temperature
            && temperature_supported
            && !(effort.is_some() && defaults.reasoning_disallows_temperature)
        {
            fields.insert("temperature".into(), json!(temperature.as_f64()));
        }
        if let Some(limit) = self.max_tokens {
            fields.insert(
                output.ok_or(ApiError::InvalidRequest)?.as_str().into(),
                json!(limit),
            );
        }
        match shape {
            ReasoningShape::Effort => {
                if let Some(effort) = effort {
                    fields.insert("reasoning_effort".into(), json!(effort));
                }
            }
            ReasoningShape::Thinking => {
                if let Some(budget) = self.thinking_budget {
                    fields.insert(
                        "thinking".into(),
                        json!({"type":"enabled","budget_tokens":budget}),
                    );
                }
            }
            ReasoningShape::Nested => {
                let mut reasoning = Map::new();
                if let Some(effort) = effort {
                    reasoning.insert("effort".into(), json!(effort));
                }
                if let Some(budget) = self.thinking_budget {
                    reasoning.insert("max_tokens".into(), json!(budget));
                }
                if !reasoning.is_empty() {
                    fields.insert("reasoning".into(), Value::Object(reasoning));
                }
            }
        }
        fields.extend(payload.clone());
        if fields.contains_key("max_tokens") && fields.contains_key("max_completion_tokens") {
            return Err(ApiError::InvalidRequest);
        }
        Ok(Value::Object(fields))
    }
}
