//! Exact model pricing/capacity contracts; no editor or network dependency.

use kargu_core::models::{
    ContextCapacity, InputTokenRate, NumericError, OutputCapacity, OutputTokenRate,
};
use serde_json::Value;

type TestResult = Result<(), Box<dyn std::error::Error>>;

#[test]
fn exact_prices_keep_sub_micro_values_and_normalize_only_trailing_zeroes() -> TestResult {
    for (source, expected) in [
        ("0", "0"),
        ("0.0000", "0"),
        (" 0.0000001 ", "0.0000001"),
        ("1e-38", "0.00000000000000000000000000000000000001"),
        ("1.2500", "1.25"),
        ("125e-2", "1.25"),
        ("1e3", "1000"),
        (
            "0.000000000000000000123456789012345678",
            "0.000000000000000000123456789012345678",
        ),
        (
            "340282366920938463463374607431768211455",
            "340282366920938463463374607431768211455",
        ),
    ] {
        let input: InputTokenRate = source.parse()?;
        let output: OutputTokenRate = source.parse()?;
        assert_eq!(input.to_string(), expected);
        assert_eq!(output.to_string(), expected);
        assert_eq!(input.is_zero(), expected == "0");
        assert_eq!(output.is_zero(), expected == "0");
        assert_eq!(
            serde_json::to_value(&input)?,
            Value::String(expected.to_owned())
        );
    }
    Ok(())
}

#[test]
fn invalid_price_text_never_becomes_a_free_model() {
    for source in [
        "", " ", "invalid9", "9invalid", "NaN", "Infinity", "-0", "-1", "+1", "1e", "1e1e1", ".5",
        "1.", "1,2", "0x0", "1 2",
    ] {
        assert_eq!(source.parse::<InputTokenRate>(), Err(NumericError::Syntax));
        assert_eq!(source.parse::<OutputTokenRate>(), Err(NumericError::Syntax));
    }
}

#[test]
fn unsupported_precision_and_overflow_are_errors_not_underflow_or_saturation() {
    for source in ["1e-39", "0e-39", "1e39", "1e-30000"] {
        assert_eq!(
            source.parse::<InputTokenRate>(),
            Err(NumericError::Precision)
        );
    }
    for source in ["340282366920938463463374607431768211456", "4e38"] {
        assert_eq!(source.parse::<InputTokenRate>(), Err(NumericError::Range));
    }
    assert_eq!(
        "0".repeat(129).parse::<InputTokenRate>(),
        Err(NumericError::Range)
    );
}

#[test]
fn capacity_parse_accepts_only_exact_positive_integral_quantities() -> TestResult {
    for (source, expected) in [
        ("128000", 128000),
        ("1.0", 1),
        ("2e3", 2000),
        ("18446744073709551615", u64::MAX),
    ] {
        assert_eq!(source.parse::<ContextCapacity>()?.get(), expected);
        assert_eq!(source.parse::<OutputCapacity>()?.get(), expected);
    }
    for source in ["0", "0.0", "1.5", "1e-1"] {
        assert_eq!(
            source.parse::<ContextCapacity>(),
            Err(NumericError::Capacity)
        );
        assert_eq!(
            source.parse::<OutputCapacity>(),
            Err(NumericError::Capacity)
        );
    }
    assert_eq!(
        "18446744073709551616".parse::<ContextCapacity>(),
        Err(NumericError::Range)
    );
    assert_eq!(ContextCapacity::try_from(0), Err(NumericError::Capacity));
    assert_eq!(OutputCapacity::try_from(0), Err(NumericError::Capacity));
    Ok(())
}

#[test]
fn json_prices_preserve_the_source_number_before_domain_parsing() -> TestResult {
    #[derive(serde::Deserialize, serde::Serialize)]
    struct Source {
        price: Box<serde_json::value::RawValue>,
        context: Box<serde_json::value::RawValue>,
    }
    let source =
        r#"{"price":0.000000000000000000123456789012345678,"context":18446744073709551615}"#;
    let value: Source = serde_json::from_str(source)?;
    let price = value.price.get();
    assert_eq!(price, "0.000000000000000000123456789012345678");
    assert_eq!(price.parse::<InputTokenRate>()?.to_string(), price);
    let context = value.context.get();
    assert_eq!(context.parse::<ContextCapacity>()?.get(), u64::MAX);
    let encoded = serde_json::to_string(&value)?;
    let again: Source = serde_json::from_str(&encoded)?;
    assert_eq!(again.price.get(), value.price.get());
    assert_eq!(again.context.get(), value.context.get());
    Ok(())
}

#[test]
fn domain_serde_cannot_bypass_numeric_constructors() -> TestResult {
    assert!(serde_json::from_str::<ContextCapacity>("0").is_err());
    assert!(serde_json::from_str::<OutputCapacity>("1.5").is_err());
    assert!(serde_json::from_str::<InputTokenRate>(r#""invalid9""#).is_err());
    assert!(serde_json::from_str::<InputTokenRate>("0.1").is_err());
    let rate: InputTokenRate = serde_json::from_str(r#""0.0000001""#)?;
    assert!(!rate.is_zero());
    assert_eq!(serde_json::to_string(&rate)?, r#""0.0000001""#);
    Ok(())
}
