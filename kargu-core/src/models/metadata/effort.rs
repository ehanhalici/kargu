//! Captured provider-declared reasoning paths, never model-name inference.

use super::{Field, MetadataError, RawMetadata};
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;

/// One finite printable effort label, not an arbitrary JSON or Lisp symbol.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(try_from = "String")]
pub struct EffortName(String);
impl TryFrom<String> for EffortName {
    type Error = MetadataError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.is_empty() || value.len() > 128 || value.chars().any(char::is_control) {
            return Err(MetadataError::Shape);
        }
        Ok(Self(value))
    }
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Encoding {
    List,
    Csv,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct SpecDto {
    path: Vec<String>,
    #[serde(rename = "type")]
    encoding: Encoding,
}
#[derive(Clone)]
struct PathKey(String);
impl TryFrom<String> for PathKey {
    type Error = MetadataError;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.is_empty() || value.len() > 256 || value.chars().any(char::is_control) {
            return Err(MetadataError::Limit);
        }
        Ok(Self(value))
    }
}
#[derive(Clone)]
struct EffortPath(Vec<PathKey>);
impl TryFrom<Vec<String>> for EffortPath {
    type Error = MetadataError;
    fn try_from(path: Vec<String>) -> Result<Self, Self::Error> {
        if path.is_empty() || path.len() > 16 {
            return Err(MetadataError::Limit);
        }
        path.into_iter()
            .map(PathKey::try_from)
            .collect::<Result<Vec<_>, _>>()
            .map(Self)
    }
}
#[derive(Clone)]
struct Spec {
    path: EffortPath,
    encoding: Encoding,
}
impl TryFrom<SpecDto> for Spec {
    type Error = MetadataError;
    fn try_from(dto: SpecDto) -> Result<Self, Self::Error> {
        Ok(Self {
            path: EffortPath::try_from(dto.path)?,
            encoding: dto.encoding,
        })
    }
}

/// Validated provider declaration; bounded, immutable, no executable expressions.
#[derive(Clone, Default, Deserialize)]
#[serde(try_from = "Vec<SpecDto>")]
pub struct EffortSpecs(Vec<Spec>);
impl TryFrom<Vec<SpecDto>> for EffortSpecs {
    type Error = MetadataError;
    fn try_from(dtos: Vec<SpecDto>) -> Result<Self, Self::Error> {
        if dtos.len() > 32 {
            return Err(MetadataError::Limit);
        }
        dtos.into_iter()
            .map(Spec::try_from)
            .collect::<Result<Vec<_>, _>>()
            .map(Self)
    }
}
fn names(source: &str, encoding: &Encoding) -> Field<Vec<EffortName>> {
    if source == "null" {
        return Field::Missing;
    }
    let values: Option<Vec<String>> = match encoding {
        Encoding::List => serde_json::from_str(source).ok(),
        Encoding::Csv => serde_json::from_str::<String>(source).ok().map(|source| {
            source
                .split(',')
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
                .collect()
        }),
    };
    values
        .and_then(|values| {
            if values.len() > 128 {
                None
            } else {
                values
                    .into_iter()
                    .filter(|value| !value.is_empty())
                    .map(EffortName::try_from)
                    .collect::<Result<Vec<_>, _>>()
                    .ok()
            }
        })
        .map_or(Field::Invalid, |values| {
            if values.is_empty() {
                Field::Missing
            } else {
                Field::Known(values)
            }
        })
}
fn path(source: &str, keys: &[PathKey], encoding: &Encoding) -> Field<Vec<EffortName>> {
    let Some((key, rest)) = keys.split_first() else {
        return names(source, encoding);
    };
    if source.starts_with('[') {
        let Ok(values) = serde_json::from_str::<Vec<Box<RawValue>>>(source) else {
            return Field::Invalid;
        };
        for value in values {
            let result = path(value.get(), keys, encoding);
            if !matches!(result, Field::Missing) {
                return result;
            }
        }
        Field::Missing
    } else if source.starts_with('{') {
        let Ok(raw) = serde_json::from_str::<RawMetadata>(source) else {
            return Field::Invalid;
        };
        raw.first(&[&key.0])
            .map_or(Field::Missing, |source| path(source, rest, encoding))
    } else {
        Field::Missing
    }
}
impl EffortSpecs {
    pub(super) fn read(&self, raw: &RawMetadata) -> Field<Vec<EffortName>> {
        if let Some(value) = raw.first(&["reasoning-efforts"]) {
            let names = names(value, &Encoding::List);
            if matches!(names, Field::Known(_)) {
                return names;
            }
        }
        let mut invalid = false;
        for spec in &self.0 {
            let Some((first, rest)) = spec.path.0.split_first() else {
                continue;
            };
            let Some(source) = raw.first(&[&first.0]) else {
                continue;
            };
            match path(source, rest, &spec.encoding) {
                known @ Field::Known(_) => return known,
                Field::Invalid => invalid = true,
                Field::Missing => {}
            }
        }
        if invalid {
            Field::Invalid
        } else {
            Field::Missing
        }
    }
}
