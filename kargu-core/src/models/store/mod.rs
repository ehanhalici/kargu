//! Single-writer atomic metadata publication with consuming preparation.
//!
//! An unprepared update is not a commit token:
//! ```compile_fail
//! use kargu_core::models::store::{ModelStore, ModelUpdate};
//! fn wrong(store: &mut ModelStore, update: ModelUpdate) { store.commit(update); }
//! ```

mod domain;
use crate::{
    constants::limits,
    domain::ApiProviderId,
    domain::ModelId,
    models::metadata::{EffortSpecs, ModelFields, RawMetadata},
};
use domain::Operation;
pub use domain::{MetadataRevision, ModelUpdate, StoreError};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json, value::RawValue};
use std::collections::{BTreeMap, BTreeSet};

/// Immutable native model authority captured before preparation IO.
#[derive(Clone, Default)]
pub(crate) struct RunModelPolicy {
    pub tools: bool,
    pub reasoning: bool,
    pub parameters: Option<Vec<String>>,
    pub efforts: Option<Vec<crate::models::metadata::EffortName>>,
    compact_threshold: crate::history::CompactThreshold,
}
impl RunModelPolicy {
    pub(crate) fn compact_threshold(&self) -> crate::history::CompactThreshold {
        self.compact_threshold
    }
}

/// Summary DTO for UI presentation of a model's capabilities.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ModelSummaryDto {
    /// Canonical model identity.
    pub id: String,
    /// Context window in tokens, or None if unknown.
    pub context_window: Option<u64>,
    /// Max output tokens, or None if unknown.
    pub max_output: Option<u64>,
    /// Declared reasoning effort labels (e.g. ["low", "medium", "high"]).
    pub reasoning_efforts: Vec<String>,
    /// Preformatted price label (e.g. "$3.00/M"), or None if unknown.
    pub price_label: Option<String>,
    /// True if model is free or known zero-cost.
    pub free: bool,
    /// True if model supports vision.
    pub vision: bool,
    /// True if model allows tools.
    pub supports_tools: bool,
    /// True if model allows reasoning.
    pub supports_reasoning: bool,
}

#[derive(Clone, Default)]
struct Entry {
    raw: Option<RawMetadata>,
    overrides: BTreeMap<String, Box<RawValue>>,
}
impl Entry {
    fn effective(&self) -> Result<RawMetadata, StoreError> {
        let mut raw = self.raw.clone().unwrap_or(RawMetadata::try_from("{}")?);
        for (key, value) in &self.overrides {
            raw.set(key, value.clone());
        }
        Ok(raw)
    }
    fn retained_bytes(&self) -> usize {
        self.overrides.iter().fold(
            self.raw.as_ref().map_or(0, RawMetadata::retained_bytes),
            |bytes, (key, value)| {
                bytes
                    .saturating_add(key.len())
                    .saturating_add(value.get().len())
            },
        )
    }
}
#[derive(Clone, Default)]
struct Provider {
    entries: BTreeMap<ModelId, Entry>,
    advertised: Vec<ModelId>,
    refused: BTreeSet<ModelId>,
    specs: EffortSpecs,
}
#[derive(Clone, Copy, Eq, PartialEq)]
struct StoreId(uuid::Uuid);
fn alias<'a>(
    entries: &'a BTreeMap<ModelId, Entry>,
    id: &'a ModelId,
) -> Result<&'a ModelId, StoreError> {
    if let Some((canonical, _)) = entries.get_key_value(id) {
        return Ok(canonical);
    }
    if id.as_str().contains('/') {
        return Ok(id);
    }
    let suffix = format!("/{}", id.as_str());
    let mut matches = entries
        .keys()
        .filter(|candidate| candidate.as_str().ends_with(&suffix));
    let found = matches.next();
    if matches.next().is_some() {
        return Err(StoreError::Ambiguous);
    }
    Ok(found.unwrap_or(id))
}

/// A completed pure preparation; consumed exactly once by its original writer.
pub struct PreparedUpdate {
    owner: StoreId,
    base: MetadataRevision,
    revision: MetadataRevision,
    providers: BTreeMap<ApiProviderId, Provider>,
    snapshot: Value,
    snapshot_json: String,
}
/// Authoritative application metadata state. No IO or independently mutable view.
pub struct ModelStore {
    owner: StoreId,
    revision: MetadataRevision,
    providers: BTreeMap<ApiProviderId, Provider>,
    snapshot: Value,
    snapshot_json: String,
}
impl Default for ModelStore {
    fn default() -> Self {
        Self::new()
    }
}
impl ModelStore {
    /// Construct an empty, uniquely owned publication lifetime.
    pub fn new() -> Self {
        let snapshot = json!({"revision":0,"records":[],"aliases":[],"catalogs":[],"refusals":[],"defaults":unknown_view()});
        let snapshot_json = snapshot.to_string();
        Self {
            owner: StoreId(uuid::Uuid::new_v4()),
            revision: MetadataRevision::default(),
            providers: BTreeMap::new(),
            snapshot,
            snapshot_json,
        }
    }
    /// Borrow the immutable last committed projection; never applies staging.
    pub fn snapshot(&self) -> &Value {
        &self.snapshot
    }
    /// Current committed revision, not a submitted intent acknowledgement.
    pub fn revision(&self) -> MetadataRevision {
        self.revision
    }
    pub(crate) fn snapshot_json(&self) -> &str {
        &self.snapshot_json
    }
    /// Prepare a complete candidate without mutating live state or awaiting IO.
    pub fn prepare(
        &self,
        provider: ApiProviderId,
        update: ModelUpdate,
        specs: EffortSpecs,
    ) -> Result<PreparedUpdate, StoreError> {
        let mut providers = self.providers.clone();
        let entry = providers.entry(provider).or_default();
        if matches!(
            &update.0,
            Operation::Put { .. } | Operation::Override { .. } | Operation::ReplaceCatalog(_)
        ) {
            entry.specs = specs;
        }
        match update.0 {
            Operation::Put { model, metadata } => {
                entry.entries.entry(model).or_default().raw = Some(metadata)
            }
            Operation::Override {
                model,
                property,
                value,
            } => {
                let model = alias(&entry.entries, &model)?.clone();
                entry
                    .entries
                    .entry(model)
                    .or_default()
                    .overrides
                    .insert(property.as_str().to_owned(), value);
            }
            Operation::ReplaceCatalog(catalog) => {
                let mut fresh = BTreeSet::new();
                entry.advertised.clear();
                for (model, source) in catalog.into_records() {
                    if fresh.insert(model.clone()) {
                        entry.advertised.push(model.clone());
                    }
                    entry.entries.entry(model).or_default().raw =
                        Some(RawMetadata::try_from(source.get())?);
                }
                entry.entries.retain(|model, record| {
                    if fresh.contains(model) {
                        true
                    } else {
                        record.raw = None;
                        !record.overrides.is_empty()
                    }
                });
            }
            Operation::RefuseTools(model) => {
                entry.refused.insert(model);
            }
            Operation::ClearToolRefusals => {
                for provider in providers.values_mut() {
                    provider.refused.clear();
                }
            }
        }
        let count = providers.values().fold(0_usize, |count, provider| {
            count
                .saturating_add(provider.entries.len())
                .saturating_add(provider.refused.len())
        });
        let bytes = providers.iter().fold(0_usize, |bytes, (id, provider)| {
            let bytes = provider
                .refused
                .iter()
                .fold(bytes, |bytes, id| bytes.saturating_add(id.as_str().len()));
            provider.entries.iter().fold(
                bytes.saturating_add(id.as_str().len()),
                |bytes, (id, record)| {
                    bytes
                        .saturating_add(id.as_str().len())
                        .saturating_add(record.retained_bytes())
                },
            )
        });
        if providers.len() > 256
            || count > limits::MODEL_CATALOG_RECORDS
            || bytes > limits::MODEL_CATALOG_BYTES
        {
            return Err(StoreError::Limit);
        }
        let revision = self.revision.next()?;
        let snapshot = projection(revision, &providers)?;
        let snapshot_json = serde_json::to_string(&snapshot).map_err(|_| StoreError::Invalid)?;
        if snapshot_json.len() > limits::MODEL_SNAPSHOT_BYTES {
            return Err(StoreError::Limit);
        }
        Ok(PreparedUpdate {
            owner: self.owner,
            base: self.revision,
            revision,
            providers,
            snapshot,
            snapshot_json,
        })
    }
    /// Commit once, refusing another owner or a candidate superseded by a commit.
    pub fn commit(&mut self, update: PreparedUpdate) -> Result<MetadataRevision, StoreError> {
        if update.owner != self.owner || update.base != self.revision {
            return Err(StoreError::Stale);
        }
        self.providers = update.providers;
        self.revision = update.revision;
        self.snapshot = update.snapshot;
        self.snapshot_json = update.snapshot_json;
        Ok(self.revision)
    }
    /// Return models for a specific provider in summary DTO format.
    pub fn provider_models(&self, provider: &ApiProviderId) -> Vec<ModelSummaryDto> {
        let Some(p) = self.providers.get(provider) else {
            return Vec::new();
        };
        let mut results = Vec::new();
        let mut seen = BTreeSet::new();
        for id in &p.advertised {
            if seen.insert(id.clone())
                && let Some(dto) = self.entry_summary(p, id)
            {
                results.push(dto);
            }
        }
        for id in p.entries.keys() {
            if seen.insert(id.clone())
                && let Some(dto) = self.entry_summary(p, id)
            {
                results.push(dto);
            }
        }
        results
    }
    /// Capture request capabilities from the actual publication, with exact-only parameters.
    pub(crate) fn run_policy(
        &self,
        provider: &ApiProviderId,
        model: &ModelId,
    ) -> Result<RunModelPolicy, StoreError> {
        let Some(p) = self.providers.get(provider) else {
            return Ok(RunModelPolicy {
                tools: true,
                ..Default::default()
            });
        };
        let canonical = alias(&p.entries, model).ok();
        let fields = canonical
            .and_then(|id| p.entries.get(id))
            .map(|entry| {
                entry
                    .effective()
                    .map(|raw| ModelFields::from_raw(&raw, &p.specs))
            })
            .transpose()?;
        let tools = fields.as_ref().is_none_or(ModelFields::allows_tools)
            && !p.refused.contains(model)
            && canonical.is_none_or(|id| !p.refused.contains(id));
        let parameters = if p.entries.contains_key(model) {
            fields.as_ref().and_then(ModelFields::request_parameters)
        } else {
            None
        };
        let efforts = if p.entries.contains_key(model) {
            fields.as_ref().and_then(ModelFields::request_efforts)
        } else {
            None
        };
        let compact_threshold =
            crate::history::CompactThreshold::from_context_window(fields.as_ref().and_then(|f| {
                f.display_snapshot()
                    .get("context-window")
                    .and_then(Value::as_u64)
            }));
        Ok(RunModelPolicy {
            tools,
            reasoning: fields.as_ref().is_some_and(ModelFields::allows_reasoning),
            parameters,
            efforts,
            compact_threshold,
        })
    }
    fn entry_summary(&self, p: &Provider, id: &ModelId) -> Option<ModelSummaryDto> {
        let entry = p.entries.get(id)?;
        let raw = entry.effective().ok()?;
        let fields = ModelFields::from_raw(&raw, &p.specs);
        let display = fields.display_snapshot();
        let efforts = display
            .get("reasoning-efforts")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default();
        let price_label = display
            .get("price-label")
            .and_then(|v| v.as_str().map(String::from));
        let free = display
            .get("free")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let vision = display
            .get("vision")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let context_window = display.get("context-window").and_then(|v| v.as_u64());
        let max_output = display.get("max-output").and_then(|v| v.as_u64());
        Some(ModelSummaryDto {
            id: id.as_str().to_owned(),
            context_window,
            max_output,
            reasoning_efforts: efforts,
            price_label,
            free,
            vision,
            supports_tools: fields.allows_tools() && !p.refused.contains(id),
            supports_reasoning: fields.allows_reasoning(),
        })
    }
    /// Directly replace a provider's model catalog in live store.
    pub fn update_catalog(
        &mut self,
        provider: ApiProviderId,
        catalog: crate::models::catalog::ModelCatalog,
        specs: EffortSpecs,
    ) -> Result<MetadataRevision, StoreError> {
        let update = ModelUpdate::replace_catalog(catalog);
        let prepared = self.prepare(provider, update, specs)?;
        self.commit(prepared)
    }
}
/// The unprefixed name of a `vendor/model` id, if it has a non-empty one.
fn basename(model: &ModelId) -> Option<&str> {
    model
        .as_str()
        .rsplit_once('/')
        .map(|(_, basename)| basename)
        .filter(|basename| !basename.is_empty())
}

fn refuses(provider: &Provider, name: &str) -> bool {
    provider
        .refused
        .iter()
        .any(|refused| refused.as_str() == name)
}

/// Short alias to its model and tool flag; `None` when two models share it.
type ShortAliases<'a> = BTreeMap<&'a str, Option<(&'a ModelId, bool)>>;

/// Push one provider's model records; return its unambiguous short aliases.
fn model_records<'a>(
    id: &ApiProviderId,
    provider: &'a Provider,
    records: &mut Vec<Value>,
) -> Result<ShortAliases<'a>, StoreError> {
    let mut short = ShortAliases::new();
    for (model, record) in &provider.entries {
        let raw = record.effective()?;
        let fields = ModelFields::from_raw(&raw, &provider.specs);
        let mut metadata = raw.snapshot()?;
        let object = metadata.as_object_mut().ok_or(StoreError::Invalid)?;
        object.insert("provider".to_owned(), json!(id));
        object.insert("id".to_owned(), json!(model));
        records.push(json!({"provider":id,"id":model,"metadata":metadata,"fields":fields,"display":fields.display_snapshot(),
            "tools":fields.allows_tools() && !provider.refused.contains(model),"reasoning":fields.allows_reasoning(),"input_zero":fields.input_is_zero()}));
        if let Some(basename) = basename(model) {
            let tools = fields.allows_tools() && !refuses(provider, basename);
            short
                .entry(basename)
                .and_modify(|value| *value = None)
                .or_insert(Some((model, tools)));
        }
    }
    Ok(short)
}

fn projection(
    revision: MetadataRevision,
    providers: &BTreeMap<ApiProviderId, Provider>,
) -> Result<Value, StoreError> {
    let mut records = Vec::new();
    let mut aliases = Vec::new();
    let mut catalogs = Vec::new();
    let mut refusals = Vec::new();
    for (id, provider) in providers {
        catalogs.push(json!({"provider":id,"models":provider.advertised}));
        for model in &provider.refused {
            refusals.push(json!({"provider":id,"id":model,"tools":false}));
        }
        let short = model_records(id, provider, &mut records)?;
        for (name, (model, tools)) in short
            .into_iter()
            .filter_map(|(name, model)| Some((name, model?)))
        {
            aliases.push(json!({"provider":id,"alias":name,"id":model,"tools":tools}));
        }
    }
    Ok(
        json!({"revision":revision,"records":records,"aliases":aliases,"catalogs":catalogs,"refusals":refusals,"defaults":unknown_view()}),
    )
}

fn unknown_view() -> Value {
    let fields = ModelFields::default();
    json!({"metadata":null,"fields":fields,"display":fields.display_snapshot(),"tools":fields.allows_tools(),"reasoning":fields.allows_reasoning(),"input_zero":false})
}
