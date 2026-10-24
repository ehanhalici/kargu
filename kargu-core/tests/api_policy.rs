//! Port of test-parameters.el and reasoning/conditional-fixture contracts.

use kargu_core::api::{
    HttpRequest,
    policy::{DefaultsPatch, ReasoningShape, RequestTuning},
};
use serde_json::{Value, json};
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn apply(
    tuning: Value,
    format: Value,
    shape: ReasoningShape,
    payload: Value,
) -> Result<Value, Box<dyn std::error::Error>> {
    let tuning: RequestTuning = serde_json::from_value(tuning)?;
    let defaults: DefaultsPatch = serde_json::from_value(format)?;
    Ok(tuning.apply(payload, &defaults, shape)?)
}
fn fields(tuning: Value) -> Result<Value, Box<dyn std::error::Error>> {
    apply(tuning, json!({}), ReasoningShape::Effort, json!({}))
}

#[test]
fn captured_provider_defaults_and_explicit_null_override_shared_format() -> TestResult {
    assert_eq!(
        fields(json!({"temperature":0,"max_tokens":1234}))?,
        json!({"temperature":0.0,"max_tokens":1234})
    );
    assert_eq!(
        fields(
            json!({"temperature":0.2,"max_tokens":1234,"provider_policy":{"max-output-key":"max_completion_tokens","sampling-parameters":null}})
        )?,
        json!({"max_completion_tokens":1234})
    );
    assert_eq!(fields(json!({}))?, json!({}));
    let result = apply(
        json!({"temperature":0.2,"max_tokens":42,"provider_policy":{"sampling-parameters":null}}),
        json!({"max-output-key":"max_completion_tokens","sampling-parameters":["temperature"]}),
        ReasoningShape::Effort,
        json!({}),
    )?;
    assert_eq!(result, json!({"max_completion_tokens":42}));
    Ok(())
}

#[test]
fn exact_declared_capabilities_override_defaults_and_choose_one_alias() -> TestResult {
    assert_eq!(
        fields(
            json!({"temperature":0.2,"max_tokens":500,"supported_parameters":["max_completion_tokens"]})
        )?,
        json!({"max_completion_tokens":500})
    );
    assert_eq!(
        fields(
            json!({"temperature":0.4,"max_tokens":600,"supported_parameters":["max_tokens","temperature"],"provider_policy":{"max-output-key":"max_completion_tokens","sampling-parameters":null}})
        )?,
        json!({"temperature":0.4,"max_tokens":600})
    );
    for preferred in ["max_tokens", "max_completion_tokens"] {
        assert_eq!(
            fields(
                json!({"max_tokens":123,"supported_parameters":["max_tokens","max_completion_tokens"],"provider_policy":{"max-output-key":preferred}})
            )?,
            json!({preferred:123})
        );
    }
    assert!(
        fields(json!({"max_tokens":100,"supported_parameters":["temperature","tools"]})).is_err()
    );
    assert_eq!(
        fields(json!({"temperature":0.3,"supported_parameters":["temperature","tools"]}))?,
        json!({"temperature":0.3})
    );
    assert_eq!(
        fields(
            json!({"max_tokens":10,"supported_parameters":[],"provider_policy":{"max-output-key":"max_completion_tokens"}})
        )?,
        json!({"max_completion_tokens":10})
    );
    assert_eq!(
        fields(
            json!({"max_tokens":10,"supported_parameters":["max_completion_tokens"],"provider_policy":{"max-output-key":null}})
        )?,
        json!({"max_completion_tokens":10})
    );
    assert!(fields(json!({"max_tokens":10,"provider_policy":{"max-output-key":null}})).is_err());
    Ok(())
}

#[test]
fn invalid_settings_are_rejected_before_network_not_silently_ignored() -> TestResult {
    for limit in [json!(0), json!(-1), json!(2.5), json!("100")] {
        assert!(serde_json::from_value::<RequestTuning>(json!({"max_tokens":limit})).is_err());
    }
    for temperature in [json!(-0.1), json!(2.1), json!("0.2")] {
        assert!(
            serde_json::from_value::<RequestTuning>(json!({"temperature":temperature})).is_err()
        );
    }
    assert!(fields(json!({"max_tokens":10,"provider_policy":{"max-output-key":"typo"}})).is_err());
    assert!(fields(json!({"provider_policy":{"unknown":true}})).is_err());
    assert!(fields(json!({"supported_parameters":vec!["x";129]})).is_err());
    assert!(fields(json!({"effort":"too\nlong"})).is_err());
    let dto = json!({"url":"http://localhost:1/chat/completions","method":"post","headers":{},"body":"{}","stream":false,
        "tuning":{"max_tokens":0},"timeouts":{"connect_ms":1,"first_byte_ms":1,"idle_ms":null,"deadline_ms":null}});
    assert!(serde_json::from_value::<HttpRequest>(dto).is_err());
    Ok(())
}

#[test]
fn conditional_temperature_rule_uses_explicit_reasoning_not_model_regexes() -> TestResult {
    for (effort, temperature) in [
        ("off", true),
        ("none", false),
        ("high", false),
        ("", true),
        ("nil", true),
    ] {
        let result = fields(
            json!({"temperature":0.5,"effort":effort,"provider_policy":{"reasoning-disallows-temperature":true}}),
        )?;
        assert_eq!(result.get("temperature").is_some(), temperature);
    }
    assert_eq!(
        fields(json!({"effort":"none"}))?,
        json!({"reasoning_effort":"none"})
    );
    assert_eq!(fields(json!({"effort":"off"}))?, json!({}));
    Ok(())
}

#[test]
fn reasoning_shape_preserves_none_off_and_budget_without_universal_clamps() -> TestResult {
    assert_eq!(
        apply(
            json!({"effort":"none"}),
            json!({}),
            ReasoningShape::Nested,
            json!({})
        )?,
        json!({"reasoning":{"effort":"none"}})
    );
    assert_eq!(
        apply(
            json!({"effort":"off","thinking_budget":4096}),
            json!({}),
            ReasoningShape::Effort,
            json!({})
        )?,
        json!({})
    );
    assert_eq!(
        apply(
            json!({"effort":"off","thinking_budget":4096}),
            json!({}),
            ReasoningShape::Nested,
            json!({})
        )?,
        json!({"reasoning":{"max_tokens":4096}})
    );
    assert_eq!(
        apply(
            json!({"effort":"off","thinking_budget":4096}),
            json!({}),
            ReasoningShape::Thinking,
            json!({})
        )?,
        json!({"thinking":{"type":"enabled","budget_tokens":4096}})
    );
    assert_eq!(
        apply(
            json!({"thinking_budget":17}),
            json!({}),
            ReasoningShape::Thinking,
            json!({})
        )?,
        json!({"thinking":{"type":"enabled","budget_tokens":17}})
    );
    Ok(())
}

#[test]
fn explicit_extras_replace_values_but_cannot_reintroduce_cap_conflicts() -> TestResult {
    for payload in [
        json!({"max_tokens":0}),
        json!({"max_completion_tokens":-1}),
        json!({"temperature":"0.2"}),
        json!({"temperature":2.1}),
    ] {
        assert!(apply(json!({}), json!({}), ReasoningShape::Effort, payload).is_err());
    }
    assert!(
        apply(
            json!({"supported_parameters":["tools"]}),
            json!({}),
            ReasoningShape::Effort,
            json!({"max_tokens":100})
        )
        .is_err()
    );
    assert!(
        apply(
            json!({"effort":"none","provider_policy":{"reasoning-disallows-temperature":true}}),
            json!({}),
            ReasoningShape::Effort,
            json!({"temperature":0.2})
        )
        .is_err()
    );
    assert_eq!(
        apply(
            json!({"temperature":0.5,"max_tokens":100}),
            json!({}),
            ReasoningShape::Effort,
            json!({"temperature":0.25,"max_tokens":200})
        )?,
        json!({"temperature":0.25,"max_tokens":200})
    );
    assert!(
        apply(
            json!({"max_tokens":100,"provider_policy":{"max-output-key":"max_completion_tokens"}}),
            json!({}),
            ReasoningShape::Effort,
            json!({"max_tokens":200})
        )
        .is_err()
    );
    assert!(
        apply(
            json!({}),
            json!({}),
            ReasoningShape::Effort,
            json!({"max_tokens":100,"max_completion_tokens":100})
        )
        .is_err()
    );
    Ok(())
}
