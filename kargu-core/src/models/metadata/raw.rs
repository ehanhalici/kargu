//! Scoped exact numeric source retention, without global serde number features.

use super::MetadataError;
use crate::constants::limits;
use serde::{
    Deserialize, Deserializer,
    de::{self, MapAccess, Visitor},
};
use serde_json::{Value, value::RawValue};
use std::{collections::BTreeMap, fmt};

#[derive(Clone, Default)]
pub(crate) struct RawMetadata(BTreeMap<String, Box<RawValue>>);
impl<'de> Deserialize<'de> for RawMetadata {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct ObjectVisitor;
        impl<'de> Visitor<'de> for ObjectVisitor {
            type Value = RawMetadata;
            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a model metadata object with unique keys")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
                let mut fields = BTreeMap::new();
                while let Some(key) = map.next_key::<String>()? {
                    if fields.contains_key(&key) {
                        return Err(de::Error::custom("duplicate model metadata key"));
                    }
                    fields.insert(key, map.next_value()?);
                }
                Ok(RawMetadata(fields))
            }
        }
        deserializer.deserialize_map(ObjectVisitor)
    }
}
impl TryFrom<&str> for RawMetadata {
    type Error = MetadataError;
    fn try_from(source: &str) -> Result<Self, Self::Error> {
        if source.len() > limits::MODEL_CATALOG_BYTES {
            return Err(MetadataError::Limit);
        }
        let raw: Self = serde_json::from_str(source).map_err(|_| MetadataError::Shape)?;
        for key in ["pricing", "top_provider", "architecture", "details"] {
            if let Some(value) = raw.0.get(key) {
                // Preserve the legacy one-object wrapper accepted by metadata ports.
                let source = value.get();
                if source.starts_with('{') {
                    let _: Self = serde_json::from_str(source).map_err(|_| MetadataError::Shape)?;
                } else if source.starts_with('[') {
                    let values: Vec<Box<RawValue>> =
                        serde_json::from_str(source).map_err(|_| MetadataError::Shape)?;
                    if let [value] = values.as_slice()
                        && value.get().starts_with('{')
                    {
                        let _: Self =
                            serde_json::from_str(value.get()).map_err(|_| MetadataError::Shape)?;
                    }
                }
            }
        }
        Ok(raw)
    }
}
impl RawMetadata {
    pub(crate) fn first(&self, keys: &[&str]) -> Option<&str> {
        keys.iter()
            .filter_map(|key| self.0.get(*key).map(|value| value.get()))
            .find(|source| *source != "null")
    }
    pub(super) fn nested(&self, key: &str, field: &str) -> Option<&str> {
        // Nested fields are read from retained raw spans, not reconstructed floats.
        // RawValue borrows from the original owned string during this scan.
        let source = self.0.get(key)?.get();
        let object = if source.starts_with('[') {
            let values: Vec<&RawValue> = serde_json::from_str(source).ok()?;
            let [value] = values.as_slice() else {
                return None;
            };
            value.get()
        } else {
            source
        };
        let fields: BTreeMap<&str, &RawValue> = serde_json::from_str(object).ok()?;
        fields
            .get(field)
            .map(|value| value.get())
            .filter(|source| *source != "null")
    }
    pub(crate) fn snapshot(&self) -> Result<Value, MetadataError> {
        let mut fields = serde_json::Map::new();
        for (key, value) in &self.0 {
            let value = if key == "pricing" {
                pricing_snapshot(value.get())?
            } else if matches!(
                key.as_str(),
                "input-cost"
                    | "output-cost"
                    | "context_length"
                    | "context_window"
                    | "inputTokenLimit"
                    | "context-window"
                    | "max_output"
                    | "outputTokenLimit"
                    | "max_completion_tokens"
                    | "max-output"
            ) {
                // Integral JSON quantities keep their exact integer kind. Other
                // numeric lexemes stay strings, never rounded JSON floats.
                if !matches!(key.as_str(), "input-cost" | "output-cost")
                    && value.get().parse::<u64>().is_ok()
                {
                    serde_json::from_str(value.get()).map_err(|_| MetadataError::Shape)?
                } else {
                    exact_literal(value.get())?
                }
            } else if key == "top_provider" && value.get().starts_with('{') {
                let nested: Self =
                    serde_json::from_str(value.get()).map_err(|_| MetadataError::Shape)?;
                nested.snapshot()?
            } else if key == "top_provider" && value.get().starts_with('[') {
                let values: Vec<Box<RawValue>> =
                    serde_json::from_str(value.get()).map_err(|_| MetadataError::Shape)?;
                if let [value] = values.as_slice()
                    && value.get().starts_with('{')
                {
                    let nested: Self =
                        serde_json::from_str(value.get()).map_err(|_| MetadataError::Shape)?;
                    Value::Array(vec![nested.snapshot()?])
                } else {
                    serde_json::from_str(value.get()).map_err(|_| MetadataError::Shape)?
                }
            } else {
                serde_json::from_str(value.get()).map_err(|_| MetadataError::Shape)?
            };
            fields.insert(key.clone(), value);
        }
        Ok(Value::Object(fields))
    }
    pub(crate) fn set(&mut self, key: &str, value: Box<RawValue>) {
        self.0.insert(key.to_owned(), value);
    }
    pub(crate) fn retained_bytes(&self) -> usize {
        self.0.iter().fold(0_usize, |bytes, (key, value)| {
            bytes
                .saturating_add(key.len())
                .saturating_add(value.get().len())
        })
    }
}

fn pricing_snapshot(source: &str) -> Result<Value, MetadataError> {
    if source.starts_with('{') {
        let pricing: RawMetadata =
            serde_json::from_str(source).map_err(|_| MetadataError::Shape)?;
        let mut fields = serde_json::Map::new();
        for (key, value) in pricing.0 {
            fields.insert(key, exact_literal(value.get())?);
        }
        Ok(Value::Object(fields))
    } else if source.starts_with('[') {
        let values: Vec<Box<RawValue>> =
            serde_json::from_str(source).map_err(|_| MetadataError::Shape)?;
        if let [value] = values.as_slice()
            && value.get().starts_with('{')
        {
            Ok(Value::Array(vec![pricing_snapshot(value.get())?]))
        } else {
            serde_json::from_str(source).map_err(|_| MetadataError::Shape)
        }
    } else {
        serde_json::from_str(source).map_err(|_| MetadataError::Shape)
    }
}

fn exact_literal(source: &str) -> Result<Value, MetadataError> {
    if source.starts_with(|character: char| character.is_ascii_digit() || character == '-') {
        Ok(Value::String(source.to_owned()))
    } else {
        serde_json::from_str(source).map_err(|_| MetadataError::Shape)
    }
}
