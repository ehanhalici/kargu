//! Distinct bounded semantic strings; opaque raw JSON is not one of these.

use super::MetadataError;
use serde::{Deserialize, Serialize};

macro_rules! text {
    ($name:ident, $limit:literal, $doc:literal) => {
        #[doc = $doc]
        #[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
        #[serde(try_from = "String")]
        pub struct $name(String);
        impl TryFrom<String> for $name {
            type Error = MetadataError;
            fn try_from(value: String) -> Result<Self, Self::Error> {
                if value.is_empty() || value.len() > $limit || value.chars().any(char::is_control) {
                    return Err(MetadataError::Shape);
                }
                Ok(Self(value))
            }
        }
        impl $name {
            pub(super) fn as_str(&self) -> &str {
                &self.0
            }
        }
    };
}
text!(
    ParameterName,
    256,
    "One declared request parameter, not a reasoning effort."
);
text!(
    MetadataLabel,
    1025,
    "A finite printable metadata display label."
);
