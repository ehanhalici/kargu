//! Native replacements for the former Elisp wire/cache engine contracts.

use kargu_core::{
    api::{
        ApiError, HttpRequest, ModelId, cache,
        wire::{WireCodec, WireSpec},
    },
    providers::{ApiEndpoint, ApiProviderId},
};
use serde_json::{Value, json};
type TestResult = Result<(), Box<dyn std::error::Error>>;

fn spec() -> Result<Value, serde_json::Error> {
    let catalog: Value = serde_json::from_str(include_str!("../assets/providers.json"))?;
    Ok(catalog["formats"]["anthropic"].clone())
}
fn codec(
    model: &str,
    provider: &str,
    endpoint: &str,
) -> Result<WireCodec, Box<dyn std::error::Error>> {
    Ok(WireSpec::try_from(spec()?)?.bind(
        &ApiEndpoint::try_from(endpoint.to_owned())?,
        Some(&ModelId::try_from(model.to_owned())?),
        Some(&ApiProviderId::try_from(provider.to_owned())?),
    )?)
}
fn native_response() -> Value {
    json!({"type":"message","stop_reason":"tool_use","content":[
        {"type":"thinking","thinking":"private thought","signature":"opaque-signature"},
        {"type":"redacted_thinking","data":"opaque-redaction"},
        {"type":"text","text":"hello"},
        {"type":"tool_use","id":"c1","name":"read","input":{"path":"a"}}],
        "usage":{"input_tokens":100,"output_tokens":1,"cache_read_input_tokens":80,"cache_creation_input_tokens":20}})
}

#[test]
fn blocks_encode_system_tools_results_grouping_and_copy_keys() -> TestResult {
    let spec = WireSpec::try_from(spec()?)?;
    let body = spec.encode(json!({"model":"claude","messages":[
        {"role":"system","content":"be brief"},{"role":"user","content":"hi"},
        {"role":"assistant","content":"inspect","tool_calls":[{"id":"c1","function":{"name":"read","arguments":"{\"path\":\"a\"}"}}]},
        {"role":"tool","tool_call_id":"c1","content":"result"},{"role":"user","content":"continue"}],
        "tools":[{"type":"function","function":{"name":"read","description":"Read","parameters":{"type":"object"}}}],
        "temperature":0,"thinking":{"type":"enabled","budget_tokens":1024},"unsupported":"not forwarded"}))?;
    assert_eq!(body["system"], json!([{"type":"text","text":"be brief"}]));
    assert_eq!(body["max_tokens"], 4096);
    assert_eq!(body["temperature"], 0);
    assert_eq!(
        body["messages"][1]["content"][1],
        json!({"type":"tool_use","id":"c1","name":"read","input":{"path":"a"}})
    );
    assert_eq!(
        body["messages"][2]["content"],
        json!([
        {"type":"tool_result","tool_use_id":"c1","content":"result"},{"type":"text","text":"continue"}])
    );
    assert_eq!(body["tools"][0]["input_schema"], json!({"type":"object"}));
    assert!(body.get("unsupported").is_none());
    Ok(())
}

#[test]
fn blocks_response_usage_and_finish_are_native_without_zero_invention() -> TestResult {
    let wire = codec("claude", "anthropic", "https://localhost/messages")?;
    let normalized = wire.decode(native_response())?;
    assert_eq!(normalized["choices"][0]["message"]["content"], "hello");
    assert_eq!(normalized["choices"][0]["finish_reason"], "tool_calls");
    assert_eq!(
        normalized["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"],
        "{\"path\":\"a\"}"
    );
    assert_eq!(
        normalized["usage"],
        json!({"prompt_tokens":200,"completion_tokens":1,"prompt_tokens_details":{"cached_tokens":80,"cache_write_tokens":20}})
    );
    for (stop, finish) in [
        ("end_turn", "stop"),
        ("max_tokens", "length"),
        ("refusal", "content_filter"),
    ] {
        let result = wire.decode(json!({"stop_reason":stop,"content":[],"usage":{}}))?;
        assert_eq!(result["choices"][0]["finish_reason"], finish);
        assert_eq!(result["usage"], json!({}));
    }
    let absent = wire.decode(json!({"type":"message","content":[]}))?;
    assert!(absent.get("usage").is_none());
    for error in [Value::Null, json!(false)] {
        let normalized = wire.decode(json!({"type":"message","content":[],"error":error}))?;
        assert!(normalized.get("choices").is_some());
    }
    for invalid in [json!(-1), json!(0.5), json!("100")] {
        assert!(
            wire.decode(json!({"type":"message","content":[],"usage":{"input_tokens":invalid}}))
                .is_err()
        );
    }
    assert!(matches!(wire.decode(json!({"type":"message","content":[],"usage":{"input_tokens":u64::MAX,"cache_read_input_tokens":1}})), Err(ApiError::Limit)));
    Ok(())
}

#[test]
fn opaque_signatures_are_retained_only_for_exact_authority() -> TestResult {
    let wire = codec("claude", "anthropic", "https://localhost/messages")?;
    let response = wire.decode(native_response())?;
    let message = response["choices"][0]["message"].clone();
    let payload = json!({"model":"claude","messages":[message]});
    let encoded = wire.encode(payload.clone())?;
    assert_eq!(
        encoded["messages"][0]["content"][0]["signature"],
        "opaque-signature"
    );
    assert_eq!(
        encoded["messages"][0]["content"][1]["data"],
        "opaque-redaction"
    );
    assert!(!encoded.to_string().contains("_kargu_opaque_content"));
    for other in [
        codec("other-model", "anthropic", "https://localhost/messages")?,
        codec("claude", "custom", "https://localhost/messages")?,
        codec("claude", "anthropic", "https://localhost/other")?,
    ] {
        assert!(
            !other
                .encode(payload.clone())?
                .to_string()
                .contains("opaque-signature")
        );
    }
    let mut modified = spec()?;
    modified["max-tokens-default"] = json!(2048);
    let changed = WireSpec::try_from(modified)?.bind(
        &ApiEndpoint::try_from("https://localhost/messages".to_owned())?,
        Some(&ModelId::try_from("claude".to_owned())?),
        Some(&ApiProviderId::try_from("anthropic".to_owned())?),
    )?;
    assert!(
        !changed
            .encode(payload.clone())?
            .to_string()
            .contains("opaque-signature")
    );
    let compatible = WireSpec::default().bind(
        &ApiEndpoint::try_from("https://localhost/messages".to_owned())?,
        Some(&ModelId::try_from("claude".to_owned())?),
        None,
    )?;
    assert!(
        !compatible
            .encode(payload)?
            .to_string()
            .contains("_kargu_opaque_content")
    );
    Ok(())
}

#[test]
fn explicit_custom_rules_not_provider_name_control_wire() -> TestResult {
    let mut custom = spec()?;
    custom["blocks"][0]["type"] = json!("custom_text");
    custom["blocks"][0]["field"] = json!("value");
    custom["system-key"] = json!("instructions");
    custom["max-tokens-default"] = json!(512);
    let wire = WireSpec::try_from(custom)?;
    let payload = wire.encode(json!({"model":"local","messages":[{"role":"system","content":"s"},{"role":"user","content":"u"}]}))?;
    assert_eq!(
        payload["instructions"][0],
        json!({"type":"custom_text","value":"s"})
    );
    assert_eq!(
        payload["messages"][0]["content"][0],
        json!({"type":"custom_text","value":"u"})
    );
    assert_eq!(payload["max_tokens"], 512);
    // An unrelated provider body is never shape-guessed from the global catalog.
    assert_eq!(
        WireSpec::default().decode(native_response())?,
        native_response()
    );
    Ok(())
}

#[test]
fn malformed_rules_and_tool_arguments_fail_before_io() -> TestResult {
    for value in [
        json!({"message-shape":"invented"}),
        json!({"message-shape":"blocks"}),
        json!({"stream":"yes"}),
    ] {
        assert!(WireSpec::try_from(value).is_err());
    }
    let mut duplicate = spec()?;
    let block = duplicate["blocks"][0].clone();
    duplicate["blocks"]
        .as_array_mut()
        .ok_or("blocks")?
        .push(block);
    assert!(WireSpec::try_from(duplicate).is_err());
    let wire = WireSpec::try_from(spec()?)?;
    assert!(
        wire.encode(json!({"model":"claude","messages":[],"max_completion_tokens":10}))
            .is_err()
    );
    for arguments in [json!("[1]"), json!("{broken"), json!(false), json!([])] {
        assert!(wire.encode(json!({"model":"claude","messages":[{"role":"assistant","tool_calls":[{"id":"c1","function":{"name":"read","arguments":arguments}}]}]})).is_err());
    }
    let dto = json!({"url":"http://localhost/messages","method":"post","headers":{},"body":"{\"stream\":true}","stream":true,"wire":spec()?,"timeouts":{"connect_ms":1,"first_byte_ms":1,"idle_ms":null,"deadline_ms":null}});
    assert!(serde_json::from_value::<HttpRequest>(dto).is_err());
    Ok(())
}

#[test]
fn stable_cache_prefix_is_pure_and_runtime_is_not_marked() -> TestResult {
    let source = json!({"messages":[{"role":"system","content":"Instructions\n<runtime_environment>\nfile: a"},{"role":"user","content":"Question"}]});
    let mut first = source.clone();
    cache::prepare(&mut first)?;
    assert!(source["messages"][0]["content"].is_string());
    assert_eq!(
        first["messages"][0]["content"][0]["cache_control"],
        json!({"type":"ephemeral"})
    );
    assert!(
        first["messages"][0]["content"][1]
            .get("cache_control")
            .is_none()
    );
    assert!(first["messages"][0].get("cache_control").is_none());
    assert_eq!(first["messages"][1], source["messages"][1]);
    let mut second = json!({"messages":[{"role":"system","content":"Instructions\n<runtime_environment>\nfile: b"}]});
    cache::prepare(&mut second)?;
    assert_eq!(
        first["messages"][0]["content"][0],
        second["messages"][0]["content"][0]
    );
    Ok(())
}

#[test]
fn cache_boundary_uses_utf8_safe_checked_ranges_and_preserves_first_marker() -> TestResult {
    let stable = "Yönergeler 🦀\n";
    let runtime = "<runtime_environment>\ndosya: ğ\n<runtime_environment>\nsecond marker";
    let source = json!({"messages":[{"role":"system","content":format!("{stable}{runtime}")}]});
    let mut payload = source.clone();
    cache::prepare(&mut payload)?;
    let blocks = payload["messages"][0]["content"]
        .as_array()
        .ok_or("cache blocks")?;
    assert_eq!(blocks.len(), 2);
    let prefix = blocks.first().ok_or("stable block")?;
    let suffix = blocks.get(1).ok_or("runtime block")?;
    assert_eq!(prefix["text"], stable);
    assert_eq!(prefix["cache_control"], json!({"type":"ephemeral"}));
    assert_eq!(suffix["text"], runtime);
    assert!(suffix.get("cache_control").is_none());
    assert_eq!(
        source["messages"][0]["content"],
        format!("{stable}{runtime}")
    );
    for text in ["", "🦀 only", "<runtime_environment>\nno stable prefix"] {
        let mut payload = json!({"messages":[{"role":"system","content":text}]});
        cache::prepare(&mut payload)?;
        if text.is_empty() {
            assert_eq!(payload["messages"][0]["content"], text);
        } else {
            let blocks = payload["messages"][0]["content"]
                .as_array()
                .ok_or("whole block")?;
            assert_eq!(blocks.len(), 1);
            assert_eq!(blocks.first().ok_or("whole block")?["text"], text);
        }
    }
    Ok(())
}

#[test]
fn native_cache_boundaries_survive_tools_and_completed_tool_results() -> TestResult {
    let mut payload = json!({"model":"claude","messages":[{"role":"system","content":"Stable"},{"role":"user","content":"Question"},
        {"role":"assistant","content":"","tool_calls":[{"id":"c1","function":{"name":"read","arguments":"{}"}}]},
        {"role":"tool","tool_call_id":"c1","content":"Result"}],
        "tools":[{"type":"function","function":{"name":"first","parameters":{}}},{"type":"function","function":{"name":"read","parameters":{}}}]});
    cache::prepare(&mut payload)?;
    let body = WireSpec::try_from(spec()?)?.encode(payload)?;
    assert!(body["system"][0].get("cache_control").is_some());
    assert!(body["tools"][0].get("cache_control").is_none());
    assert!(body["tools"][1].get("cache_control").is_some());
    assert!(
        body["messages"][2]["content"][0]["content"][0]
            .get("cache_control")
            .is_some()
    );
    assert!(
        body["messages"][2]["content"][0]
            .get("cache_control")
            .is_none()
    );
    Ok(())
}

#[test]
fn cache_marks_completed_assistant_not_latest_human_or_empty_tools() -> TestResult {
    let mut payload = json!({"messages":[{"role":"system","content":"Stable"},{"role":"user","content":"one"},
        {"role":"assistant","content":"answer"},{"role":"user","content":"two"}],"tools":[]});
    cache::prepare(&mut payload)?;
    assert!(
        payload["messages"][2]["content"][0]
            .get("cache_control")
            .is_some()
    );
    assert_eq!(payload["messages"][3]["content"], "two");
    assert!(payload["messages"][2].get("cache_control").is_none());
    assert_eq!(payload["tools"], json!([]));
    for invalid in [json!({"messages":false}), json!({"tools":["invalid"]})] {
        assert!(cache::prepare(&mut invalid.clone()).is_err());
    }
    Ok(())
}
