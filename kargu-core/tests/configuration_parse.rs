//! Pure strict configuration schema, ordering, legacy import and redaction.

use kargu_core::{application::host::Host, configuration::ParseInput};
use serde_json::{Value, json};
type TestResult = Result<(), Box<dyn std::error::Error>>;
fn parse(source: &str) -> Result<Value, serde_json::Error> {
    Ok(
        serde_json::from_value::<ParseInput>(json!({"source":source,"generation":u64::MAX}))?
            .resolve(),
    )
}

#[test]
fn supported_strings_arrays_and_provider_order_match_editor_contract() -> TestResult {
    let value = parse(
        "provider = '302ai'\nreview_mode = 'blocking'\n[providers.z]\napikey = ''\n[providers.302ai]\napi = 'https://fixture.invalid/v1/?tenant=a%2Fb/'\n[providers.\"my.proxy\"]\nmodels = [\n'a]#b', # comment\n'\\literal',\n\"\\u00e7\\U0001F642\",\n]\n",
    )?;
    assert_eq!(value["status"], "ok");
    assert_eq!(value["generation"], u64::MAX);
    assert_eq!(value["config"]["provider"], "302ai");
    assert_eq!(value["config"]["review-mode"], "blocking");
    assert_eq!(value["config"]["providers"][0]["name"], "z");
    assert_eq!(value["config"]["providers"][0]["data"]["apikey"], "");
    assert_eq!(value["config"]["providers"][1]["name"], "302ai");
    assert_eq!(
        value["config"]["providers"][2]["data"]["models"],
        json!(["a]#b", "\\literal", "ç🙂"])
    );
    Ok(())
}

#[test]
fn strict_schema_never_returns_partial_data_or_parser_source() -> TestResult {
    for source in [
        "[other]\nx = 'synthetic-secret'",
        "model = 42",
        "provider = true",
        "model = {id = 'm'}",
        "model = \"\"\"multiline\"\"\"",
        "model = 'm' garbage",
        "model = \"unterminated",
        "model = \"bad\\q\"",
        "model = \"bad\\uD800\"",
        "model = 'a'\nmodel = 'b'",
        "review_mode = 'unknown'",
        "[providers.a]\nmodels = ['a' 'b']",
        "[providers.a]\nmodels = ['a', 2]",
        "[providers.a]\nmodels = ['a'",
        "[providers.a]\nunknown = 'synthetic-secret'",
        "[provider.a]\n[providers.a]",
        "[providers.a]\nmodels=['''multiline''']",
        "providers = { a = {api = 'http://fixture.invalid'} }",
    ] {
        let value = parse(source)?;
        assert_eq!(value["status"], "invalid", "accepted unsupported schema");
        assert!(value.get("config").is_none());
        assert!(value["line"].as_u64().is_some_and(|line| line > 0));
        assert!(!value.to_string().contains("synthetic-secret"));
    }
    Ok(())
}

#[test]
fn legacy_fallback_alias_and_empty_fields_are_preserved() -> TestResult {
    let legacy = parse("api='http://fixture.invalid'\napikey=''\nname='legacy'\n")?;
    assert_eq!(legacy["config"]["model"], "legacy");
    assert_eq!(
        legacy["config"]["providers"][0],
        json!({"name":"default","data":{"api":"http://fixture.invalid","apikey":"","models":["legacy"]}})
    );
    let alias = parse("provider='z'\n[provider.z]\nmodel='z'\n[providers.a]\nmodels=[]")?;
    assert_eq!(alias["config"]["provider"], "z");
    assert_eq!(alias["config"]["providers"][0]["name"], "z");
    assert_eq!(alias["config"]["providers"][1]["data"]["models"], json!([]));
    let empty = parse("provider=''\nmodel=''\nname='fallback'\n[providers.empty]\n")?;
    assert_eq!(empty["config"]["provider"], Value::Null);
    assert_eq!(empty["config"]["model"], "fallback");
    assert_eq!(
        empty["config"]["providers"][0]["data"]["models"],
        json!([""])
    );
    assert_eq!(parse("")?["config"]["providers"], json!([]));
    Ok(())
}

#[test]
fn input_bounds_and_digest_are_deterministic() -> TestResult {
    let source = "provider='a'";
    let first = parse(source)?;
    assert_eq!(first, parse(source)?);
    assert_ne!(first["digest"], parse("provider='b'")?["digest"]);
    assert!(parse(&" ".repeat(65537)).is_err());
    for value in [json!(-1), json!(1.5), json!("2"), Value::Null] {
        assert!(
            serde_json::from_value::<ParseInput>(json!({"source":"","generation":value})).is_err()
        );
    }
    assert!(
        serde_json::from_value::<ParseInput>(
            json!({"source":"","generation":0,"extra":"synthetic-secret"})
        )
        .is_err()
    );
    Ok(())
}

#[test]
fn host_requires_ready_epoch_and_correlation_without_creating_an_application() -> TestResult {
    let mut host = Host::new();
    assert!(
        host.dispatch("configuration/parse", json!({}), true)
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
    assert!(
        init["capabilities"]
            .as_array()
            .is_some_and(|caps| caps.contains(&json!("configuration_parse")))
    );
    let args = json!({"connection_epoch":init["connection_epoch"],"arguments":{"source":"provider='a'","generation":7}});
    assert!(
        host.dispatch("configuration/parse", args.clone(), true)
            .result
            .is_err()
    );
    host.dispatch("initialized", json!({}), false)
        .result
        .map_err(|_| "ready failed")?;
    assert!(
        host.dispatch("configuration/parse", args.clone(), false)
            .result
            .is_err()
    );
    assert_eq!(
        host.dispatch("configuration/parse", args.clone(), true)
            .result
            .map_err(|_| "parse failed")?["config"]["provider"],
        "a"
    );
    let mut foreign = args;
    foreign["connection_epoch"] = json!("foreign-epoch");
    let fault = host
        .dispatch("configuration/parse", foreign, true)
        .result
        .err()
        .ok_or("accepted foreign epoch")?;
    assert_eq!(fault.status, "stale_owner");
    assert!(host.dispatch("ping", json!({}), true).result.is_ok());
    Ok(())
}
