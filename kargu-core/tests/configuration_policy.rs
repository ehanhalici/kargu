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

fn publish(
    host: &mut Host,
    scope: &Value,
    generation: u64,
    source: &str,
    context: Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    let ticket = prepare(host, scope, generation, source)?;
    call(
        host,
        scope,
        "configuration/commit",
        json!({"capture_id":ticket["capture_id"],"context":context}),
    )
}

#[test]
fn source_revision_ignores_other_sessions_choices_but_tracks_changed_credentials() -> TestResult {
    let (mut host, scope) = host()?;
    let first = publish(&mut host, &scope, 1, "provider='custom'", context())?;
    let mut changed = context();
    changed["selected_provider"] = json!("different");
    changed["selected_model"] = json!("Other/CaseSensitive");
    let second = publish(&mut host, &scope, 2, "provider='custom'", changed.clone())?;
    assert_eq!(first["revision"], second["revision"]);
    assert_eq!(second["default"]["provider"], "different");
    assert_eq!(second["fallback"]["provider"], "custom");
    changed["api_key"] = json!("changed-private");
    assert_eq!(
        publish(&mut host, &scope, 3, "provider='custom'", changed)?["revision"],
        2
    );
    Ok(())
}

#[test]
fn source_identity_frames_collection_boundaries_and_ignores_registry_order() -> TestResult {
    let (mut host, scope) = host()?;
    let mut captured = context();
    captured["registry"] =
        json!([{"id":"custom","models":["x","environment"],"env":["y"]},{"id":"other"}]);
    assert_eq!(
        publish(&mut host, &scope, 1, "", captured.clone())?["revision"],
        1
    );
    captured["registry"] =
        json!([{"id":"other"},{"id":"custom","models":["x","environment"],"env":["y"]}]);
    assert_eq!(
        publish(&mut host, &scope, 2, "", captured.clone())?["revision"],
        1
    );
    captured["registry"] =
        json!([{"id":"custom","models":["x"],"env":["environment","y"]},{"id":"other"}]);
    assert_eq!(publish(&mut host, &scope, 3, "", captured)?["revision"], 2);
    Ok(())
}

#[test]
fn transient_context_and_provider_selection_are_revision_bound_not_publications() -> TestResult {
    let (mut host, scope) = host()?;
    publish(
        &mut host,
        &scope,
        1,
        "provider='custom'\n[providers.custom]\nmodel='Configured/Case'",
        context(),
    )?;
    let mut transient = context();
    transient["api_key"] = json!("transient-private");
    let resolved = call(
        &mut host,
        &scope,
        "configuration/resolve",
        json!({"revision":1,"context":transient,"target":{}}),
    )?;
    assert_eq!(resolved["credential"]["secret"], "transient-private");
    let select = |provider: &str, no_model, batch| json!({"revision":1,"provider":provider,"no_model":no_model,"batch":batch,"cached_models":["Cached/Case"]});
    assert_eq!(
        call(
            &mut host,
            &scope,
            "configuration/select",
            select("custom", false, true)
        )?["model"],
        "Configured/Case"
    );
    assert_eq!(
        call(
            &mut host,
            &scope,
            "configuration/select",
            select("custom", true, true)
        )?["model"],
        Value::Null
    );
    assert_eq!(
        call(
            &mut host,
            &scope,
            "configuration/select",
            select("other", false, true)
        )?["model"],
        "Cached/Case"
    );
    assert_eq!(
        call(
            &mut host,
            &scope,
            "configuration/select",
            select("other", false, false)
        )?["model"],
        Value::Null
    );
    let snapshot = call(&mut host, &scope, "configuration/snapshot", json!({}))?;
    assert_eq!(snapshot["revision"], 1);
    assert_eq!(snapshot["default"]["credential"]["kind"], "interop");
    Ok(())
}

#[test]
fn invalid_model_identity_and_oversized_or_ambiguous_captures_fail_closed() -> TestResult {
    for model in [" ".to_owned(), "x".repeat(513), "unsafe\nmodel".to_owned()] {
        assert!(target("", context(), json!({"model":model})).is_err());
    }
    // Explicit empty is reserved for catalog connection preparation.
    assert_eq!(target("", context(), json!({"model":""}))?["model"], "");
    assert!(
        serde_json::from_value::<ConfigurationDocument>(
            json!({"providers":[{"name":"Custom","data":{}},{"name":"custom","data":{}}]})
        )
        .is_err()
    );
    let mut oversized = context();
    oversized["environment"] = json!({"A":"x".repeat(65537)});
    assert!(serde_json::from_value::<PolicyContext>(oversized).is_err());
    let malformed = "${".repeat(12000);
    assert_eq!(
        target(
            &format!("[providers.custom]\napikey='{malformed}'"),
            context(),
            json!({})
        )?["credential"]["secret"],
        malformed
    );
    Ok(())
}
