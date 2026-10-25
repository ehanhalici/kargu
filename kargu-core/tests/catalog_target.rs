//! Endpoint/auth projection boundaries, including actual host epoch admission.

use kargu_core::{application::host::Host, providers::catalog_target::CatalogTargetInput};
use serde_json::{Value, json};
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn input(base: &str) -> Value {
    json!({"provider":"fixture","configuration_revision":7,"api_base":base,
        "default_api":null,"models_api":null,"models_auth":null,"native_models":null})
}
fn resolve(value: Value) -> Result<Value, Box<dyn std::error::Error>> {
    let parsed: CatalogTargetInput = serde_json::from_value(value)?;
    Ok(serde_json::to_value(parsed.resolve()?)?)
}

#[test]
fn dedicated_public_and_private_targets_are_distinct() -> TestResult {
    let mut args = input("https://provider.invalid/v1/");
    args["default_api"] = json!("https://provider.invalid/v1");
    args["models_api"] = json!("https://catalog.invalid/public/models");
    args["models_auth"] = json!("none");
    let target = resolve(args.clone())?;
    assert_eq!(target["url"], "https://catalog.invalid/public/models");
    assert_eq!(target["authentication"], "public");
    assert_eq!(target["configuration_revision"], 7);
    args["models_auth"] = json!("required");
    assert_eq!(resolve(args)?["authentication"], "provider");
    Ok(())
}

#[test]
fn override_never_inherits_public_even_if_derived_url_matches() -> TestResult {
    let mut args = input("https://custom.invalid");
    args["default_api"] = json!("https://default.invalid/v1");
    args["models_api"] = json!("https://custom.invalid/models");
    args["models_auth"] = json!("none");
    let target = resolve(args)?;
    assert_eq!(target["url"], "https://custom.invalid/models");
    assert_eq!(target["authentication"], "provider");
    let mut query = input("https://custom.invalid/v1?tenant=x/");
    query["default_api"] = json!("https://custom.invalid/v1?tenant=x");
    query["models_api"] = json!("https://custom.invalid/public/models");
    query["models_auth"] = json!("none");
    let target = resolve(query)?;
    assert_eq!(target["url"], "https://custom.invalid/v1/models?tenant=x/");
    assert_eq!(target["authentication"], "provider");
    Ok(())
}

#[test]
fn native_and_compatible_paths_preserve_queries_and_complete_models_paths() -> TestResult {
    for (base, expected) in [
        ("http://127.0.0.1:11434", "http://127.0.0.1:11434/api/tags"),
        (
            "http://127.0.0.1:11434/v1",
            "http://127.0.0.1:11434/v1/models",
        ),
        (
            "http://127.0.0.1:11434/v1?tenant=synthetic",
            "http://127.0.0.1:11434/v1/models?tenant=synthetic",
        ),
        (
            "http://127.0.0.1:11434/models?tenant=x",
            "http://127.0.0.1:11434/models?tenant=x",
        ),
    ] {
        let mut args = input(base);
        args["default_api"] = json!("https://default.invalid");
        args["native_models"] = json!({"path":"/api/tags","unless-suffix":"/v1"});
        assert_eq!(resolve(args)?["url"], expected);
    }
    assert_eq!(
        resolve(input("https://custom.invalid/v1?key=a%2Fb&x=1"))?["url"],
        "https://custom.invalid/v1/models?key=a%2Fb&x=1"
    );
    Ok(())
}

#[test]
fn unresolved_default_template_does_not_invalidate_explicit_custom_base() -> TestResult {
    let mut args = input("https://configured.invalid/v1");
    args["default_api"] = json!("https://${AZURE_RESOURCE}.example.invalid/v1");
    args["models_api"] = json!("https://${AZURE_RESOURCE}.example.invalid/models");
    assert_eq!(
        resolve(args)?["url"],
        "https://configured.invalid/v1/models"
    );
    Ok(())
}

#[test]
fn malformed_input_and_metadata_fail_at_the_typed_boundary() {
    for (field, invalid) in [
        ("provider", json!("")),
        ("configuration_revision", json!(-1)),
        ("configuration_revision", json!(1.5)),
        ("configuration_revision", json!("7")),
        ("api_base", json!("file:///tmp/private")),
        (
            "api_base",
            json!("https://user:synthetic-secret@host.invalid"),
        ),
        ("api_base", json!("https://host.invalid/v1#private")),
        ("api_base", json!(" https://host.invalid/v1")),
        ("api_base", json!("https://${UNRESOLVED}.invalid/v1")),
        (
            "api_base",
            json!(format!("https://host.invalid/{}", "x".repeat(8192))),
        ),
        ("models_auth", json!("optional")),
        ("native_models", json!({"path":"//foreign.invalid/models"})),
        ("native_models", json!({"path":"/../models"})),
        ("native_models", json!({"path":"/models?synthetic-secret"})),
        (
            "native_models",
            json!({"path":"/models","unless-suffix":42}),
        ),
        ("native_models", json!({"path":"/models","unknown":true})),
        ("unknown", json!(true)),
    ] {
        let mut args = input("https://host.invalid/v1");
        args[field] = invalid;
        let result = resolve(args);
        assert!(result.is_err(), "accepted invalid target field {field}");
        if let Err(error) = result {
            assert!(!error.to_string().contains("synthetic-secret"));
        }
    }
}

#[test]
fn maximum_integer_revision_survives_without_float_conversion() -> TestResult {
    let mut args = input("https://host.invalid/v1");
    args["configuration_revision"] = json!(u64::MAX);
    assert_eq!(
        resolve(args)?["configuration_revision"].as_u64(),
        Some(u64::MAX)
    );
    Ok(())
}

#[test]
fn host_projection_is_readonly_epoch_bound_and_requires_ready_request() -> TestResult {
    let mut host = Host::new();
    let arguments = input("https://host.invalid/v1");
    assert!(
        host.dispatch("provider/catalogTarget", json!({}), true)
            .result
            .is_err()
    );
    let init = host
        .dispatch(
            "initialize",
            json!({"protocol_major":1,"protocol_minor":0,
        "client_version":"fixture","capabilities":[],"limits":{"max_frame_bytes":1048576}}),
            true,
        )
        .result
        .map_err(|_| "initialize failed")?;
    let request = json!({"connection_epoch":init["connection_epoch"],"arguments":arguments});
    assert!(
        host.dispatch("provider/catalogTarget", request.clone(), true)
            .result
            .is_err()
    );
    host.dispatch("initialized", json!({}), false)
        .result
        .map_err(|_| "ready failed")?;
    assert!(
        host.dispatch("provider/catalogTarget", request.clone(), false)
            .result
            .is_err()
    );
    let actual = host
        .dispatch("provider/catalogTarget", request.clone(), true)
        .result
        .map_err(|_| "target failed")?;
    assert_eq!(actual, resolve(arguments)?);
    let mut foreign = request;
    foreign["connection_epoch"] = json!("old-epoch");
    let fault = host
        .dispatch("provider/catalogTarget", foreign, true)
        .result
        .err()
        .ok_or("accepted foreign epoch")?;
    assert_eq!(fault.status, "stale_owner");
    assert!(host.dispatch("ping", json!({}), true).result.is_ok());
    Ok(())
}
