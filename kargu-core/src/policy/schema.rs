//! Bounded tool-schema parsing and structural argument checks.
//! Domain executors still validate paths, revisions, capabilities and exact argv.

use crate::{constants::limits, error::CoreError};
use serde::{Deserialize, Serialize, Serializer, ser::SerializeMap};
use serde_json::Value;
use std::{
    borrow::Borrow,
    collections::{BTreeMap, BTreeSet},
};

/// Bounded human-facing metadata, never execution authority.
#[derive(Clone, Deserialize, Serialize)]
#[serde(try_from = "String")]
pub struct ToolDescription(String);
impl TryFrom<String> for ToolDescription {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        if value.len() > limits::TOOL_DESCRIPTION_BYTES {
            return Err(CoreError::Limit);
        }
        Ok(Self(value))
    }
}
impl ToolDescription {
    /// Borrow description text for a model schema or passive editor projection.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Primitive JSON schema kinds supported by native tool arguments.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum SchemaType {
    /// An object with named properties.
    Object,
    /// A JSON array.
    Array,
    /// An exact string.
    String,
    /// An integer, not a lossy conversion from floating point.
    Integer,
    /// Any JSON number; domain-specific finite/range checks still follow.
    Number,
    /// JSON true or false.
    Boolean,
    /// Explicit JSON null, distinct from an absent property.
    Null,
}

#[derive(Clone, Eq, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
#[serde(try_from = "String")]
struct ParameterName(String);
impl Borrow<str> for ParameterName {
    fn borrow(&self) -> &str {
        &self.0
    }
}
impl TryFrom<String> for ParameterName {
    type Error = CoreError;
    fn try_from(value: String) -> Result<Self, CoreError> {
        if value.is_empty() || value.len() > 128 || value.chars().any(char::is_control) {
            return Err(CoreError::InvalidValue {
                field: "ParameterName",
            });
        }
        Ok(Self(value))
    }
}

fn allow_additional() -> bool {
    true
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SchemaInput {
    #[serde(rename = "type")]
    kind: SchemaType,
    description: Option<ToolDescription>,
    #[serde(default)]
    properties: BTreeMap<ParameterName, Box<ToolSchema>>,
    #[serde(default)]
    required: Vec<ParameterName>,
    minimum: Option<i64>,
    #[serde(rename = "enum")]
    choices: Option<Vec<String>>,
    items: Option<Box<ToolSchema>>,
    #[serde(default = "allow_additional", rename = "additionalProperties")]
    additional: bool,
}

/// Parse-once bounded schema. It cannot relabel a tool's effect or allowed modes.
#[derive(Clone, Deserialize)]
#[serde(try_from = "SchemaInput")]
pub struct ToolSchema {
    kind: SchemaType,
    description: Option<ToolDescription>,
    properties: BTreeMap<ParameterName, Box<ToolSchema>>,
    required: Vec<ParameterName>,
    minimum: Option<i64>,
    choices: Option<Vec<String>>,
    items: Option<Box<ToolSchema>>,
    additional: bool,
}
impl TryFrom<SchemaInput> for ToolSchema {
    type Error = CoreError;
    fn try_from(input: SchemaInput) -> Result<Self, CoreError> {
        if (input.kind != SchemaType::Object
            && (!input.properties.is_empty() || !input.required.is_empty()))
            || (input.kind != SchemaType::Array && input.items.is_some())
            || (!matches!(input.kind, SchemaType::Integer | SchemaType::Number)
                && input.minimum.is_some())
            || (input.kind != SchemaType::String && input.choices.is_some())
        {
            return Err(CoreError::InvalidValue {
                field: "ToolSchema",
            });
        }
        let required: BTreeSet<_> = input.required.iter().collect();
        if required.len() != input.required.len()
            || input.choices.as_ref().is_some_and(|choices| {
                choices.len() > limits::TOOL_SCHEMA_NODES
                    || choices
                        .iter()
                        .any(|choice| choice.len() > limits::TOOL_DESCRIPTION_BYTES)
            })
        {
            return Err(CoreError::Limit);
        }
        let schema = Self {
            kind: input.kind,
            description: input.description,
            properties: input.properties,
            required: input.required,
            minimum: input.minimum,
            choices: input.choices,
            items: input.items,
            additional: input.additional,
        };
        let mut nodes = SchemaNodes(0);
        schema.measure(SchemaDepth(0), &mut nodes)?;
        Ok(schema)
    }
}
struct SchemaNodes(usize);
#[derive(Clone, Copy)]
struct SchemaDepth(usize);
impl ToolSchema {
    fn measure(&self, depth: SchemaDepth, nodes: &mut SchemaNodes) -> Result<(), CoreError> {
        if depth.0 >= limits::TOOL_SCHEMA_DEPTH {
            return Err(CoreError::Limit);
        }
        nodes.0 = nodes
            .0
            .checked_add(1)
            .ok_or(CoreError::ArithmeticOverflow)?;
        if nodes.0 > limits::TOOL_SCHEMA_NODES {
            return Err(CoreError::Limit);
        }
        let next = SchemaDepth(
            depth
                .0
                .checked_add(1)
                .ok_or(CoreError::ArithmeticOverflow)?,
        );
        for child in self.properties.values() {
            child.measure(next, nodes)?;
        }
        if let Some(items) = &self.items {
            items.measure(next, nodes)?;
        }
        Ok(())
    }
    /// Primitive kind of this schema.
    pub fn kind(&self) -> SchemaType {
        self.kind
    }
    /// Validate argument shape before any native/editor effect is admitted.
    pub fn validate(&self, value: &Value) -> Result<(), CoreError> {
        let valid = match self.kind {
            SchemaType::Object => value.is_object(),
            SchemaType::Array => value.is_array(),
            SchemaType::String => value.is_string(),
            SchemaType::Boolean => value.is_boolean(),
            SchemaType::Integer => value.as_i64().is_some() || value.as_u64().is_some(),
            SchemaType::Number => value.is_number(),
            SchemaType::Null => value.is_null(),
        };
        if !valid {
            return Err(CoreError::InvalidValue {
                field: "ToolArguments",
            });
        }
        if let Some(object) = value.as_object() {
            if self.required.iter().any(|key| !object.contains_key(&key.0)) {
                return Err(CoreError::InvalidValue {
                    field: "ToolArguments",
                });
            }
            for (key, value) in object {
                if let Some(schema) = self.properties.get(key.as_str()) {
                    schema.validate(value)?;
                } else if !self.additional {
                    return Err(CoreError::InvalidValue {
                        field: "ToolArguments",
                    });
                }
            }
        }
        if let (Some(items), Some(values)) = (&self.items, value.as_array()) {
            if values.len() > limits::TOOL_SCHEMA_NODES {
                return Err(CoreError::Limit);
            }
            for value in values {
                items.validate(value)?;
            }
        }
        if let Some(minimum) = self.minimum {
            let enough = value
                .as_i64()
                .map(|value| value >= minimum)
                .or_else(|| {
                    value
                        .as_u64()
                        .map(|value| minimum <= 0 || value >= minimum.unsigned_abs())
                })
                .or_else(|| value.as_f64().map(|value| value >= minimum as f64))
                .unwrap_or(false);
            if !enough {
                return Err(CoreError::InvalidValue {
                    field: "ToolArguments",
                });
            }
        }
        if let Some(choices) = &self.choices
            && !value
                .as_str()
                .is_some_and(|text| choices.iter().any(|choice| choice == text))
        {
            return Err(CoreError::InvalidValue {
                field: "ToolArguments",
            });
        }
        Ok(())
    }
}
impl Serialize for ToolSchema {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut fields = serializer.serialize_map(None)?;
        fields.serialize_entry("type", &self.kind)?;
        if let Some(description) = &self.description {
            fields.serialize_entry("description", description)?;
        }
        if self.kind == SchemaType::Object {
            // Providers requiring an explicit empty properties object retain it.
            fields.serialize_entry("properties", &self.properties)?;
            if !self.additional {
                fields.serialize_entry("additionalProperties", &false)?;
            }
        }
        if !self.required.is_empty() {
            fields.serialize_entry("required", &self.required)?;
        }
        if let Some(minimum) = self.minimum {
            fields.serialize_entry("minimum", &minimum)?;
        }
        if let Some(choices) = &self.choices {
            fields.serialize_entry("enum", choices)?;
        }
        if let Some(items) = &self.items {
            fields.serialize_entry("items", items)?;
        }
        fields.end()
    }
}
