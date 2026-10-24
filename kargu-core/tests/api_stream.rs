//! Former Elisp SSE/pressure contracts, now exercised at their Rust owner.

use kargu_core::api::{
    ApiError,
    stream::{StreamDecoder, StreamLimits},
};
use serde_json::{Value, json};
type TestResult = Result<(), Box<dyn std::error::Error>>;
fn decode(body: &str) -> Result<Value, ApiError> {
    let mut decoder = StreamDecoder::new(StreamLimits::default());
    decoder.feed(body.as_bytes())?;
    Ok(decoder.finish()?.1)
}
fn event(delta: Value) -> String {
    format!("data: {}\n\n", json!({"choices":[{"delta":delta}]}))
}

#[test]
fn every_utf8_byte_boundary_comments_crlf_and_multiline_data_are_preserved() -> TestResult {
    let text = "Merhaba dünya 🦀🚀🤖";
    let body = format!(
        ": keepalive\r\nevent: message\r\ndata: {{\"choices\":\r\ndata: [{{\"delta\":{{\"content\":\"{text}\"}}}}]}}\r\n\r\ndata: [DONE]"
    );
    let expected = decode(&body)?;
    for split in 0..=body.len() {
        let mut decoder = StreamDecoder::new(StreamLimits::default());
        decoder.feed(body.as_bytes().get(..split).ok_or("split prefix")?)?;
        decoder.feed(body.as_bytes().get(split..).ok_or("split suffix")?)?;
        assert_eq!(decoder.finish()?.1, expected);
    }
    let mut decoder = StreamDecoder::new(StreamLimits::default());
    for byte in body.as_bytes() {
        decoder.feed(std::slice::from_ref(byte))?;
    }
    assert_eq!(
        decoder.finish()?.1["choices"][0]["message"]["content"],
        text
    );
    Ok(())
}

#[test]
fn completion_is_required_and_error_cannot_be_revived() -> TestResult {
    let partial = event(
        json!({"content":"partial","tool_calls":[{"index":0,"function":{"name":"bash","arguments":"{}"}}]}),
    );
    assert!(matches!(decode(&partial), Err(ApiError::Incomplete)));
    for invalid in [
        "data: {broken\n\ndata: [DONE]\n\n",
        "event: error\ndata: {\"message\":\"secret upstream text\"}\n\ndata: [DONE]\n\n",
    ] {
        let mut decoder = StreamDecoder::new(StreamLimits::default());
        assert!(decoder.feed(invalid.as_bytes()).is_err());
        assert!(decoder.feed(b"data: [DONE]\n\n").is_err());
        assert!(decoder.finish().is_err());
    }
    for terminal in [
        "data: [DONE]\n\n",
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n",
    ] {
        let body = format!(
            "{}{terminal}{}data: {{\"usage\":{{\"completion_tokens\":7}}}}\n\n",
            event(json!({"content":"kept"})),
            event(json!({"content":"late ignored"}))
        );
        let response = decode(&body)?;
        assert_eq!(response["choices"][0]["message"]["content"], "kept");
        assert_eq!(response["usage"]["completion_tokens"], 7);
    }
    Ok(())
}

#[test]
fn tool_fragment_order_identity_snapshots_legacy_and_reasoning_are_preserved() -> TestResult {
    let mut body = event(
        json!({"reasoning_details":[{"summary":[{"text":"Think"}]}],"content":[{"output_text":"Hello"}],
        "tool_calls":[{"index":"2","id":"two","function":{"name":"b","arguments":"{"}}, {"index":0,"id":"zero","function":{"name":"a","arguments":"{}"}}]}),
    );
    body.push_str(&event(json!({"tool_calls":[{"index":0,"function":{"name":"","arguments":{"x":1}}},{"index":2,"function":{"name":"","arguments":"\"y\":2}"}}]})));
    body.push_str("data: [DONE]\n\n");
    let response = decode(&body)?;
    let message = &response["choices"][0]["message"];
    assert_eq!(message["reasoning_content"], "Think");
    assert_eq!(message["content"], "Hello");
    assert_eq!(message["tool_calls"][0]["id"], "zero");
    assert_eq!(
        message["tool_calls"][0]["function"]["arguments"],
        "{\"x\":1}"
    );
    assert_eq!(message["tool_calls"][1]["id"], "two");
    assert_eq!(message["tool_calls"][0]["function"]["name"], "a");
    assert_eq!(message["tool_calls"][1]["function"]["name"], "b");
    let conflicting = format!(
        "{}{}data: [DONE]\n\n",
        event(json!({"tool_calls":[{"index":0,"id":"a"}]})),
        event(json!({"tool_calls":[{"index":0,"id":"b"}]}))
    );
    assert!(decode(&conflicting).is_err());
    for index in [json!(null), json!(-1), json!(1.5), json!("invalid")] {
        let invalid = format!(
            "{}data: [DONE]\n\n",
            event(json!({"tool_calls":[{"index":index}]}))
        );
        assert!(decode(&invalid).is_err());
    }
    let legacy = format!(
        "{}data: [DONE]\n\n",
        event(json!({"function_call":{"name":"old","arguments":"{}"}}))
    );
    assert_eq!(
        decode(&legacy)?["choices"][0]["message"]["tool_calls"][0]["function"]["name"],
        "old"
    );
    Ok(())
}

#[test]
fn independent_bounds_reject_before_success_and_only_lowering_is_allowed() -> TestResult {
    for policy in [
        json!({"raw_bytes":0}),
        json!({"raw_bytes":4*1024*1024+1}),
        json!({"line_bytes":65537}),
        json!({"tool_calls":65}),
    ] {
        assert!(serde_json::from_value::<StreamLimits>(policy).is_err());
    }
    let cases = [
        (
            json!({"line_bytes":16}),
            "data: ".to_owned() + &"x".repeat(17),
        ),
        (
            json!({"event_bytes":8}),
            "data: 1234\ndata: 5678\n\n".to_owned(),
        ),
        (json!({"raw_bytes":16}), ": ping\n".repeat(3)),
        (
            json!({"tool_calls":1}),
            event(json!({"tool_calls":[{"index":0},{"index":1}]})),
        ),
        (
            json!({"argument_bytes":2}),
            event(json!({"tool_calls":[{"index":0,"function":{"arguments":"123"}}]})),
        ),
    ];
    for (policy, body) in cases {
        let mut decoder = StreamDecoder::new(serde_json::from_value(policy)?);
        assert!(matches!(
            decoder.feed(body.as_bytes()),
            Err(ApiError::Limit)
        ));
        assert!(decoder.finish().is_err());
    }
    assert!(decode("data: {\"choices\":[]}\n\n").is_err());
    assert!(
        StreamDecoder::new(StreamLimits::default())
            .feed(b"data: \xff\n\n")
            .is_err()
    );
    Ok(())
}
