//! Single-writer atomic metadata publication with consuming preparation.
//!
//! An unprepared update is not a commit token:
//! ```compile_fail
//! use kargu_core::models::store::{ModelStore, ModelUpdate};
//! fn wrong(store: &mut ModelStore, update: ModelUpdate) { store.commit(update); }
//! ```

mod domain;
use crate::{
    api::ModelId,
    constants::limits,
    models::metadata::{EffortSpecs, ModelFields, RawMetadata},
    providers::ApiProviderId,
};
use domain::Operation;
pub use domain::{MetadataRevision, ModelUpdate, StoreError};
use serde_json::{Value, json, value::RawValue};
use std::collections::{BTreeMap, BTreeSet};

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
    owner: uuid::Uuid,
    base: MetadataRevision,
    revision: MetadataRevision,
    providers: BTreeMap<ApiProviderId, Provider>,
    snapshot: Value,
}
/// Authoritative application metadata state. No IO or independently mutable view.
pub struct ModelStore {
    owner: uuid::Uuid,
    revision: MetadataRevision,
    providers: BTreeMap<ApiProviderId, Provider>,
    snapshot: Value,
}
impl Default for ModelStore {
    fn default() -> Self {
        Self::new()
    }
}
impl ModelStore {
    /// Construct an empty, uniquely owned publication lifetime.
    pub fn new() -> Self {
        Self {
            owner: uuid::Uuid::new_v4(),
            revision: MetadataRevision::default(),
            providers: BTreeMap::new(),
            snapshot: json!({"revision":0,"records":[],"aliases":[],"catalogs":[],"refusals":[]}),
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
    /// Prepare a complete candidate without mutating live state or awaiting IO.
    pub fn prepare(
        &self,
        provider: ApiProviderId,
        update: ModelUpdate,
        specs: EffortSpecs,
    ) -> Result<PreparedUpdate, StoreError> {
        let mut providers = self.providers.clone();
        let entry = providers.entry(provider).or_default();
        entry.specs = specs;
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
            Operation::ClearToolRefusals => entry.refused.clear(),
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
        if serde_json::to_vec(&snapshot)
            .map_err(|_| StoreError::Invalid)?
            .len()
            > limits::MODEL_CATALOG_BYTES.saturating_mul(2)
        {
            return Err(StoreError::Limit);
        }
        Ok(PreparedUpdate {
            owner: self.owner,
            base: self.revision,
            revision,
            providers,
            snapshot,
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
        Ok(self.revision)
    }
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
            refusals.push(json!({"provider":id,"id":model}));
        }
        let mut short: BTreeMap<&str, Option<&ModelId>> = BTreeMap::new();
        for (model, record) in &provider.entries {
            let raw = record.effective()?;
            let fields = ModelFields::from_raw(&raw, &provider.specs);
            let mut metadata = raw.snapshot()?;
            let object = metadata.as_object_mut().ok_or(StoreError::Invalid)?;
            object.insert("provider".to_owned(), json!(id));
            object.insert("id".to_owned(), json!(model));
            records.push(json!({"provider":id,"id":model,"metadata":metadata,"fields":fields,
                "tools":fields.allows_tools() && !provider.refused.contains(model),"reasoning":fields.allows_reasoning(),"input_zero":fields.input_is_zero()}));
            if let Some((_, basename)) = model.as_str().rsplit_once('/') {
                short
                    .entry(basename)
                    .and_modify(|value| *value = None)
                    .or_insert(Some(model));
            }
        }
        for (name, model) in short {
            if let Some(model) = model {
                aliases.push(json!({"provider":id,"alias":name,"id":model}));
            }
        }
    }
    Ok(
        json!({"revision":revision,"records":records,"aliases":aliases,"catalogs":catalogs,"refusals":refusals}),
    )
}
