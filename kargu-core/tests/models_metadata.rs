//! Exact normalization fixtures before migration of the editor store consumer.

use kargu_core::models::metadata::{EffortSpecs, MetadataError, ModelMetadata};
use serde_json::{Value, json};
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn fields(source: &str) -> Result<Value, Box<dyn std::error::Error>> {
    Ok(serde_json::to_value(
        ModelMetadata::parse(source, &EffortSpecs::default())?.fields(),
    )?)
}
fn declared() -> Result<EffortSpecs, serde_json::Error> {
    serde_json::from_value(json!([
        {"path":["reasoning","supported_efforts"],"type":"list"},
        {"path":["options","values"],"type":"csv"}
    ]))
}

#[test]
fn missing_invalid_zero_and_positive_prices_are_four_distinct_observations() -> TestResult {
    assert_eq!(
        fields("{}")?.get("input_cost"),
        Some(&json!({"state":"missing"}))
    );
    for invalid in [
        "invalid9", "NaN", "Infinity", "-1", "1e-39", "1.5 USD", "1e999",
    ] {
        let source = json!({"pricing":{"prompt":invalid}}).to_string();
        let parsed = ModelMetadata::parse(&source, &EffortSpecs::default())?;
        assert!(!parsed.fields().input_is_zero());
        assert_eq!(
            serde_json::to_value(parsed.fields())?.get("input_cost"),
            Some(&json!({"state":"invalid"})),
            "{invalid}"
        );
    }
    for source in [
        r#"{"pricing":{"prompt":0}}"#,
        r#"{"input-cost":"0.000e-3"}"#,
    ] {
        let parsed = ModelMetadata::parse(source, &EffortSpecs::default())?;
        assert!(parsed.fields().input_is_zero());
        assert_eq!(
            serde_json::to_value(parsed.fields())?.get("input_cost"),
            Some(&json!({"state":"known","value":"0"}))
        );
    }
    assert_eq!(
        fields(r#"{"pricing":{"prompt":1e-38}}"#)?.get("input_cost"),
        Some(&json!({"state":"known","value":"0.00000000000000000000000000000000000001"}))
    );
    Ok(())
}

#[test]
fn numeric_capacities_never_round_an_intermediate_float() -> TestResult {
    for source in [
        r#"{"context_length":1.5}"#,
        r#"{"context_length":9007199254740992.5}"#,
        r#"{"context_length":0}"#,
        r#"{"context_length":-1}"#,
        r#"{"context_length":"32k"}"#,
    ] {
        assert_eq!(
            fields(source)?.get("context_window"),
            Some(&json!({"state":"invalid"}))
        );
    }
    assert_eq!(
        fields(r#"{"context_length":18446744073709551615}"#)?.get("context_window"),
        Some(&json!({"state":"known","value":u64::MAX}))
    );
    let raw = ModelMetadata::parse(r#"{"context_length":9007199254740992.5,"top_provider":[{"max_completion_tokens":9007199254740992.5}],"pricing":[{"prompt":1e-38}]}"#, &EffortSpecs::default())?.raw_snapshot()?;
    assert_eq!(
        raw.get("context_length"),
        Some(&json!("9007199254740992.5"))
    );
    assert_eq!(
        raw.pointer("/top_provider/0/max_completion_tokens"),
        Some(&json!("9007199254740992.5"))
    );
    assert_eq!(raw.pointer("/pricing/0/prompt"), Some(&json!("1e-38")));
    assert_eq!(
        fields(r#"{"inputTokenLimit":"2e3","outputTokenLimit":1024.0}"#)?.get("max_output"),
        Some(&json!({"state":"known","value":1024}))
    );
    for key in [
        "context_length",
        "context_window",
        "inputTokenLimit",
        "context-window",
    ] {
        assert_eq!(
            fields(&json!({key:100}).to_string())?.get("context_window"),
            Some(&json!({"state":"known","value":100}))
        );
    }
    for source in [
        r#"{"top_provider":{"max_completion_tokens":100}}"#,
        r#"{"top_provider":[{"max_completion_tokens":100}]}"#,
    ] {
        assert_eq!(
            fields(source)?.get("max_output"),
            Some(&json!({"state":"known","value":100}))
        );
    }
    Ok(())
}

#[test]
fn exact_input_output_and_cache_rates_do_not_imply_all_components_are_free() -> TestResult {
    let parsed = ModelMetadata::parse(
        r#"{"pricing":{"prompt":0,"completion":0.00000012345678901234567890123456789,"input_cache_read":1e-38,"input_cache_write":"invalid9"}}"#,
        &EffortSpecs::default(),
    )?;
    assert!(parsed.fields().input_is_zero());
    let fields = serde_json::to_value(parsed.fields())?;
    assert_eq!(fields.get("free"), Some(&json!({"state":"missing"})));
    assert_eq!(
        fields.get("output_cost"),
        Some(&json!({"state":"known","value":"0.00000012345678901234567890123456789"}))
    );
    assert_eq!(
        fields.get("cache_write_cost"),
        Some(&json!({"state":"invalid"}))
    );
    assert_eq!(
        parsed.raw_snapshot()?.pointer("/pricing/completion"),
        Some(&json!("0.00000012345678901234567890123456789"))
    );
    Ok(())
}

#[test]
fn tools_preserve_absence_null_false_and_nonempty_parameters() -> TestResult {
    for source in [
        "{}",
        r#"{"supports_tools":null}"#,
        r#"{"supported_parameters":[]}"#,
        r#"{"supported_parameters":["tools"]}"#,
    ] {
        assert!(
            ModelMetadata::parse(source, &EffortSpecs::default())?
                .fields()
                .allows_tools()
        );
    }
    for source in [
        r#"{"supports_tools":false}"#,
        r#"{"supports-tools":"false"}"#,
        r#"{"supportedParameters":["temperature"]}"#,
    ] {
        assert!(
            !ModelMetadata::parse(source, &EffortSpecs::default())?
                .fields()
                .allows_tools()
        );
    }
    assert_eq!(
        fields(r#"{"supports_tools":{}}"#)?.get("supports_tools"),
        Some(&json!({"state":"invalid"}))
    );
    assert_eq!(
        fields(r#"{"supported_parameters":["tools",3]}"#)?.get("supported_parameters"),
        Some(&json!({"state":"invalid"}))
    );
    Ok(())
}

#[test]
fn efforts_follow_only_declared_paths_in_order_and_explicit_disable_wins() -> TestResult {
    let specs = declared()?;
    let source = r#"{"reasoning":[{"supported_efforts":["low","high"]}],"options":{"values":"minimal, medium, high"}}"#;
    let parsed = ModelMetadata::parse(source, &specs)?;
    assert!(parsed.fields().allows_reasoning());
    assert_eq!(
        serde_json::to_value(parsed.fields())?.get("reasoning_efforts"),
        Some(&json!({"state":"known","value":["low","high"]}))
    );
    assert!(
        !ModelMetadata::parse(source, &EffortSpecs::default())?
            .fields()
            .allows_reasoning()
    );
    let csv = ModelMetadata::parse(
        r#"{"reasoning":{"supported_efforts":"not a list"},"options":{"values":" minimal, , high "}}"#,
        &specs,
    )?;
    assert_eq!(
        serde_json::to_value(csv.fields())?.get("reasoning_efforts"),
        Some(&json!({"state":"known","value":["minimal","high"]}))
    );
    for source in [
        r#"{"supports_reasoning":false,"reasoning-efforts":["high"]}"#,
        r#"{"supports-reasoning":"false","reasoning":{"supported_efforts":["low"]}}"#,
    ] {
        let parsed = ModelMetadata::parse(source, &specs)?;
        assert!(!parsed.fields().allows_reasoning());
        assert_eq!(
            serde_json::to_value(parsed.fields())?.get("reasoning_efforts"),
            Some(&json!({"state":"known","value":[]}))
        );
    }
    assert!(
        ModelMetadata::parse(r#"{"supports-reasoning":true}"#, &specs)?
            .fields()
            .allows_reasoning()
    );
    let duplicate = ModelMetadata::parse(
        r#"{"reasoning":{"supported_efforts":["low"],"supported_efforts":["high"]}}"#,
        &specs,
    )?;
    assert!(!duplicate.fields().allows_reasoning());
    assert_eq!(
        serde_json::to_value(duplicate.fields())?.get("reasoning_efforts"),
        Some(&json!({"state":"invalid"}))
    );
    Ok(())
}

#[test]
fn vision_and_parameter_labels_come_from_metadata_not_model_names() -> TestResult {
    assert_eq!(
        fields(r#"{"id":"vision-free-reasoner-128k"}"#)?.get("vision"),
        Some(&json!({"state":"missing"}))
    );
    let fields = fields(
        r#"{"architecture":{"modality":"text+image->text"},"details":{"parameter_size":"8B","quantization_level":"Q4"}}"#,
    )?;
    assert_eq!(
        fields.get("vision"),
        Some(&json!({"state":"known","value":true}))
    );
    assert_eq!(
        fields.get("params"),
        Some(&json!({"state":"known","value":"8B Q4"}))
    );
    Ok(())
}

#[test]
fn duplicate_semantic_keys_and_unbounded_declarations_are_not_accepted() -> TestResult {
    for source in [
        r#"{"context_length":1,"context_length":2}"#,
        r#"{"pricing":{"prompt":0,"prompt":1}}"#,
        r#"{"top_provider":{"max_completion_tokens":1,"max_completion_tokens":2}}"#,
    ] {
        assert!(matches!(
            ModelMetadata::parse(source, &EffortSpecs::default()),
            Err(MetadataError::Shape)
        ));
    }
    for specs in [
        json!([{"path":[],"type":"list"}]),
        json!([{"path":["x"],"type":"eval"}]),
        json!(vec![json!({"path":["x"],"type":"list"}); 33]),
    ] {
        assert!(serde_json::from_value::<EffortSpecs>(specs).is_err());
    }
    Ok(())
}
