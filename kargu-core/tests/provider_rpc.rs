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

#[test]
fn test_provider_list_dto_fields_and_namespace_and_no_secrets()
-> Result<(), Box<dyn std::error::Error>> {
    let mut host = create_ready_host();
    let dispatch = host.dispatch(methods::PROVIDER_LIST, json!({}), true);
    assert!(dispatch.result.is_ok());
    let value = dispatch.result?;
    assert_eq!(value["status"], "ok");
    assert!(value["config_revision"].is_number());
    let providers = value["providers"].as_array().ok_or("providers array")?;
    for p in providers {
        assert!(p["id"].is_string());
        assert!(p["name"].is_string());
        assert!(matches!(
            p["namespace"].as_str(),
            Some("embedded" | "api" | "custom" | "application")
        ));
        assert!(matches!(
            p["readiness"].as_str(),
            Some("ready" | "available")
        ));
        assert!(matches!(
            p["availability"].as_str(),
            Some("ready" | "available")
        ));
        assert!(p["config_revision"].is_number());
        assert!(p["authenticated"].is_boolean());
        assert!(p["status"].is_string());

        // Zero secret leaks
        assert!(p.get("apikey").is_none());
        assert!(p.get("secret").is_none());
        assert!(p.get("api_key").is_none());
        assert!(p.get("headers").is_none());
        assert!(p.get("extra_headers").is_none());
    }
    Ok(())
}

#[test]
fn test_provider_list_with_configured_profiles_and_duplicate_names()
-> Result<(), Box<dyn std::error::Error>> {
    let mut host = create_ready_host();
    let app_res = host.dispatch("application/create", json!({}), true);
    assert!(app_res.result.is_ok());
    let app_id = app_res.result?["application_id"]
        .as_str()
        .ok_or("app_id")?
        .to_string();

    let sess_res = host.dispatch("session/create", json!({"application_id": app_id}), true);
    assert!(sess_res.result.is_ok());
    let scope = sess_res.result?;

    let toml_source = "provider='openrouter'\n\
[providers.openrouter]\n\
apikey='synthetic-openrouter-secret'\n\
[providers.p1]\n\
api='https://p1.invalid/v1'\n\
apikey='synthetic-p1-secret'\n\
[providers.p2]\n\
api='https://p2.invalid/v1'\n\
apikey='synthetic-p2-secret'\n\
[providers.codex]\n\
api='http://127.0.0.1:8080/v1'\n";

    let parsed: kargu_core::configuration::ParseInput =
        serde_json::from_value(json!({"source": toml_source, "generation": 0}))?;
    let resolved = parsed.resolve();
    assert_eq!(resolved["status"], "ok");
    let parsed_doc = resolved["config"].clone();

    let prep_res = host.dispatch(
        "configuration/prepare",
        json!({
            "scope": scope,
            "arguments": {
                "generation": 1,
                "path": "/fake/config.toml",
                "digest": resolved["digest"],
                "document": parsed_doc,
                "registry": []
            }
        }),
        true,
    );
    assert!(
        prep_res.result.is_ok(),
        "prepare failed: {:?}",
        prep_res.result
    );
    let capture_id = prep_res.result?["capture_id"].clone();

    let commit_res = host.dispatch(
        "configuration/commit",
        json!({
            "scope": scope,
            "arguments": {
                "capture_id": capture_id,
                "context": {
                    "api_base": "https://fallback.invalid/v1",
                    "environment": {},
                    "registry": []
                }
            }
        }),
        true,
    );
    assert!(
        commit_res.result.is_ok(),
        "commit failed: {:?}",
        commit_res.result
    );
    let config_rev = commit_res.result?["revision"].as_u64().ok_or("rev")?;

    let list_res = host.dispatch(
        methods::PROVIDER_LIST,
        json!({
            "application_id": app_id
        }),
        true,
    );
    assert!(
        list_res.result.is_ok(),
        "provider/list failed: {:?}",
        list_res.result
    );
    let value = list_res.result?;
    assert_eq!(value["status"], "ok");
    assert_eq!(value["config_revision"], config_rev);

    let providers = value["providers"].as_array().ok_or("providers array")?;

    // 1. Check openrouter (configured from catalog -> api namespace)
    let openrouter = providers
        .iter()
        .find(|p| p["id"] == "openrouter")
        .ok_or("openrouter found")?;
    assert_eq!(openrouter["namespace"], "api");
    assert_eq!(openrouter["authenticated"], true);
    assert_eq!(openrouter["readiness"], "ready");

    // 2. Check p1 and p2: both exist with distinct IDs
    let p1 = providers
        .iter()
        .find(|p| p["id"] == "p1")
        .ok_or("p1 found")?;
    let p2 = providers
        .iter()
        .find(|p| p["id"] == "p2")
        .ok_or("p2 found")?;
    assert_eq!(p1["namespace"], "custom");
    assert_eq!(p2["namespace"], "custom");
    assert_eq!(p1["authenticated"], true);
    assert_eq!(p2["authenticated"], true);

    // 3. Check codex (application backend)
    let codex = providers
        .iter()
        .find(|p| p["id"] == "codex")
        .ok_or("codex found")?;
    assert_eq!(codex["namespace"], "application");

    // 4. Check an unconfigured catalog provider (e.g. nvidia)
    let nvidia = providers
        .iter()
        .find(|p| p["id"] == "nvidia")
        .ok_or("nvidia found")?;
    assert_eq!(nvidia["namespace"], "embedded");

    // 5. Ensure NO secrets leak anywhere in the JSON
    let rendered = serde_json::to_string(&value)?;
    assert!(!rendered.contains("synthetic-openrouter-secret"));
    assert!(!rendered.contains("synthetic-p1-secret"));
    assert!(!rendered.contains("synthetic-p2-secret"));

    Ok(())
}
