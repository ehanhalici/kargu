//! Provider discovery normalization, numeric preservation and bounded failures.

use kargu_core::{
    constants::limits,
    models::{
        catalog::{CatalogError, ModelCatalog},
        metadata::{EffortSpecs, ModelMetadata},
    },
};
use serde_json::{Value, json};
type TestResult = Result<(), Box<dyn std::error::Error>>;

#[test]
fn all_declared_envelopes_share_one_ordered_canonical_projection() -> TestResult {
    for source in [
        r#"{"data":[{"id":"a"},{"id":"b"}]}"#,
        r#"{"models":[{"id":"a"},{"id":"b"}]}"#,
        r#"{"items":[{"id":"a"},{"id":"b"}]}"#,
        r#"[{"id":"a"},{"id":"b"}]"#,
        r#"["a","b"]"#,
    ] {
        assert_eq!(
            ModelCatalog::try_from(source)?.into_snapshot(),
            json!({"models":[{"id":"a"},{"id":"b"}]})
        );
    }
    Ok(())
}

#[test]
fn explicit_empty_is_success_but_missing_null_invalid_or_error_is_not() -> TestResult {
    for source in [
        "[]",
        r#"{"data":[]}"#,
        r#"{"models":[],"error":null}"#,
        r#"{"items":[],"error":false}"#,
    ] {
        assert_eq!(
            ModelCatalog::try_from(source)?.into_snapshot(),
            json!({"models":[]})
        );
    }
    for source in [
        "null",
        "false",
        "{}",
        "",
        "  ",
        r#"{"data":null}"#,
        r#"{"data":{},"models":[]}"#,
        r#"{"data":"bad"}"#,
        r#"{"data":[],"error":"synthetic secret"}"#,
        r#"{"data":[],"error":{}}"#,
        "[42]",
        "[null]",
        "[[]]",
    ] {
        assert!(ModelCatalog::try_from(source).is_err(), "accepted {source}");
    }
    Ok(())
}

#[test]
fn model_ids_keep_case_and_namespace_while_explicit_google_prefix_is_removed() -> TestResult {
    let result = ModelCatalog::try_from(
        r#"{"models":[{"name":"models/Gemini/Model","description":"🦀"},"vendor/Model","model"]}"#,
    )?
    .into_snapshot();
    assert_eq!(result.pointer("/models/0/id"), Some(&json!("Gemini/Model")));
    assert_eq!(
        result.pointer("/models/0/name"),
        Some(&json!("models/Gemini/Model"))
    );
    assert_eq!(result.pointer("/models/0/description"), Some(&json!("🦀")));
    assert_eq!(result.pointer("/models/1/id"), Some(&json!("vendor/Model")));
    assert_eq!(result.pointer("/models/2/id"), Some(&json!("model")));
    for source in [
        r#"[{}]"#,
        r#"[""]"#,
        r#"["models/"]"#,
        r#"["a\nb"]"#,
        r#"[{"id":null,"name":"fallback"}]"#,
        r#"[{"id":4}]"#,
    ] {
        assert!(ModelCatalog::try_from(source).is_err());
    }
    Ok(())
}

#[test]
fn prices_are_not_rounded_by_an_intermediate_json_number() -> TestResult {
    let result = ModelCatalog::try_from(r#"[{"id":"precise","input-cost":0.000000000000000000123456789012345678,"pricing":{"prompt":1e-38,"completion":0,"cache_read":0.0000001,"request":"invalid9"},"supports_tools":false}]"#)?.into_snapshot();
    assert_eq!(
        result.pointer("/models/0/input-cost"),
        Some(&json!("0.000000000000000000123456789012345678"))
    );
    assert_eq!(
        result.pointer("/models/0/pricing/prompt"),
        Some(&json!("1e-38"))
    );
    assert_eq!(
        result.pointer("/models/0/pricing/completion"),
        Some(&json!("0"))
    );
    assert_eq!(
        result.pointer("/models/0/pricing/cache_read"),
        Some(&json!("0.0000001"))
    );
    // Invalid raw metadata is not "fixed" into free by this envelope boundary.
    // Typed rate normalization, not this projection, decides validity.
    assert_eq!(
        result.pointer("/models/0/pricing/request"),
        Some(&json!("invalid9"))
    );
    assert_eq!(
        result.pointer("/models/0/supports_tools"),
        Some(&Value::Bool(false))
    );
    Ok(())
}

#[test]
fn canonical_catalog_round_trip_preserves_every_capacity_alias_before_normalization() -> TestResult
{
    for (keys, field) in [
        (
            vec![
                "context_length",
                "context_window",
                "inputTokenLimit",
                "context-window",
            ],
            "context_window",
        ),
        (
            vec![
                "max_output",
                "outputTokenLimit",
                "max_completion_tokens",
                "max-output",
            ],
            "max_output",
        ),
    ] {
        for key in keys {
            for (literal, expected, state) in [
                ("9007199254740992.5", json!("9007199254740992.5"), "invalid"),
                (
                    "18446744073709551616",
                    json!("18446744073709551616"),
                    "invalid",
                ),
                ("1e999", json!("1e999"), "invalid"),
                ("-1", json!("-1"), "invalid"),
                ("2e3", json!("2e3"), "known"),
                ("1024.0", json!("1024.0"), "known"),
                ("18446744073709551615", json!(u64::MAX), "known"),
            ] {
                let source = format!(r#"[{{"id":"m","{key}":{literal}}}]"#);
                let snapshot = ModelCatalog::try_from(source.as_str())?.into_snapshot();
                let record = snapshot.pointer("/models/0").ok_or("missing record")?;
                assert_eq!(record.get(key), Some(&expected), "{key}: {literal}");
                let normalized =
                    ModelMetadata::parse(&record.to_string(), &EffortSpecs::default())?;
                let fields = serde_json::to_value(normalized.fields())?;
                assert_eq!(
                    fields.pointer(&format!("/{field}/state")),
                    Some(&json!(state))
                );
            }
        }
    }
    Ok(())
}

#[test]
fn nested_wrappers_share_the_exact_metadata_boundary() -> TestResult {
    for wrapper in [false, true] {
        let top = r#"{"max_completion_tokens":9007199254740992.5}"#;
        let price = r#"{"prompt":1e-38}"#;
        let (top, price) = if wrapper {
            (format!("[{top}]"), format!("[{price}]"))
        } else {
            (top.to_owned(), price.to_owned())
        };
        let source = format!(r#"[{{"id":"m","top_provider":{top},"pricing":{price}}}]"#);
        let snapshot = ModelCatalog::try_from(source.as_str())?.into_snapshot();
        let record = snapshot.pointer("/models/0").ok_or("missing record")?;
        let normalized = ModelMetadata::parse(&record.to_string(), &EffortSpecs::default())?;
        let fields = serde_json::to_value(normalized.fields())?;
        assert_eq!(fields.pointer("/max_output/state"), Some(&json!("invalid")));
        assert_eq!(
            fields.pointer("/input_cost/value"),
            Some(&json!("0.00000000000000000000000000000000000001"))
        );
    }
    Ok(())
}

#[test]
fn duplicate_control_keys_are_rejected_before_publication() {
    for source in [
        r#"{"data":[],"data":["a"]}"#,
        r#"[{"id":"a","id":"b"}]"#,
        r#"[{"id":"a","pricing":{"prompt":0,"prompt":1}}]"#,
        r#"[{"id":"a","pricing":[{"prompt":0,"prompt":1}]}]"#,
        r#"[{"id":"a","top_provider":{"max_completion_tokens":1,"max_completion_tokens":2}}]"#,
        r#"[{"id":"a","top_provider":[{"max_completion_tokens":1,"max_completion_tokens":2}]}]"#,
    ] {
        assert!(matches!(
            ModelCatalog::try_from(source),
            Err(CatalogError::Shape)
        ));
    }
}

#[test]
fn record_and_raw_byte_bounds_are_explicit_failures_not_truncated_empty_catalogs() -> TestResult {
    let models = vec!["model"; limits::MODEL_CATALOG_RECORDS];
    let source = serde_json::to_string(&models)?;
    let result = ModelCatalog::try_from(source.as_str())?.into_snapshot();
    assert_eq!(
        result.get("models").and_then(Value::as_array).map(Vec::len),
        Some(limits::MODEL_CATALOG_RECORDS)
    );
    let too_many = serde_json::to_string(&vec![
        "model";
        limits::MODEL_CATALOG_RECORDS.saturating_add(1)
    ])?;
    assert!(matches!(
        ModelCatalog::try_from(too_many.as_str()),
        Err(CatalogError::Limit)
    ));
    let too_large = " ".repeat(limits::MODEL_CATALOG_BYTES.saturating_add(1));
    assert!(matches!(
        ModelCatalog::try_from(too_large.as_str()),
        Err(CatalogError::Limit)
    ));
    Ok(())
}
