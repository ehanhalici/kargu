//! Strict legacy schema over the TOML parser; no custom TOML lexer or IO.

use super::domain::{ConfigText, ConfigurationError, ProviderName};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use toml::Spanned;
use zeroize::Zeroizing;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Document {
    provider: Option<Spanned<ConfigText>>,
    model: Option<Spanned<ConfigText>>,
    name: Option<Spanned<ConfigText>>,
    api: Option<Spanned<ConfigText>>,
    apikey: Option<Spanned<ConfigText>>,
    review_mode: Option<Spanned<ReviewMode>>,
    providers: Option<BTreeMap<ProviderName, Spanned<Provider>>>,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Provider {
    api: Option<Spanned<ConfigText>>,
    apikey: Option<Spanned<ConfigText>>,
    model: Option<Spanned<ConfigText>>,
    models: Option<Spanned<Vec<Spanned<ConfigText>>>>,
}

#[derive(Deserialize, serde::Serialize)]
#[serde(rename_all = "lowercase")]
enum ReviewMode {
    Auto,
    Async,
    Blocking,
}
fn check_text<T>(source: &str, value: &Spanned<T>) -> Result<(), ConfigurationError> {
    let raw = source
        .get(value.span())
        .ok_or_else(|| ConfigurationError::at(source, 0))?;
    if raw.starts_with("\"\"\"") || raw.starts_with("'''") {
        return Err(ConfigurationError::at(source, value.span().start));
    }
    Ok(())
}
fn nonempty(value: Option<&Spanned<ConfigText>>) -> Value {
    value
        .filter(|value| !value.get_ref().as_str().is_empty())
        .map(|value| value.get_ref().editor_value())
        .unwrap_or(Value::Null)
}
impl Provider {
    fn into_editor(self, source: &str) -> Result<Map<String, Value>, ConfigurationError> {
        let mut result = Map::new();
        for (name, value) in [
            ("api", self.api),
            ("apikey", self.apikey),
            ("model", self.model),
        ] {
            if let Some(value) = value {
                check_text(source, &value)?;
                result.insert(name.to_owned(), value.into_inner().editor_value());
            }
        }
        if let Some(models) = self.models {
            if models.get_ref().len() > 4096 {
                return Err(ConfigurationError::Limit);
            }
            let mut values = Vec::new();
            for model in models.into_inner() {
                check_text(source, &model)?;
                values.push(model.into_inner().editor_value());
            }
            result.insert("models".to_owned(), Value::Array(values));
        }
        Ok(result)
    }
}
impl Document {
    pub(super) fn parse(source: &str) -> Result<Value, ConfigurationError> {
        // Legacy accepted a scalar `provider` beside `[provider.NAME]` tables.
        // Normalize only that header spelling, not values or a TOML grammar.
        // Line boundaries are retained; diagnostics never echo either source.
        let mut normalized = Zeroizing::new(String::with_capacity(source.len()));
        for line in source.split_inclusive('\n') {
            let trimmed = line.trim_start_matches([' ', '\t']);
            if let Some(rest) = trimmed.strip_prefix("[provider.") {
                normalized.push_str(
                    line.get(..line.len().saturating_sub(trimmed.len()))
                        .unwrap_or_default(),
                );
                normalized.push_str("[providers.");
                normalized.push_str(rest);
            } else {
                normalized.push_str(line);
            }
        }
        let document: Self = toml::from_str(&normalized)
            .map_err(|error| ConfigurationError::from_toml(&normalized, error))?;
        document.into_editor(&normalized)
    }

    pub(super) fn into_editor(self, source: &str) -> Result<Value, ConfigurationError> {
        for value in [
            &self.provider,
            &self.model,
            &self.name,
            &self.api,
            &self.apikey,
        ]
        .into_iter()
        .flatten()
        {
            check_text(source, value)?;
        }
        if let Some(review) = &self.review_mode {
            check_text(source, review)?;
        }
        let review = self.review_mode.map(Spanned::into_inner);
        let tables = self.providers.unwrap_or_default();
        let selected = nonempty(self.provider.as_ref());
        if tables.len() > 512 {
            return Err(ConfigurationError::Limit);
        }
        let mut ordered: Vec<_> = tables.into_iter().collect();
        ordered.sort_by_key(|(_, provider)| provider.span().start);
        let mut providers = Vec::new();
        for (name, provider) in ordered {
            if source
                .get(provider.span())
                .is_some_and(|text| text.starts_with('{'))
            {
                return Err(ConfigurationError::at(source, provider.span().start));
            }
            let data = provider.into_inner().into_editor(source)?;
            if !data.is_empty() {
                providers.push(json!({"name":name.editor_value(),"data":data}));
            }
        }
        let model = if self
            .model
            .as_ref()
            .is_some_and(|value| !value.get_ref().as_str().is_empty())
        {
            nonempty(self.model.as_ref())
        } else {
            nonempty(self.name.as_ref())
        };
        if providers.is_empty()
            && (self.api.is_some()
                || self.apikey.is_some()
                || self.name.is_some()
                || self.model.is_some())
        {
            let mut data = Map::new();
            if let Some(value) = self.api {
                data.insert("api".to_owned(), value.into_inner().editor_value());
            }
            if let Some(value) = self.apikey {
                data.insert("apikey".to_owned(), value.into_inner().editor_value());
            }
            if let Some(value) = self.model.or(self.name) {
                data.insert(
                    "models".to_owned(),
                    json!([value.into_inner().editor_value()]),
                );
            }
            providers.push(json!({"name":"default","data":data}));
        }
        Ok(json!({"provider":selected,"model":model,"review-mode":review,"providers":providers}))
    }
}
