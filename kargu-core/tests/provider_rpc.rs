//! Tests for provider/list, model/list and catalog fetching.

use kargu_core::{
    application::host::Host, constants::protocol::methods, providers::ProviderCatalog,
};
use serde_json::json;

fn create_ready_host() -> Host {
    let mut host = Host::new();
    let init_res = host.dispatch(
        "initialize",
        json!({
            "protocol_major": 1,
            "protocol_minor": 0,
            "client_version": "test",
            "capabilities": [],
            "limits": {
                "max_frame_bytes": 1048576
            }
        }),
        true,
    );
    assert!(init_res.result.is_ok());
    let initialized_res = host.dispatch("initialized", json!({}), false);
    assert!(initialized_res.result.is_ok());
    host
}

#[test]
fn test_provider_list_returns_embedded_and_configured_providers()
-> Result<(), Box<dyn std::error::Error>> {
    let mut host = create_ready_host();
    let dispatch = host.dispatch(methods::PROVIDER_LIST, json!({}), true);
    assert!(
        dispatch.result.is_ok(),
        "provider/list failed: {:?}",
        dispatch.result
    );
    let value = dispatch.result?;
    assert_eq!(value["status"], "ok");
    let providers = value["providers"].as_array().ok_or("providers is array")?;
    assert!(!providers.is_empty());

    // Verify presence of standard providers
    let openrouter = providers
        .iter()
        .find(|p| p["id"] == "openrouter")
        .ok_or("openrouter found")?;
    assert_eq!(openrouter["name"], "OpenRouter");

    let nvidia = providers
        .iter()
        .find(|p| p["id"] == "nvidia")
        .ok_or("nvidia found")?;
    assert_eq!(nvidia["name"], "Nvidia");

    let opencode = providers
        .iter()
        .find(|p| p["id"] == "opencode")
        .ok_or("opencode found")?;
    assert_eq!(opencode["name"], "OpenCode Zen");
    Ok(())
}

#[test]
fn test_model_list_returns_models_for_provider() -> Result<(), Box<dyn std::error::Error>> {
    let mut host = create_ready_host();
    let dispatch = host.dispatch(
        methods::MODEL_LIST,
        json!({
            "provider": "openrouter"
        }),
        true,
    );
    assert!(
        dispatch.result.is_ok(),
        "model/list failed: {:?}",
        dispatch.result
    );
    let value = dispatch.result?;
    assert_eq!(value["status"], "ok");
    assert_eq!(value["provider"], "openrouter");
    let models = value["models"].as_array().ok_or("models is array")?;
    assert!(!models.is_empty(), "models should not be empty");

    for m in models {
        assert!(m["id"].is_string());
        assert!(m["supports_tools"].is_boolean());
        assert!(m["supports_reasoning"].is_boolean());
        assert!(m["reasoning_efforts"].is_array());
    }
    Ok(())
}

#[test]
fn test_catalog_effort_specs_extraction() -> Result<(), Box<dyn std::error::Error>> {
    let catalog = ProviderCatalog::embedded()?;
    let openrouter_id = kargu_core::providers::ApiProviderId::try_from("openrouter".to_string())?;
    let specs = catalog.effort_specs(&openrouter_id);

    // Parse a synthetic metadata record with openrouter reasoning specs
    let source = r#"{"id":"test-model","reasoning":{"supported_efforts":["low","high"]}}"#;
    let meta = kargu_core::models::metadata::ModelMetadata::parse(source, &specs)?;
    assert!(meta.fields().allows_reasoning());
    let display = meta.fields().display_snapshot();
    let efforts = display["reasoning-efforts"]
        .as_array()
        .ok_or("efforts array")?;
    assert_eq!(efforts.len(), 2);
    assert_eq!(efforts[0], "low");
    assert_eq!(efforts[1], "high");
    Ok(())
}

#[test]
fn test_provider_list_authenticated_only() -> Result<(), Box<dyn std::error::Error>> {
    let mut host = create_ready_host();
    let dispatch = host.dispatch(
        methods::PROVIDER_LIST,
        json!({
            "authenticated_only": true
        }),
        true,
    );
    assert!(dispatch.result.is_ok());
    let value = dispatch.result?;
    assert_eq!(value["status"], "ok");
    let providers = value["providers"].as_array().ok_or("expected array")?;
    // Without configured profiles committed yet, authenticated_only does not leak unconfigured catalog providers
    assert!(providers.is_empty() || providers.iter().all(|p| p["authenticated"] == true));
    Ok(())
}

#[test]
fn test_model_list_indicates_fallback_for_unloaded_provider()
-> Result<(), Box<dyn std::error::Error>> {
    let mut host = create_ready_host();
    let dispatch = host.dispatch(
        methods::MODEL_LIST,
        json!({
            "provider": "openrouter"
        }),
        true,
    );
    assert!(dispatch.result.is_ok());
    let value = dispatch.result?;
    assert_eq!(value["status"], "ok");
    assert_eq!(value["fallback"], true);
    assert_eq!(value["cached"], false);
    Ok(())
}

#[test]
fn test_openrouter_definition_models_endpoint() -> Result<(), Box<dyn std::error::Error>> {
    let catalog = ProviderCatalog::embedded()?;
    let openrouter_id = kargu_core::providers::ApiProviderId::try_from("openrouter".to_string())?;
    let def = catalog.get(&openrouter_id).ok_or("openrouter not found")?;
    assert_eq!(
        def.models_endpoint().as_str(),
        "https://openrouter.ai/api/v1/models"
    );
    Ok(())
}

#[test]
fn unknown_application_cannot_borrow_another_provider_or_model_view() {
    let mut host = create_ready_host();
    let foreign = kargu_core::domain::ApplicationId::new();
    for (method, mut params) in [
        (methods::PROVIDER_LIST, json!({})),
        (methods::MODEL_LIST, json!({"provider":"openrouter"})),
    ] {
        params["application_id"] = json!(foreign);
        assert!(host.dispatch(method, params, true).result.is_err());
    }
}
