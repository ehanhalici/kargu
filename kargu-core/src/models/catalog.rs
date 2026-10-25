//! Bounded provider discovery envelope boundary, before any UI publication.

use crate::{api::ModelId, constants::limits};
use serde::{
    Deserialize, Deserializer,
    de::{self, MapAccess, Visitor},
};
use serde_json::{Map, Value, json, value::RawValue};
use std::{collections::BTreeMap, fmt};

/// Payload-free discovery failures. No upstream body is an error message.
#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum CatalogError {
    /// Missing or malformed list, error envelope, duplicate key or invalid item.
    #[error("Invalid model catalog response")]
    Shape,
    /// A model identity was missing or invalid.
    #[error("Invalid model catalog identity")]
    Identity,
    /// Resource capacity was exceeded.
    #[error("Model catalog limit exceeded")]
    Limit,
}

/// Raw DTO fields retain numeric lexemes; duplicate envelope/record/price keys
/// cannot be resolved by an accidental last-writer-wins parser.
struct RawObject(BTreeMap<String, Box<RawValue>>);
impl<'de> Deserialize<'de> for RawObject {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct ObjectVisitor;
        impl<'de> Visitor<'de> for ObjectVisitor {
            type Value = RawObject;
            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("an object with unique keys")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<RawObject, A::Error> {
                let mut fields = BTreeMap::new();
                while let Some(key) = map.next_key::<String>()? {
                    if fields.contains_key(&key) {
                        return Err(de::Error::custom("duplicate model metadata key"));
                    }
                    fields.insert(key, map.next_value()?);
                }
                Ok(RawObject(fields))
            }
        }
        deserializer.deserialize_map(ObjectVisitor)
    }
}
fn parse<'de, T: Deserialize<'de>>(source: &'de str) -> Result<T, CatalogError> {
    serde_json::from_str(source).map_err(|_| CatalogError::Shape)
}

/// Preserve price lexemes before an opaque metadata value can enter a generic
/// JSON decoder. No f64, price rounding or "free" decision occurs here.
fn price_literal(value: &RawValue) -> Result<Value, CatalogError> {
    let source = value.get();
    if source.starts_with(|character: char| character.is_ascii_digit() || character == '-') {
        Ok(Value::String(source.to_owned()))
    } else {
        parse(source)
    }
}
struct Record {
    id: ModelId,
    fields: Map<String, Value>,
    source: Box<RawValue>,
}
impl TryFrom<&RawValue> for Record {
    type Error = CatalogError;
    fn try_from(value: &RawValue) -> Result<Self, Self::Error> {
        let source = value.get();
        let (id, source_fields) = if source.starts_with('"') {
            (parse::<String>(source)?, BTreeMap::new())
        } else {
            let source_fields = parse::<RawObject>(source)?.0;
            let identity = source_fields
                .get("id")
                .or_else(|| source_fields.get("name"))
                .ok_or(CatalogError::Identity)?;
            let id = parse::<String>(identity.get()).map_err(|_| CatalogError::Identity)?;
            (id, source_fields)
        };
        let id = id.trim();
        let id = id.strip_prefix("models/").unwrap_or(id);
        let id = ModelId::try_from(id.to_owned()).map_err(|_| CatalogError::Identity)?;
        let mut fields = Map::new();
        for (key, value) in source_fields {
            if key == "id" {
                continue;
            }
            let value = match key.as_str() {
                "pricing" if value.get().starts_with('{') => {
                    let mut pricing = Map::new();
                    for (key, value) in parse::<RawObject>(value.get())?.0 {
                        pricing.insert(key, price_literal(&value)?);
                    }
                    Value::Object(pricing)
                }
                "input-cost" | "output-cost" => price_literal(&value)?,
                _ => parse(value.get())?,
            };
            fields.insert(key, value);
        }
        let source = if source.starts_with('"') {
            RawValue::from_string("{}".to_owned()).map_err(|_| CatalogError::Shape)?
        } else {
            value.to_owned()
        };
        Ok(Self { id, fields, source })
    }
}

/// Accepted ordered records. An empty catalog is explicit, never inferred.
pub struct ModelCatalog(Vec<Record>);
impl TryFrom<&str> for ModelCatalog {
    type Error = CatalogError;
    fn try_from(source: &str) -> Result<Self, Self::Error> {
        if source.len() > limits::MODEL_CATALOG_BYTES {
            return Err(CatalogError::Limit);
        }
        let source = source.trim();
        let models: Vec<Box<RawValue>> = if source.starts_with('[') {
            parse(source)?
        } else {
            let mut fields = parse::<RawObject>(source)?.0;
            if fields
                .get("error")
                .is_some_and(|error| !matches!(error.get(), "null" | "false"))
            {
                return Err(CatalogError::Shape);
            }
            let key = ["data", "models", "items"]
                .into_iter()
                .find(|key| fields.contains_key(*key))
                .ok_or(CatalogError::Shape)?;
            let list = fields.remove(key).ok_or(CatalogError::Shape)?;
            parse(list.get())?
        };
        if models.len() > limits::MODEL_CATALOG_RECORDS {
            return Err(CatalogError::Limit);
        }
        models
            .iter()
            .map(|value| Record::try_from(value.as_ref()))
            .collect::<Result<Vec<_>, _>>()
            .map(Self)
    }
}
impl ModelCatalog {
    pub(crate) fn into_records(self) -> impl Iterator<Item = (ModelId, Box<RawValue>)> {
        self.0.into_iter().map(|record| (record.id, record.source))
    }
    /// One stable wire shape. Price lexemes stay decimal strings; remaining
    /// semantic capability/override decisions belong to their subsequent cutover.
    pub fn into_snapshot(self) -> Value {
        let models: Vec<_> = self
            .0
            .into_iter()
            .map(|record| {
                let mut fields = record.fields;
                fields.insert("id".to_owned(), json!(record.id));
                Value::Object(fields)
            })
            .collect();
        json!({"models": models})
    }
}
