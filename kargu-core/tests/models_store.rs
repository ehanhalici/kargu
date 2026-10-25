//! Revisioned single-writer model ownership, aliases, overrides and atomicity.

use kargu_core::{
    models::{
        metadata::EffortSpecs,
        store::{ModelStore, ModelUpdate, StoreError},
    },
    providers::ApiProviderId,
};
use serde_json::{Value, json};
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn update(store: &mut ModelStore, provider: &str, source: &str) -> TestResult {
    let prepared = store.prepare(
        ApiProviderId::try_from(provider.to_owned())?,
        ModelUpdate::try_from(source)?,
        EffortSpecs::default(),
    )?;
    store.commit(prepared)?;
    Ok(())
}
fn record<'a>(store: &'a ModelStore, provider: &str, model: &str) -> Option<&'a Value> {
    store
        .snapshot()
        .get("records")?
        .as_array()?
        .iter()
        .find(|record| {
            record.get("provider") == Some(&json!(provider))
                && record.get("id") == Some(&json!(model))
        })
}
fn put(model: &str, context: u64) -> String {
    json!({"operation":"put","model":model,"metadata":{"context_length":context}}).to_string()
}

#[test]
fn preparation_is_not_publication_and_commit_is_bound_to_original_owner_and_revision() -> TestResult
{
    let mut first = ModelStore::new();
    let mut other = ModelStore::new();
    let provider = ApiProviderId::try_from("a".to_owned())?;
    let prepared = first.prepare(
        provider.clone(),
        ModelUpdate::try_from(put("Model", 10).as_str())?,
        EffortSpecs::default(),
    )?;
    assert_eq!(first.snapshot().get("revision"), Some(&json!(0)));
    assert!(record(&first, "a", "Model").is_none());
    assert_eq!(other.commit(prepared), Err(StoreError::Stale));
    let older = first.prepare(
        provider,
        ModelUpdate::try_from(put("Model", 10).as_str())?,
        EffortSpecs::default(),
    )?;
    update(&mut first, "a", &put("Model", 20))?;
    assert_eq!(first.commit(older), Err(StoreError::Stale));
    assert_eq!(
        record(&first, "a", "Model")
            .and_then(|record| record.pointer("/fields/context_window/value")),
        Some(&json!(20))
    );
    Ok(())
}

#[test]
fn identity_pairs_and_opaque_model_case_never_collide() -> TestResult {
    let mut store = ModelStore::new();
    for (provider, model, capacity) in [
        (" A ", "Model", 10),
        ("a", "model", 20),
        ("a/b", "c", 30),
        ("a", "b/c", 40),
    ] {
        update(&mut store, provider, &put(model, capacity))?;
    }
    for (provider, model, capacity) in [
        ("a", "Model", 10),
        ("a", "model", 20),
        ("a/b", "c", 30),
        ("a", "b/c", 40),
    ] {
        assert_eq!(
            record(&store, provider, model)
                .and_then(|record| record.pointer("/fields/context_window/value")),
            Some(&json!(capacity))
        );
    }
    Ok(())
}

#[test]
fn unique_alias_override_uses_canonical_record_but_ambiguity_cannot_mutate_state() -> TestResult {
    let mut store = ModelStore::new();
    update(&mut store, "a", &put("vendor/shared", 10))?;
    update(&mut store, "b", &put("other/shared", 20))?;
    update(
        &mut store,
        "a",
        r#"{"operation":"override","model":"shared","property":"context-window","value":99}"#,
    )?;
    assert!(record(&store, "a", "shared").is_none());
    assert_eq!(
        record(&store, "a", "vendor/shared")
            .and_then(|record| record.pointer("/fields/context_window/value")),
        Some(&json!(99))
    );
    update(&mut store, "a", &put("second/shared", 30))?;
    let before = store.snapshot().clone();
    let result = store.prepare(
        ApiProviderId::try_from("a".to_owned())?,
        ModelUpdate::try_from(
            r#"{"operation":"override","model":"shared","property":"context-window","value":88}"#,
        )?,
        EffortSpecs::default(),
    );
    assert!(matches!(result, Err(StoreError::Ambiguous)));
    assert_eq!(store.snapshot(), &before);
    assert!(
        !store
            .snapshot()
            .get("aliases")
            .and_then(Value::as_array)
            .ok_or("aliases missing")?
            .iter()
            .any(|alias| alias.get("provider") == Some(&json!("a"))
                && alias.get("alias") == Some(&json!("shared")))
    );
    update(&mut store, "a", &put("shared", 50))?;
    assert_eq!(
        record(&store, "a", "shared")
            .and_then(|record| record.pointer("/fields/context_window/value")),
        Some(&json!(50))
    );
    Ok(())
}

#[test]
fn catalog_refresh_is_atomic_prunes_provider_only_and_preserves_explicit_overrides() -> TestResult {
    let mut store = ModelStore::new();
    update(&mut store, "a", &put("kept", 10))?;
    update(&mut store, "a", &put("removed", 20))?;
    update(&mut store, "b", &put("removed", 30))?;
    update(
        &mut store,
        "a",
        r#"{"operation":"override","model":"removed","property":"supports-tools","value":false}"#,
    )?;
    update(
        &mut store,
        "a",
        r#"{"operation":"replace_catalog","catalog":{"models":[{"id":"kept","description":"new"},"fresh"]}}"#,
    )?;
    assert_eq!(
        record(&store, "a", "kept")
            .and_then(|record| record.pointer("/fields/context_window/state")),
        Some(&json!("missing"))
    );
    assert_eq!(
        record(&store, "a", "removed").and_then(|record| record.get("tools")),
        Some(&json!(false))
    );
    assert_eq!(
        record(&store, "a", "removed")
            .and_then(|record| record.pointer("/fields/context_window/state")),
        Some(&json!("missing"))
    );
    assert_eq!(
        record(&store, "b", "removed")
            .and_then(|record| record.pointer("/fields/context_window/value")),
        Some(&json!(30))
    );
    update(
        &mut store,
        "a",
        r#"{"operation":"replace_catalog","catalog":[]}"#,
    )?;
    assert!(record(&store, "a", "kept").is_none());
    assert!(record(&store, "a", "fresh").is_none());
    assert!(record(&store, "a", "removed").is_some());
    assert!(record(&store, "b", "removed").is_some());
    Ok(())
}

#[test]
fn refresh_retains_first_id_order_last_record_data_and_exact_source_numbers() -> TestResult {
    let mut store = ModelStore::new();
    update(
        &mut store,
        "a",
        r#"{"operation":"replace_catalog","catalog":[{"id":"models/vendor/Model","context_length":10},"second",{"id":"vendor/Model","context_length":9007199254740992.5,"pricing":{"prompt":0.000000000000000000123456789012345678}}]}"#,
    )?;
    assert_eq!(
        store.snapshot().pointer("/catalogs/0/models"),
        Some(&json!(["vendor/Model", "second"]))
    );
    let record = record(&store, "a", "vendor/Model").ok_or("record missing")?;
    assert_eq!(
        record.pointer("/fields/context_window/state"),
        Some(&json!("invalid"))
    );
    assert_eq!(
        record.pointer("/fields/input_cost/value"),
        Some(&json!("0.000000000000000000123456789012345678"))
    );
    assert_eq!(
        record.pointer("/metadata/pricing/prompt"),
        Some(&json!("0.000000000000000000123456789012345678"))
    );
    Ok(())
}

#[test]
fn invalid_update_never_clears_last_good_snapshot_or_changes_ownership() -> TestResult {
    let mut store = ModelStore::new();
    update(&mut store, "a", &put("good", 10))?;
    let before = store.snapshot().clone();
    for source in [
        r#"{"operation":"replace_catalog","catalog":{"models":null}}"#,
        r#"{"operation":"override","model":"good","property":"provider","value":"b"}"#,
        r#"{"operation":"put","model":"","metadata":{}}"#,
        r#"{"operation":"put","model":"good","metadata":{"context_length":1,"context_length":2}}"#,
    ] {
        assert!(ModelUpdate::try_from(source).is_err());
        assert_eq!(store.snapshot(), &before);
    }
    let mut detached = store.snapshot().clone();
    if let Some(revision) = detached.get_mut("revision") {
        *revision = json!(999);
    }
    assert_eq!(store.snapshot(), &before);
    Ok(())
}

#[test]
fn tool_refusal_identity_is_scoped_and_does_not_mutate_detached_snapshots() -> TestResult {
    let mut store = ModelStore::new();
    update(&mut store, "a", &put("Model", 10))?;
    update(&mut store, "b", &put("Model", 20))?;
    let before = store.snapshot().clone();
    update(
        &mut store,
        "a",
        r#"{"operation":"refuse_tools","model":"Model"}"#,
    )?;
    assert_eq!(
        record(&store, "a", "Model").and_then(|record| record.get("tools")),
        Some(&json!(false))
    );
    assert_eq!(
        record(&store, "b", "Model").and_then(|record| record.get("tools")),
        Some(&json!(true))
    );
    assert_eq!(before.pointer("/records/0/tools"), Some(&json!(true)));
    update(
        &mut store,
        "a",
        r#"{"operation":"refuse_tools","model":"missing"}"#,
    )?;
    assert_eq!(
        store.snapshot().get("refusals"),
        Some(&json!([{"provider":"a","id":"Model"},{"provider":"a","id":"missing"}]))
    );
    update(&mut store, "a", r#"{"operation":"clear_tool_refusals"}"#)?;
    assert_eq!(
        record(&store, "a", "Model").and_then(|record| record.get("tools")),
        Some(&json!(true))
    );
    update(
        &mut store,
        "a",
        r#"{"operation":"put","model":"owned","metadata":{"provider":"foreign","id":"foreign"}}"#,
    )?;
    assert_eq!(
        record(&store, "a", "owned").and_then(|record| record.pointer("/metadata/provider")),
        Some(&json!("a"))
    );
    assert_eq!(
        record(&store, "a", "owned").and_then(|record| record.pointer("/metadata/id")),
        Some(&json!("owned"))
    );
    Ok(())
}
