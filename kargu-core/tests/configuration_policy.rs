//! Native policy and one authoritative application config publication.
use kargu_core::{
    application::host::Host,
    configuration::{
        ParseInput,
        policy::{ConfigurationDocument, PolicyContext, TargetInput, resolve},
    },
    providers::ProviderCatalog,
};
use serde_json::{Value, json};
type TestResult = Result<(), Box<dyn std::error::Error>>;
fn document(source: &str) -> Result<Value, Box<dyn std::error::Error>> {
    let parsed: ParseInput = serde_json::from_value(json!({"source":source,"generation":0}))?;
    let value = parsed.resolve();
    assert_eq!(value["status"], "ok");
    Ok(value["config"].clone())
}
fn context() -> Value {
    json!({"api_base":"http://fallback.invalid/v1","api_key":null,"selected_provider":null,"selected_model":null,"environment":{},"registry":[]})
}
fn target(source: &str, context: Value, input: Value) -> Result<Value, Box<dyn std::error::Error>> {
    let document: ConfigurationDocument = serde_json::from_value(document(source)?)?;
    let context: PolicyContext = serde_json::from_value(context)?;
    Ok(resolve(
        &document,
        &context,
        serde_json::from_value::<TargetInput>(input)?,
        &ProviderCatalog::embedded()?,
    )?
    .into_editor_value())
}
#[test]
fn selection_endpoint_and_global_credential_precedence_preserve_raw_query() -> TestResult {
    let mut captured = context();
    captured["api_key"] = json!("global-private");
    captured["selected_provider"] = json!("custom");
    captured["selected_model"] = json!("selected");
    let source = "provider='top'\nmodel='top-model'\n[providers.custom]\napi='https://fixture.invalid/v1/?tenant=a%2Fb/'\napikey='file-private'\nmodel='configured'\n[providers.other]\napikey='other-private'";
    let value = target(
        source,
        captured.clone(),
        json!({"provider":null,"model":null}),
    )?;
    assert_eq!(value["provider"], "custom");
    assert_eq!(value["model"], "selected");
    assert_eq!(
        value["endpoint"],
        "https://fixture.invalid/v1/?tenant=a%2Fb/"
    );
    assert_eq!(value["credential"]["secret"], "global-private");
    let other = target(
        source,
        captured,
        json!({"provider":"other","model":"explicit"}),
    )?;
    assert_eq!(other["credential"]["secret"], "other-private");
    assert_eq!(other["model"], "explicit");
    assert_eq!(other["endpoint"], "http://fallback.invalid/v1");
    Ok(())
}
#[test]
fn environment_expansion_is_single_pass_and_empty_key_blocks_provider_environment() -> TestResult {
    let mut captured = context();
    captured["registry"] = json!([{"id":"custom","env":["FALLBACK"]}]);
    captured["environment"] = json!({"TOKEN":"${NOT_RECURSIVE}","FALLBACK":"environment-private"});
    let source = "provider='custom'\n[providers.custom]\napikey='prefix-${TOKEN}-suffix'";
    assert_eq!(
        target(source, captured.clone(), json!({}))?["credential"]["secret"],
        "prefix-${NOT_RECURSIVE}-suffix"
    );
    let missing = target(
        "provider='custom'\n[providers.custom]\napikey='private-${MISSING}'",
        captured.clone(),
        json!({}),
    )?;
    assert_eq!(missing["credential"]["secret"], "environment-private");
    assert_eq!(missing["missing_environment"], json!(["MISSING"]));
    assert!(!missing.to_string().contains("private-${"));
    assert_eq!(
        target(
            "provider='custom'\n[providers.custom]\napikey=''",
            captured,
            json!({})
        )?["credential"],
        json!({"kind":"keyless"})
    );
    Ok(())
}
#[test]
fn no_credential_is_interop_and_invalid_selected_endpoints_never_resolve() -> TestResult {
    assert_eq!(
        target("", context(), json!({}))?["credential"]["kind"],
        "interop"
    );
    for endpoint in [
        "file:///private",
        "https://user:private@fixture.invalid",
        "https://fixture.invalid/#fragment",
        "https://${HOST}/v1",
    ] {
        assert!(
            target(
                &format!("[providers.custom]\napi='{endpoint}'"),
                context(),
                json!({})
            )
            .is_err()
        );
    }
    Ok(())
}
fn host() -> Result<(Host, Value), Box<dyn std::error::Error>> {
    let mut host = Host::new();
    host.dispatch("initialize",json!({"protocol_major":1,"protocol_minor":0,"client_version":"test","capabilities":[],"limits":{"max_frame_bytes":1048576}}),true).result.map_err(|_|"initialize")?;
    host.dispatch("initialized", json!({}), false)
        .result
        .map_err(|_| "initialized")?;
    let app = host
        .dispatch("application/create", json!({}), true)
        .result
        .map_err(|_| "application")?;
    let scope = host
        .dispatch("session/create", app, true)
        .result
        .map_err(|_| "session")?;
    Ok((host, scope))
}
fn call(
    host: &mut Host,
    scope: &Value,
    method: &str,
    args: Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    host.dispatch(method, json!({"scope":scope,"arguments":args}), true)
        .result
        .map_err(|fault| format!("config rpc {method}: {}", fault.status).into())
}
fn prepare(
    host: &mut Host,
    scope: &Value,
    generation: u64,
    source: &str,
) -> Result<Value, Box<dyn std::error::Error>> {
    call(
        host,
        scope,
        "configuration/prepare",
        json!({"generation":generation,"path":"/synthetic/config","digest":"a".repeat(64),"document":document(source)?,"registry":[]}),
    )
}
#[test]
fn staged_config_has_one_native_writer_and_obsolete_tickets_cannot_commit() -> TestResult {
    let (mut host, scope) = host()?;
    let first = prepare(&mut host, &scope, 1, "provider='old'")?;
    assert!(!first.to_string().contains("provider='old'"));
    let second = prepare(&mut host, &scope, 2, "provider='new'")?;
    assert!(
        call(
            &mut host,
            &scope,
            "configuration/commit",
            json!({"capture_id":first["capture_id"],"context":context()})
        )
        .is_err()
    );
    let committed = call(
        &mut host,
        &scope,
        "configuration/commit",
        json!({"capture_id":second["capture_id"],"context":context()}),
    )?;
    assert_eq!(committed["revision"], 1);
    assert_eq!(committed["default"]["provider"], "new");
    assert!(prepare(&mut host, &scope, 1, "provider='old'").is_err());
    let resolved = call(
        &mut host,
        &scope,
        "configuration/resolve",
        json!({"revision":1,"target":{}}),
    )?;
    assert_eq!(resolved["provider"], "new");
    assert!(
        call(
            &mut host,
            &scope,
            "configuration/resolve",
            json!({"revision":0,"target":{}})
        )
        .is_err()
    );
    let third = prepare(&mut host, &scope, 3, "provider='new'")?;
    assert_eq!(
        call(
            &mut host,
            &scope,
            "configuration/commit",
            json!({"capture_id":third["capture_id"],"context":context()})
        )?["revision"],
        1
    );
    assert!(
        call(
            &mut host,
            &scope,
            "configuration/commit",
            json!({"capture_id":third["capture_id"],"context":context()})
        )
        .is_err()
    );
    Ok(())
}
#[test]
fn foreign_session_and_revocation_cannot_publish_a_staged_configuration() -> TestResult {
    let (mut host, scope) = host()?;
    let prepared = prepare(&mut host, &scope, 1, "provider='private'")?;
    let other = host
        .dispatch(
            "session/create",
            json!({"application_id":scope["application_id"]}),
            true,
        )
        .result
        .map_err(|_| "other session")?;
    assert!(
        call(
            &mut host,
            &other,
            "configuration/commit",
            json!({"capture_id":prepared["capture_id"],"context":context()})
        )
        .is_err()
    );
    call(
        &mut host,
        &scope,
        "configuration/abort",
        json!({"capture_id":prepared["capture_id"]}),
    )?;
    assert!(
        call(
            &mut host,
            &scope,
            "configuration/commit",
            json!({"capture_id":prepared["capture_id"],"context":context()})
        )
        .is_err()
    );
    let prepared = prepare(&mut host, &scope, 2, "provider='private'")?;
    host.dispatch("session/close", scope.clone(), true)
        .result
        .map_err(|_| "close")?;
    assert!(
        call(
            &mut host,
            &scope,
            "configuration/commit",
            json!({"capture_id":prepared["capture_id"],"context":context()})
        )
        .is_err()
    );
    Ok(())
}
