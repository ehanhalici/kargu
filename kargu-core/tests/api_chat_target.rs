//! Chat URL policy is parsed before HTTP authority capture, never in the editor.

use kargu_core::{
    api::{HttpRequest, wire::WireSpec},
    providers::ApiEndpoint,
};
use serde_json::{Value, json};
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn endpoint(spec: WireSpec, base: &str) -> Result<String, Box<dyn std::error::Error>> {
    Ok(spec
        .chat_endpoint(ApiEndpoint::try_from(base.to_owned())?)?
        .into())
}

fn request() -> Value {
    json!({"url":"https://fixture.invalid/v1/?tenant=a%2Fb/","target":"chat",
        "method":"post","headers":{},"body":"{\"model\":\"m\",\"messages\":[]}",
        "stream":false,"timeouts":{"connect_ms":100,"first_byte_ms":100}})
}

#[test]
fn packaged_formats_and_default_derive_paths_without_changing_queries() -> TestResult {
    let catalog: Value = serde_json::from_str(include_str!("../assets/providers.json"))?;
    for (format, suffix) in [("openapi", "/chat/completions"), ("anthropic", "/messages")] {
        for (base, prefix) in [
            ("https://fixture.invalid/", "https://fixture.invalid"),
            (
                "https://fixture.invalid/v1///",
                "https://fixture.invalid/v1",
            ),
            (
                "https://fixture.invalid/a%2Fb/",
                "https://fixture.invalid/a%2Fb",
            ),
        ] {
            let spec = WireSpec::try_from(catalog["formats"][format].clone())?;
            assert_eq!(
                endpoint(spec, &format!("{base}?tenant=a%2Fb/&x=%252F"))?,
                format!("{prefix}{suffix}?tenant=a%2Fb/&x=%252F")
            );
        }
    }
    assert_eq!(
        endpoint(WireSpec::default(), "https://fixture.invalid/v1/")?,
        "https://fixture.invalid/v1/chat/completions"
    );
    assert_eq!(
        endpoint(
            WireSpec::try_from(json!({"chat-path":"/custom/generate"}))?,
            "https://fixture.invalid/v1/?tenant=local/"
        )?,
        "https://fixture.invalid/v1/custom/generate?tenant=local/"
    );
    Ok(())
}

#[test]
fn static_chat_paths_cannot_replace_origin_query_or_traverse() {
    for path in [
        "",
        "messages",
        "//foreign.invalid/messages",
        "/a//b",
        "/../messages",
        "/./messages",
        "/%2e%2e/messages",
        "/a%2Fb",
        "/messages?key=synthetic-secret",
        "/messages#synthetic-secret",
        "/messages\\extra",
        "/messages\n",
        "/${PATH}",
    ] {
        let result = WireSpec::try_from(json!({"chat-path":path}));
        assert!(result.is_err());
        if let Err(error) = result {
            assert!(!error.to_string().contains("synthetic-secret"));
        }
    }
    assert!(WireSpec::try_from(json!({"chat-path":null})).is_err());
    assert!(WireSpec::try_from(json!({"chat-path":42})).is_err());
    assert!(WireSpec::try_from(json!({"chat-path":format!("/{}", "a".repeat(1024))})).is_err());
}

#[test]
fn target_profile_is_closed_post_only_and_bounded_before_io() -> TestResult {
    assert!(serde_json::from_value::<HttpRequest>(request()).is_ok());
    let mut exact = request();
    exact
        .as_object_mut()
        .ok_or("fixture object")?
        .remove("target");
    assert!(serde_json::from_value::<HttpRequest>(exact.clone()).is_ok());
    exact["target"] = json!("exact");
    assert!(serde_json::from_value::<HttpRequest>(exact).is_ok());
    for (field, invalid) in [
        ("target", json!("unknown")),
        ("target", Value::Null),
        ("target", json!(true)),
        ("method", json!("get")),
        ("response_profile", json!("model_catalog")),
        ("wire", json!({"chat-path":"//foreign.invalid/messages"})),
        (
            "url",
            json!(format!("https://fixture.invalid/{}", "a".repeat(8155))),
        ),
    ] {
        let mut value = request();
        value[field] = invalid;
        assert!(serde_json::from_value::<HttpRequest>(value).is_err());
    }
    assert!(kargu_core::constants::protocol::LIFECYCLE_CAPABILITIES.contains(&"api_chat_target"));
    Ok(())
}
